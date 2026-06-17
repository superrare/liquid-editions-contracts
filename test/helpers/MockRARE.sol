// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mock RARE Token for testing
/// @dev Simple ERC20 token that mints tokens on demand
contract MockRARE is ERC20 {
    constructor() ERC20("Mock RARE", "MRARE") {
        // Mint initial supply to deployer
        _mint(msg.sender, 10_000_000 ether);
    }

    /// @notice Mint tokens to an address (for testing)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
