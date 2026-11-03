// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////////////////////
    Tessera book PROXY, i.e. the quote update (anchor / spread / refBlock / tag), the ~27k-gas path from the paper.

    WHERE IT LIVES: in the book proxy (one per pair, deployed by the engine), not in the implementation.
    Sources: runtime bytecode embedded in the engine's createBook, and the Dedaub decompilation of the live proxy
    0x4B963fB4A26f082D94f964FA3c2764821Cc06Bd4 (the two agree).

    HOW IT WORKS
      - There is no function selector. An authorised updater sends one word, which is written verbatim into slot 0.
        (Calldata shorter than 32 bytes is zero-padded: the sample tx is 25 bytes, the 7 low zero bytes are dropped.)
      - Authorised = one of 10 addresses baked into the proxy (immutables, listed below).
      - The only check is on the tag: it must advance by 1..15 (mod 256). That orders updates, rejects replays and
        stale ones, and lets several updaters race for the same block.
      - NOTHING else is validated: refBlock is whatever the updater says (not block.number), and the anchor and
        spread have no range checks. An old or future refBlock just makes swaps refuse to fill (age fee).

    PACKED WORD (high bit -> low bit), checked against the sample tx
      0xd5 00032d03de 00000000000000000f8aecc9e95c9480 000015 (+ 7 zero bytes)
        tag u8 | refBlock u40 | priceAnchor u128 | spreadPpm u24 | 56 unused bits
        213    | 53281758    | 1.1199678e18       | 21 ppm       | 0

    OTHER BEHAVIOUR
      - selector 0xa9977bfe: public getter, returns slot 0.
      - every OTHER call from an updater is ALSO treated as a quote update (the updater check runs before the
        delegatecall), so an updater can never call the book's own functions; the book operator is another address.
      - ADMIN (the engine) calling upgradeToAndCall upgrades the implementation; any other call, from the admin or
        anyone else, is delegatecalled to the implementation.
//////////////////////////////////////////////////////////////////////////////////////////*/

