// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

interface ITesseraSwapCallback {
  function tesseraSwapCallback(int256, int256, bytes calldata) external;
}
