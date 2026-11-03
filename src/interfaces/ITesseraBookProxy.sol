// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice The proxy-admin function the engine uses on every book (ERC-1967).
interface ITesseraBookProxy {
  function upgradeToAndCall(address _newImplementation, bytes calldata _data) external payable;
}
