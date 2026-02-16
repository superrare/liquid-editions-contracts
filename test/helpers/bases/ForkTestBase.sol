// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";

/// @title Fork Test Base
/// @notice Shared fork setup: URL resolution, createSelectFork, NetworkConfig
/// @dev All e2e/fork tests should inherit this. Set FORK_URL in .env (or MAINNET_RPC_URL as fallback).
abstract contract ForkTestBase is Test {
    NetworkConfig.Config internal config;

    /// @notice Default fork URL when env vars are not set
    /// @dev Override in subclass for chain-specific default (e.g. Base vs Ethereum)
    function _defaultForkUrl() internal pure virtual returns (string memory) {
        return "https://mainnet.base.org";
    }

    /// @notice Resolve fork URL from environment
    /// @dev Priority: FORK_URL > MAINNET_RPC_URL > _defaultForkUrl()
    function _getForkUrl() internal view returns (string memory) {
        try vm.envString("FORK_URL") returns (string memory url) {
            if (bytes(url).length > 0) return url;
        } catch {}
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            if (bytes(url).length > 0) return url;
        } catch {}
        return _defaultForkUrl();
    }

    /// @notice Override to pin fork block (e.g. for auction salt reuse). Return 0 for latest.
    function _getForkBlock() internal virtual returns (uint256) {
        return 0;
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
