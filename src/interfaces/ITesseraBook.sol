// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice Interface of a Tessera pool (one proxy per pair; the shared implementation is what was decompiled).
/// @dev Names are mine; only the selectors, types and behaviour come from the bytecode. The real selector of
///      `updateBook` is 0xdba310cf. Selectors of the manager / helper calls are listed on `IPoolManager`.
interface ITesseraBook {
  /*////////////////////////////////////////////////////////////
                              STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @dev One storage slot (160 + 64 + 8 bits).
  struct BookLevel {
    uint160 liquidity; //  capacity of the level, in the TAKER'S INPUT token (base on bids, quote on asks)
    uint64 multiplier; //  ppm; level price = top-of-book price * multiplier / 1e6. Must be strictly decreasing
    //  down the ladder (checked while walking, not when writing).
    bool endOfBook; //     terminator: nothing at or after this index is real (stale data is never read)
  }

  /// @dev Storage view of both ladders (raw slots 8..27 and 28..47). NOT the calldata shape of `updateBook`.
  struct OrderBook {
    BookLevel[20] bids; // taker SELLS BASE here, receives quote
    BookLevel[20] asks; // taker SELLS QUOTE here, receives base
  }

  /// @dev Calldata shape of `updateBook`: ONE tuple of two dynamic arrays (<= 19 levels each, the 20th slot is the
  ///      terminator). Bids first, asks second, matching `OrderBook`.
  struct BookUpdate {
    BookLevel[] bids;
    BookLevel[] asks;
  }

  /// @dev Logical field order. On-chain it is packed from the top bit down: tag, refBlock, priceAnchor, spreadPpm,
  ///      then 56 unused low bits (raw slot 0).
  struct Quote {
    uint8 tag;
    uint40 refBlock; // block of the last quote update; drives the age fee and the expiry
    uint128 priceAnchor; // 1e18 fixed point, WHOLE-token units (quote per base)
    uint24 spreadPpm;
  }

  /// @dev Age-fee parameters (raw slot 6).
  struct QuoteFreshness {
    uint64 blocksExpiryAge; //   age (blocks since refBlock) from which there is NO FILL at all
    uint64 blocksGracePeriod; // no age fee while age < grace
    uint32 quadraticCoeff; //    age fee (ppm) = coeff * (age - grace + 1)^2 ...
    uint32 ageFeeCap; //         ... capped here (<= 1e6)
  }

  /// @dev All operator-tunable parameters, in the order of the raw 13-argument call (0x75e8422f).
  struct PoolConfig {
    uint24 baseFee; //                  <= 1e6
    uint24 factor; //                   <= 1e6
    uint8 excludedBestLevels;
    bool nettingEnabled;
    QuoteFreshness freshness; //        freshness.ageFeeCap <= 1e6
    uint32 addressFee;
    bool whitelistOnly;
    uint32 priorityMultiplierPpm;
    uint32 priorityFee;
    address fingerprintHelper;
  }

  /*////////////////////////////////////////////////////////////
                              EVENTS
  ////////////////////////////////////////////////////////////*/

  /// @dev Exact types are a guess. The two accumulators are the values BEFORE this trade is added.
  event Swap(
    address caller,
    uint256 amountIn,
    uint256 amountOut,
    address baseToken,
    address quoteToken,
    uint8 tag,
    uint256 baseFlowAccumulator,
    uint256 quoteFlowAccumulator
  );

  /// @dev Only emitted when the mode byte is non-zero.
  event ModeUsed(uint8 mode);

  /*////////////////////////////////////////////////////////////
                              ERRORS
  ////////////////////////////////////////////////////////////*/

