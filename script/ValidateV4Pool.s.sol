// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/**
 * @title ValidateV4Pool
 * @notice Validates that a V4 pool exists and is properly initialized before RAREBurner deployment
 * @dev Checks pool state, liquidity, and configuration match expected parameters
 *
 * Environment Variables Required:
 * - CHAIN_ID (optional): Target chain ID (defaults to block.chainid)
 * - BURNER_POOL_FEE: Pool fee to validate (default: 3000)
 * - BURNER_TICK_SPACING: Tick spacing to validate (default: 60)
 * - BURNER_HOOKS: Hooks address (default: address(0))
 *
 * Usage:
 *   forge script script/ValidateV4Pool.s.sol:ValidateV4Pool --rpc-url $RPC_URL
 */
contract ValidateV4Pool is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        // Get chain ID from environment or use block.chainid
        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _chainId) {
            chainId = _chainId;
        } catch {
            chainId = block.chainid;
        }

        // Get network configuration
        NetworkConfig.Config memory config = NetworkConfig.getConfig(chainId);

        // Load pool parameters (matching RAREBurnerDeploy defaults)
        uint24 poolFee = uint24(vm.envOr("BURNER_POOL_FEE", uint256(3000)));
        int24 tickSpacing = int24(vm.envOr("BURNER_TICK_SPACING", int256(60)));

        address hooks;
        try vm.envAddress("BURNER_HOOKS") returns (address _hooks) {
            hooks = _hooks;
        } catch {
            hooks = address(0);
        }

        console.log("=== V4 Pool Validation for RAREBurner ===");
        console.log("");
        console.log("Network:");
        console.log("--------");
        console.log("Chain ID:");
        console.logUint(chainId);
        console.log("");

        console.log("Addresses:");
        console.log("----------");
        console.log("RARE Token:");
        console.logAddress(config.rareToken);
        console.log("V4 PoolManager:");
        console.logAddress(config.uniswapV4PoolManager);
        console.log("WETH:");
        console.logAddress(config.weth);
        console.log("");

        console.log("Pool Parameters:");
        console.log("----------------");
        console.log("Fee:");
        console.logUint(poolFee);
        console.log("Tick Spacing:");
        console.logInt(tickSpacing);
        console.log("Hooks:");
        console.logAddress(hooks);
        console.log("");

        // Validate required addresses
        require(
            config.rareToken != address(0),
            "RARE token address not configured for this network"
        );
        require(
            config.uniswapV4PoolManager != address(0),
            "V4 PoolManager not configured for this network"
        );

        // Build PoolKey (native ETH vs RARE)
        // ETH (ADDRESS_ZERO) always sorts before any ERC20
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO, // Native ETH
            currency1: Currency.wrap(config.rareToken),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        // Compute PoolId
        PoolId poolId = key.toId();
        bytes32 poolIdBytes = PoolId.unwrap(poolId);

        console.log("Computed PoolKey:");
        console.log("-----------------");
        console.log("currency0 (ETH):");
        console.logAddress(Currency.unwrap(key.currency0));
        console.log("currency1 (RARE):");
        console.logAddress(Currency.unwrap(key.currency1));
        console.log("fee:");
        console.logUint(key.fee);
        console.log("tickSpacing:");
        console.logInt(key.tickSpacing);
        console.log("hooks:");
        console.logAddress(address(key.hooks));
        console.log("");

        console.log("PoolId:");
        console.logBytes32(poolIdBytes);
        console.log("");

        // Query pool state from PoolManager
        IPoolManager poolManager = IPoolManager(config.uniswapV4PoolManager);

        console.log("=== Pool State Check ===");
        console.log("");

        // Get slot0 (price and tick info)
        (
            uint160 sqrtPriceX96,
            int24 tick,
            uint24 protocolFee,
            uint24 lpFee
        ) = poolManager.getSlot0(poolId);

        // Check if pool is initialized (sqrtPriceX96 != 0)
        if (sqrtPriceX96 == 0) {
            console.log("Pool is NOT INITIALIZED!");
            console.log("");
            console.log("ERROR: Cannot find pool with these parameters:");
            console.log("  - Fee:");
            console.logUint(poolFee);
            console.log("  - Tick Spacing:");
            console.logInt(tickSpacing);
            console.log("  - Hooks:");
            console.logAddress(hooks);
            console.log("");
            console.log(
                "This pool must be initialized and have liquidity before deploying RAREBurner."
            );
            console.log("");
            console.log("Expected PoolId:");
            console.logBytes32(poolIdBytes);
            console.log("");
            console.log("ACTION REQUIRED:");
            console.log("1. Verify BURNER_POOL_FEE matches your deployed pool");
            console.log(
                "2. Verify BURNER_TICK_SPACING matches your deployed pool"
            );
            console.log("3. Initialize pool if not done yet");
            console.log("4. Add liquidity to the pool");
            return;
        }

        console.log("Pool is INITIALIZED!");
        console.log("");
        console.log("Slot0 Data:");
        console.log("-----------");
        console.log("sqrtPriceX96:");
        console.logUint(sqrtPriceX96);
        console.log("Current tick:");
        console.logInt(tick);
        console.log("Protocol fee:");
        console.logUint(protocolFee);
        console.log("LP fee:");
        console.logUint(lpFee);
        console.log("");

        // Check liquidity
        uint128 liquidity = poolManager.getLiquidity(poolId);
        console.log("Total Liquidity:");
        console.logUint(liquidity);
        console.log("");

        if (liquidity == 0) {
            console.log("WARNING: Pool has ZERO liquidity!");
            console.log("The pool exists but has no liquidity providers.");
            console.log(
                "RAREBurner will fail to execute swaps until liquidity is added."
            );
            console.log("");
        } else {
            console.log("SUCCESS: Pool has liquidity!");
            console.log("");
        }

        // Validation summary
        console.log("=== VALIDATION SUMMARY ===");
        console.log("");
        console.log("Pool Status: READY");
        console.log("Pool ID:");
        console.logBytes32(poolIdBytes);
        console.log("Initialized: YES");
        console.log("Has Liquidity:", liquidity > 0);
        console.log("");

        if (liquidity > 0) {
            console.log("READY TO DEPLOY RAREBurner!");
            console.log("");
            console.log("Deploy command:");
            console.log(
                "forge script script/RAREBurnerDeploy.s.sol:RAREBurnerDeploy --rpc-url $RPC_URL --broadcast"
            );
        } else {
            console.log(
                "ACTION REQUIRED: Add liquidity before deploying RAREBurner"
            );
        }
    }
}
