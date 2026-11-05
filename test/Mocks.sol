// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract MockToken is ERC20 {
  uint8 private immutable DECIMALS;

  constructor(string memory _symbol, uint8 _decimals) ERC20(_symbol, _symbol) {
    DECIMALS = _decimals;
  }

  function decimals() public view override returns (uint8) {
    return DECIMALS;
  }

  function mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }
}

/// @dev Answers the raw selector the book calls (0x4a89bec0, name unknown): f(uint8 mode) -> ppm.
contract MockModeFeeHelper {
  mapping(uint8 => uint256) public feeOf;

  function setFee(uint8 _mode, uint256 _fee) external {
    feeOf[_mode] = _fee;
  }

  fallback(bytes calldata _data) external returns (bytes memory) {
    require(msg.sig == bytes4(0x4a89bec0), 'selector');
    return abi.encode(feeOf[abi.decode(_data[4:], (uint8))]);
  }
}

/// @dev Answers the raw selector the book calls (0x1ed58fc8, name unknown): f(origin, sender) -> bool.
contract MockFingerprintHelper {
  bool public isMatch;

  function setMatch(bool _isMatch) external {
    isMatch = _isMatch;
  }

  fallback(bytes calldata) external returns (bytes memory) {
    require(msg.sig == bytes4(0x1ed58fc8), 'selector');
    return abi.encode(isMatch ? uint256(1) : uint256(0));
  }
}