  // Original messages are short codes (T1, T3, T4, T6, T16, T17, T19, T23, T24, ...); these are readable names.
  error TradingDisabled();
  error PoolManagerInactive();
  error CallerNotPoolManager();
  error NotOperator();
  error NotMultiSig();
  error NotTradingController();
  error AlreadyInitialized();
  error ZeroAmount();
  error ZeroInput();
  error ZeroOutput();
  error NoQuote();
  error QuoteRejected(); //                     the quote is too old (age fee returned NO_FILL)
  error InsufficientLiquidity();
  error MultipliersNotStrictlyDecreasing();
  error PriceOverflow();
  error FeeTooHigh(); //                        fee >= 100% cannot be grossed up
  error FeeAbove100Percent(); //                baseFee or ageFeeCap > 1e6
  error FactorAbove100Percent(); //             factor > 1e6
  error AddressBlacklisted();
  error AddressNotWhitelisted();
  error StaleDefaultFeeUpdate();
  error InvalidAddresses();
  error LengthMismatch();
  error TooManyOrders();
  error TransferFailed(address token);

  /*////////////////////////////////////////////////////////////
                              CONSTANT
  ////////////////////////////////////////////////////////////*/

  /// @dev 20 slots per ladder; at most 19 real levels, one slot is the terminator.
  function MAX_BOOK_LEVELS() external pure returns (uint256);

  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  function quote() external view returns (uint8 tag, uint40 refBlock, uint128 priceAnchor, uint24 spreadPpm);

  /// @notice Total INPUT (base units) the pool received on the BID side since the last book update.
  /// @dev Each swap adds `input * factor / 1e6`. Reset by `updateBook` and `reconfigure`.
  function baseFlowAccumulator() external view returns (uint256);

  /// @notice Total INPUT (quote units) the pool received on the ASK side since the last book update.
  /// @dev Same unit and reset rules as `baseFlowAccumulator`.
  function quoteFlowAccumulator() external view returns (uint256);

  /// @notice Shared manager / registry: kill switch, address labels, level-exclusion block, priority-fee reference.
  function poolManager() external view returns (address);

  function operator() external view returns (address);

  function multiSigOwner() external view returns (address);

  function isInitialized() external view returns (bool);

  /// @notice Kill switch.
  function tradingEnabled() external view returns (bool);

  function baseToken() external view returns (address);

  function quoteToken() external view returns (address);

  function baseDecimals() external view returns (uint8);

  function quoteDecimals() external view returns (uint8);

  // ── fee and netting parameters ──

  /// @notice ppm. Waived for default-exempt senders / origins. Set per block via `setDefaultFee`.
  function defaultFee() external view returns (uint32);

  /// @notice ppm. Flat fee component.
  function baseFee() external view returns (uint24);

  function quoteFreshness()
    external
    view
    returns (uint64 blocksExpiryAge, uint64 blocksGracePeriod, uint32 quadraticCoeff, uint32 ageFeeCap);

  /// @notice ppm. Share of each swap's INPUT that is added to the flow accumulator.
  function factor() external view returns (uint24);

  /// @notice Number of best levels hidden from the walk; only active while
  ///         block.number < poolManager.levelExclusionDeadlineBlock().
  function excludedBestLevels() external view returns (uint8);

  /// @notice If true, opposite-direction flow gives capacity back (netting at the anchor price).
  function nettingEnabled() external view returns (bool);

  function addressFee() external view returns (uint32);

  /// @notice If true, only default-exempt callers can trade.
  function whitelistOnly() external view returns (bool);

  /// @notice ppm. Priority-fee threshold = manager's reference * this / 1e6.
  function priorityMultiplierPpm() external view returns (uint32);

  /// @notice ppm. Surcharge when the effective priority fee (gasprice - basefee) is above the threshold.
  function priorityFee() external view returns (uint32);

  function fingerprintHelper() external view returns (address);

  function modeFeeHelper() external view returns (address);

  function askSide() external view returns (BookLevel[20] memory);

  function bidSide() external view returns (BookLevel[20] memory);

  /*////////////////////////////////////////////////////////////
                              SWAPS
  ////////////////////////////////////////////////////////////*/

  /// @notice Exact input swap. Returns the net output (after fees).
  /// @param takeBidSide true: taker sells BASE into the bids; false: taker sells QUOTE into the asks.
  /// @param amountIn raw input units.
  /// @param sender the router's `msg.sender` as forwarded by the engine (NOT a token recipient); the fee uses it
  ///        and tx.origin for the address checks.
  /// @param data first byte = fee "mode"; the rest is ignored.
  /// @dev Callable by anyone who passes the checks (trading enabled, manager active, quote not expired); in practice
  ///      the engine. NO token transfers here: the router pays out of the treasury and pulls the input.
  ///      Flow: checks -> reentrancy lock -> best price -> walk -> fee (incl. mode) -> out = gross * (1 - fee)
  ///      -> add input * factor / 1e6 to the side's accumulator -> emit Swap (and ModeUsed if mode != 0).
  function sell(
    bool takeBidSide,
    uint256 amountIn,
    address sender,
    bytes calldata data
  ) external returns (uint256 amountOut);

