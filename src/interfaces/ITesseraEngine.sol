// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

interface ITesseraEngine {
  function swapAmount(
    address tokenIn,
    address tokenOut,
    int256 amountSpecified,
    address sender,
    bytes calldata swapData
  ) external returns (uint256, uint256);
  function swapAmountView(
    address tokenIn,
    address tokenOut,
    int256 amountSpecified,
    address sender
  ) external view returns (uint256 amountIn, uint256 amountOut);
}
