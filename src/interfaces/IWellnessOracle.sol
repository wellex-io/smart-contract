// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IWellnessOracle
/// @notice Oracle interface that returns APY in basis points per user.
interface IWellnessOracle {
    /// @notice Returns APY (in basis points) for a user.
    /// @param account User address.
    /// @return APY value in basis points (100 = 1%).
    function getApyBps(address account) external view returns (uint256);
}
