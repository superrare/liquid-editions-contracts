// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IWETH
/// @notice Minimal WETH interface for wrapping/unwrapping native ETH and handling ERC20-compatible transfers.
interface IWETH {
    /// @notice Wrap ETH into WETH.
    /// @dev msg.value controls minted WETH amount.
    function deposit() external payable;

    /// @notice Unwrap WETH back to native ETH.
    /// @param wad ETH amount in wei to withdraw.
    function withdraw(uint256 wad) external;

    /// @notice Approve spending of WETH.
    /// @param guy Spender address.
    /// @param wad Amount approved.
    /// @return True on success.
    function approve(address guy, uint256 wad) external returns (bool);

    /// @notice Transfer WETH to another account.
    /// @param dst Recipient.
    /// @param wad Amount transferred.
    /// @return True on success.
    function transfer(address dst, uint256 wad) external returns (bool);

    /// @notice Transfer WETH from another account using existing allowance.
    /// @param src Token owner.
    /// @param dst Recipient.
    /// @param wad Amount transferred.
    /// @return True on success.
    function transferFrom(
        address src,
        address dst,
        uint256 wad
    ) external returns (bool);

    /// @notice Read current WETH balance of an account.
    /// @param guy Target account.
    /// @return Token balance.
    function balanceOf(address guy) external view returns (uint256);
}
