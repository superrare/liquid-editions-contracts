// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";

/// @notice Minimal ERC-1046 token URI surface for ERC20 metadata.
interface IERC1046 {
    function tokenURI() external view returns (string memory);
}

/// @title ISovereignERC20
/// @notice Core no-market owner-controlled ERC20 deployed by the Liquid factory.
interface ISovereignERC20 is IERC5313, IERC1046, IERC165 {
    /// @notice Thrown when the token name is empty.
    error EmptyName();

    /// @notice Thrown when the token symbol is empty.
    error EmptySymbol();

    /// @notice Thrown when a bounded token is initialized with more supply than its cap.
    error MaxSupplyBelowInitialSupply(uint256 maxSupply, uint256 initialSupply);

    /// @notice Thrown when minting would exceed a non-zero maximum supply.
    error MaxSupplyExceeded(uint256 maxSupply, uint256 currentSupply, uint256 mintAmount);

    /// @notice Emitted when the ERC-1046 token URI changes.
    event TokenURIUpdated(string oldTokenURI, string newTokenURI);

    /// @notice Optional supply cap. A value of 0 means minting is uncapped.
    function maxSupply() external view returns (uint256);

    /// @notice Mints tokens to an account. Only callable by the owner.
    function mint(address to, uint256 amount) external;

    /// @notice Updates the ERC-1046 token URI. Only callable by the owner.
    function setTokenURI(string calldata newTokenURI) external;

    /// @notice Burns tokens from the caller.
    function burn(uint256 amount) external;

    /// @notice Burns tokens from an account using the caller's allowance.
    function burnFrom(address account, uint256 amount) external;
}
