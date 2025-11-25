// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {LiquidFactory} from "../src/LiquidFactory.sol";
import {Liquid} from "../src/Liquid.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/**
 * @title LiquidFactoryDeploy
 * @notice Deployment script for LiquidFactory and Liquid implementation
 * @dev Requires RAREBurner to be deployed first and configured in NetworkConfig
 *
 * Prerequisites:
 * 1. Deploy RAREBurner using RAREBurnerDeploy.s.sol
 * 2. Update NetworkConfig.sol with the address
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for deployment
 * - PROTOCOL_FEE_RECIPIENT: Address to receive protocol fees
 *
 * Environment Variables Optional:
 * - CHAIN_ID: Target chain ID (defaults to block.chainid)
 *
 * Usage:
 *   forge script script/LiquidFactoryDeploy.s.sol:LiquidFactoryDeploy --rpc-url $RPC_URL --broadcast
 */
contract LiquidFactoryDeploy is Script {
    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address protocolFeeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");

        // Get chain ID from environment or use block.chainid
        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _chainId) {
            chainId = _chainId;
        } catch {
            chainId = block.chainid;
        }

        // Get network configuration
        NetworkConfig.Config memory config = NetworkConfig.getConfig(chainId);

        // Validate required addresses from NetworkConfig
        require(
            config.rareBurner != address(0),
            "RAREBurner not found in NetworkConfig. Deploy RAREBurner first using RAREBurnerDeploy.s.sol"
        );

        console.log("Deploying to network with chain ID:");
        console.logUint(chainId);
        console.log("Deployer address:");
        console.logAddress(vm.addr(deployerPrivateKey));
        console.log("Protocol fee recipient:");
        console.logAddress(protocolFeeRecipient);
        console.log("");
        console.log("Using RAREBurner from NetworkConfig:");
        console.logAddress(config.rareBurner);
        console.log("");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy Liquid implementation
        console.log("Deploying Liquid implementation...");
        Liquid liquidImplementation = new Liquid();
        console.log("Liquid implementation deployed at:");
        console.logAddress(address(liquidImplementation));

        // Deploy LiquidFactory
        console.log("Deploying LiquidFactory...");
        LiquidFactory factory = new LiquidFactory(
            vm.addr(deployerPrivateKey), // admin
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager,
            config.rareBurner, // rareBurner address from NetworkConfig
            5000, // rareBurnFeeBPS (50% of remainder after creator fee)
            3000, // protocolFeeBPS (30% of remainder after creator fee)
            2000, // referrerFeeBPS (20% of remainder after creator fee)
            300, // defaultTotalFeeBPS (2% total trading fee)
            2500, // defaultCreatorFeeBPS (25% of total fee goes to creator)
            -180, // lpTickLower - max expensive (after price rises) - multiple of 60
            120000, // lpTickUpper - starting point (cheap tokens, bonding curve bottom) - multiple of 60
            config.uniswapV4Quoter, // v4 quoter for price discovery
            address(0), // pool hooks (none)
            60, // pool tick spacing (matches 0.3% fee tier)
            300, // internalMaxSlippageBps (3%)
            0.00000000000001 ether, // minOrderSizeWei
            1e15 // minInitialLiquidityWei (0.001 ETH)
        );
        console.log("LiquidFactory deployed at:");
        console.logAddress(address(factory));

        // Set the implementation in the factory
        console.log("Setting implementation in factory...");
        factory.setImplementation(address(liquidImplementation));

        vm.stopBroadcast();

        // Log deployment summary
        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("Network Chain ID:");
        console.logUint(chainId);
        console.log("Deployer:");
        console.logAddress(vm.addr(deployerPrivateKey));
        console.log("");
        console.log("Deployed Contracts:");
        console.log("-------------------");
        console.log("Liquid Implementation:");
        console.logAddress(address(liquidImplementation));
        console.log("LiquidFactory:");
        console.logAddress(address(factory));
        console.log("");
        console.log("Referenced Contracts:");
        console.log("---------------------");
        console.log("RAREBurner (from NetworkConfig):");
        console.logAddress(config.rareBurner);
        console.log("");
        console.log("Network Configuration:");
        console.log("----------------------");
        console.log("WETH:");
        console.logAddress(config.weth);
        console.log("Uniswap V4 Pool Manager:");
        console.logAddress(config.uniswapV4PoolManager);
        console.log("Uniswap V4 Quoter:");
        console.logAddress(config.uniswapV4Quoter);
        console.log("");
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Verify all contracts on Etherscan/Basescan");
        console.log("");
        console.log("2. Create Liquid tokens using the factory:");
        console.log(
            '   cast send <factory> "createLiquidToken(address,string,string,string)" <creator> <uri> <name> <symbol> --value 0.1ether'
        );
        console.log("");
        console.log("Architecture:");
        console.log("-------------");
        console.log(
            "Liquid tokens get config from LiquidFactory (including rareBurnFeeBPS)"
        );
        console.log("RAREBurner is fully configured and ready to burn RARE");
        console.log(
            "Liquid -> forwards ETH to -> RAREBurner -> burns RARE via V4"
        );
        console.log("Fees distributed directly to recipients (no escrow)");
        console.log("");
        console.log("Factory Functions:");
        console.log("------------------");
        console.log("- createLiquidToken(creator, tokenURI, name, symbol)");
        console.log(
            "- pushConfig(GlobalConfig) - Update global config (admin only)"
        );
        console.log(
            "- setTradingKnobs(slippageBps, minWei) - Update trading params (admin only)"
        );
        console.log("");
        console.log("RAREBurner Functions:");
        console.log("--------------------------------");
        console.log("- flush() - Manually trigger burn attempt (anyone)");
        console.log("- pause(bool) - Pause/unpause deposits and burns (admin)");
        console.log(
            "- sweep(address, amount) - Sweep accumulated ETH (admin, emergency)"
        );
        console.log("");
        console.log("Configuration Notes:");
        console.log("--------------------");
        console.log("Three-Tier Fee System:");
        console.log(
            "- TIER 1: Total fee = 2% of trade (defaultTotalFeeBPS = 200)"
        );
        console.log(
            "- TIER 2: Creator gets 25% of collected fees (defaultCreatorFeeBPS = 2500)"
        );
        console.log("- TIER 3: Remaining 75% split as:");
        console.log("  * RARE burn: 50% (rareBurnFeeBPS = 5000)");
        console.log("  * Protocol: 30% (protocolFeeBPS = 3000)");
        console.log("  * Referrer: 20% (referrerFeeBPS = 2000)");
        console.log("");
        console.log("Deployment Notes:");
        console.log("-----------------");
        console.log("- RAREBurner: Shared contract from NetworkConfig");
        console.log("- Can be reused across multiple factory deployments");
        console.log("- Deploy RAREBurner first using RAREBurnerDeploy.s.sol");
    }
}
