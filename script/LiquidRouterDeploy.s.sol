// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {LiquidRouter} from "../src/LiquidRouter.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/**
 * @title LiquidRouterDeploy
 * @notice Deployment script for LiquidRouter
 * @dev Requires LiquidFactory to be deployed first and configured in NetworkConfig
 *
 * Prerequisites:
 * 1. Deploy LiquidFactory using LiquidFactoryDeploy.s.sol
 * 2. Deploy burner using RAREBurnerDeploy.s.sol
 * 3. Update NetworkConfig.sol with the LiquidFactory and RAREBurner addresses
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for deployment
 *
 * Environment Variables Optional:
 * - CHAIN_ID: Target chain ID (defaults to block.chainid)
 * - UNIVERSAL_ROUTER: Override Universal Router address (defaults to NetworkConfig)
 * - LIQUID_FACTORY: Override LiquidFactory address (defaults to NetworkConfig)
 *
 * Usage:
 *   forge script script/LiquidRouterDeploy.s.sol:LiquidRouterDeploy --rpc-url $RPC_URL --broadcast
 */
contract LiquidRouterDeploy is Script {
    function run() external {
        // Load environment variables
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

        // Allow environment variable overrides for Universal Router
        address universalRouter;
        try vm.envAddress("UNIVERSAL_ROUTER") returns (address _router) {
            universalRouter = _router;
        } catch {
            universalRouter = config.uniswapUniversalRouter;
        }

        // Allow environment variable overrides for LiquidFactory
        address liquidFactory;
        try vm.envAddress("LIQUID_FACTORY") returns (address _factory) {
            liquidFactory = _factory;
        } catch {
            liquidFactory = config.liquidFactory;
        }

        // Validate required addresses
        require(
            universalRouter != address(0),
            "Universal Router address not configured. Set UNIVERSAL_ROUTER env var or update NetworkConfig."
        );
        require(
            liquidFactory != address(0),
            "LiquidFactory address not configured. Deploy LiquidFactory first and set LIQUID_FACTORY env var or update NetworkConfig."
        );

        console.log("Deploying LiquidRouter to network with chain ID:");
        console.logUint(chainId);
        console.log("Deployer address:");
        console.logAddress(vm.addr(deployerPrivateKey));
        console.log("");
        console.log("Configuration:");
        console.log("--------------");
        console.log("Universal Router:");
        console.logAddress(universalRouter);
        console.log("LiquidFactory:");
        console.logAddress(liquidFactory);
        console.log("");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy LiquidRouter
        console.log("Deploying LiquidRouter...");
        LiquidRouter router = new LiquidRouter(universalRouter, liquidFactory);
        console.log("LiquidRouter deployed at:");
        console.logAddress(address(router));

        vm.stopBroadcast();

        // Log deployment summary
        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("Network Chain ID:");
        console.logUint(chainId);
        console.log("Deployer:");
        console.logAddress(vm.addr(deployerPrivateKey));
        console.log("");
        console.log("Deployed Contract:");
        console.log("------------------");
        console.log("LiquidRouter:");
        console.logAddress(address(router));
        console.log("");
        console.log("Configuration:");
        console.log("--------------");
        console.log("Universal Router:");
        console.logAddress(universalRouter);
        console.log("LiquidFactory (for fee config):");
        console.logAddress(liquidFactory);
        console.log("");
        console.log("Fee Structure:");
        console.log("--------------");
        console.log("Total Fee: 3% (TOTAL_FEE_BPS = 300)");
        console.log("Beneficiary Fee: 25% (BENEFICIARY_FEE_BPS = 2500)");
        console.log("Remainder split pulled from LiquidFactory:");
        console.log("  - RARE Burn: rareBurnFeeBPS from factory");
        console.log("  - Protocol: protocolFeeBPS from factory");
        console.log("  - Referrer: referrerFeeBPS from factory");
        console.log("");
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Verify contract on Etherscan/Basescan:");
        console.log(
            "   forge verify-contract <address> LiquidRouter --chain <chain>"
        );
        console.log("");
        console.log("2. Register tokens with beneficiaries:");
        console.log(
            '   cast send <router> "registerToken(address,address)" <token> <beneficiary>'
        );
        console.log("");
        console.log(
            "3. (Optional) Enable allowlist to restrict to registered tokens:"
        );
        console.log('   cast send <router> "setAllowlistEnabled(bool)" true');
        console.log("");
        console.log("Usage:");
        console.log("------");
        console.log("Buy tokens (ETH -> Token):");
        console.log(
            "   router.buy{value: ethAmount}(token, recipient, referrer, minOut, routeData, deadline)"
        );
        console.log("");
        console.log("Sell tokens (Token -> ETH):");
        console.log("   1. Approve router to spend tokens");
        console.log(
            "   2. router.sell(token, amount, recipient, referrer, minOut, routeData, deadline)"
        );
        console.log("");
        console.log("Quote functions:");
        console.log(
            "   router.quoteBuy(ethAmount) -> (feeBps, ethFee, ethForSwap)"
        );
        console.log(
            "   router.quoteSell(grossEth) -> (feeBps, ethFee, ethToUser)"
        );
        console.log(
            "   router.quoteFeeBreakdown(totalFee) -> (beneficiary, protocol, referrer, burn)"
        );
        console.log("");
        console.log(
            "NOTE: routeData must be pre-encoded Universal Router calldata."
        );
        console.log("Use Uniswap SDK to generate swap routes off-chain.");
    }
}
