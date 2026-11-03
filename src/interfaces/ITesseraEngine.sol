// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice The engine = book manager = book factory (0x31e99e05fee3dce580af777c3fd63ee1b3b40c17).
interface ITesseraEngine {
  /*////////////////////////////////////////////////////////////
                             STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @dev The 26 arguments of createBook (0xb8744eb4), in order. The middle fields (fees, netting, age curve,
  ///      priority) are mapped from the argument TYPES and the book's range checks; the order within them is the
  ///      natural one but not proven. The book itself ignores `updaters` and `operator` in `reconfigure`; they are
  ///      used by the engine to build the proxy and to initialize the book. All fields are static, so this struct
  ///      encodes exactly like the 26 flat words of the original.
  struct BookParams {
    address baseToken;
    address quoteToken;
    uint8 baseDecimals;
    uint8 quoteDecimals;
    uint32 baseFee; //               <= 1e6
    bool nettingEnabled;
    uint32 factor; //                <= 1e6
    uint64 blocksExpiryAge;
    uint64 blocksGracePeriod;
    uint32 quadraticCoeff;
    uint32 ageFeeCap; //             <= 1e6
    uint32 addressFee;
    bool whitelistOnly;
    uint32 priorityMultiplierPpm;
    uint32 priorityFee;
    address[10] updaters; //         allowed to write the book's quote (see the proxy)
    address operator; //             the book's operator: book updates, config, default fee
  }

  /*////////////////////////////////////////////////////////////
                             ERRORS
  ////////////////////////////////////////////////////////////*/

  error NotMultiSig(); //              T1
  error NotActive(); //                T16
  error NotKiller(); //                T31
  error NotOwner(); //                 original message unknown
  error NotExclusionSetter(); //       bare revert
  error ZeroAddress(); //              T21 (unverified which of the two checks)
  error IdenticalTokens(); //          T22
  error ZeroAmount(); //               T10
  error AmountTooLarge(); //           T34 (int256.min)
  error NoRoute(); //                  T33
  error InvalidPath(); //              T35 (books / tokens length mismatch)
  error PathEndsMismatch(); //         message unknown
  error BookTokenMismatch(); //        message unknown
  error FeeAbove100Percent();
  error LengthMismatch();
  error TransferFailed(address token);
  error EthTransferFailed();

  /*////////////////////////////////////////////////////////////
                       EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Hardcoded governance address (also passed to every book as its multiSigOwner).
  function multiSigOwner() external view returns (address);

  /// @notice Only caller of `swapAmount` (the router).
  function owner() external view returns (address);

  /// @notice Global kill switch; every book reads it.
  function isActive() external view returns (bool);

  /// @notice Intermediate token for two-hop routes.
  function hub() external view returns (address);

  /// @notice Book logic used for new books; updated by `upgradeAllBooks`.
  function implementation() external view returns (address);

  /// @notice May set `levelExclusionDeadlineBlock`.
  function exclusionSetter() external view returns (address);

  /// @notice Pause switches, address labels and the priority-fee reference.
  function killer() external view returns (address);

  /// @notice Reference priority fee; books charge a surcharge above reference * priorityMultiplier / 1e6.
  function priorityFeeReference() external view returns (uint256);

  /// @notice 0 ordinary, 1 default-exempt, 2 penalized, 3 blacklisted (read by the books).
  function addressLabel(address _account) external view returns (uint16);

  /// @notice While block.number is below this, books hide their `excludedBestLevels` best levels.
  function levelExclusionDeadlineBlock() external view returns (uint256);

  function swapAmountView(
    address _tokenIn,
    address _tokenOut,
    int256 _amountSpecified,
    address _sender
  ) external view returns (uint256 _amountIn, uint256 _amountOut);

  /// @notice Order-independent key of a pair.
  function pairKey(address _a, address _b) external pure returns (bytes32);

  /// @notice Original 0x15f09335. Book of a pair, and whether the pair is known.
  function getBook(address _a, address _b) external view returns (bool _exists, address _book);

  function bookCount() external view returns (uint256);

  function bookAt(uint256 _i) external view returns (bytes32 _key, address _book);

  function allBooks() external view returns (bytes32[] memory _keys, address[] memory _books);

  /*////////////////////////////////////////////////////////////
                       EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Router only. Executes a swap through one book, or two books via `hub`. Original 0xe70c3a4d.
  function swapAmount(
    address _tokenIn,
    address _tokenOut,
    int256 _amountSpecified,
    address _sender,
    bytes calldata _swapData
  ) external returns (uint256 _amountIn, uint256 _amountOut);

  /// @notice Multisig only. Deploys a book proxy for a pair, initializes and configures it. Original 0xb8744eb4.
  function createBook(BookParams calldata _params) external returns (address _book);

  /// @notice Killer only. Stops every book: they all read `isActive`.
  function killContract() external;

  /// @notice Killer only. Original 0x7bceec47.
  function enableTradingAll() external;

  /// @notice Killer only. Original 0x988b3bd8.
  function disableTradingAll() external;

  /// @notice Killer only. Original 0xca82e2e4.
  function enableTrading(address _book) external;

  /// @notice Killer only. Original 0x9577588e.
  function disableTrading(address _book) external;

  /// @notice Killer only. Original 0xae4f7967.
  function setAddressLabel(address _account, uint16 _label) external;

  /// @notice Killer only. Original 0xcd72e1a3.
  function setPriorityFeeReference(uint256 _reference) external;

  /// @notice Exclusion setter only. Original 0x5ad90747.
  function setLevelExclusionDeadline(uint256 _blockNumber) external;

  /// @notice Multisig only. Re-opens the engine.
  function unkillContract() external;

  /// @notice Multisig only. Original 0x162df1f2.
  function setOwner(address _newOwner) external;

  /// @notice Multisig only. Original 0x8ca9a127.
  function setKiller(address _newKiller) external;

  /// @notice Multisig only. Original 0x87b1d55b.
  function setExclusionSetter(address _newSetter) external;

  /// @notice Multisig only. Original 0xa576c919.
  function upgradeAllBooks(address _newImplementation) external;

  /// @notice Multisig only. Original 0x2c88026b (`rescueTokensss1337`).
  function rescueTokens(address[] calldata _tokens, uint256[] calldata _amounts, address _to) external;

  /// @notice Multisig only. Original 0x8f05e71b (`rescueEthhh1337`).
  function rescueEth(uint256 _amount, address _to) external;
}
