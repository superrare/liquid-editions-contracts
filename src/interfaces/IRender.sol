// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title IRender
/// @notice Interface for render contracts that provide dynamic token metadata
interface IRender {
    /// @notice Returns the token URI (no parameters)
    /// @return The token URI string
    function tokenURI() external view returns (string memory);

    /// @notice Returns the token URI for a specific token ID (ERC721-style)
    /// @param tokenId The token ID
    /// @return The token URI string
    function tokenURI(uint256 tokenId) external view returns (string memory);
}
