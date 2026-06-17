// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title ILiquidGuard
/// @notice Interface for the LiquidGuard hook contract
/// @dev Used by LiquidFactory to whitelist token contracts before pool initialization,
///      and by FeeDistributor to be set as the approved hook.
interface ILiquidGuard {
    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when an initializer is not allowed to initialize a pool
    error UnauthorizedInitializer(address sender);

    /// @notice Thrown when a call is not from the PoolManager
    error NotPoolManager();

    /// @notice Thrown when an admin function caller is neither owner nor factory
    error NotOwnerOrFactory();

    /// @notice Thrown when an invalid factory address is configured
    error InvalidFactoryAddress();

    /// @notice Thrown when a non-zero fee distributor address has no code (not a contract)
    error InvalidFeeDistributor();

    /// @notice Thrown when a computed/proposed fee exceeds the swap amount or configured upper bound.
    error FeeTooLarge(uint256 fee, uint256 amount);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when the fee distributor is updated
    event FeeDistributorUpdated(address indexed oldDistributor, address indexed newDistributor);

    /// @notice Emitted when the total fee BPS is updated
    event TotalFeeBpsUpdated(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when the factory is updated
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Returns the configured factory address
    function factory() external view returns (address);

    /// @notice Returns the configured fee distributor address
    function feeDistributor() external view returns (address);

    /// @notice Returns the total fee in basis points
    function totalFeeBPS() external view returns (uint16);

    /// @notice Returns the RARE token address
    function RARE_TOKEN() external view returns (address);

    /// @notice Checks if an address is an allowed initializer
    /// @param initializer The address to check
    function allowedInitializers(address initializer) external view returns (bool);

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @notice Sets the factory address that can add initializers
    /// @param _factory The LiquidFactory contract address
    function setFactory(address _factory) external;

    /// @notice Sets the fee distributor address and syncs totalFeeBPS from it.
    /// @dev totalFeeBPS is read from the new distributor. To change fees, deploy a new
    ///      FeeDistributor with the desired totalFeeBPS and call this function.
    /// @param _feeDistributor The FeeDistributor contract address
    function setFeeDistributor(address _feeDistributor) external;

    /// @notice Adds an initializer address to the allowed initializers list
    /// @dev Callable by owner or factory. Must be called before the token attempts pool initialization.
    /// @param initializer The Liquid token contract address that will initialize a pool
    function addInitializer(address initializer) external;

    /// @notice Removes an initializer from the allowed initializers list
    /// @param initializer The initializer address to remove
    function removeInitializer(address initializer) external;
}
