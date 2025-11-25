// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {RAREBurner} from "../src/RAREBurner.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/**
 * @title RAREBurnerDeploy
 * @notice Standalone deployment script for RAREBurner contract
 * @dev This script deploys a fully configured RAREBurner independent of LiquidFactory
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for deployment
 * - CHAIN_ID (optional): Target chain ID (defaults to block.chainid)
 *
 * Environment Variables Optional (with defaults):
 * - BURNER_TRY_ON_DEPOSIT: true/false (default: true)
 * - BURNER_POOL_FEE: Pool fee in basis points (default: 3000 = 0.3%)
 * - BURNER_TICK_SPACING: Tick spacing (default: 60)
 * - BURNER_HOOKS: Hooks address (default: address(0))
 * - BURNER_BURN_ADDRESS: Target burn address (default: 0x000000000000000000000000000000000000dEaD)
 * - BURNER_V4_QUOTER: V4 Quoter address for slippage protection (default: network's v4Quoter)
 * - BURNER_MAX_SLIPPAGE_BPS: Max slippage in basis points (default: 300 = 3%)
 * - BURNER_ENABLED: true/false - enable burns on deployment (default: true)
 *
 * Usage:
 *   forge script script/RAREBurnerDeploy.s.sol:RAREBurnerDeploy --rpc-url $RPC_URL --broadcast
 */
contract RAREBurnerDeploy is Script {
    function run() external {
        // Load required environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Get chain ID from environment or use block.chainid
        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _chainId) {
            chainId = _chainId;
        } catch {
            chainId = block.chainid;
        }

        // Get network configuration
        NetworkConfig.Config memory config = NetworkConfig.getConfig(chainId);

        // Load optional configuration parameters with defaults
        bool tryOnDeposit = vm.envOr("BURNER_TRY_ON_DEPOSIT", true);
        uint24 poolFee = uint24(vm.envOr("BURNER_POOL_FEE", uint256(3000)));
        int24 tickSpacing = int24(vm.envOr("BURNER_TICK_SPACING", int256(60)));

        address hooks;
        try vm.envAddress("BURNER_HOOKS") returns (address _hooks) {
            hooks = _hooks;
        } catch {
            hooks = address(0);
        }

        address burnAddress;
        try vm.envAddress("BURNER_BURN_ADDRESS") returns (
            address _burnAddress
        ) {
            burnAddress = _burnAddress;
        } catch {
            burnAddress = 0x000000000000000000000000000000000000dEaD;
        }

        address v4Quoter;
        try vm.envAddress("BURNER_V4_QUOTER") returns (address _quoter) {
            v4Quoter = _quoter;
        } catch {
            // Default to network's v4Quoter if available
            v4Quoter = config.uniswapV4Quoter;
        }

        uint16 maxSlippageBPS = uint16(
            vm.envOr("BURNER_MAX_SLIPPAGE_BPS", uint256(300))
        );
        bool enabled = vm.envOr("BURNER_ENABLED", true);

        address deployer = vm.addr(deployerPrivateKey);

        // Log deployment configuration
        console.log("=== RAREBurner Deployment Configuration ===");
        console.log("Network Chain ID:");
        console.logUint(chainId);
        console.log("Deployer address:");
        console.logAddress(deployer);
        console.log("");

        console.log("Network Configuration:");
        console.log("----------------------");
        console.log("RARE Token:");
        console.logAddress(config.rareToken);
        console.log("Uniswap V4 PoolManager:");
        console.logAddress(config.uniswapV4PoolManager);
        console.log("WETH:");
        console.logAddress(config.weth);
        console.log("");

        console.log("Pool Configuration:");
        console.log("-------------------");
        console.log("Pool Fee:");
        console.logUint(poolFee);
        console.log("Tick Spacing:");
        console.logInt(tickSpacing);
        console.log("Hooks:");
        console.logAddress(hooks);
        console.log("");

        console.log("Burner Settings:");
        console.log("----------------");
        console.log("Try On Deposit:", tryOnDeposit);
        console.log("Burn Address:");
        console.logAddress(burnAddress);
        console.log("V4 Quoter:");
        console.logAddress(v4Quoter);
        console.log("Max Slippage BPS:");
        console.logUint(maxSlippageBPS);
        console.log("Enabled:", enabled);
        console.log("");

        // Validate configuration
        require(
            config.rareToken != address(0),
            "RARE token address not configured for this network"
        );
        require(
            config.uniswapV4PoolManager != address(0),
            "V4 PoolManager not configured for this network"
        );
        require(burnAddress != address(0), "Burn address cannot be zero");

        if (maxSlippageBPS > 0) {
            require(
                v4Quoter != address(0),
                "V4 Quoter required when slippage protection is enabled"
            );
        }

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy RAREBurner with full configuration
        console.log("Deploying RAREBurner...");
        RAREBurner rareBurner = new RAREBurner(
            deployer, // owner (admin)
            tryOnDeposit, // attempt burn on deposit
            config.rareToken, // RARE token address
            config.uniswapV4PoolManager, // V4 PoolManager
            poolFee, // fee
            tickSpacing, // tickSpacing
            hooks, // hooks
            burnAddress, // burnAddress
            v4Quoter, // v4Quoter
            maxSlippageBPS, // maxSlippageBPS
            enabled // enabled
        );

        console.log("RAREBurner deployed at:");
        console.logAddress(address(rareBurner));

        vm.stopBroadcast();

        // Validate deployment
        console.log("");
        console.log("=== Deployment Validation ===");
        bool isActive = rareBurner.isRAREBurnActive();
        console.log("Is RARE Burn Active:", isActive);

        bool isValid = rareBurner.validatePoolConfig();
        console.log("Pool Config Valid:", isValid);

        uint256 pendingEth = rareBurner.pendingEth();
        console.log("Pending ETH:");
        console.logUint(pendingEth);

        // Log deployment summary
        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("Network Chain ID:");
        console.logUint(chainId);
        console.log("Deployer:");
        console.logAddress(deployer);
        console.log("");
        console.log("Deployed Contract:");
        console.log("------------------");
        console.log("RAREBurner:");
        console.logAddress(address(rareBurner));
        console.log("");
        console.log("Status:");
        console.log("-------");
        console.log("RARE Burn Active:", isActive);
        console.log("Pool Config Valid:", isValid);
        console.log("");
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Verify contract on Etherscan/Basescan:");
        console.log(
            "   forge verify-contract <address> RAREBurner --chain-id",
            chainId
        );
        console.log("");
        console.log("2. Configure LiquidFactory to use this burner:");
        console.log("   factory.setRareBurner(", address(rareBurner), ")");
        console.log("");
        console.log("3. Set appropriate RARE burn fee in factory:");
        console.log("   factory.setRareBurnFeeBPS(<fee_bps>)");
        console.log("");
        console.log("RAREBurner Functions:");
        console.log("---------------------");
        console.log("- flush() - Manually trigger burn attempt (anyone)");
        console.log("- toggleBurnEnabled(bool) - Enable/disable burns (admin)");
        console.log("- pause(bool) - Pause/unpause deposits and burns (admin)");
        console.log(
            "- sweep(address, amount) - Sweep accumulated ETH (admin, emergency)"
        );
        console.log("");

        if (!isActive) {
            console.log("WARNING: RARE burn is NOT active!");
            console.log("This could be due to:");
            console.log("- Pool not initialized on V4 PoolManager");
            console.log(
                "- Incorrect pool parameters (fee, tick spacing, hooks)"
            );
            console.log("- Burns disabled (enabled = false)");
        }
    }
}
