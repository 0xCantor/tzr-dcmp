// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice Helpers the pool staticcalls (set by the operator).
interface IFingerprintHelper {
  /// @dev 0x1ed58fc8. true = this (origin, sender) pair matches a known pattern and pays `addressFee`.
  function matches(address origin, address sender) external view returns (bool);
}
