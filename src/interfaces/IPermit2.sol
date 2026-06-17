// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IPermit2
/// @notice Minimal interface for Uniswap Permit2 AllowanceTransfer functionality
/// @dev Permit2 is Uniswap's token approval system used by Universal Router
///      Full interface: https://github.com/Uniswap/permit2
interface IPermit2 {
    /// @notice Approves a spender to use tokens via Permit2
    /// @dev This sets an allowance in Permit2's storage (separate from ERC20 allowance)
    ///      The token must first be approved to Permit2 via standard ERC20 approve
    /// @param token The token to approve
    /// @param spender The address to approve (e.g., Universal Router)
    /// @param amount The amount to approve (uint160 max = 2^160-1)
    /// @param expiration The expiration timestamp for the approval (uint48)
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;

    /// @notice Returns the allowance for a spender on a token for a given owner
    /// @param owner The owner of the tokens
    /// @param token The token address
    /// @param spender The spender address
    /// @return amount The current allowance amount
    /// @return expiration The expiration timestamp
    /// @return nonce The current nonce (for signature-based transfers)
    function allowance(
        address owner,
        address token,
        address spender
    ) external view returns (uint160 amount, uint48 expiration, uint48 nonce);
}
