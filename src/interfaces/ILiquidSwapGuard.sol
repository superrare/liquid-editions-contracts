// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ILiquidSwapGuard
/// @notice Interface for LiquidSwapGuard hook contract
/// @dev Used by LiquidFactory to whitelist token contracts before pool initialization
interface ILiquidSwapGuard {
    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when the swap router has not been registered as verified
    error UnverifiedRouter(address router);

    /// @notice Thrown when the router-provided caller is not whitelisted
    error UnauthorizedCaller(address caller);

    /// @notice Thrown when the router does not implement the expected msg-sender callback
    error RouterDoesNotImplementMsgSender(address router);

    /// @notice Thrown when an initializer is not allowed to initialize a pool
    error UnauthorizedInitializer(address sender);

    /// @notice Thrown when a call is not from the PoolManager
    error NotPoolManager();

    /// @notice Thrown when an admin function caller is neither owner nor factory
    error NotOwnerOrFactory();

    /// @notice Thrown when an invalid factory address is configured
    error InvalidFactoryAddress();

    /// @notice Returns the currently configured factory
    function factory() external view returns (address);

    /// @notice Returns whether a router is verified (swaps from this router pass the first beforeSwap check)
    /// @param router The router contract address (e.g. Universal Router)
    function verifiedRouters(address router) external view returns (bool);

    /// @notice Returns whether a caller is allowed (address returned by router.msgSender(), typically LiquidRouter)
    /// @param caller The caller address
    function allowedCallers(address caller) external view returns (bool);

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

    /// @notice Adds a router address to the verified routers list
    /// @param router The router contract address (e.g. Universal Router)
    function addRouter(address router) external;

    /// @notice Removes a router from the verified routers list
    /// @param router The router address to remove
    function removeRouter(address router) external;

    /// @notice Adds a caller address to the allowed callers list
    /// @param caller The caller address to whitelist (typically LiquidRouter)
    function addCaller(address caller) external;

    /// @notice Removes a caller from the allowed callers list
    /// @param caller The caller address to remove
    function removeCaller(address caller) external;

    /// @notice Checks if an address is an allowed initializer
    /// @param initializer The address to check
    /// @return True if the address is allowed to initialize pools
    function allowedInitializers(address initializer) external view returns (bool);
}
