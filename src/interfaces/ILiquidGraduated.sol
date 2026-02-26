// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {ILiquidBase} from "liquid-editions/interfaces/ILiquidBase.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title ILiquidGraduated
/// @notice Interface for Liquid tokens launched via CCA auction; extends ILiquid with auction-specific views
/// @dev Post-graduation, all ILiquid functions work identically. Pre-graduation, pool views revert with PoolNotInitialized.
///      Migration is performed by strategy.migrate(), not by the token.
interface ILiquidGraduated is ILiquid, ILiquidBase {
    /// @notice Thrown when caller is not the factory (for setPoolId)
    error NotMigrator();

    /// @notice Thrown when the market has already graduated
    error AlreadyGraduated();

    /// @notice Thrown when a new pool ID is invalid
    error InvalidPoolId();

    /// @notice Emitted when a token contract updates its pool ID
    event PoolIdUpdated(PoolId indexed oldPoolId, PoolId indexed newPoolId);

    /// @notice The CCA auction contract address (strategy.initializer())
    function auctionAddress() external view returns (address);

    /// @notice Whether the market has graduated (pool is live)
    function isGraduated() external view returns (bool);

    /// @notice The LBP strategy contract
    function strategy() external view returns (address);

    /// @notice Returns auction state summary
    /// @return auction The CCA auction contract address
    /// @return graduated Whether the market has graduated
    /// @return strategyAddr The LBP strategy contract address
    function getAuctionState()
        external
        view
        returns (address auction, bool graduated, address strategyAddr);
}
