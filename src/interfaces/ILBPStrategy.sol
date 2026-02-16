// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title ILBPStrategy
/// @notice Minimal interface for LBP strategy interaction (FullRangeLBPStrategy)
interface ILBPStrategy {
    /// @notice Notify the strategy that tokens have been received
    function onTokensReceived() external;

    /// @notice Migrate raised funds and tokens to a v4 pool
    function migrate() external;

    /// @notice The token being distributed
    function token() external view returns (address);

    /// @notice The initializer (CCA auction)
    function initializer() external view returns (address);
}
