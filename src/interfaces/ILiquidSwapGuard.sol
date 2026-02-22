// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ILiquidSwapGuard
/// @notice Interface for LiquidSwapGuard hook contract
/// @dev Used by LiquidFactory to whitelist token contracts before pool initialization
interface ILiquidSwapGuard {
    /// @notice Returns the currently configured factory
    function factory() external view returns (address);

    /// @notice Sets the factory address that can add initializers
    /// @param _factory The LiquidFactory contract address
    function setFactory(address _factory) external;

    /// @notice Adds an initializer address to the allowed initializers list
    /// @dev Callable by owner or factory. Must be called before the token attempts pool initialization.
    /// @param initializer The Liquid token contract address that will initialize a pool
    function addInitializer(address initializer) external;

    /// @notice Removes an initializer from the allowed initializers list
    /// @param initializer The initializer address to remove
    function removeInitializer(address initializer) external;

    /// @notice Checks if an address is an allowed initializer
    /// @param initializer The address to check
    /// @return True if the address is allowed to initialize pools
    function allowedInitializers(address initializer) external view returns (bool);
}
