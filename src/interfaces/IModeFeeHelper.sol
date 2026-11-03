// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice Helper the book staticcalls (set by the operator).
interface IModeFeeHelper {
  /// @dev 0x4a89bec0. Fee in ppm for the swap's mode byte; the book clamps it to 1e6.
  function modeFee(uint8 _mode) external view returns (uint256);
}
