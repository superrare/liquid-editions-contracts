// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title ILiquidBase
/// @notice Shared interface for both LiquidInstant and LiquidGraduated
/// @dev Provides unified launch state for frontends/indexers
interface ILiquidBase {
    enum LaunchType {
        INSTANT,
        GRADUATED,
        MULTICURVE
    }

    /// @notice Returns launch state for integration
    /// @return launchType INSTANT or GRADUATED
    /// @return poolLive Whether the pool exists and is tradeable
    /// @return auction CCA auction address (address(0) for INSTANT)
    /// @return strategy LBP strategy address (address(0) for INSTANT)
    function getLaunchState()
        external
        view
        returns (
            LaunchType launchType,
            bool poolLive,
            address auction,
            address strategy
        );
}