  /// @notice Exact output swap. Returns the input needed. The output is grossed up for the fee, then the book is
  ///         walked backwards (rounding UP, ceil division).
  function buy(
    bool takeBidSide,
    uint256 amountOut,
    address sender,
    bytes calldata data
  ) external returns (uint256 amountIn);

  /*////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Net output of `sell`, WITHOUT the mode fee (previews take no mode; `data` is ignored).
  /// @dev Manager-only (T4).
  function previewSell(
    bool takeBidSide,
    uint256 amountIn,
    address sender,
    bytes calldata data
  ) external view returns (uint256 netOutput);

  /// @notice Input needed by `buy`, WITHOUT the mode fee. Returns type(uint256).max when it cannot be filled.
  /// @dev Manager-only (T4).
  function previewBuy(
    bool takeBidSide,
    uint256 amountOut,
    address sender,
    bytes calldata data
  ) external view returns (uint256 netInput);

  /// @notice Gross exact-in walk (no fee). Returns 0 if the book cannot absorb the whole input.
  /// @dev Not necessarily external in the original (the decompiler inlined it); exposed here for convenience.
  function bookWalkExactIn(bool takeBidSide, uint256 amountIn) external view returns (uint256 grossOutput);

  /// @notice Gross exact-out walk (no fee). Returns type(uint256).max when it cannot be filled.
  function bookWalkExactOut(bool takeBidSide, uint256 grossAmountOut) external view returns (uint256 amountIn);

  /// @notice Top-of-book price.
  /// @dev Ask = ceil(anchor * (1e6 + spread) / 1e6); bid = floor(anchor * (1e6 - spread) / 1e6),
  ///      and `ok` is false for the bid when spread >= 1e6.
  function bestPrice(bool isBid)
    external
    view
    returns (bool ok, uint128 price, uint128 anchor, uint40 refBlock, uint8 tag);

  /*////////////////////////////////////////////////////////////
                         OPERATOR / ADMIN
  ////////////////////////////////////////////////////////////*/

  /// @notice Operator only. Selector 0xdba310cf. Replaces both ladders, resets both accumulators.
  function updateBook(BookUpdate calldata book) external;

  /// @notice Operator only. Raw selector 0x75e8422f (13 flat arguments). Does not touch accumulators or the book.
  function configure(PoolConfig calldata config) external;

  /// @notice Pool manager only. Raw selector 0x209dab1e. PARTIAL: the real calldata is 26 words, signature unverified.
  function reconfigure(address addressA, address addressB, PoolConfig calldata config) external;

  /// @notice Operator only. Raw selector 0x1667d875. Argument = ~(0xdeadbeefdeadbeefdeadbeef ^ encoded), a uint96 of
  ///         [fee u32 | block number u64]; it only applies in the block it names.
  function setDefaultFee(uint96 encoded) external;

  /// @notice Operator only. Raw selector 0x7bcffd54.
  function setModeFeeHelper(address helper) external;

  /// @notice Operator or pool manager.
  function enableTrading() external;

  /// @notice Operator or pool manager.
  function disableTrading() external;

  /// @notice Anyone, once. Raw selector 0x67107049.
  function initialize(
    address multiSigOwner,
    address poolManager,
    address operator,
    address baseToken,
    address quoteToken,
    uint8 baseDecimals,
    uint8 quoteDecimals
  ) external;

  /// @notice Multisig only. Original name `rescueTokensss1337` (0x2c88026b).
  function rescueTokens(address[] calldata tokens, uint256[] calldata amounts, address to) external;

  /// @notice Multisig only. Original name `rescueEthhh1337` (0x8f05e71b).
  function rescueEth(uint256 amount, address to) external;
}
