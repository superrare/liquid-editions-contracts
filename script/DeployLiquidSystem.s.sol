// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {DeployConfig} from "./config/DeployConfig.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {DeployRAREBurner} from "./deployers/DeployRAREBurner.s.sol";
import {DeployLiquidFactory} from "./deployers/DeployLiquidFactory.s.sol";
import {DeployLiquidRouter} from "./deployers/DeployLiquidRouter.s.sol";

/**
 * @title DeployLiquidSystem
 * @notice Orchestrates deployment of all Liquid system contracts
 * @dev Uses individual deployer libraries and supports partial deployments via flags
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for deployment
 * - PROTOCOL_FEE_RECIPIENT: Address to receive protocol fees
 *
 * Environment Variables Optional:
 * - CHAIN_ID: Target chain ID (defaults to block.chainid)
 * - DEPLOY_BURNER: If false, use existing rareBurner from NetworkConfig (default: true)
 * - DEPLOY_FACTORY: If false, use existing liquidFactory from NetworkConfig (default: true)
 * - DEPLOY_ROUTER: If false, use existing liquidRouter from NetworkConfig (default: true)
 *
 * Usage:
 *   # Full deployment
 *   forge script script/DeployLiquidSystem.s.sol:DeployLiquidSystem --rpc-url $RPC_URL --broadcast
 *
 *   # Redeploy only router
 *   DEPLOY_BURNER=false DEPLOY_FACTORY=false DEPLOY_ROUTER=true \
 *   forge script script/DeployLiquidSystem.s.sol:DeployLiquidSystem --rpc-url $RPC_URL --broadcast
 *
 * Note: If you encounter gas limit errors, use --gas-limit flag:
 *   forge script script/DeployLiquidSystem.s.sol:DeployLiquidSystem --rpc-url $RPC_URL --broadcast --gas-limit 30000000
 */
