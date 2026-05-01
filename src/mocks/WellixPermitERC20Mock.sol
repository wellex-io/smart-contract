// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Testnet / dev stake asset with EIP-2612 (`ERC20Permit`). `depositForWithPermit` works when this is `WellixGateway.stakeAsset`.
/// @dev Permit domain name matches `name()`; integrators must use the same string in typed data.
contract WellixPermitERC20Mock is ERC20Permit {
    constructor() ERC20("WellixPermitMock", "WXPM") ERC20Permit("WellixPermitMock") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
