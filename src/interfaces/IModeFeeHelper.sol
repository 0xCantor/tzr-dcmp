// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IModeFeeHelper {
  /// @dev 0x4a89bec0. Fee in ppm for the swap's mode byte; the pool clamps it to 1e6.
  function modeFee(uint8 mode) external view returns (uint256);
}