contract DeployLiquidSystem is Script {
    function run() external {
        // Load required environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address protocolFeeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");

        // Get chain ID from environment or use block.chainid
        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _chainId) {
            chainId = _chainId;
        } catch {
            chainId = block.chainid;
        }

        // Load deployment flags (default to true)
        bool deployBurner = vm.envOr("DEPLOY_BURNER", true);
        bool deployFactory = vm.envOr("DEPLOY_FACTORY", true);
        bool deployRouter = vm.envOr("DEPLOY_ROUTER", true);

        // Get configurations
        DeployConfig.Config memory deployConfig = DeployConfig.getConfig(
            chainId
        );
        NetworkConfig.Config memory networkConfig = NetworkConfig.getConfig(
            chainId
        );

        address deployer = vm.addr(deployerPrivateKey);

        console.log("========================================");
        console.log("Deploying Liquid System");
        console.log("========================================");
        console.log("Chain ID:");
        console.logUint(chainId);
        console.log("Deployer:");
        console.logAddress(deployer);
        console.log("Protocol Fee Recipient:");
        console.logAddress(protocolFeeRecipient);
        console.log("");
        console.log("Deployment Flags:");
        console.log("  DEPLOY_BURNER:", deployBurner);
        console.log("  DEPLOY_FACTORY:", deployFactory);
        console.log("  DEPLOY_ROUTER:", deployRouter);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============================================
        // Step 1: RAREBurner - deploy or use existing
        // ============================================
        address burner;
        if (deployBurner) {
            console.log("=== Step 1: Deploying RAREBurner ===");
            burner = DeployRAREBurner.deploy(
                deployer,
                deployConfig.burner,
                networkConfig
            );
        } else {
            burner = networkConfig.rareBurner;
            require(
                burner != address(0),
                "DEPLOY_BURNER=false but no rareBurner in NetworkConfig"
            );
            console.log("=== Step 1: Using existing RAREBurner ===");
            console.log("RAREBurner address:");
            console.logAddress(burner);
        }
        console.log("");

        // ============================================
        // Step 2: LiquidFactory - deploy or use existing
        // ============================================
        address factory;
        address implementation;
        if (deployFactory) {
            console.log("=== Step 2: Deploying LiquidFactory ===");
            (factory, implementation) = DeployLiquidFactory.deploy(
                deployer,
                deployConfig.factory,
                networkConfig
            );
        } else {
            factory = networkConfig.liquidFactory;
            require(
                factory != address(0),
                "DEPLOY_FACTORY=false but no liquidFactory in NetworkConfig"
            );
            console.log("=== Step 2: Using existing LiquidFactory ===");
            console.log("LiquidFactory address:");
            console.logAddress(factory);
            // Implementation address not available from NetworkConfig, but not needed if factory exists
        }
        console.log("");

        // ============================================
        // Step 3: LiquidRouter - deploy or use existing
        // ============================================
        address router;
        address routerImplementation;
        if (deployRouter) {
            console.log("=== Step 3: Deploying LiquidRouter ===");
            (router, routerImplementation) = DeployLiquidRouter.deploy(
                protocolFeeRecipient,
                deployConfig.router,
                networkConfig,
                burner
            );
        } else {
            router = networkConfig.liquidRouter;
            require(
                router != address(0),
                "DEPLOY_ROUTER=false but no liquidRouter in NetworkConfig"
            );
            console.log("=== Step 3: Using existing LiquidRouter ===");
            console.log("LiquidRouter address:");
            console.logAddress(router);
            // Implementation address not available from NetworkConfig, but not needed if router exists
        }
        console.log("");

        vm.stopBroadcast();

        // ============================================
        // Deployment Summary
        // ============================================
        console.log("");
        console.log("========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("Chain ID:");
        console.logUint(chainId);
        console.log("");
        console.log("Final Addresses:");
        console.log("----------------");
        console.log("RAREBurner:");
        console.logAddress(burner);
        console.log(deployBurner ? "  (deployed)" : "  (existing)");
        if (deployFactory) {
            console.log("Liquid Implementation:");
            console.logAddress(implementation);
            console.log("  (deployed)");
        }
        console.log("LiquidFactory:");
        console.logAddress(factory);
        console.log(deployFactory ? "  (deployed)" : "  (existing)");
        if (deployRouter) {
            console.log("LiquidRouter Implementation:");
            console.logAddress(routerImplementation);
            console.log("  (deployed)");
        }
        console.log("LiquidRouter Proxy:");
        console.logAddress(router);
        console.log(deployRouter ? "  (deployed)" : "  (existing)");
        console.log("");

        console.log("Referenced Contracts (from NetworkConfig):");
        console.log("----------------------------------------");
        console.log("RARE Token:");
        console.logAddress(networkConfig.rareToken);
        console.log("WETH:");
        console.logAddress(networkConfig.weth);
        console.log("Uniswap V4 Pool Manager:");
        console.logAddress(networkConfig.uniswapV4PoolManager);
        console.log("Uniswap V4 Quoter:");
        console.logAddress(networkConfig.uniswapV4Quoter);
        console.log("Uniswap Universal Router:");
        console.logAddress(networkConfig.uniswapUniversalRouter);
        console.log("");

        if (deployBurner || deployFactory || deployRouter) {
            console.log("========================================");
            console.log("UPDATE NetworkConfig.sol");
            console.log("========================================");
            console.log(
                "Update the following addresses in script/config/NetworkConfig.sol:"
            );
            console.log("");
            if (deployBurner) {
                console.log("rareBurner:");
                console.logAddress(burner);
                console.log(",");
            }
            if (deployFactory) {
                console.log("liquidFactory:");
                console.logAddress(factory);
                console.log(",");
            }
            if (deployRouter) {
                console.log("liquidRouter:");
                console.logAddress(router);
                console.log(",");
            }
            console.log("");
        }

        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Update NetworkConfig.sol with any new addresses above");
        console.log(
            "2. Update buy-liquid-live.ts and sell-liquid-live.ts with new router address (if router was deployed)"
        );
        console.log("");
        console.log(
            "3. Create tokens using (permissionless - anyone can create):"
        );
        console.log(
            "   forge script script/CreateToken.s.sol --rpc-url $RPC_URL --broadcast"
        );
        console.log(
            "   NOTE: Caller must have RARE tokens approved to factory"
        );
        console.log("4. Test buy/sell using:");
        console.log("   cd scripts && npx ts-node buy-liquid-live.ts");
    }
}
