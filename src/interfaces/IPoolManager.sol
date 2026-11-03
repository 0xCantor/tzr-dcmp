// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IPoolManager {
  /// @dev The manager's label for an address.
  enum AddressLabel {
    Ordinary,
    DefaultExempt, // default fee waived
    Penalized, //     pays addressFee
    Blacklisted //    cannot trade
  }

  function isActive() external view returns (bool);

  /// @dev selector 0x8c4cdb49 (real name unknown). While block.number is below the returned block,
  ///      the pool hides its `excludedBestLevels` best levels.
  function levelExclusionDeadlineBlock() external view returns (uint256);

  /// @dev selector 0x8547d972 (real name unknown). The manager's address registry.
  function addressLabel(address account) external view returns (AddressLabel);

  /// @dev selector 0xeb101276 (real name unknown). A reference priority fee; the pool charges a surcharge to
  ///      trades whose priority fee is above `reference * priorityMultiplierPpm / 1e6`.
  ///      The decompilation lost the call target; every other manager call goes to `poolManager`, so I assume it too.
  function priorityFeeReference() external view returns (uint256);
}
