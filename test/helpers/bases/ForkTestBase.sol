// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";

/// @title Fork Test Base
/// @notice Shared fork setup: URL resolution, createSelectFork, NetworkConfig
/// @dev All e2e/fork tests should inherit this. Set FORK_URL in .env.
abstract contract ForkTestBase is Test {
    NetworkConfig.Config internal config;

    /// @notice Resolve fork URL from environment
    /// @dev Priority: FORK_URL, hard-fail if missing.
    function _getForkUrl() internal view returns (string memory) {
        return ForkUrlResolver.requireForkUrl(vm);
    }

    /// @notice Override to pin fork block (e.g. for auction salt reuse). Return 0 for latest.
    /// @dev Defaults to FORK_BLOCK env var if set; helps RPC caching and avoids rate-limit flakes.
    function _getForkBlock() internal virtual returns (uint256) {
        return vm.envOr("FORK_BLOCK", uint256(0));
    }

    /// @notice Create fork and load config. Call from setUp().
    function _setupFork() internal {
        string memory forkUrl = _getForkUrl();
        uint256 forkBlock = _getForkBlock();
        if (forkBlock != 0) {
            vm.createSelectFork(forkUrl, forkBlock);
        } else {
            vm.createSelectFork(forkUrl);
        }
        config = NetworkConfig.getConfig(block.chainid);
    }
}
