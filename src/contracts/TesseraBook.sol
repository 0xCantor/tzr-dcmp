// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IBookManager} from '../interfaces/IBookManager.sol';
import {ITesseraBook} from '../interfaces/ITesseraBook.sol';
import {ITesseraEngine} from '../interfaces/ITesseraEngine.sol';

// TODO: round UP where the original does (exact-out walk, fee gross-up); SafeERC20 in rescueTokens;
//       OpenZeppelin ReentrancyGuard instead of the inline flag.

/// @notice The book: one proxy per pair delegates here (see `TesseraBookProxy`). Prices trades, never moves tokens.
contract TesseraBook is ITesseraBook {
  /*////////////////////////////////////////////////////////////
                            CONSTANTS
  ////////////////////////////////////////////////////////////*/

  uint256 public constant MAX_BOOK_LEVELS = 20;
  uint256 internal constant PPM = 1e6;
  uint256 internal constant WAD = 1e18;

  /// @dev One slot per ladder is always reserved for the terminator.
  uint256 internal constant MAX_LEVELS_PER_UPDATE = MAX_BOOK_LEVELS - 1;

  /// @dev Exact-out walks return this when the book cannot deliver the requested output
  ///      (the original swap turns it into "T8: Insufficient Liquidity"). Exact-in returns 0 for the same case.
  uint256 internal constant NOT_FILLABLE = type(uint256).max;

  /// @dev What the age-fee calculation returns for "this quote is too old, do not fill" (original: uint32.max).
  uint256 internal constant NO_FILL = type(uint32).max;

  /// @dev Iterations of the gas burner run at the end of every successful swap (original 0x41e3, called from sell AND buy).
  uint256 internal constant SWAP_GAS_BURN_ITERATIONS = 1000;

  /// @dev Iterations of the gas burner run when the sender or tx.origin is labelled Penalized (original: inline in
  ///      all four copies of the fee function, so previews pay it too).
  uint256 internal constant PENALIZED_GAS_BURN_ITERATIONS = 500;

  /// @dev XOR key that obfuscates the `setDefaultFee` argument.
  uint96 internal constant DEFAULT_FEE_KEY = 0xdeadbeefdeadbeefdeadbeef;

  /*////////////////////////////////////////////////////////////
                             STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @dev Written by the PROXY (raw 32-byte word in slot 0), read here.
  Quote public quote;
  OrderBook internal clob;

  /// @notice Total INPUT the book received on the bid side (base units) since the last book update.
  uint256 public baseFlowAccumulator;
  /// @notice Total INPUT the book received on the ask side (quote units) since the last book update.
  uint256 public quoteFlowAccumulator;

  address public bookManager;
  bool public tradingEnabled;
  bool public nettingEnabled;
  uint8 public excludedBestLevels;

  uint8 public baseDecimals;
  uint8 public quoteDecimals;

  address public baseToken;
  address public quoteToken;

  /// @notice Share (ppm) of every trade's INPUT that is added to the flow accumulators: accumulator += input * factor / 1e6.
  /// @dev Raw storage is a uint32, capped at 1e6 by the config setters.
  uint24 public factor;

  address public multiSigOwner; // may only withdraw stray funds
  bool public isInitialized;

  address public operator; // updates the book and the default fee; tunes the config (NOT the quote: see the proxy)
  uint32 public defaultFee; // ppm. Set by the operator, flipped within the block (see setDefaultFee).

  // ── fee parameters ──
  uint24 public baseFee; // flat component, ppm
  QuoteFreshness public quoteFreshness;
  uint32 public addressFee; // charged to penalized addresses and fingerprint matches
  bool public whitelistOnly; // if true, ONLY default-exempt callers can trade
  uint32 public priorityMultiplierPpm; // threshold = reference priority fee * this / 1e6
  uint32 public priorityFee; // surcharge for trades above that threshold
  address public fingerprintHelper; // answers "does this (origin, sender) look like a known pattern?"
  address public modeFeeHelper; // maps the mode byte to a fee

  /// @dev OZ-style reentrancy flag (1 = free, 2 = entered).
  uint256 private reentrancyStatus = 1;

  modifier nonReentrant() {
    require(reentrancyStatus != 2, 'reentrancy');
    reentrancyStatus = 2;
    _;
    reentrancyStatus = 1;
  }

  modifier onlyOperator() {
    if (msg.sender != operator) revert NotOperator();
    _;
  }

  modifier onlyMultiSig() {
    if (msg.sender != multiSigOwner) revert NotMultiSig();
    _;
  }

  /// @dev The operator OR the book manager can pause and resume trading.
  modifier onlyTradingController() {
    if (msg.sender != operator && msg.sender != bookManager) revert NotTradingController();
    _;
  }

  /*////////////////////////////////////////////////////////////
                       EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Top-of-book price. Ask: rounded UP, bid: rounded DOWN, i.e. both roundings favour the book.
  function bestPrice(bool _isBid)
    public
    view
    returns (bool _ok, uint128 _price, uint128 _anchor, uint40 _refBlock, uint8 _tag)
  {
    Quote memory _q = quote;
    _anchor = _q.priceAnchor;
    _refBlock = _q.refBlock;
    _tag = _q.tag;

    if (_isBid) {
      if (_q.spreadPpm >= PPM) return (false, 0, _anchor, _refBlock, _tag);
      _price = uint128(uint256(_anchor) * (PPM - _q.spreadPpm) / PPM);
    } else {
      uint256 _ask = (uint256(_anchor) * (PPM + _q.spreadPpm) + (PPM - 1)) / PPM;
      if (_ask > type(uint128).max) revert PriceOverflow();
      _price = uint128(_ask);
    }
    _ok = true;
  }

  function askSide() external view returns (BookLevel[20] memory) {
    return clob.asks;
  }

  function bidSide() external view returns (BookLevel[20] memory) {
    return clob.bids;
  }

  /// @notice Gross output (before fees) for selling `_amountIn` into the book; 0 if the book cannot absorb it.
  /// @param _takeBidSide true: taker pays base, receives quote, trades against `bids`.
  ///                     false: taker pays quote, receives base, trades against `asks`.
  function bookWalkExactIn(bool _takeBidSide, uint256 _amountIn) public view returns (uint256 _grossOutput) {
    if (!tradingEnabled) revert TradingDisabled();
    if (!IBookManager(bookManager).isActive()) revert BookManagerInactive();

    (
      bool _ok,
      BookLevel[MAX_BOOK_LEVELS] storage _side,
      uint256 _bestBookPrice,
      uint256 _netDepletion,
      uint256 _excludedLevels
    ) = _loadSide(_takeBidSide);
    if (!_ok) return 0;

    uint256 _remainingInput = _amountIn;
    uint64 _prevMul = type(uint64).max;
    bool _isConsumed = true; // true until we meet the first level that still has liquidity left

    for (uint256 _i; _i < MAX_BOOK_LEVELS; ++_i) {
      BookLevel memory _level = side(_side, _i); // 1 SLOAD

      if (_level.endOfBook) break;
      if (_i < _excludedLevels) continue; // hidden by the operator: not tradable, not counted against net depletion

      uint256 _availableLiquidity = _level.liquidity;

      if (_isConsumed) {
        if (_netDepletion >= _availableLiquidity) {
          _netDepletion -= _availableLiquidity; // level completely used up: skip it
          continue;
        }
        // First level with liquidity left: only the part above the remaining depletion is open.
        _availableLiquidity -= _netDepletion;
        _isConsumed = false;
      }

      // Levels must get strictly worse down the book. Enforced when READING, not when the book is written.
      if (_level.multiplier >= _prevMul) revert MultipliersNotStrictlyDecreasing();
      _prevMul = _level.multiplier;

      // Two floor divisions, in this order (matters for exact parity with the contract).
      uint256 _levelPrice = _bestBookPrice * _level.multiplier / PPM;

      if (_remainingInput < _availableLiquidity) {
        // The order ends inside this level: partial fill, done.
        _grossOutput += _remainingInput * _levelPrice / WAD;
        _remainingInput = 0;
        break;
      }

      // The whole open part of the level is taken, move on to the next, worse level.
      // (When this exactly empties the order the loop still visits one more level, so a bad multiplier there reverts.)
      _grossOutput += _availableLiquidity * _levelPrice / WAD;
      _remainingInput -= _availableLiquidity;
    }

    if (_remainingInput != 0) return 0; // not enough depth
  }

  /// @notice Input needed to receive `_grossAmountOut` from the book, or NOT_FILLABLE if the book is too shallow.
  /// @dev Mirror image of bookWalkExactIn: same levels, same prices, same netting; the loop budget is now the
  ///      OUTPUT still wanted, and the function accumulates the INPUT that pays for it.
  /// @dev `_grossAmountOut` is the amount BEFORE fees. The original grosses the net amount up first
  ///      (`ceil(netOut * 1e6 / (1e6 - fee))`, 0x3c41) and only then walks the book.
  ///      TODO: fee gross-up lives in the caller (buy / previewBuy), not here.
  /// @param _takeBidSide same meaning as in bookWalkExactIn.
  function bookWalkExactOut(bool _takeBidSide, uint256 _grossAmountOut) public view returns (uint256 _amountIn) {
    if (!tradingEnabled) revert TradingDisabled();
    if (!IBookManager(bookManager).isActive()) revert BookManagerInactive();

    (
      bool _ok,
      BookLevel[MAX_BOOK_LEVELS] storage _side,
      uint256 _bestBookPrice,
      uint256 _netDepletion,
      uint256 _excludedLevels
    ) = _loadSide(_takeBidSide);
    if (!_ok) return NOT_FILLABLE;

    uint256 _remainingOutput = _grossAmountOut;
    uint64 _prevMul = type(uint64).max;
    bool _isConsumed = true;

    for (uint256 _i; _i < MAX_BOOK_LEVELS; ++_i) {
      BookLevel memory _level = side(_side, _i); // 1 SLOAD

      if (_level.endOfBook) break;
      if (_i < _excludedLevels) continue;

      uint256 _availableLiquidity = _level.liquidity; // in INPUT units, as always

      if (_isConsumed) {
        if (_netDepletion >= _availableLiquidity) {
          _netDepletion -= _availableLiquidity;
          continue;
        }
        _availableLiquidity -= _netDepletion;
        _isConsumed = false;
      }

      if (_level.multiplier >= _prevMul) revert MultipliersNotStrictlyDecreasing();
      _prevMul = _level.multiplier;

      uint256 _levelPrice = _bestBookPrice * _level.multiplier / PPM;

      // Most OUTPUT this level can still give us: all its open liquidity, priced at this level.
      uint256 _levelMaxOutput = _availableLiquidity * _levelPrice / WAD;

      if (_remainingOutput < _levelMaxOutput) {
        // The order ends inside this level: pay only for what we still need.
        // TODO: round UP (original: ceil, `(x + d - 1) / d`) so the book never undercharges.
        _amountIn += _remainingOutput * WAD / _levelPrice;
        _remainingOutput = 0;
        break;
      }

      // Take the whole open part of the level and keep going.
      // NOTE (quirk kept from the original): if _remainingOutput is already 0 here and a following level is so
      // small that _levelMaxOutput rounds to 0, this branch still charges that level's full liquidity.
      _amountIn += _availableLiquidity;
      _remainingOutput -= _levelMaxOutput;
    }

    if (_remainingOutput != 0) return NOT_FILLABLE; // not enough depth
  }

  // What the original previews (0x21523c7e / 0x43db5616) do differently from the swaps:
  //   - they take NO `data` argument, so there is no fee mode: previews carry no mode fee at all (not even what the
  //     helper returns for mode 0). A swap that passes a nonzero mode byte can therefore differ from its preview.
  //   - same gate as the swaps: only the book manager may call them (T17 / T16 / T4).
  //   - they never revert for "cannot fill": exact-in returns 0, exact-out returns NOT_FILLABLE (uint256.max).
  //     (They still revert for the checks above, for a blacklisted caller, and on a bad multiplier.)
  //   - no zero-amount check and no zero-result check.

  /// @notice Net output `sell` would give right now, or 0 if it cannot fill / the quote is expired.
  function previewSell(bool _takeBidSide, uint256 _amountIn, address _sender)
    external
    view
    returns (uint256 _netOutput)
  {
    _requireSwapAllowed();

    // Same order as the original: walk first, fee second (the fee check runs even if the walk found no depth).
    uint256 _grossOutput = bookWalkExactIn(_takeBidSide, _amountIn);

    (bool _rejected, uint256 _feePpm) = _computeFee(_sender, quote.refBlock, 0);
    if (_rejected) return 0; // quote expired

    _netOutput = _grossOutput * (PPM - _feePpm) / PPM;
  }

  /// @notice Input `buy` would charge right now for exactly `_amountOut`, or NOT_FILLABLE (uint256.max) if it cannot fill.
  /// @dev NOT_FILLABLE covers: no quote on this side, expired quote, fee that cannot be grossed up, too little depth.
  function previewBuy(bool _takeBidSide, uint256 _amountOut, address _sender)
    external
    view
    returns (uint256 _netInput)
  {
    _requireSwapAllowed();

    (bool _hasQuote,,, uint40 _refBlock,) = bestPrice(_takeBidSide);
    if (!_hasQuote) return NOT_FILLABLE; // (the fee is not even computed in this case)

    (bool _rejected, uint256 _feePpm) = _computeFee(_sender, _refBlock, 0);
    if (_rejected) return NOT_FILLABLE;

    uint256 _grossAmountOut = _grossUpForFee(_amountOut, _feePpm);
    if (_grossAmountOut == NOT_FILLABLE) return NOT_FILLABLE;

    _netInput = bookWalkExactOut(_takeBidSide, _grossAmountOut);
  }

  /// @notice Off-chain helper: builds the `_encoded` argument of setDefaultFee.
  function encodeDefaultFeeUpdate(uint32 _fee, uint64 _blockNumber) external pure returns (uint96) {
    uint96 _decoded = (uint96(_fee) << 64) | _blockNumber;
    return DEFAULT_FEE_KEY ^ ~_decoded;
  }

  /*////////////////////////////////////////////////////////////
                       EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice One-shot setup of a (proxy) book. Original 0x67107049.
  /// @dev NOT access controlled in the original: whoever calls first wins, so a proxy has to be initialized in the
  ///      same transaction that deploys it (the proxy constructor does). The default fee starts at 0 (it shares a
  ///      slot with the operator address).
  function initialize(
    address _multiSigOwner,
    address _bookManager,
    address _operator,
    address _baseToken,
    address _quoteToken,
    uint8 _baseDecimals,
    uint8 _quoteDecimals
  ) external {
    if (isInitialized) revert AlreadyInitialized();

    bookManager = _bookManager;
    baseToken = _baseToken;
    quoteToken = _quoteToken;
    baseDecimals = _baseDecimals;
    quoteDecimals = _quoteDecimals;
    operator = _operator;
    multiSigOwner = _multiSigOwner;

    tradingEnabled = true;
    isInitialized = true;
  }

  /// @notice Exact-input swap. Returns the NET output (after fees).
  /// @dev No token transfers happen here: the book only prices the trade and books it into the flow accumulators.
  ///      Settlement is up to the router (it pays from the treasury and pulls the input).
  /// @param _takeBidSide true: taker sells base into `bids`; false: taker sells quote into `asks`.
  /// @param _sender the contract that called the router (TesseraSwap's `msg.sender`), forwarded by the engine.
  ///        The fee uses it, together with tx.origin, for the address checks (paper, App. C.2).
  ///        It is NOT the token recipient: the book never sees that address.
  /// @param _data first byte = fee "mode" (0 if empty).
  function sell(bool _takeBidSide, uint256 _amountIn, address _sender, bytes calldata _data)
    external
    nonReentrant
    returns (uint256 _amountOut)
  {
    _requireSwapAllowed();
    if (_amountIn == 0) revert ZeroAmount();

    uint8 _mode = _feeMode(_data);

    // (the walk reads the quote again itself, as the original does)
    (bool _hasQuote,,, uint40 _refBlock, uint8 _tag) = bestPrice(_takeBidSide);
    if (!_hasQuote) revert NoQuote();

    uint256 _grossOutput = bookWalkExactIn(_takeBidSide, _amountIn);
    if (_grossOutput == 0) revert InsufficientLiquidity();

    (bool _rejected, uint256 _feePpm) = _computeFee(_sender, _refBlock, _modeFee(_mode));
    if (_rejected) revert QuoteRejected();

    // Fee is taken from the OUTPUT, after the book walk: Y_exec = Y_book * (1 - fee).
    _amountOut = _grossOutput * (PPM - _feePpm) / PPM;
    if (_amountOut == 0) revert ZeroOutput();

    _recordSwap(_takeBidSide, _sender, _amountIn, _amountOut, _tag, _mode);
  }

  /// @notice Exact-output swap. Returns the input the taker has to pay for exactly `_amountOut` (net of fees).
  /// @dev Same as `sell`, except the order of the steps: the fee is computed FIRST, the wanted output is grossed up
  ///      so that it is still `_amountOut` after the fee, and only then is the book walked backwards.
  function buy(bool _takeBidSide, uint256 _amountOut, address _sender, bytes calldata _data)
    external
    nonReentrant
    returns (uint256 _amountIn)
  {
    _requireSwapAllowed();
    if (_amountOut == 0) revert ZeroAmount();

    uint8 _mode = _feeMode(_data);

    (bool _hasQuote,,, uint40 _refBlock, uint8 _tag) = bestPrice(_takeBidSide);
    if (!_hasQuote) revert NoQuote();

    (bool _rejected, uint256 _feePpm) = _computeFee(_sender, _refBlock, _modeFee(_mode));
    if (_rejected) revert QuoteRejected();

    uint256 _grossAmountOut = _grossUpForFee(_amountOut, _feePpm);
    if (_grossAmountOut == NOT_FILLABLE) revert FeeTooHigh();

    _amountIn = bookWalkExactOut(_takeBidSide, _grossAmountOut);
    if (_amountIn == NOT_FILLABLE) revert InsufficientLiquidity();
    if (_amountIn == 0) revert ZeroInput();

    _recordSwap(_takeBidSide, _sender, _amountIn, _amountOut, _tag, _mode);
  }

  /// @notice Replaces the whole book (both ladders) and starts the flow netting from scratch. Original 0xdba310cf
  ///         (~152k gas in the paper). It does NOT touch the quote: anchor / spread / refBlock / tag have their own,
  ///         cheaper raw-calldata path (~27k gas) in the proxy.
  /// @dev Steps, in the original order:
  ///        1. operator only
  ///        2. at most 19 levels per side (index 19 is reserved for the terminator)
  ///        3. zero both flow accumulators (a fresh book starts with nothing depleted)
  ///        4. write the bid levels, then a terminator
  ///        5. write the ask levels, then a terminator
  ///      Deliberately absent (as in the original): no check that multipliers decrease, that liquidity is non-zero,
  ///      or that the input levels do not carry `endOfBook = true`. A bad book is only caught by the walk
  ///      (swaps / quotes revert), so the operator is trusted. Levels after the terminator are NOT cleared:
  ///      stale data stays in storage but is never read.
  function updateBook(BookUpdate calldata _book) external onlyOperator {
    if (_book.bids.length > MAX_LEVELS_PER_UPDATE || _book.asks.length > MAX_LEVELS_PER_UPDATE) {
      revert TooManyOrders();
    }

    baseFlowAccumulator = 0;
    quoteFlowAccumulator = 0;

    _writeLadder(clob.bids, _book.bids);
    _writeLadder(clob.asks, _book.asks);
  }

  /// @notice The operator's full parameter update. Original 0x75e8422f. Does not touch the accumulators or the ladders.
  function configure(BookConfig calldata _config) external onlyOperator {
    _checkLimits(_config.baseFee, _config.freshness.ageFeeCap, _config.factor);
    _storeConfig(_config);
    excludedBestLevels = _config.excludedBestLevels;
    fingerprintHelper = _config.fingerprintHelper;
  }

  /// @notice Book manager only. Original 0x209dab1e: the engine calls it right after deploying the book proxy.
  /// @dev Same checks and writes as `configure`, except `excludedBestLevels` and the fingerprint helper, plus: both
  ///      flow accumulators are RESET and the two tokens must be non-zero and different. The tokens and decimals
  ///      are not stored again (`initialize` did it), and `updaters` / `operator` are ignored here.
  ///      The middle fields of `ITesseraEngine.BookParams` are mapped from types, see there.
  function reconfigure(ITesseraEngine.BookParams calldata _params) external {
    if (!IBookManager(bookManager).isActive()) revert BookManagerInactive();
    if (msg.sender != bookManager) revert CallerNotBookManager();

    if (_params.baseToken == address(0) || _params.quoteToken == address(0) || _params.baseToken == _params.quoteToken)
    {
      revert InvalidAddresses();
    }
    _checkLimits(_params.baseFee, _params.ageFeeCap, _params.factor);

    baseFlowAccumulator = 0;
    quoteFlowAccumulator = 0;

    // `excludedBestLevels` and `fingerprintHelper` are not written by `_storeConfig`, so their values here are unused.
    _storeConfig(
      BookConfig({
        baseFee: uint24(_params.baseFee), // <= 1e6, fits
        factor: uint24(_params.factor),
        excludedBestLevels: excludedBestLevels,
        nettingEnabled: _params.nettingEnabled,
        freshness: QuoteFreshness({
          blocksExpiryAge: _params.blocksExpiryAge,
          blocksGracePeriod: _params.blocksGracePeriod,
          quadraticCoeff: _params.quadraticCoeff,
          ageFeeCap: _params.ageFeeCap
        }),
        addressFee: _params.addressFee,
        whitelistOnly: _params.whitelistOnly,
        priorityMultiplierPpm: _params.priorityMultiplierPpm,
        priorityFee: _params.priorityFee,
        fingerprintHelper: fingerprintHelper
      })
    );
  }

  /// @notice Sets the DEFAULT fee for the current block. Original 0x1667d875.
  /// @dev The argument is obfuscated and block-bound:  decoded = ~(KEY ^ encoded), a uint96 =
  ///        [ fee (32 bits) | block number (64 bits) ]
  ///      and the update only goes through if the block number inside it is the current one, so a late
  ///      transaction can never apply an old fee. The operator flips this at the start and the end of every block
  ///      (paper, Sec. 7.4 "spoofing"): a high fee while trades are executed, a low one at the end of the block,
  ///      which is the state aggregators read when they route.
  /// @dev On a wrong block: Dedaub shows a silent no-op, heimdall shows a bare revert (empty data). I chose revert
  ///      (matches a plain `require`). Check a failed 0x1667d875 transaction on BaseScan to settle it.
  function setDefaultFee(uint96 _encoded) external onlyOperator {
    uint96 _decoded = ~(DEFAULT_FEE_KEY ^ _encoded);
    if (uint64(block.number) != uint64(_decoded)) revert StaleDefaultFeeUpdate();
    defaultFee = uint32(_decoded >> 64);
  }

  /// @notice Operator sets the helper that prices the mode byte. Original 0x7bcffd54 (no zero-address check).
  function setModeFeeHelper(address _helper) external onlyOperator {
    modeFeeHelper = _helper;
  }

  function enableTrading() external onlyTradingController {
    tradingEnabled = true;
  }

  function disableTrading() external onlyTradingController {
    tradingEnabled = false;
  }

  /// @notice Multisig-only withdrawal of stray tokens. Original 0x2c88026b ("rescueTokensss1337").
  function rescueTokens(address[] calldata _tokens, uint256[] calldata _amounts, address _to) external onlyMultiSig {
    if (_tokens.length != _amounts.length) revert LengthMismatch();

    for (uint256 _i; _i < _tokens.length; ++_i) {
      // TODO: use OpenZeppelin's SafeERC20.
      (bool _ok, bytes memory _ret) = _tokens[_i].call(abi.encodeWithSelector(bytes4(0xa9059cbb), _to, _amounts[_i]));
      bool _success = _ok && (_ret.length == 0 ? _tokens[_i].code.length != 0 : abi.decode(_ret, (bool)));
      if (!_success) revert TransferFailed(_tokens[_i]);
    }
  }

  /// @notice Multisig-only withdrawal of native ETH. Original 0x8f05e71b ("rescueEthhh1337").
  function rescueEth(uint256 _amount, address _to) external onlyMultiSig {
    (bool _ok,) = _to.call{value: _amount}('');
    require(_ok);
  }

  /*////////////////////////////////////////////////////////////
                    PRIVATE / INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @dev Checks shared by both swaps AND both previews, in the original order. Only the BOOK MANAGER may call any of them.
  function _requireSwapAllowed() private view {
    if (!tradingEnabled) revert TradingDisabled(); // T17
    if (!IBookManager(bookManager).isActive()) revert BookManagerInactive(); // T16
    if (msg.sender != bookManager) revert CallerNotBookManager(); // T4
  }

  /// @dev Fee "mode" is the first byte of `data`; empty data means mode 0.
  function _feeMode(bytes calldata _data) private pure returns (uint8) {
    return _data.length == 0 ? 0 : uint8(_data[0]);
  }

  /// @dev Books the trade. Original order: event (with PRE-trade accumulators) -> accumulator update -> mode event.
  ///      Then a pure gas burner (see `_burnGas`) and only then the mode event.
  function _recordSwap(
    bool _takeBidSide,
    address _sender,
    uint256 _amountIn,
    uint256 _amountOut,
    uint8 _tag,
    uint8 _mode
  ) private {
    emit Swap(_sender, _amountIn, _amountOut, baseToken, quoteToken, _tag, baseFlowAccumulator, quoteFlowAccumulator);

    // The accumulator of the side that was HIT grows by the taker's INPUT (base on bids, quote on asks), scaled by
    // `factor`. This is the same unit the book walk subtracts from the levels (inferred, see the open questions).
    uint256 _flowDelta = _amountIn * factor / PPM;
    if (_takeBidSide) baseFlowAccumulator += _flowDelta;
    else quoteFlowAccumulator += _flowDelta;

    _burnGas(SWAP_GAS_BURN_ITERATIONS);

    if (_mode != 0) emit ModeUsed(_mode);
  }

  /// @dev Pure gas burner, no state change and no result (original: `0x41e3` with 1000 iterations, plus an identical
  ///      inline loop with 500 iterations on the penalized branch of the fee). Each iteration allocates a fresh
  ///      64-byte memory struct {word0 = 32, word1 = i} and never frees it, so the free pointer keeps growing and
  ///      memory expansion makes the cost super-linear (1000 iterations = ~64 KB). Rough cost: ~150-200k gas for 1000
  ///      iterations, ~70-100k for 500 (estimate from the opcode count, not measured).
  ///      PURPOSE (inferred, the paper does not mention it): a deliberate gas tax.
  ///        - On every successful swap it makes the book's own execution expensive, which is the reason a swap costs
  ///          ~200k+ gas while a quote update is ~27k. It raises the price of spamming the book and of probing it with
  ///          many cheap calls. Reverted swaps never reach it (it runs after all the checks).
  ///        - On a penalized address it adds a SECOND, gas-denominated penalty on top of the `addressFee`.
  ///          Because the fee function also backs the previews, a penalized caller pays it on previews too.
  ///      The allocation below is not byte-exact with the original (a 64-byte struct), only equivalent in effect.
  ///      NOTE: the optimizer may drop the allocation if the result is provably unused, check the compiled gas.
  function _burnGas(uint256 _iterations) private pure {
    for (uint256 _i; _i < _iterations; ++_i) {
      bytes memory _burned = abi.encode(uint256(32), _i);
      _burned; // silence the unused-variable warning
    }
  }

  /// @dev TODO: round UP. Original (0x3c41): `ceil(net * 1e6 / (1e6 - fee))`, skipped when fee == 0.
  /// @return NOT_FILLABLE when no amount can cover the fee (fee >= 100%) or the multiplication would overflow,
  ///         exactly like the original's sentinel. `buy` turns it into a revert, `previewBuy` returns it as is.
  function _grossUpForFee(uint256 _netAmountOut, uint256 _feePpm) private pure returns (uint256) {
    if (_feePpm == 0) return _netAmountOut;
    if (_feePpm >= PPM || _netAmountOut > type(uint256).max / PPM) return NOT_FILLABLE;
    return _netAmountOut * PPM / (PPM - _feePpm);
  }

  // The original contains ONE fee function, emitted four times (0x15bb, 0x2aa6, 0x34e5, 0x3786). The copies differ
  // only in whether the mode fee is part of the sum: swaps include it, previews do not.
  //
  //   fee (ppm) = mode + age + base + default + priority + address        capped at 1e6 (100%)
  //
  // It is taken from the OUTPUT, after the book walk: Y_exec = Y_book * (1 - fee).
  // (The original sums in checked uint32 arithmetic and panics on overflow; this one sums in uint256 and caps.)

  /// @param _sender the contract that called the router (NOT the token recipient). `tx.origin` is checked as well.
  /// @param _modeFeePpm pass `_modeFee(mode)` for swaps and 0 for previews.
  /// @return _rejected true when the quote is too old to be filled (see _ageFeePpm).
  /// @dev Reverts for blacklisted addresses, and for non-whitelisted ones when `whitelistOnly` is on.
  function _computeFee(address _sender, uint40 _refBlock, uint256 _modeFeePpm)
    internal
    view
    returns (bool _rejected, uint256 _feePpm)
  {
    // 1. Age. Also the only reason a quote can be rejected.
    uint256 _ageFee = _ageFeePpm(_refBlock);
    if (_ageFee == NO_FILL) return (true, 0);

    // 2. Who is trading? The manager's registry labels both the calling contract and the EOA behind the transaction.
    IBookManager.AddressLabel _senderLabel = IBookManager(bookManager).addressLabel(_sender);
    IBookManager.AddressLabel _originLabel = IBookManager(bookManager).addressLabel(tx.origin);

    // 3. Default fee: waived if EITHER address is default-exempt.
    uint256 _defaultFee = (_senderLabel == IBookManager.AddressLabel.DefaultExempt
        || _originLabel == IBookManager.AddressLabel.DefaultExempt)
      ? 0
      : defaultFee;

    _feePpm = _modeFeePpm + _ageFee + baseFee + _defaultFee + _priorityFeePpm()
      + _addressFeePpm(_sender, _senderLabel, _originLabel);

    if (_feePpm > PPM) _feePpm = PPM;
  }

  /// @dev AGE fee (original 0x4494). Nothing while the quote is within its grace period, then quadratic in the
  ///      number of blocks past it, capped; NO_FILL once the quote has expired (or `_refBlock` is in the future).
  ///      Paper: "no freshness penalty for a short grace period, an increasingly worse price thereafter,
  ///      and no fill at all once the quote expires."
  ///      The original saturates to the cap on every uint32 overflow step; with cap <= 1e6 that equals this plain min().
  function _ageFeePpm(uint40 _refBlock) private view returns (uint256) {
    QuoteFreshness memory _f = quoteFreshness;

    if (block.number < _refBlock) return NO_FILL;
    uint256 _age = block.number - _refBlock;

    if (_age >= _f.blocksExpiryAge) return NO_FILL;
    if (_age < _f.blocksGracePeriod) return 0;

    uint256 _blocksPastGrace = _age - _f.blocksGracePeriod + 1;
    uint256 _fee = uint256(_f.quadraticCoeff) * _blocksPastGrace * _blocksPastGrace;
    return _fee < _f.ageFeeCap ? _fee : _f.ageFeeCap;
  }

  /// @dev PRIORITY fee (original 0x48d5 + inline). A flat surcharge for trades that bid a high priority fee,
  ///      i.e. that try to land ahead of the operator's quote update at the start of the block.
  ///      A single configured value; the two spikes (2 and 5 bps) in the paper are most likely two config epochs.
  function _priorityFeePpm() private view returns (uint256) {
    uint256 _threshold = IBookManager(bookManager).priorityFeeReference() * priorityMultiplierPpm / PPM;
    uint256 _effectivePriorityFee = tx.gasprice < block.basefee ? 0 : tx.gasprice - block.basefee;
    return _effectivePriorityFee > _threshold ? priorityFee : 0;
  }

  /// @dev ADDRESS fee. Order matters and matches the original:
  ///        whitelist-only mode: the sender must be default-exempt, and NOTHING ELSE is checked (no blacklist, no fee).
  ///                             (Only one of the two labels is looked at; I believe it is the sender's, not certain.)
  ///        otherwise:           blacklisted (either address) -> revert
  ///                             penalized   (either address) -> address fee
  ///                             else                         -> address fee only if the fingerprint helper matches
  ///      The penalized branch also burns gas (`_burnGas`, 500 iterations) before the fee is returned.
  function _addressFeePpm(
    address _sender,
    IBookManager.AddressLabel _senderLabel,
    IBookManager.AddressLabel _originLabel
  ) private view returns (uint256) {
    if (whitelistOnly) {
      if (_senderLabel != IBookManager.AddressLabel.DefaultExempt) {
        revert AddressNotWhitelisted();
      }
      return 0;
    }

    if (_senderLabel == IBookManager.AddressLabel.Blacklisted || _originLabel == IBookManager.AddressLabel.Blacklisted)
    {
      revert AddressBlacklisted();
    }

    if (_senderLabel == IBookManager.AddressLabel.Penalized || _originLabel == IBookManager.AddressLabel.Penalized) {
      _burnGas(PENALIZED_GAS_BURN_ITERATIONS);
      return addressFee;
    }

    // Also runs for default-exempt addresses (paper, App. C.2).
    return _matchesFingerprint(_sender) ? addressFee : 0;
  }

  /// @dev Original 0x481b. Asks the helper `f(tx.origin, sender) -> bool` (selector 0x1ed58fc8, name unknown).
  ///      Paper examples: origins with a "coffee" prefix, tiny forwarding contracts created in the same transaction,
  ///      Metric's swap callback. A missing helper, a failed call or a short answer all mean "no match".
  function _matchesFingerprint(address _sender) private view returns (bool) {
    address _helper = fingerprintHelper;
    if (_helper == address(0)) return false;

    (bool _ok, bytes memory _ret) = _helper.staticcall(abi.encodeWithSelector(bytes4(0x1ed58fc8), tx.origin, _sender));
    if (!_ok || _ret.length < 32) return false;

    uint256 _answer = abi.decode(_ret, (uint256));
    require(_answer <= 1); // the original reverts (empty data) on a non-boolean answer
    return _answer == 1;
  }

  /// @dev MODE fee (original 0x4120). The first byte of the swap's `data`, priced by an external helper
  ///      `f(uint8 mode) -> ppm` (selector 0x4a89bec0, name unknown). Applies to swaps only: the previews never see it.
  ///      NOTE: it is looked up even for mode 0, so the helper may charge something for "no mode".
  function _modeFee(uint8 _mode) private view returns (uint256) {
    address _helper = modeFeeHelper;
    if (_helper == address(0)) return 0;

    (bool _ok, bytes memory _ret) = _helper.staticcall(abi.encodeWithSelector(bytes4(0x4a89bec0), _mode));
    if (!_ok || _ret.length < 32) return 0;

    uint256 _fee = abi.decode(_ret, (uint256));
    return _fee > PPM ? PPM : _fee;
  }

  /// @dev Everything that differs between the two directions, decided once. Pulled out of bookWalkExactIn so
  ///      that both walks share it (the original decompilation duplicated this block in four places).
  /// @return _ok false when the side has no quote at all (bid side with spread >= 100%).
  /// @return _side the ladder the taker trades against.
  /// @return _bestBookPrice RAW output units per RAW input unit at the best level, 1e18 fixed point.
  /// @return _netDepletion how much of this side's configured liquidity is already used up,
  ///         in this side's input units: own flow minus the opposite side's flow converted at the anchor, floored at 0.
  /// @return _excludedLevels how many best levels the operator currently hides.
  function _loadSide(bool _takeBidSide)
    private
    view
    returns (
      bool _ok,
      BookLevel[MAX_BOOK_LEVELS] storage _side,
      uint256 _bestBookPrice,
      uint256 _netDepletion,
      uint256 _excludedLevels
    )
  {
    _side = _takeBidSide ? clob.bids : clob.asks;

    (bool _hasQuote, uint128 _bestPriceWad, uint128 _anchorWad,,) = bestPrice(_takeBidSide);
    if (!_hasQuote) return (false, _side, 0, 0, 0);

    // Bid: pays base, gets quote -> bid price already is "quote per base".
    // Ask: pays quote, gets base -> needs "base per quote", i.e. 1 / ask.
    _bestBookPrice = _takeBidSide ? _toRawQuotePerBase(_bestPriceWad) : _toRawBasePerQuote(_invert(_bestPriceWad));

    // Converts the OPPOSITE side's flow into this side's input units, at the anchor (the neutral price).
    uint256 _inventoryConversionPrice = _takeBidSide
      ? _toRawBasePerQuote(_invert(_anchorWad)) // opposite flow is quote -> base
      : _toRawQuotePerBase(_anchorWad); //         opposite flow is base  -> quote

    (uint256 _currentSideFlow, uint256 _oppositeSideFlow) =
      _takeBidSide ? (baseFlowAccumulator, quoteFlowAccumulator) : (quoteFlowAccumulator, baseFlowAccumulator);

    _netDepletion = _currentSideFlow;
    if (nettingEnabled) {
      // NOTE: the raw code resets the accumulator variable to 0 right before the loops. I read that as a decompiler
      // artefact; taken literally, netting and accumulators would be dead code.
      uint256 _oppositeFlowInOwnUnits = _oppositeSideFlow * _inventoryConversionPrice / WAD;
      _netDepletion = _currentSideFlow > _oppositeFlowInOwnUnits ? _currentSideFlow - _oppositeFlowInOwnUnits : 0;
    }

    _excludedLevels = block.number < IBookManager(bookManager).levelExclusionDeadlineBlock() ? excludedBestLevels : 0;
    _ok = true;
  }

  /// @dev tiny readability helper: `side(_side, i)` reads as "level i of the side".
  function side(BookLevel[MAX_BOOK_LEVELS] storage _side, uint256 _i) private view returns (BookLevel memory) {
    return _side[_i];
  }

  /// @dev 1e36 / price: "quote per base" <-> "base per quote", both 1e18 fixed point.
  function _invert(uint128 _price) private pure returns (uint128) {
    if (_price == 0) return 0;
    uint256 _inverted = 1e36 / _price;
    if (_inverted >= type(uint128).max) revert PriceOverflow();
    return uint128(_inverted);
  }

  /// @dev WHOLE-token "quote per base" (1e18) -> RAW quote units per RAW base unit (1e18).
  ///      Base 18 dec / quote 6 dec: divide by 1e12.
  function _toRawQuotePerBase(uint128 _wholeTokenPrice) private view returns (uint256) {
    (uint8 _b, uint8 _q) = (baseDecimals, quoteDecimals);
    if (_b == _q) return _wholeTokenPrice;
    if (_b < _q) return uint256(_wholeTokenPrice) * 10 ** (_q - _b);
    return _wholeTokenPrice / 10 ** (_b - _q);
  }

  /// @dev WHOLE-token "base per quote" (1e18) -> RAW base units per RAW quote unit (1e18).
  ///      Base 18 dec / quote 6 dec: multiply by 1e12.
  function _toRawBasePerQuote(uint128 _wholeTokenPrice) private view returns (uint256) {
    (uint8 _b, uint8 _q) = (baseDecimals, quoteDecimals);
    if (_b == _q) return _wholeTokenPrice;
    if (_q < _b) return uint256(_wholeTokenPrice) * 10 ** (_b - _q);
    return _wholeTokenPrice / 10 ** (_q - _b);
  }

  /// @dev Copies `_levels` into the front of `_ladder` and caps it with a terminator: one SSTORE per level plus one
  ///      for the terminator. (The decompiled bit-twiddling is exactly Solidity's packing of {uint160, uint64, bool}.)
  function _writeLadder(BookLevel[MAX_BOOK_LEVELS] storage _ladder, BookLevel[] calldata _levels) private {
    uint256 _count = _levels.length; // <= 19, so _ladder[_count] is always in bounds

    for (uint256 _i; _i < _count; ++_i) {
      _ladder[_i] = _levels[_i];
    }

    _ladder[_count] = BookLevel({liquidity: 0, multiplier: 0, endOfBook: true});
  }

  /// @dev Only these three values are range-checked. The address, priority and default fees are not (the total is
  ///      capped at 1e6 when it is computed).
  function _checkLimits(uint256 _baseFee, uint256 _ageFeeCap, uint256 _factor) private pure {
    if (_baseFee > PPM || _ageFeeCap > PPM) revert FeeAbove100Percent();
    if (_factor > PPM) revert FactorAbove100Percent();
  }

  /// @dev Writes the parameters shared by `configure` and `reconfigure` (NOT `excludedBestLevels` / `fingerprintHelper`).
  function _storeConfig(BookConfig memory _config) private {
    baseFee = _config.baseFee;
    factor = _config.factor;
    nettingEnabled = _config.nettingEnabled;
    quoteFreshness = _config.freshness;
    addressFee = _config.addressFee;
    whitelistOnly = _config.whitelistOnly;
    priorityMultiplierPpm = _config.priorityMultiplierPpm;
    priorityFee = _config.priorityFee;
  }
}
