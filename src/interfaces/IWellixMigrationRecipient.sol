// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IWellixMigrationRecipient
/// @notice Optional V2 hook: canonical gateway V1 address is trusted by recipient when ingesting off-chain backed state.
/// @dev MVP stub — implement in a future gateway; V1 only exposes `exportUserLedger` + this interface for integration design.
interface IWellixMigrationRecipient {
    /// @param user Original staker (same address on V2 if EOA).
    /// @param activePrincipal_ Value from V1 `activePrincipalByUser` at migration time.
    /// @param pendingRewardsAmount Value from V1 `pendingRewards` at migration time.
    /// @param positionIds Position ids from V1 (may be empty if V2 only cares about aggregates).
    function acceptWellixV1LedgerSnapshot(
        address user,
        uint256 activePrincipal_,
        uint256 pendingRewardsAmount,
        uint256[] calldata positionIds
    ) external;
}
