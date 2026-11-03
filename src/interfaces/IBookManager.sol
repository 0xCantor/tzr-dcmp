// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice What a book calls on its manager (the engine). Selectors are the real ones where known.
interface IBookManager {
  /// @dev The manager's label for an address.
  enum AddressLabel {
    Ordinary,
    DefaultExempt, // default fee waived
    Penalized, //     pays addressFee
    Blacklisted //    cannot trade
  }

  /// @dev 0x22f3e2d4. Global kill switch.
  function isActive() external view returns (bool);

  /// @dev 0x8c4cdb49 (real name unknown). While block.number is below the returned block,
  ///      the book hides its `excludedBestLevels` best levels.
  function levelExclusionDeadlineBlock() external view returns (uint256);

  /// @dev 0x8547d972 (real name unknown). The manager's address registry.
  function addressLabel(address _account) external view returns (AddressLabel);

  /// @dev 0xeb101276 (real name unknown). A reference priority fee; the book charges a surcharge to
  ///      trades whose priority fee is above `reference * priorityMultiplierPpm / 1e6`.
  function priorityFeeReference() external view returns (uint256);
}
