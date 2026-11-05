// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';

import {TesseraBook} from '../src/contracts/TesseraBook.sol';
import {TesseraEngine} from '../src/contracts/TesseraEngine.sol';
import {TesseraSwap} from '../src/contracts/TesseraSwap.sol';
import {ITesseraBook} from '../src/interfaces/ITesseraBook.sol';
import {ITesseraEngine} from '../src/interfaces/ITesseraEngine.sol';

import {MockFingerprintHelper, MockModeFeeHelper, MockToken} from './Mocks.sol';

/// @dev Full stack: engine (hub = USDC) + router + two books (WETH/USDC, XTK/USDC).
contract TesseraTest is Test {
  address internal constant MULTISIG = 0xdbD31EA3dE20A2b36a5bD36C7167699F2450b5C6;
  uint256 internal constant PPM = 1e6;

  // WETH/USDC quote: anchor 2000 USDC per WETH
  uint128 internal constant ANCHOR = 2000e18;
  // spread 1000 ppm -> bid 1998, ask 2002.
  uint24 internal constant SPREAD = 1000;

  uint256 internal constant RAW_BID = 1998e6; //   raw USDC per raw WETH, 1e18 fixed point
  uint256 internal constant RAW_BID_L2 = 1978.02e6; // RAW_BID * 0.99

  // Address labels in the engine.
  uint16 internal constant ORDINARY = 0;
  uint16 internal constant DEFAULT_EXEMPT = 1;
  uint16 internal constant PENALIZED = 2;
  uint16 internal constant BLACKLISTED = 3;

  // Actors
  address internal operator = makeAddr('operator');
  address internal killer = makeAddr('killer');
  address internal exclusionSetter = makeAddr('exclusionSetter');
  address internal treasury = makeAddr('treasury');
  address internal routerOwner = makeAddr('routerOwner');
  address internal trader = makeAddr('trader');
  address internal updater = makeAddr('updater');

  address[10] internal updaters;

  // Tokens
  MockToken internal weth;
  MockToken internal usdc;
  MockToken internal xtk;

  TesseraEngine internal engine;
  TesseraSwap internal router;

  ITesseraBook internal book; //  WETH/USDC
  ITesseraBook internal xBook; // XTK/USDC

  /*////////////////////////////////////////////////////////////
                              SETUP
  ////////////////////////////////////////////////////////////*/

  function setUp() public {
    weth = new MockToken('WETH', 18);
    usdc = new MockToken('USDC', 6);
    xtk = new MockToken('XTK', 18);

    updaters[0] = updater;
    for (uint256 _i = 1; _i < 10; ++_i) {
      updaters[_i] = makeAddr(string(abi.encodePacked('updater', vm.toString(_i))));
    }

    TesseraBook _implementation = new TesseraBook();
    engine = new TesseraEngine(address(this), address(usdc), address(_implementation), exclusionSetter, killer);
    router = new TesseraSwap(address(engine), treasury, routerOwner);

    vm.prank(MULTISIG);
    engine.setOwner(address(router));

    book = _createBook(address(weth), address(usdc), 18, 6);
    xBook = _createBook(address(xtk), address(usdc), 18, 6);

    // Funds and approvals. The treasury pays outputs, the trader pays inputs.
    MockToken[3] memory _tokens = [weth, usdc, xtk];
    for (uint256 _i; _i < 3; ++_i) {
      _tokens[_i].mint(treasury, 1e30);
      _tokens[_i].mint(trader, 1e30);
      vm.prank(treasury);
      _tokens[_i].approve(address(router), type(uint256).max);
      vm.prank(trader);
      _tokens[_i].approve(address(router), type(uint256).max);
    }

    _pushQuote(book, ANCHOR, SPREAD);
    _setLadder(book, _defaultBids(), _defaultAsks());

    _pushQuote(xBook, 1e18, 0);
    ITesseraBook.BookLevel[] memory _xBids = new ITesseraBook.BookLevel[](1);
    _xBids[0] = _level(1_000_000e18, 1e6);
    ITesseraBook.BookLevel[] memory _xAsks = new ITesseraBook.BookLevel[](1);
    _xAsks[0] = _level(1_000_000e6, 1e6);
    _setLadder(xBook, _xBids, _xAsks);
  }

  /*////////////////////////////////////////////////////////////
                            HELPERS
  ////////////////////////////////////////////////////////////*/

  function _createBook(
    address _base,
    address _quote,
    uint8 _baseDecimals,
    uint8 _quoteDecimals
  ) internal returns (ITesseraBook) {
    ITesseraEngine.BookParams memory _params = ITesseraEngine.BookParams({
      baseToken: _base,
      quoteToken: _quote,
      baseDecimals: _baseDecimals,
      quoteDecimals: _quoteDecimals,
      baseFee: 0,
      nettingEnabled: true,
      factor: uint32(PPM),
      blocksExpiryAge: 10,
      blocksGracePeriod: 2,
      quadraticCoeff: 10,
      ageFeeCap: 1000,
      addressFee: 0,
      whitelistOnly: false,
      priorityMultiplierPpm: uint32(PPM),
      priorityFee: 0,
      updaters: updaters,
      operator: operator
    });
    vm.prank(MULTISIG);
    return ITesseraBook(engine.createBook(_params));
  }

  /// @dev Same values as `_createBook`, so a test can change one field and call `_configure`.
  function _defaultConfig() internal pure returns (ITesseraBook.BookConfig memory) {
    return ITesseraBook.BookConfig({
      baseFee: 0,
      factor: uint24(PPM),
      excludedBestLevels: 0,
      nettingEnabled: true,
      freshness: ITesseraBook.QuoteFreshness({
        blocksExpiryAge: 10, blocksGracePeriod: 2, quadraticCoeff: 10, ageFeeCap: 1000
      }),
      addressFee: 0,
      whitelistOnly: false,
      priorityMultiplierPpm: uint32(PPM),
      priorityFee: 0,
      fingerprintHelper: address(0)
    });
  }

  function _configure(ITesseraBook _book, ITesseraBook.BookConfig memory _config) internal {
    vm.prank(operator);
    _book.configure(_config);
  }

  /// @dev The proxy's word = Solidity's packing of `Quote`, low bit to high bit:
  ///      tag u8 | refBlock u40 | anchor u128 | spread u24 | 56 unused.
  function _encodeQuote(uint8 _tag, uint40 _refBlock, uint128 _anchor, uint24 _spread) internal pure returns (bytes32) {
    return bytes32(uint256(_tag) | (uint256(_refBlock) << 8) | (uint256(_anchor) << 48) | (uint256(_spread) << 176));
  }

  /// @dev Tag read from storage: a getter call from an updater would itself be treated as a quote update.
  function _tagOf(ITesseraBook _book) internal view returns (uint8) {
    return uint8(uint256(vm.load(address(_book), bytes32(0))));
  }

  /// @dev Raw call from an updater, tag + 1, refBlock = current block.
  function _pushQuote(ITesseraBook _book, uint128 _anchor, uint24 _spread) internal {
    (uint8 _tag,,,) = _book.quote();
    bytes32 _word = _encodeQuote(_tag + 1, uint40(block.number), _anchor, _spread);
    vm.prank(updater);
    (bool _ok,) = address(_book).call(abi.encodePacked(_word));
    require(_ok, 'quote update failed');
  }

  function _level(uint160 _liquidity, uint64 _multiplier) internal pure returns (ITesseraBook.BookLevel memory) {
    return ITesseraBook.BookLevel({liquidity: _liquidity, multiplier: _multiplier, endOfBook: false});
  }

  /// @dev Bids in WETH: 1 @ 100%, 2 @ 99%, 5 @ 98%.
  function _defaultBids() internal pure returns (ITesseraBook.BookLevel[] memory _bids) {
    _bids = new ITesseraBook.BookLevel[](3);
    _bids[0] = _level(1e18, 1e6);
    _bids[1] = _level(2e18, 990_000);
    _bids[2] = _level(5e18, 980_000);
  }

  /// @dev Asks in USDC: 2000 @ 100%, 4000 @ 99%, 10000 @ 98%.
  function _defaultAsks() internal pure returns (ITesseraBook.BookLevel[] memory _asks) {
    _asks = new ITesseraBook.BookLevel[](3);
    _asks[0] = _level(2000e6, 1e6);
    _asks[1] = _level(4000e6, 990_000);
    _asks[2] = _level(10_000e6, 980_000);
  }

  function _setLadder(
    ITesseraBook _book,
    ITesseraBook.BookLevel[] memory _bids,
    ITesseraBook.BookLevel[] memory _asks
  ) internal {
    vm.prank(operator);
    _book.updateBook(ITesseraBook.BookUpdate({bids: _bids, asks: _asks}));
  }

  /// @dev Router swap from the trader (msg.sender and tx.origin = trader), no slippage limit.
  function _swap(
    address _tokenIn,
    address _tokenOut,
    int256 _amountSpecified,
    bytes memory _swapData
  ) internal returns (uint256 _amountIn, uint256 _amountOut) {
    uint256 _inBefore = MockToken(_tokenIn).balanceOf(trader);
    uint256 _outBefore = MockToken(_tokenOut).balanceOf(trader);

    uint256 _check = _amountSpecified > 0 ? 0 : type(uint256).max;
    vm.prank(trader, trader);
    router.tesseraSwapWithAllowances(_tokenIn, _tokenOut, _amountSpecified, _check, trader, _swapData);

    _amountIn = _inBefore - MockToken(_tokenIn).balanceOf(trader);
    _amountOut = MockToken(_tokenOut).balanceOf(trader) - _outBefore;
  }

  function _sellWeth(uint256 _amountIn) internal returns (uint256 _amountOut) {
    (, _amountOut) = _swap(address(weth), address(usdc), int256(_amountIn), '');
  }

  function _preview(
    address _tokenIn,
    address _tokenOut,
    int256 _amountSpecified
  ) internal returns (uint256 _amountIn, uint256 _amountOut) {
    vm.prank(trader, trader);
    return router.tesseraSwapViewAmounts(_tokenIn, _tokenOut, _amountSpecified);
  }

  /// @dev Expected net output for a gross output and a total fee.
  function _net(uint256 _gross, uint256 _feePpm) internal pure returns (uint256) {
    return _gross * (PPM - _feePpm) / PPM;
  }

  /// @dev Raw WETH per raw USDC at the ask (ask = 2002 rounded up, inverted, decimals 18 vs 6).
  function _rawAsk() internal pure returns (uint256) {
    uint256 _ask = 2002e18;
    return (1e36 / _ask) * 1e12;
  }

  function _label(address _account, uint16 _value) internal {
    vm.prank(killer);
    engine.setAddressLabel(_account, _value);
  }

  /// @dev Encodes first: a prank is consumed by the next call, which would otherwise be the encoder.
  function _setDefaultFee(uint32 _fee) internal {
    uint96 _encoded = book.encodeDefaultFeeUpdate(_fee, uint64(block.number));
    vm.prank(operator);
    book.setDefaultFee(_encoded);
  }

  function _expectSwapRevert(bytes4 _selector) internal {
    vm.prank(trader, trader);
    vm.expectRevert(_selector);
    router.tesseraSwapWithAllowances(address(weth), address(usdc), 1e18, 0, trader, '');
  }

  /*////////////////////////////////////////////////////////////
                         QUOTE UPDATE (PROXY)
  ////////////////////////////////////////////////////////////*/

  function test_quoteUpdate_storesWordInSlotZero() public {
    vm.roll(block.number + 7);
    (uint8 _tagBefore,,,) = book.quote();

    bytes32 _word = _encodeQuote(_tagBefore + 1, uint40(block.number), 2100e18, 500);

    vm.prank(updater);
    (bool _ok,) = address(book).call(abi.encodePacked(_word));
    assertTrue(_ok);

    assertEq(
      vm.load(address(book), bytes32(0)),
      /* slot0 */
      _word
    );

    (uint8 _tag, uint40 _refBlock, uint128 _anchor, uint24 _spread) = book.quote();

    assertEq(_tag, _tagBefore + 1);
    assertEq(_refBlock, block.number);
    assertEq(_anchor, 2100e18);
    assertEq(_spread, 500);
  }

  function test_quoteUpdate_anyOfTheTenUpdaters() public {
    for (uint256 _i; _i < 10; ++_i) {
      (uint8 _tag,,,) = book.quote();

      vm.prank(updaters[_i]);
      (bool _ok,) = address(book).call(abi.encodePacked(_encodeQuote(_tag + 1, uint40(block.number), ANCHOR, SPREAD)));

      assertTrue(_ok);
    }
  }

  function test_quoteUpdate_nonUpdaterReverts() public {
    bytes32 _before = vm.load(address(book), bytes32(0));

    (uint8 _tag,,,) = book.quote();

    vm.prank(trader);
    (bool _ok,) = address(book).call(abi.encodePacked(_encodeQuote(_tag + 1, 1, 1, 1)));

    assertFalse(_ok);
    assertEq(vm.load(address(book), bytes32(0)), _before);
  }

  /*////////////////////////////////////////////////////////////
                              PRICES
  ////////////////////////////////////////////////////////////*/

  function test_bestPrice_bidAndAsk() public view {
    (bool _ok, uint128 _bid, uint128 _anchor,,) = book.bestPrice(true);

    assertTrue(_ok);
    assertEq(_anchor, ANCHOR);
    assertEq(_bid, 1998e18);

    (_ok,,,,) = book.bestPrice(false);
    (, uint128 _ask,,,) = book.bestPrice(false);

    assertTrue(_ok);
    assertEq(_ask, 2002e18);
  }

  function test_bestPrice_bidSideClosedAtFullSpread() public {
    _pushQuote(book, ANCHOR, uint24(PPM));

    (bool _ok,,,,) = book.bestPrice(true);

    assertFalse(_ok);
    assertEq(book.bookWalkExactIn(true, 1e18), 0);
  }

  function test_quoteUpdate_movesWholeBook() public {
    assertEq(book.bookWalkExactIn(true, 2e18), RAW_BID + RAW_BID_L2);

    _pushQuote(book, 2 * ANCHOR, SPREAD); // every level doubles, liquidity unchanged
    assertEq(book.bookWalkExactIn(true, 2e18), 2 * (RAW_BID + RAW_BID_L2));
  }

  /*////////////////////////////////////////////////////////////
                           BOOK UPDATE
  ////////////////////////////////////////////////////////////*/

  function test_updateBook_onlyOperator() public {
    vm.prank(trader);
    vm.expectRevert(ITesseraBook.NotOperator.selector);
    book.updateBook(ITesseraBook.BookUpdate({bids: _defaultBids(), asks: _defaultAsks()}));
  }

  function test_updateBook_resetsAccumulators() public {
    _sellWeth(1e18);
    assertEq(book.baseFlowAccumulator(), 1e18);

    _setLadder(book, _defaultBids(), _defaultAsks());

    assertEq(book.baseFlowAccumulator(), 0);
    assertEq(book.quoteFlowAccumulator(), 0);
  }

  function test_updateBook_shorterBookHidesStaleLevels() public {
    ITesseraBook.BookLevel[] memory _one = new ITesseraBook.BookLevel[](1);

    _one[0] = _level(1e18, 1e6);
    _setLadder(book, _one, _defaultAsks());

    assertEq(book.bookWalkExactIn(true, 1e18), RAW_BID);
    assertEq(book.bookWalkExactIn(true, 1.5e18), 0); // level 2 is stale data behind the terminator
  }

  function test_walk_revertsOnNonDecreasingMultipliers() public {
    ITesseraBook.BookLevel[] memory _bad = new ITesseraBook.BookLevel[](2);

    _bad[0] = _level(1e18, 990_000);
    _bad[1] = _level(1e18, 1e6);

    _setLadder(book, _bad, _defaultAsks()); // accepted on write

    book.bookWalkExactIn(true, 0.5e18); // ends inside level 1, level 2 is never read

    vm.expectRevert(ITesseraBook.MultipliersNotStrictlyDecreasing.selector);
    book.bookWalkExactIn(true, 1.5e18);
  }

  /*////////////////////////////////////////////////////////////
                         LEVEL EXCLUSION
  ////////////////////////////////////////////////////////////*/

  function test_levelExclusion_onlyBeforeDeadline() public {
    ITesseraBook.BookConfig memory _config = _defaultConfig();

    _config.excludedBestLevels = 1;
    _configure(book, _config);

    assertEq(book.bookWalkExactIn(true, 1e18), RAW_BID); // no deadline set yet

    vm.prank(exclusionSetter);
    engine.setLevelExclusionDeadline(block.number + 2);

    assertEq(book.bookWalkExactIn(true, 1e18), RAW_BID_L2);

    vm.roll(block.number + 2);
    assertEq(book.bookWalkExactIn(true, 1e18), RAW_BID);
  }

  /*////////////////////////////////////////////////////////////
                            EXACT IN
  ////////////////////////////////////////////////////////////*/

  function test_exactIn_sellBaseInsideOneLevel() public {
    uint256 _treasuryUsdc = usdc.balanceOf(treasury);
    uint256 _treasuryWeth = weth.balanceOf(treasury);

    (uint256 _in, uint256 _out) = _swap(address(weth), address(usdc), 1e18, '');

    assertEq(_in, 1e18);
    assertEq(_out, RAW_BID);
    assertEq(usdc.balanceOf(treasury), _treasuryUsdc - RAW_BID);
    assertEq(weth.balanceOf(treasury), _treasuryWeth + 1e18);
  }

  function test_exactIn_sellBaseAcrossLevels() public {
    (, uint256 _out) = _swap(address(weth), address(usdc), 2e18, '');
    assertEq(_out, RAW_BID + RAW_BID_L2);
  }

  function test_exactIn_sellQuote() public {
    (uint256 _in, uint256 _out) = _swap(address(usdc), address(weth), 2000e6, '');

    assertEq(_in, 2000e6);
    assertEq(_out, 2000e6 * _rawAsk() / 1e18);
  }

  function test_exactIn_insufficientLiquidity() public {
    vm.prank(trader, trader);

    vm.expectRevert(ITesseraBook.InsufficientLiquidity.selector);
    router.tesseraSwapWithAllowances(address(weth), address(usdc), 9e18, 0, trader, ''); // book holds 8 WETH
  }

  function test_exactIn_slippageCheck() public {
    vm.prank(trader, trader);

    vm.expectRevert(bytes('ACF'));
    router.tesseraSwapWithAllowances(address(weth), address(usdc), 1e18, RAW_BID + 1, trader, '');
  }

  /*////////////////////////////////////////////////////////////
                            EXACT OUT
  ////////////////////////////////////////////////////////////*/

  function test_exactOut_insideOneLevel() public {
    (uint256 _in, uint256 _out) = _swap(address(weth), address(usdc), -int256(RAW_BID), '');
    assertEq(_out, RAW_BID);
    assertEq(_in, 1e18);
  }

  function test_exactOut_acrossLevels() public {
    (uint256 _in, uint256 _out) = _swap(address(weth), address(usdc), -3000e6, '');
    assertEq(_out, 3000e6);
    assertEq(_in, 1e18 + (3000e6 - RAW_BID) * 1e18 / RAW_BID_L2);
  }

  function test_exactOut_slippageCheck() public {
    vm.prank(trader, trader);
    vm.expectRevert(bytes('ACF'));
    router.tesseraSwapWithAllowances(address(weth), address(usdc), -int256(RAW_BID), 1e18 - 1, trader, '');
  }

  /*////////////////////////////////////////////////////////////
                             PREVIEWS
  ////////////////////////////////////////////////////////////*/

  function test_preview_matchesSwap_exactIn() public {
    (uint256 _pIn, uint256 _pOut) = _preview(address(weth), address(usdc), 2.5e18);
    (uint256 _in, uint256 _out) = _swap(address(weth), address(usdc), 2.5e18, '');

    assertEq(_pIn, _in);
    assertEq(_pOut, _out);
  }

  function test_preview_matchesSwap_exactOut() public {
    (uint256 _pIn, uint256 _pOut) = _preview(address(usdc), address(weth), -1.5e18);
    (uint256 _in, uint256 _out) = _swap(address(usdc), address(weth), -1.5e18, '');

    assertEq(_pIn, _in);
    assertEq(_pOut, _out);
  }

  function test_preview_cannotFill() public {
    (, uint256 _out) = _preview(address(weth), address(usdc), 9e18);
    assertEq(_out, 0); // 0 - can't fill

    (uint256 _in,) = _preview(address(weth), address(usdc), -100_000e6);
    assertEq(_in, type(uint256).max); // 2^256-1 - can't fill
  }

  /*////////////////////////////////////////////////////////////
                         FLOW ACCUMULATORS
  ////////////////////////////////////////////////////////////*/

  function test_accumulators_growByInputTimesFactor() public {
    _sellWeth(1e18);
    assertEq(book.baseFlowAccumulator(), 1e18);

    ITesseraBook.BookConfig memory _config = _defaultConfig();
    _config.factor = 500_000;
    _configure(book, _config);

    _swap(address(usdc), address(weth), 1000e6, '');

    assertEq(book.quoteFlowAccumulator(), 500e6);
    assertEq(book.baseFlowAccumulator(), 1e18);
  }

  function test_accumulators_sameDirectionDepletesBestLevel() public {
    assertEq(_sellWeth(1e18), RAW_BID);
    assertEq(_sellWeth(1e18), RAW_BID_L2); // level 1 used up
  }

  function test_accumulators_partialDepletion() public {
    _sellWeth(0.4e18);
    // 0.6 WETH left at level 1, then 0.4 at level 2.
    assertEq(_sellWeth(1e18), 0.6e18 * RAW_BID / 1e18 + 0.4e18 * RAW_BID_L2 / 1e18);
  }

  function test_accumulators_oppositeFlowNetsAtAnchor() public {
    _sellWeth(1e18);
    _swap(address(usdc), address(weth), 2000e6, ''); // 2000 USDC = 1 WETH at the anchor
    assertEq(_sellWeth(1e18), RAW_BID); // level 1 restored
  }

  function test_accumulators_noNettingWhenDisabled() public {
    ITesseraBook.BookConfig memory _config = _defaultConfig();
    _config.nettingEnabled = false;
    _configure(book, _config);

    _sellWeth(1e18);
    _swap(address(usdc), address(weth), 2000e6, '');
    assertEq(_sellWeth(1e18), RAW_BID_L2);
  }

  function test_accumulators_resetByBookUpdate() public {
    _sellWeth(1e18);
    _setLadder(book, _defaultBids(), _defaultAsks());
    assertEq(_sellWeth(1e18), RAW_BID);
  }

  /*////////////////////////////////////////////////////////////
                         TWO HOPS
  ////////////////////////////////////////////////////////////*/

  function test_twoHop_exactIn() public {
    // WETH -> USDC (bids of WETH/USDC) -> XTK (asks of XTK/USDC, 1 USDC per XTK).
    (uint256 _in, uint256 _out) = _swap(address(weth), address(xtk), 1e18, '');

    assertEq(_in, 1e18);
    assertEq(_out, 1998e18);
    assertEq(book.baseFlowAccumulator(), 1e18);
    assertEq(xBook.quoteFlowAccumulator(), RAW_BID);
  }

  function test_twoHop_exactOut() public {
    (uint256 _in, uint256 _out) = _swap(address(weth), address(xtk), -1000e18, '');
    assertEq(_out, 1000e18);
    assertEq(_in, 1000e6 * 1e18 / RAW_BID);
  }

  function test_twoHop_previewMatchesSwap() public {
    (uint256 _pIn, uint256 _pOut) = _preview(address(xtk), address(weth), 3000e18);
    (uint256 _in, uint256 _out) = _swap(address(xtk), address(weth), 3000e18, '');
    assertEq(_pIn, _in);
    assertEq(_pOut, _out);
  }

  function test_noRoute() public {
    vm.prank(trader, trader);
    vm.expectRevert(ITesseraEngine.NoRoute.selector);
    router.tesseraSwapWithAllowances(address(weth), makeAddr('unknown'), 1e18, 0, trader, '');
  }

  /*////////////////////////////////////////////////////////////
                               AGE
  ////////////////////////////////////////////////////////////*/

  // Defaults: grace 2, expiry 10, coefficient 10, cap 1000.

  function test_ageFee_zeroInsideGrace() public {
    vm.roll(block.number + 1);
    assertEq(_sellWeth(0.1e18), 0.1e18 * RAW_BID / 1e18);
  }

  function test_ageFee_quadraticAfterGrace() public {
    uint256 _refBlock = block.number;

    vm.roll(_refBlock + 2); // age 2: 10 * 1^2
    assertEq(_sellWeth(0.1e18), _net(0.1e18 * RAW_BID / 1e18, 10));

    vm.roll(_refBlock + 4); // age 4: 10 * 3^2
    assertEq(_sellWeth(0.1e18), _net(0.1e18 * RAW_BID / 1e18, 90));
  }

  function test_ageFee_capped() public {
    ITesseraBook.BookConfig memory _config = _defaultConfig();
    _config.freshness.quadraticCoeff = 500;
    _configure(book, _config);

    vm.roll(block.number + 3); // 500 * 2^2 = 2000 > cap 1000
    assertEq(_sellWeth(0.1e18), _net(0.1e18 * RAW_BID / 1e18, 1000));
  }

  function test_ageFee_noFillAtExpiry() public {
    vm.roll(block.number + 9);
    _sellWeth(0.1e18); // age 9 still fills

    vm.roll(block.number + 1); // age 10
    _expectSwapRevert(ITesseraBook.QuoteRejected.selector);

    (, uint256 _out) = _preview(address(weth), address(usdc), 1e18);
    assertEq(_out, 0);
    (uint256 _in,) = _preview(address(weth), address(usdc), -1e6);
    assertEq(_in, type(uint256).max);
  }

  /*////////////////////////////////////////////////////////////
                             PRIORITY
  ////////////////////////////////////////////////////////////*/

  function test_priorityFee_onlyAboveThreshold() public {
    ITesseraBook.BookConfig memory _config = _defaultConfig();
    _config.priorityMultiplierPpm = 1_500_000; // threshold = 1.5 * reference
    _config.priorityFee = 200;
    _configure(book, _config);

    vm.prank(killer);
    engine.setPriorityFeeReference(2 gwei); // threshold 3 gwei

    vm.fee(10 gwei);
    vm.txGasPrice(13 gwei); // tip 3 gwei, not above the threshold
    assertEq(_sellWeth(0.1e18), 0.1e18 * RAW_BID / 1e18);

    vm.txGasPrice(13 gwei + 1); // tip above the threshold
    assertEq(_sellWeth(0.1e18), _net(0.1e18 * RAW_BID / 1e18, 200));
  }

  /*////////////////////////////////////////////////////////////
                             DEFAULT
  ////////////////////////////////////////////////////////////*/

  function test_defaultFee_setForCurrentBlock() public {
    uint96 _encoded = book.encodeDefaultFeeUpdate(300, uint64(block.number));
    vm.prank(operator);
    book.setDefaultFee(_encoded);

    assertEq(book.defaultFee(), 300);
    assertEq(_sellWeth(0.1e18), _net(0.1e18 * RAW_BID / 1e18, 300));
  }

  function test_defaultFee_staleBlockReverts() public {
    uint96 _encoded = book.encodeDefaultFeeUpdate(300, uint64(block.number));
    vm.roll(block.number + 1);
    vm.prank(operator);
    vm.expectRevert(ITesseraBook.StaleDefaultFeeUpdate.selector);
    book.setDefaultFee(_encoded);
  }

  function test_defaultFee_waivedForExemptSender() public {
    _setDefaultFee(300);
    _label(trader, DEFAULT_EXEMPT);

    assertEq(_sellWeth(0.1e18), 0.1e18 * RAW_BID / 1e18);
  }

  function test_defaultFee_waivedForExemptOrigin() public {
    _setDefaultFee(300);
    address _origin = makeAddr('origin');
    _label(_origin, DEFAULT_EXEMPT);

    vm.prank(trader, _origin);
    router.tesseraSwapWithAllowances(address(weth), address(usdc), 0.1e18, 0.1e18 * RAW_BID / 1e18, trader, '');
  }

  /*////////////////////////////////////////////////////////////
                             ADDRESS
  ////////////////////////////////////////////////////////////*/

  function test_addressFee_blacklistedSenderOrOrigin() public {
    _label(trader, BLACKLISTED);
    _expectSwapRevert(ITesseraBook.AddressBlacklisted.selector);

    _label(trader, ORDINARY);
    address _origin = makeAddr('origin');
    _label(_origin, BLACKLISTED);
    vm.prank(trader, _origin);
    vm.expectRevert(ITesseraBook.AddressBlacklisted.selector);
    router.tesseraSwapWithAllowances(address(weth), address(usdc), 1e18, 0, trader, '');
  }

  function test_addressFee_penalized() public {
    ITesseraBook.BookConfig memory _config = _defaultConfig();
    _config.addressFee = 150;
    _configure(book, _config);

    assertEq(_sellWeth(0.1e18), 0.1e18 * RAW_BID / 1e18);
    _label(trader, PENALIZED);
    assertEq(_sellWeth(0.1e18), _net(0.1e18 * RAW_BID / 1e18, 150));
  }

  function test_addressFee_fingerprintMatch() public {
    MockFingerprintHelper _helper = new MockFingerprintHelper();
    ITesseraBook.BookConfig memory _config = _defaultConfig();
    _config.addressFee = 150;
    _config.fingerprintHelper = address(_helper);
    _configure(book, _config);

    assertEq(_sellWeth(0.1e18), 0.1e18 * RAW_BID / 1e18);
    _helper.setMatch(true);
    assertEq(_sellWeth(0.1e18), _net(0.1e18 * RAW_BID / 1e18, 150));
  }

  function test_whitelistOnly() public {
    ITesseraBook.BookConfig memory _config = _defaultConfig();
    _config.whitelistOnly = true;
    _config.addressFee = 150;
    _configure(book, _config);

    _expectSwapRevert(ITesseraBook.AddressNotWhitelisted.selector);

    _label(trader, DEFAULT_EXEMPT);
    assertEq(_sellWeth(0.1e18), 0.1e18 * RAW_BID / 1e18);
  }

  /*////////////////////////////////////////////////////////////
                         ALL FEE COMPONENTS
  ////////////////////////////////////////////////////////////*/

  function test_fee_sumOfAllComponents() public {
    MockModeFeeHelper _modeHelper = new MockModeFeeHelper();
    _modeHelper.setFee(2, 7);
    vm.prank(operator);
    book.setModeFeeHelper(address(_modeHelper));

    ITesseraBook.BookConfig memory _config = _defaultConfig();
    _config.baseFee = 100;
    _config.addressFee = 150;
    _config.priorityFee = 200;
    _configure(book, _config);

    _setDefaultFee(300);
    vm.prank(killer);
    engine.setPriorityFeeReference(1 gwei);
    _label(trader, PENALIZED);

    vm.roll(block.number + 3); // age 3: 10 * 2^2 = 40
    _setDefaultFee(300);
    vm.fee(1 gwei);
    vm.txGasPrice(3 gwei);

    // mode 7 + age 40 + base 100 + default 300 + priority 200 + address 150
    (, uint256 _out) = _swap(address(weth), address(usdc), 0.1e18, hex'02');
    assertEq(_out, _net(0.1e18 * RAW_BID / 1e18, 797));
  }
}
