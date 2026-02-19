// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {DeployConfig} from "./config/DeployConfig.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {DeployRAREBurner} from "./deployers/DeployRAREBurner.s.sol";
import {DeployLiquidFactory} from "./deployers/DeployLiquidFactory.s.sol";
import {DeployLiquidRouter} from "./deployers/DeployLiquidRouter.s.sol";
import {DeployLiquidAuctioneer} from "./deployers/DeployLiquidAuctioneer.s.sol";
import {DeployLiquidSwapGuard} from "./deployers/DeployLiquidSwapGuard.s.sol";
import {LiquidSwapGuard} from "liquid-editions/LiquidSwapGuard.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {LiquidAuctioneer} from "liquid-editions/LiquidAuctioneer.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

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
 * - DEPLOY_BURNER: Set true to deploy RAREBurner (default: false, uses NetworkConfig)
 * - DEPLOY_FACTORY: Set true to deploy LiquidFactory + implementations (default: false)
 * - DEPLOY_ROUTER: Set true to deploy LiquidRouter (default: false)
 * - DEPLOY_AUCTIONEER: Set true to deploy LiquidAuctioneer (default: false)
 * - DEPLOY_SWAP_GUARD: Set true to deploy LiquidSwapGuard (default: false)
 *
 * When the chain has ccaFactory and lbpStrategyFactory in NetworkConfig (e.g. mainnet, Sepolia),
 * the factory is automatically configured for Graduated (CCA) tokens on first run.
 *
 * Usage:
 *   # Full deployment
 *   DEPLOY_BURNER=true DEPLOY_FACTORY=true DEPLOY_ROUTER=true DEPLOY_AUCTIONEER=true DEPLOY_SWAP_GUARD=true \
 *   forge script script/DeployLiquidSystem.s.sol:DeployLiquidSystem --rpc-url $RPC_URL --broadcast
 *
 *   # Deploy only router
 *   DEPLOY_ROUTER=true \
 *   forge script script/DeployLiquidSystem.s.sol:DeployLiquidSystem --rpc-url $RPC_URL --broadcast
 *
 *   # Deploy only auctioneer (CCA bid/exit/claim/triggerGraduation)
 *   DEPLOY_AUCTIONEER=true \
 *   forge script script/DeployLiquidSystem.s.sol:DeployLiquidSystem --rpc-url $RPC_URL --broadcast
 *
 *   # Deploy only swap guard (Instant/MultiCurve/Graduated pool protection)
 *   DEPLOY_SWAP_GUARD=true \
 *   forge script script/DeployLiquidSystem.s.sol:DeployLiquidSystem --rpc-url $RPC_URL --broadcast
 *
 * Note: If you encounter gas limit errors, use --gas-limit flag:
 *   forge script script/DeployLiquidSystem.s.sol:DeployLiquidSystem --rpc-url $RPC_URL --broadcast --gas-limit 30000000
 */
