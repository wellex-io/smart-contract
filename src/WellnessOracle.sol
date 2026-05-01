// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IWellnessOracle } from "./interfaces/IWellnessOracle.sol";

/// @title WellnessOracle
/// @notice Role-gated APY oracle used by the staking vault for reward entitlement calculation.
contract WellnessOracle is AccessControl, IWellnessOracle {
    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN_ROLE");

    uint256 public constant MAX_APY_BPS = 100_000;

    mapping(address account => uint256 apyBps) private _apyBps;

    error ZeroAddress();
    error InvalidApyBps(uint256 apyBps);
    error LengthMismatch();

    event UserApyUpdated(address indexed account, uint256 apyBps);

    /// @param admin Address that receives DEFAULT_ADMIN_ROLE and ORACLE_ADMIN_ROLE.
    constructor(address admin) {
        if (admin == address(0)) {
            revert ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_ADMIN_ROLE, admin);
    }

    /// @notice Sets APY (in bps) for one account.
    /// @param account User address.
    /// @param apyBps APY in basis points (100 = 1%).
    function setUserApyBps(address account, uint256 apyBps) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (account == address(0)) {
            revert ZeroAddress();
        }
        if (apyBps > MAX_APY_BPS) {
            revert InvalidApyBps(apyBps);
        }

        _apyBps[account] = apyBps;
        emit UserApyUpdated(account, apyBps);
    }

    /// @notice Batch-sets APY values for multiple accounts.
    /// @param accounts User addresses.
    /// @param apyBpsList APY values in basis points.
    function setBatchUserApyBps(address[] calldata accounts, uint256[] calldata apyBpsList)
        external
        onlyRole(ORACLE_ADMIN_ROLE)
    {
        if (accounts.length != apyBpsList.length) {
            revert LengthMismatch();
        }

        uint256 accountLength = accounts.length;
        for (uint256 i; i < accountLength; ++i) {
            address account = accounts[i];
            uint256 apyBps = apyBpsList[i];

            if (account == address(0)) {
                revert ZeroAddress();
            }
            if (apyBps > MAX_APY_BPS) {
                revert InvalidApyBps(apyBps);
            }

            _apyBps[account] = apyBps;
            emit UserApyUpdated(account, apyBps);
        }
    }

    /// @inheritdoc IWellnessOracle
    function getApyBps(address account) external view returns (uint256) {
        return _apyBps[account];
    }
}
