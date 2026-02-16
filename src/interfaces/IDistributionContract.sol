// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Minimal interface for CCA (Continuous Clearing Auction) to signal auction tokens received.
/// @dev CCA requires the token contract to call this after transferring auction supply so it can accept bids.
interface IDistributionContract {
    function onTokensReceived() external;
}