contract DeployLiquidSystem is Script {
    uint8 private constant ROUTE_V4_SINGLE = 1;
    uint8 private constant ROUTE_V3_PATH = 2;
    uint8 private constant ROUTE_V2_PATH = 3;

    struct DeploymentResult {
        address burner;
        address guard;
        address factory;
        address implementation;
        address multiCurveImplementation;
        address graduatedImplementation;
        address router;
        address routerImplementation;
        address auctioneer;
    }

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

        // Get configurations (needed for deploySwapGuard default)
        DeployConfig.Config memory deployConfig = DeployConfig.getConfig(
            chainId
        );
        NetworkConfig.Config memory networkConfig = NetworkConfig.getConfig(
            chainId
        );

        // Load deployment flags (default to false — set to true explicitly for each component to deploy)
        bool deployBurner = vm.envOr("DEPLOY_BURNER", false);
        bool deployFactory = vm.envOr("DEPLOY_FACTORY", false);
        bool deployRouter = vm.envOr("DEPLOY_ROUTER", false);
        bool deployAuctioneer = vm.envOr("DEPLOY_AUCTIONEER", false);
        bool deploySwapGuard = vm.envOr("DEPLOY_SWAP_GUARD", false);

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
        console.log("  DEPLOY_AUCTIONEER:", deployAuctioneer);
        console.log("  DEPLOY_SWAP_GUARD:", deploySwapGuard);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        DeploymentResult memory result;

        // ============================================
        // Step 1: RAREBurner - deploy or use existing
        // ============================================
        if (deployBurner) {
            console.log("=== Step 1: Deploying RAREBurner ===");
            result.burner = DeployRAREBurner.deploy(
                deployer,
                deployConfig.burner,
                networkConfig
            );
        } else {
            result.burner = networkConfig.rareBurner;
            require(
                result.burner != address(0),
                "DEPLOY_BURNER=false but no rareBurner in NetworkConfig"
            );
            console.log("=== Step 1: Using existing RAREBurner ===");
            console.log("RAREBurner address:");
            console.logAddress(result.burner);
        }
        console.log("");

        // ============================================
        // Step 2: LiquidSwapGuard - deploy or use existing (before factory)
        // ============================================
        if (deploySwapGuard) {
            console.log("=== Step 2: Deploying LiquidSwapGuard ===");
            bytes32 guardSalt;
            try vm.envBytes32("LIQUID_SWAP_GUARD_SALT") returns (bytes32 s) {
                guardSalt = s;
            } catch {
                guardSalt = bytes32(0);
            }
            result.guard = DeployLiquidSwapGuard.deploy(
                IPoolManager(networkConfig.uniswapV4PoolManager),
                deployer,
                guardSalt
            );
        } else {
            result.guard = networkConfig.liquid.swapGuard;
            if (deployConfig.factory.useSwapGuard) {
                require(
                    result.guard != address(0),
                    "DEPLOY_SWAP_GUARD=false but no liquidSwapGuard in NetworkConfig (useSwapGuard=true)"
                );
            }
            if (result.guard != address(0)) {
                console.log("=== Step 2: Using existing LiquidSwapGuard ===");
                console.log("LiquidSwapGuard address:");
                console.logAddress(result.guard);
            }
        }
        console.log("");

        // Resolve poolHooks for factory: use guard when useSwapGuard and guard exists
        address effectivePoolHooks = address(0);
        if (deployConfig.factory.useSwapGuard && result.guard != address(0)) {
            effectivePoolHooks = result.guard;
        } else {
            effectivePoolHooks = deployConfig.factory.poolHooks;
        }
        if (deployFactory) {
            deployConfig.factory.poolHooks = effectivePoolHooks;
        }

        // ============================================
        // Step 3: LiquidFactory - deploy or use existing
        // ============================================
        if (deployFactory) {
            console.log("=== Step 3: Deploying LiquidFactory ===");
            DeployLiquidFactory.DeployResult
                memory factoryResult = DeployLiquidFactory.deploy(
                    deployer,
                    deployConfig.factory,
                    networkConfig
                );
            result.factory = factoryResult.factory;
            result.implementation = factoryResult.implementation;
            result.multiCurveImplementation = factoryResult
                .multiCurveImplementation;
            result.graduatedImplementation = factoryResult
                .graduatedImplementation;
        } else {
            result.factory = networkConfig.liquid.factory;
            require(
                result.factory != address(0),
                "DEPLOY_FACTORY=false but no liquidFactory in NetworkConfig"
            );
            console.log("=== Step 3: Using existing LiquidFactory ===");
            console.log("LiquidFactory address:");
            console.logAddress(result.factory);
            // Implementation address not available from NetworkConfig, but not needed if factory exists
        }
        console.log("");

        // ============================================
        // Step 4: LiquidRouter - deploy or use existing
        // ============================================
        if (deployRouter) {
            console.log("=== Step 4: Deploying LiquidRouter ===");
            (result.router, result.routerImplementation) = DeployLiquidRouter
                .deploy(
                    deployer,
                    protocolFeeRecipient,
                    deployConfig.fees,
                    networkConfig,
                    result.burner
                );
        } else {
            result.router = networkConfig.liquid.router;
            require(
                result.router != address(0),
                "DEPLOY_ROUTER=false but no liquidRouter in NetworkConfig"
            );
            console.log("=== Step 4: Using existing LiquidRouter ===");
            console.log("LiquidRouter address:");
            console.logAddress(result.router);
            // Implementation address not available from NetworkConfig, but not needed if router exists
        }
        console.log("");

        // ============================================
        // Step 5: LiquidAuctioneer - deploy or use existing
        // ============================================
        if (deployAuctioneer) {
            console.log("=== Step 5: Deploying LiquidAuctioneer ===");
            result.auctioneer = DeployLiquidAuctioneer.deploy(
                deployer,
                protocolFeeRecipient,
                deployConfig.fees,
                networkConfig.uniswapUniversalRouter,
                result.burner,
                networkConfig.rareToken,
                networkConfig.weth,
                false
            );
            LiquidAuctioneer auctioneerContract = LiquidAuctioneer(
                payable(result.auctioneer)
            );
            _configureAuctionRoute(
                auctioneerContract,
                address(0),
                networkConfig,
                deployConfig.auctioneerRoutes.ethToRare
            );
            if (networkConfig.usdc != address(0)) {
                _configureAuctionRoute(
                    auctioneerContract,
                    networkConfig.usdc,
                    networkConfig,
                    deployConfig.auctioneerRoutes.usdcToRare
                );
            }
            _configureAuctionRoute(
                auctioneerContract,
                networkConfig.rareToken,
                networkConfig,
                deployConfig.auctioneerRoutes.rareToRare
            );
        } else {
            result.auctioneer = networkConfig.liquid.auctioneer;
            require(
                result.auctioneer != address(0),
                "DEPLOY_AUCTIONEER=false but no liquidAuctioneer in NetworkConfig"
            );
            console.log("=== Step 5: Using existing LiquidAuctioneer ===");
            console.log("LiquidAuctioneer address:");
            console.logAddress(result.auctioneer);
        }
        console.log("");

        // ============================================
        // Step 6: Configure LiquidSwapGuard (addRouter, addCaller) and factory
        // ============================================
        if (deploySwapGuard && result.guard != address(0)) {
            console.log("=== Step 6: Configuring LiquidSwapGuard ===");
            LiquidSwapGuard guardContract = LiquidSwapGuard(result.guard);
            guardContract.addRouter(networkConfig.uniswapUniversalRouter);
            guardContract.addCaller(result.router);
            guardContract.addCaller(result.auctioneer);
            console.log("  addRouter(universalRouter)");
            console.log("  addCaller(liquidRouter)");
            console.log("  addCaller(liquidAuctioneer)");
            // If factory exists but wasn't deployed this run, set poolHooks on it
            if (!deployFactory && deployConfig.factory.useSwapGuard) {
                console.log("  Updating existing factory poolHooks...");
                LiquidFactory(result.factory).setPoolHooks(result.guard);
            }
        }
        // When only router is redeployed, whitelist it on existing guard
        if (deployRouter && !deploySwapGuard && result.guard != address(0)) {
            console.log(
                "=== Step 6b: Adding new router to existing SwapGuard ==="
            );
            LiquidSwapGuard(result.guard).addCaller(result.router);
            console.log("  addCaller(liquidRouter)");
        }
        // When only auctioneer is redeployed, whitelist it on existing guard
        if (
            deployAuctioneer && !deploySwapGuard && result.guard != address(0)
        ) {
            console.log(
                "=== Step 6c: Adding new auctioneer to existing SwapGuard ==="
            );
            LiquidSwapGuard(result.guard).addCaller(result.auctioneer);
            console.log("  addCaller(liquidAuctioneer)");
        }
        // Configure factory for Graduated (CCA) tokens when chain supports it
        if (
            result.factory != address(0) &&
            networkConfig.ccaFactory != address(0) &&
            networkConfig.lbpStrategyFactory != address(0)
        ) {
            LiquidFactory factoryContract = LiquidFactory(result.factory);
            if (factoryContract.lbpStrategyFactory() == address(0)) {
                console.log(
                    "=== Step 6d: Configuring factory for Graduated (CCA) tokens ==="
                );
                factoryContract.setCcaFactory(networkConfig.ccaFactory);
                factoryContract.setLbpStrategyFactory(
                    networkConfig.lbpStrategyFactory
                );
                factoryContract.setPositionManager(
                    networkConfig.uniswapV4PositionManager
                );
                factoryContract.setProtocolFeeRecipient(protocolFeeRecipient);
                console.log(
                    "  setCcaFactory, setLbpStrategyFactory, setPositionManager, setProtocolFeeRecipient"
                );
            }
        }
        // Link factory and router so creation auto-registers beneficiary in one tx.
        if (result.factory != address(0) && result.router != address(0)) {
            LiquidFactory factoryContract = LiquidFactory(result.factory);
            LiquidRouter routerContract = LiquidRouter(payable(result.router));
            factoryContract.setLiquidRouter(result.router);
            routerContract.setTrustedFactory(result.factory);
            console.log("=== Step 6e: Configuring auto-registration ===");
            console.log("  factory.setLiquidRouter(router)");
            console.log("  router.setTrustedFactory(factory)");
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
        console.logAddress(result.burner);
        console.log(deployBurner ? "  (deployed)" : "  (existing)");
        if (deployFactory) {
            console.log("LiquidInstant Implementation:");
            console.logAddress(result.implementation);
            console.log("  (deployed)");
            console.log("LiquidMultiCurve Implementation:");
            console.logAddress(result.multiCurveImplementation);
            console.log("  (deployed)");
            console.log("LiquidGraduated Implementation:");
            console.logAddress(result.graduatedImplementation);
            console.log("  (deployed)");
        }
        console.log("LiquidFactory:");
        console.logAddress(result.factory);
        console.log(deployFactory ? "  (deployed)" : "  (existing)");
        if (deployRouter) {
            console.log("LiquidRouter Implementation:");
            console.logAddress(result.routerImplementation);
            console.log("  (deployed)");
        }
        console.log("LiquidRouter Proxy:");
        console.logAddress(result.router);
        console.log(deployRouter ? "  (deployed)" : "  (existing)");
        console.log("LiquidAuctioneer:");
        console.logAddress(result.auctioneer);
        console.log(deployAuctioneer ? "  (deployed)" : "  (existing)");
        if (result.guard != address(0)) {
            console.log("LiquidSwapGuard:");
            console.logAddress(result.guard);
            console.log(deploySwapGuard ? "  (deployed)" : "  (existing)");
        }
        console.log("");

        console.log("Referenced Contracts (from NetworkConfig):");
        console.log("----------------------------------------");
        console.log("RARE Token:");
        console.logAddress(networkConfig.rareToken);
        console.log("USDC:");
        console.logAddress(networkConfig.usdc);
        console.log("WETH:");
        console.logAddress(networkConfig.weth);
        console.log("Uniswap V4 Pool Manager:");
        console.logAddress(networkConfig.uniswapV4PoolManager);
        console.log("Uniswap V4 Quoter:");
        console.logAddress(networkConfig.uniswapV4Quoter);
        console.log("Uniswap Universal Router:");
        console.logAddress(networkConfig.uniswapUniversalRouter);
        console.log("");

        if (
            deployBurner ||
            deployFactory ||
            deployRouter ||
            deployAuctioneer ||
            deploySwapGuard
        ) {
            console.log("========================================");
            console.log("UPDATE NetworkConfig.sol");
            console.log("========================================");
            console.log(
                "Update the following addresses in script/config/NetworkConfig.sol:"
            );
            console.log("");
            if (deployBurner) {
                console.log("rareBurner:");
                console.logAddress(result.burner);
                console.log(",");
            }
            if (deployFactory) {
                console.log("liquidFactory:");
                console.logAddress(result.factory);
                console.log(",");
            }
            if (deployRouter) {
                console.log("liquidRouter:");
                console.logAddress(result.router);
                console.log(",");
            }
            if (deployAuctioneer) {
                console.log("liquidAuctioneer:");
                console.logAddress(result.auctioneer);
                console.log(",");
            }
            if (deploySwapGuard && result.guard != address(0)) {
                console.log("liquidSwapGuard:");
                console.logAddress(result.guard);
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
            "   Instant: forge script script/CreateToken.s.sol --rpc-url $RPC_URL --broadcast"
        );
        console.log(
            "   Graduated (CCA): RPC_URL=$RPC_URL forge script script/CreateTokenWithAuction.s.sol --rpc-url $RPC_URL --broadcast --ffi"
        );
        console.log(
            "   NOTE: Caller must have RARE tokens approved to factory"
        );
        console.log("4. Test buy/sell using:");
        console.log("   cd scripts && npx ts-node buy-liquid-live.ts");
    }

    function _configureAuctionRoute(
        LiquidAuctioneer auctioneerContract,
        address tokenIn,
        NetworkConfig.Config memory networkConfig,
        DeployConfig.AuctionRouteConfig memory routeConfig
    ) internal {
        if (uint8(routeConfig.kind) == ROUTE_V4_SINGLE) {
            auctioneerContract.setTokenRouteV4(
                tokenIn,
                routeConfig.v4Fee,
                routeConfig.v4TickSpacing,
                routeConfig.v4Hooks
            );
            return;
        }
        if (uint8(routeConfig.kind) == ROUTE_V3_PATH) {
            // If no explicit path is configured, use default tokenIn -> WETH -> RARE.
            if (routeConfig.v3Path.length == 0) {
                address pathStart = tokenIn == address(0)
                    ? networkConfig.weth
                    : tokenIn;
                routeConfig.v3Path = abi.encodePacked(
                    pathStart,
                    uint24(3000),
                    networkConfig.weth,
                    uint24(3000),
                    networkConfig.rareToken
                );
            }
            auctioneerContract.setTokenRouteV3(tokenIn, routeConfig.v3Path);
            return;
        }
        if (uint8(routeConfig.kind) == ROUTE_V2_PATH) {
            auctioneerContract.setTokenRouteV2(tokenIn, routeConfig.v2Path);
        }
    }
}
