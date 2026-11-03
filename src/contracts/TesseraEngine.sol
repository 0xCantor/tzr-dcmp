// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ITesseraBook} from '../interfaces/ITesseraBook.sol';
import {ITesseraBookProxy} from '../interfaces/ITesseraBookProxy.sol';
import {ITesseraEngine} from '../interfaces/ITesseraEngine.sol';

import {TesseraBookProxy} from './TesseraBookProxy.sol';

/*//////////////////////////////////////////////////////////////////////////////////////////
    Tessera engine = book manager = book factory (0x31e99e05fee3dce580af777c3fd63ee1b3b40c17, proxy admin of every book).
    Translated from the Dedaub decompilation of the engine. Not compiled, not tested.

    ROLES
      multisig         hardcoded constant; governance and createBook
      owner            the only caller of swapAmount (the TesseraSwap router)
      killer           pause switches, address labels, priority-fee reference ("kill" role)
      exclusionSetter  sets the level-exclusion deadline

    Revert reasons in the original are short codes ("T1", "T16", ...). They are custom errors, code in a comment.
//////////////////////////////////////////////////////////////////////////////////////////*/

contract TesseraEngine is ITesseraEngine {
  uint256 internal constant PPM = 1e6;

  /// @dev Hardcoded governance address (also passed to every book as its multiSigOwner).
  /// NOTE: tessera hardcodes it ofc, but it can be settable
  address public constant multiSigOwner = 0xdbD31EA3dE20A2b36a5bD36C7167699F2450b5C6;

  /*////////////////////////////////////////////////////////////
                           STORAGE
  ////////////////////////////////////////////////////////////*/

  // slot 0
  address public owner; //            only caller of swapAmount
  bool public isActive; //            global kill switch; every book reads it

  // slots 1..4
  address public hub; //              intermediate token for two-hop routes (no setter: set at deployment)
  address public implementation; //   book logic used for new books; updated by upgradeAllBooks
  address public exclusionSetter; //  may set levelExclusionDeadlineBlock
  address public killer;

  // slot 5
  /// @dev Reference priority fee; books charge a surcharge above reference * priorityMultiplier / 1e6.
  uint256 public priorityFeeReference;

  // slots 6..8: book registry
  bytes32[] internal pairKeys;
  mapping(bytes32 => uint256) internal pairIndexPlusOne;
  mapping(bytes32 => address) internal bookOfPair;

  // slot 9
  /// @dev 0 ordinary, 1 default-exempt, 2 penalized, 3 blacklisted (read by the books).
  mapping(address => uint16) public addressLabel;

  // slot 10
  /// @dev While block.number is below this, books hide their `excludedBestLevels` best levels.
  uint256 public levelExclusionDeadlineBlock;

  modifier onlyMultiSig() {
    if (msg.sender != multiSigOwner) revert NotMultiSig();
    _;
  }

  modifier onlyKiller() {
    if (msg.sender != killer) revert NotKiller();
    _;
  }

  modifier whenActive() {
    if (!isActive) revert NotActive();
    _;
  }

  /// @dev The deployment is not decompiled: these initial values are my guess at what the constructor sets.
  constructor(address _owner, address _hub, address _implementation, address _exclusionSetter, address _killer) {
    owner = _owner;
    hub = _hub;
    implementation = _implementation;
    exclusionSetter = _exclusionSetter;
    killer = _killer;
    isActive = true;
  }

  receive() external payable {}

  /*////////////////////////////////////////////////////////////
                       EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Same routing as `swapAmount`, but only quotes (books' previews, which carry no fee mode). Original 0x77c8b706. Public.
  function swapAmountView(
    address _tokenIn,
    address _tokenOut,
    int256 _amountSpecified,
    address _sender
  ) external view returns (uint256 _amountIn, uint256 _amountOut) {
    (address[] memory _tokens, address[] memory _books) = _prepare(_tokenIn, _tokenOut, _amountSpecified);

    if (_amountSpecified > 0) {
      _amountIn = uint256(_amountSpecified);
      _amountOut = _amountIn;
      for (uint256 _i; _i < _books.length; ++_i) {
        bool _takeBidSide = _takeBidSideOf(_books[_i], _tokens[_i], _tokens[_i + 1]);
        _amountOut = ITesseraBook(_books[_i]).previewSell(_takeBidSide, _amountOut, _sender);
      }
    } else {
      _amountOut = uint256(-_amountSpecified);
      _amountIn = _amountOut;
      for (uint256 _i = _books.length; _i > 0; --_i) {
        uint256 _hop = _i - 1;
        bool _takeBidSide = _takeBidSideOf(_books[_hop], _tokens[_hop], _tokens[_hop + 1]);
        _amountIn = ITesseraBook(_books[_hop]).previewBuy(_takeBidSide, _amountIn, _sender);
      }
    }
  }

  /// @dev Order-independent key of a pair. The exact encoding of the hash input is not recoverable from the
  ///      decompilation (a 64-byte hash of the two sorted addresses); compare `pairKey` with a known key to check.
  function pairKey(address _a, address _b) public pure returns (bytes32) {
    (address _lo, address _hi) = _a < _b ? (_a, _b) : (_b, _a);
    return keccak256(abi.encode(_lo, _hi));
  }

  /// @notice Original 0x15f09335. Book of a pair, and whether the pair is known.
  function getBook(address _a, address _b) external view returns (bool _exists, address _book) {
    (_book, _exists) = _lookup(_a, _b);
  }

  function bookCount() external view returns (uint256) {
    return pairKeys.length;
  }

  function bookAt(uint256 _i) external view returns (bytes32 _key, address _book) {
    _key = pairKeys[_i];
    _book = bookOfPair[_key];
  }

  function allBooks() external view returns (bytes32[] memory _keys, address[] memory _books) {
    _keys = pairKeys;
    _books = new address[](_keys.length);
    for (uint256 _i; _i < _keys.length; ++_i) {
      _books[_i] = bookOfPair[_keys[_i]];
    }
  }

  /*////////////////////////////////////////////////////////////
                       EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Executes a swap through one book, or two books via `hub`. Original 0xe70c3a4d.
  /// @param _amountSpecified > 0: exact input (calls `sell` hop by hop, forward).
  ///                         < 0: exact output (calls `buy` hop by hop, backward, each hop's input is the previous hop's wanted output).
  /// @param _sender passed to every book unchanged: the router's `msg.sender`. Books use it for their address checks.
  /// @param _swapData passed to every book unchanged; its first byte is the fee mode.
  /// @return _amountIn what the trader pays in `_tokenIn`.
  /// @return _amountOut what the trader receives in `_tokenOut`.
  function swapAmount(
    address _tokenIn,
    address _tokenOut,
    int256 _amountSpecified,
    address _sender,
    bytes calldata _swapData
  ) external returns (uint256 _amountIn, uint256 _amountOut) {
    if (msg.sender != owner) revert NotOwner();
    (address[] memory _tokens, address[] memory _books) = _prepare(_tokenIn, _tokenOut, _amountSpecified);

    if (_amountSpecified > 0) {
      _amountIn = uint256(_amountSpecified);
      _amountOut = _amountIn;
      for (uint256 _i; _i < _books.length; ++_i) {
        bool _takeBidSide = _takeBidSideOf(_books[_i], _tokens[_i], _tokens[_i + 1]);
        _amountOut = ITesseraBook(_books[_i]).sell(_takeBidSide, _amountOut, _sender, _swapData);
      }
    } else {
      _amountOut = uint256(-_amountSpecified);
      _amountIn = _amountOut;
      for (uint256 _i = _books.length; _i > 0; --_i) {
        uint256 _hop = _i - 1;
        bool _takeBidSide = _takeBidSideOf(_books[_hop], _tokens[_hop], _tokens[_hop + 1]);
        _amountIn = ITesseraBook(_books[_hop]).buy(_takeBidSide, _amountIn, _sender, _swapData);
      }
    }
  }

  /// @notice Deploys a book proxy for a pair, initializes it and sets its parameters. Original 0xb8744eb4.
  /// @dev Creating a pair that already exists REPLACES the registered book (the old one stays in the key list once).
  function createBook(BookParams calldata _params) external onlyMultiSig whenActive returns (address _book) {
    if (_params.baseToken == address(0) || _params.quoteToken == address(0)) revert ZeroAddress();
    if (_params.baseToken == _params.quoteToken) revert IdenticalTokens();
    if (_params.baseFee > PPM || _params.factor > PPM) revert FeeAbove100Percent();

    bytes memory _initData = abi.encodeCall(
      ITesseraBook.initialize,
      (
        multiSigOwner,
        address(this),
        _params.operator,
        _params.baseToken,
        _params.quoteToken,
        _params.baseDecimals,
        _params.quoteDecimals
      )
    );
    _book = address(new TesseraBookProxy(implementation, address(this), _params.updaters, _initData));

    _register(_params.baseToken, _params.quoteToken, _book);
    ITesseraBook(_book).reconfigure(_params);
  }

  /// @notice Stops every book: they all read `isActive`. Original `killContract`.
  function killContract() external onlyKiller {
    isActive = false;
  }

  /// @notice Original 0x7bceec47. No isActive check.
  function enableTradingAll() external onlyKiller {
    for (uint256 _i; _i < pairKeys.length; ++_i) {
      ITesseraBook(bookOfPair[pairKeys[_i]]).enableTrading();
    }
  }

  /// @notice Original 0x988b3bd8.
  function disableTradingAll() external onlyKiller {
    for (uint256 _i; _i < pairKeys.length; ++_i) {
      ITesseraBook(bookOfPair[pairKeys[_i]]).disableTrading();
    }
  }

  /// @notice Original 0xca82e2e4. Any contract, not only registered books.
  function enableTrading(address _book) external onlyKiller {
    ITesseraBook(_book).enableTrading();
  }

  /// @notice Original 0x9577588e.
  function disableTrading(address _book) external onlyKiller {
    ITesseraBook(_book).disableTrading();
  }

  /// @notice Original 0xae4f7967. 0 ordinary, 1 default-exempt, 2 penalized, 3 blacklisted.
  function setAddressLabel(address _account, uint16 _label) external onlyKiller whenActive {
    addressLabel[_account] = _label;
  }

  /// @notice Original 0xcd72e1a3.
  function setPriorityFeeReference(uint256 _reference) external onlyKiller whenActive {
    priorityFeeReference = _reference;
  }

  /// @notice Original 0x5ad90747. Not gated by isActive.
  function setLevelExclusionDeadline(uint256 _blockNumber) external {
    if (msg.sender != exclusionSetter) revert NotExclusionSetter();
    levelExclusionDeadlineBlock = _blockNumber;
  }

  /// @notice Original `unkillContract`. Not gated by isActive (it is what re-opens it).
  function unkillContract() external onlyMultiSig {
    isActive = true;
  }

  /// @notice Original 0x162df1f2.
  function setOwner(address _newOwner) external onlyMultiSig whenActive {
    owner = _newOwner;
  }

  /// @notice Original 0x8ca9a127.
  function setKiller(address _newKiller) external onlyMultiSig whenActive {
    killer = _newKiller;
  }

  /// @notice Original 0x87b1d55b.
  function setExclusionSetter(address _newSetter) external onlyMultiSig whenActive {
    exclusionSetter = _newSetter;
  }

  /// @notice Original 0xa576c919. Upgrades every registered book (the engine is their proxy admin) and remembers the
  ///         implementation for new books. Books replaced by a later createBook are not in the list any more.
  function upgradeAllBooks(address _newImplementation) external onlyMultiSig whenActive {
    for (uint256 _i; _i < pairKeys.length; ++_i) {
      ITesseraBookProxy(bookOfPair[pairKeys[_i]]).upgradeToAndCall(_newImplementation, '');
    }
    implementation = _newImplementation;
  }

  /// @notice Original 0x2c88026b (`rescueTokensss1337`).
  function rescueTokens(address[] calldata _tokens, uint256[] calldata _amounts, address _to) external onlyMultiSig {
    if (_tokens.length != _amounts.length) revert LengthMismatch();

    for (uint256 _i; _i < _tokens.length; ++_i) {
      // TODO: use OpenZeppelin's SafeERC20.
      (bool _ok, bytes memory _ret) = _tokens[_i].call(abi.encodeWithSelector(bytes4(0xa9059cbb), _to, _amounts[_i]));
      bool _success = _ok && (_ret.length == 0 ? _tokens[_i].code.length != 0 : abi.decode(_ret, (bool)));
      if (!_success) revert TransferFailed(_tokens[_i]);
    }
  }

  /// @notice Original 0x8f05e71b (`rescueEthhh1337`).
  function rescueEth(uint256 _amount, address _to) external onlyMultiSig {
    (bool _ok,) = _to.call{value: _amount}('');
    if (!_ok) revert EthTransferFailed();
  }

  /*////////////////////////////////////////////////////////////
                    PRIVATE / INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @dev All input checks, in the original order. tokens.length == books.length + 1.
  function _prepare(
    address _tokenIn,
    address _tokenOut,
    int256 _amountSpecified
  ) private view returns (address[] memory _tokens, address[] memory _books) {
    if (_tokenIn == _tokenOut) revert IdenticalTokens();

    (_tokens, _books) = _findRoute(_tokenIn, _tokenOut);
    if (_books.length == 0) revert NoRoute();
    if (_books.length + 1 != _tokens.length) revert InvalidPath();
    if (_tokens[0] != _tokenIn || _tokens[_books.length] != _tokenOut) revert PathEndsMismatch();

    if (_amountSpecified == 0) revert ZeroAmount();
    if (_amountSpecified == type(int256).min) revert AmountTooLarge();
  }

  /// @dev A direct book if there is one, otherwise tokenIn -> hub -> tokenOut when both legs exist, otherwise empty.
  ///      (The decompilation shows only the second leg's check; requiring both is the only sensible reading.)
  function _findRoute(
    address _tokenIn,
    address _tokenOut
  ) private view returns (address[] memory _tokens, address[] memory _books) {
    (address _direct, bool _hasDirect) = _lookup(_tokenIn, _tokenOut);
    if (_hasDirect) {
      _tokens = new address[](2);
      (_tokens[0], _tokens[1]) = (_tokenIn, _tokenOut);
      _books = new address[](1);
      _books[0] = _direct;
      return (_tokens, _books);
    }

    (address _first, bool _hasFirst) = _lookup(_tokenIn, hub);
    (address _second, bool _hasSecond) = _lookup(hub, _tokenOut);
    if (_hasFirst && _hasSecond) {
      _tokens = new address[](3);
      (_tokens[0], _tokens[1], _tokens[2]) = (_tokenIn, hub, _tokenOut);
      _books = new address[](2);
      (_books[0], _books[1]) = (_first, _second);
    }
    // else: both arrays empty -> NoRoute
  }

  /// @dev true = the trader sells BASE into the bids (the book pays quote); false = sells QUOTE into the asks.
  function _takeBidSideOf(address _book, address _from, address _to) private view returns (bool) {
    address _base = ITesseraBook(_book).baseToken();
    address _quote = ITesseraBook(_book).quoteToken();

    if (_base == _from && _quote == _to) return true;
    if (_quote == _from && _base == _to) return false;
    revert BookTokenMismatch();
  }

  function _lookup(address _a, address _b) private view returns (address _book, bool _exists) {
    bytes32 _key = pairKey(_a, _b);
    _book = bookOfPair[_key];
    _exists = _book != address(0) || pairIndexPlusOne[_key] != 0;
  }

  function _register(address _a, address _b, address _book) private {
    bytes32 _key = pairKey(_a, _b);
    bookOfPair[_key] = _book;
    if (pairIndexPlusOne[_key] == 0) {
      pairKeys.push(_key);
      pairIndexPlusOne[_key] = pairKeys.length;
    }
  }
}