contract TesseraBookProxy {
  event Upgraded(address indexed implementation);

  error InvalidTagStep(); // original: bare revert, no data

  /// @dev Tag must advance by 1..15, wrapping at 256.
  uint8 internal constant MAX_TAG_STEP = 15;

  bytes4 internal constant QUOTE_GETTER = 0xa9977bfe; // name unknown
  bytes4 internal constant UPGRADE_TO_AND_CALL = 0x4f1ef286;

  /// @dev ERC-1967 implementation slot.
  bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  /// @dev Slot 0, shared with the implementation (`Quote public quote`). Raw word, layout above.
  uint256 internal quoteWord;

  // The 10 quote updaters of THIS proxy (read from the live book 0x4B96...6Bd4; other books may differ):
  //   0x2744e8f08cd7f0ba46530420bf38fc7476e9e754   0x2913814212d15889a7fe91ef5b17c7530074146c
  //   0x4911eb2cf514f8e600d0749b415f7e4c1e75e70e   0x825c1ccbf3b65052f2484162c5abf22df4f02480
  //   0xd4396d6159e35bf3d5b64453ae7d272127e54d21   0x41167f171fec544d285e2f122078f7034ff8b474  <- sample tx sender
  //   0x5ec4e681249b29df991bc8cfc45f35326e9ea416   0x7c8fa49c9012fa32b9e7e14f5e6782895c7c88d1
  //   0xa6286e0646d55cade61c3a40508815960c5f17d8   0xcce5b80a78d9b2d0232e1c6ec83eb7cf470238d6
  address internal immutable UPDATER_0;
  address internal immutable UPDATER_1;
  address internal immutable UPDATER_2;
  address internal immutable UPDATER_3;
  address internal immutable UPDATER_4;
  address internal immutable UPDATER_5;
  address internal immutable UPDATER_6;
  address internal immutable UPDATER_7;
  address internal immutable UPDATER_8;
  address internal immutable UPDATER_9;

  /// @dev The engine / book manager: 0x31e99e05fee3dce580af777c3fd63ee1b3b40c17.
  address internal immutable ADMIN;

  /// @dev Constructor arguments are reconstructed from the engine's createBook (12 addresses + init data):
  ///      implementation, admin, the 10 updaters, and the calldata of `initialize`, delegatecalled once.
  constructor(address _implementation, address _admin, address[10] memory _updaters, bytes memory _initData) payable {
    ADMIN = _admin;
    UPDATER_0 = _updaters[0];
    UPDATER_1 = _updaters[1];
    UPDATER_2 = _updaters[2];
    UPDATER_3 = _updaters[3];
    UPDATER_4 = _updaters[4];
    UPDATER_5 = _updaters[5];
    UPDATER_6 = _updaters[6];
    UPDATER_7 = _updaters[7];
    UPDATER_8 = _updaters[8];
    UPDATER_9 = _updaters[9];

    require(_implementation.code.length != 0, 'ERC1967InvalidImplementation');
    assembly {
      sstore(IMPLEMENTATION_SLOT, _implementation)
    }
    emit Upgraded(_implementation);

    if (_initData.length == 0) {
      require(msg.value == 0, 'ERC1967NonPayable');
    } else {
      (bool _ok,) = _implementation.delegatecall(_initData);
      require(_ok, 'FailedCall');
    }
  }

  /*////////////////////////////////////////////////////////////
                       EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @dev What an updater sends. (Off-chain helper.)
  function encodeQuote(
    uint8 _tag,
    uint40 _refBlock,
    uint128 _priceAnchor,
    uint24 _spreadPpm
  ) public pure returns (bytes32) {
    return bytes32(
      (uint256(_tag) << 248) | (uint256(_refBlock) << 208) | (uint256(_priceAnchor) << 80) | (uint256(_spreadPpm) << 56)
    );
  }

  /// @dev Reads slot 0 the way the implementation does.
  function decodeQuote(uint256 _word)
    public
    pure
    returns (uint8 _tag, uint40 _refBlock, uint128 _priceAnchor, uint24 _spreadPpm)
  {
    _tag = uint8(_word >> 248);
    _refBlock = uint40(_word >> 208);
    _priceAnchor = uint128(_word >> 80);
    _spreadPpm = uint24(_word >> 56);
  }

  /*////////////////////////////////////////////////////////////
                       EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  fallback() external payable {
    // 1. Public getter.
    if (msg.data.length >= 4 && bytes4(msg.data) == QUOTE_GETTER) {
      uint256 _word = quoteWord;
      assembly {
        mstore(0x80, _word)
        return(0x80, 0x20)
      }
    }

    // 2. Authorised updater: any call is a quote update.
    if (_isUpdater(msg.sender)) {
      _updateQuote();
      return;
    }

    // 3. Everyone else.
    if (msg.sender == ADMIN && msg.sig == UPGRADE_TO_AND_CALL) _upgradeToAndCall();
    else _delegateToImplementation();
  }

  /*////////////////////////////////////////////////////////////
                    PRIVATE / INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @dev calldata[0:32] -> slot 0, if the tag moved forward by 1..15.
  function _updateQuote() private {
    uint256 _newQuote;
    assembly {
      _newQuote := calldataload(0) // zero-pads short calldata
    }

    uint8 _tagStep;
    unchecked {
      _tagStep = uint8(_newQuote >> 248) - uint8(quoteWord >> 248); // wraps mod 256
    }
    if (_tagStep == 0 || _tagStep > MAX_TAG_STEP) revert InvalidTagStep();

    quoteWord = _newQuote;
  }

  function _isUpdater(address _caller) private view returns (bool) {
    return _caller == UPDATER_0 || _caller == UPDATER_1 || _caller == UPDATER_2 || _caller == UPDATER_3
      || _caller == UPDATER_4 || _caller == UPDATER_5 || _caller == UPDATER_6 || _caller == UPDATER_7
      || _caller == UPDATER_8 || _caller == UPDATER_9;
  }

  /// @dev ERC-1967 upgradeToAndCall(address newImplementation, bytes data), admin only.
  function _upgradeToAndCall() private {
    (address _impl, bytes memory _data) = abi.decode(msg.data[4:], (address, bytes));
    require(_impl.code.length != 0, 'ERC1967InvalidImplementation');

    assembly {
      sstore(IMPLEMENTATION_SLOT, _impl)
    }
    emit Upgraded(_impl);

    if (_data.length == 0) {
      require(msg.value == 0, 'ERC1967NonPayable');
    } else {
      (bool _ok,) = _impl.delegatecall(_data);
      require(_ok, 'FailedCall');
    }
  }

  function _delegateToImplementation() private {
    assembly {
      calldatacopy(0, 0, calldatasize())
      let _ok := delegatecall(gas(), sload(IMPLEMENTATION_SLOT), 0, calldatasize(), 0, 0)
      returndatacopy(0, 0, returndatasize())
      if iszero(_ok) { revert(0, returndatasize()) }
      return(0, returndatasize())
    }
  }
}
