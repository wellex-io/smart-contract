// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title WellnessTrustedStrategy4626
/// @notice Minimal ERC4626 strategy where a trusted operator controls external capital movement.
/// @dev Accounting remains simple and fully trust-based for MVP.
contract WellnessTrustedStrategy4626 is ERC4626, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant TRUSTED_OPERATOR_ROLE = keccak256("TRUSTED_OPERATOR_ROLE");

    error ZeroAddress();
    error InvalidAmount();

    event TrustedFundsMoved(address indexed operator, address indexed to, uint256 amount);
    event TrustedFundsReturned(address indexed operator, uint256 amount);

    /// @param asset_ Underlying ERC20 asset (e.g. USDC).
    /// @param admin Admin role holder.
    /// @param trustedOperator Address allowed to move funds externally.
    constructor(IERC20 asset_, address admin, address trustedOperator)
        ERC20("Wellix Trusted Strategy Share", "wSTRAT")
        ERC4626(asset_)
    {
        if (address(asset_) == address(0) || admin == address(0) || trustedOperator == address(0)) {
            revert ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TRUSTED_OPERATOR_ROLE, trustedOperator);
    }

    /// @notice Trusted operator forwards underlying funds to external destination.
    /// @param to Receiver of strategy funds.
    /// @param amount Amount to transfer.
    function moveFunds(address to, uint256 amount) external onlyRole(TRUSTED_OPERATOR_ROLE) {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }

        IERC20(asset()).safeTransfer(to, amount);
        emit TrustedFundsMoved(msg.sender, to, amount);
    }

    /// @notice Trusted operator returns underlying funds back to strategy contract.
    /// @param amount Amount to return.
    function returnFunds(uint256 amount) external onlyRole(TRUSTED_OPERATOR_ROLE) {
        if (amount == 0) {
            revert InvalidAmount();
        }

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit TrustedFundsReturned(msg.sender, amount);
    }

    /// @dev Simplified trusted accounting without defensive +1 offset adjustments.
    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return assets;
        }
        return assets.mulDiv(supply, totalAssets(), rounding);
    }

    /// @dev Simplified trusted accounting without defensive +1 offset adjustments.
    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return shares;
        }
        return shares.mulDiv(totalAssets(), supply, rounding);
    }
}
