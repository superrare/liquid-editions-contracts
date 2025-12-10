// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/**
 * @title ComputePoolId
 * @notice Utility script to compute Uniswap V4 pool IDs
 * @dev Computes the pool ID for a RARE/ETH pool given the configuration
 *
 * Environment Variables:
 * - CHAIN_ID: Target chain ID (defaults to block.chainid)
 * - RARE_TOKEN: Override RARE token address (defaults to NetworkConfig)
 * - POOL_FEE: Pool fee in hundredths of a bip (e.g., 3000 = 0.3%) (defaults to 3000)
 * - TICK_SPACING: Pool tick spacing (defaults to 60)
 * - HOOKS: Hooks contract address (defaults to address(0))
 *
 * Usage:
 *   forge script script/ComputePoolId.s.sol:ComputePoolId --rpc-url $RPC_URL
 *
 *   # With custom parameters:
 *   POOL_FEE=10000 TICK_SPACING=200 forge script script/ComputePoolId.s.sol:ComputePoolId
 */
contract ComputePoolId is Script {
    using PoolIdLibrary for PoolKey;

    function run() external view {
        // Get chain ID
        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _chainId) {
            chainId = _chainId;
        } catch {
            chainId = block.chainid;
        }

        // Get RARE token address
        address rareToken;
        try vm.envAddress("RARE_TOKEN") returns (address _token) {
            rareToken = _token;
        } catch {
            NetworkConfig.Config memory config = NetworkConfig.getConfig(
                chainId
            );
            rareToken = config.rareToken;
        }

        // Get pool parameters
        uint24 fee;
        try vm.envUint("POOL_FEE") returns (uint256 _fee) {
            fee = uint24(_fee);
        } catch {
            fee = 3000; // Default 0.3%
        }

        int24 tickSpacing;
        try vm.envInt("TICK_SPACING") returns (int256 _spacing) {
            tickSpacing = int24(_spacing);
        } catch {
            tickSpacing = 60; // Default for 0.3% fee tier
        }

        address hooks;
        try vm.envAddress("HOOKS") returns (address _hooks) {
            hooks = _hooks;
        } catch {
            hooks = address(0); // No hooks
        }

        require(rareToken != address(0), "RARE token address not configured");

        // Compute pool ID
        bytes32 poolId = _computePoolId(rareToken, fee, tickSpacing, hooks);

        // Log results
        console.log("=== POOL ID COMPUTATION ===");
        console.log("");
        console.log("Chain ID:", chainId);
        console.log("");
        console.log("Pool Parameters:");
        console.log("-----------------");
        console.log("RARE Token:", rareToken);
        console.log("Fee (BPS):", fee);
        console.log("Tick Spacing:", uint24(tickSpacing));
        console.log("Hooks:", hooks);
        console.log("");
        console.log("Currency Ordering:");
        console.log("------------------");
        bool ethIs0 = uint160(address(0)) < uint160(rareToken);
        if (ethIs0) {
            console.log("currency0: ETH (native)");
            console.log("currency1: RARE");
        } else {
            console.log("currency0: RARE");
            console.log("currency1: ETH (native)");
        }
        console.log("");
        console.log("Computed Pool ID:");
        console.log("------------------");
        console.logBytes32(poolId);
        console.log("");
        console.log("Copy this for NetworkConfig.rareEthPoolId");
    }

    function _computePoolId(
        address rareToken,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) internal pure returns (bytes32) {
        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(rareToken);
        bool ethIs0 = uint160(address(0)) < uint160(rareToken);

        PoolKey memory key = PoolKey({
            currency0: ethIs0 ? ethC : rareC,
            currency1: ethIs0 ? rareC : ethC,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        return PoolId.unwrap(key.toId());
    }
}
