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
import {DeployLiquidInitGuard} from "./deployers/DeployLiquidInitGuard.s.sol";
import {LiquidSwapGuard} from "liquid-editions/LiquidSwapGuard.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidAuctioneer} from "liquid-editions/LiquidAuctioneer.sol";
import {FeeDistributor} from "liquid-editions/FeeDistributor.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";
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
 * - DEPLOY_FEE_DISTRIBUTOR: Set true to deploy FeeDistributor module (default: false, uses NetworkConfig / env overrides)
 * - DEPLOY_LIQUID_REGISTRY: Set true to deploy LiquidRegistry module (default: false, uses NetworkConfig / env overrides)
 * - DEPLOY_BURNER: Set true to deploy RAREBurner (default: false, uses NetworkConfig)
 * - DEPLOY_FACTORY: Set true to deploy LiquidFactory + implementations (default: false)
 * - DEPLOY_ROUTER: Set true to deploy LiquidRouter (default: false)
 * - DEPLOY_AUCTIONEER: Set true to deploy LiquidAuctioneer (default: false)
 * - DEPLOY_SWAP_GUARD: Set true to deploy LiquidSwapGuard (default: false)
 * - DEPLOY_INIT_GUARD: Set true to deploy LiquidInitGuard (default: false)
 * - FEE_DISTRIBUTOR: Optional override address for existing FeeDistributor module
 * - LIQUID_REGISTRY: Optional override address for existing LiquidRegistry module
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
        address initGuard;
        address factory;
        address multiCurveImplementation;
        address graduatedImplementation;
        address router;
        address routerImplementation;
        address auctioneer;
    }

    function _resolveModuleAddress(
        string memory envKey,
        address fallbackAddress
    ) private view returns (address) {
        address resolved = fallbackAddress;
        try vm.envAddress(envKey) returns (address envAddress) {
            resolved = envAddress;
        } catch {
            // Keep fallback when env var is not set.
        }
        return resolved;
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
        bool deployFeeDistributor = vm.envOr("DEPLOY_FEE_DISTRIBUTOR", false);
        bool deployLiquidRegistry = vm.envOr(
            "DEPLOY_LIQUID_REGISTRY",
            false
        );
        bool deployBurner = vm.envOr("DEPLOY_BURNER", false);
        bool deployFactory = vm.envOr("DEPLOY_FACTORY", false);
        bool deployRouter = vm.envOr("DEPLOY_ROUTER", false);
        bool deployAuctioneer = vm.envOr("DEPLOY_AUCTIONEER", false);
        bool deploySwapGuard = vm.envOr("DEPLOY_SWAP_GUARD", false);
        bool deployInitGuard = vm.envOr("DEPLOY_INIT_GUARD", false);

        address deployer = vm.addr(deployerPrivateKey);
        FeeDistributor sharedFeeDistributor;
        LiquidRegistry sharedLiquidRegistry;
        address feeDistributorAddress = _resolveModuleAddress(
            "FEE_DISTRIBUTOR",
            networkConfig.liquid.feeDistributor
        );
        address liquidRegistryAddress = _resolveModuleAddress(
            "LIQUID_REGISTRY",
            networkConfig.liquid.liquidRegistry
        );

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
        console.log("  DEPLOY_FEE_DISTRIBUTOR:", deployFeeDistributor);
        console.log(
            "  DEPLOY_LIQUID_REGISTRY:",
            deployLiquidRegistry
        );
        console.log("  DEPLOY_BURNER:", deployBurner);
        console.log("  DEPLOY_FACTORY:", deployFactory);
        console.log("  DEPLOY_ROUTER:", deployRouter);
        console.log("  DEPLOY_AUCTIONEER:", deployAuctioneer);
        console.log("  DEPLOY_SWAP_GUARD:", deploySwapGuard);
        console.log("  DEPLOY_INIT_GUARD:", deployInitGuard);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        DeploymentResult memory result;

        if (deployFeeDistributor) {
            console.log("=== Step 0: Deploying FeeDistributor ===");
            sharedFeeDistributor = new FeeDistributor(
                deployer,
                deployConfig.fees.totalFeeBPS,
                protocolFeeRecipient
            );
            feeDistributorAddress = address(sharedFeeDistributor);
            console.log("FeeDistributor:");
            console.logAddress(address(sharedFeeDistributor));
            console.log("");
        } else if (feeDistributorAddress != address(0)) {
            sharedFeeDistributor = FeeDistributor(feeDistributorAddress);
            console.log("=== Step 0: Using existing FeeDistributor ===");
            console.log("FeeDistributor:");
            console.logAddress(feeDistributorAddress);
            console.log("");
        }

        if (deployLiquidRegistry) {
            console.log("=== Step 0: Deploying LiquidRegistry ===");
            sharedLiquidRegistry = new LiquidRegistry(deployer);
            liquidRegistryAddress = address(sharedLiquidRegistry);
            console.log("LiquidRegistry:");
            console.logAddress(address(sharedLiquidRegistry));
            console.log("");
        } else if (liquidRegistryAddress != address(0)) {
            sharedLiquidRegistry = LiquidRegistry(
                liquidRegistryAddress
            );
            console.log(
                "=== Step 0: Using existing LiquidRegistry ==="
            );
            console.log("LiquidRegistry:");
            console.logAddress(liquidRegistryAddress);
            console.log("");
        }

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

        // ============================================
        // Step 2a: LiquidInitGuard - deploy or use existing (before factory)
        // ============================================
        if (deployInitGuard) {
            console.log("=== Step 2a: Deploying LiquidInitGuard ===");
            bytes32 initGuardSalt;
            try vm.envBytes32("LIQUID_INIT_GUARD_SALT") returns (bytes32 s) {
                initGuardSalt = s;
            } catch {
                initGuardSalt = bytes32(0);
            }
            result.initGuard = DeployLiquidInitGuard.deploy(
                IPoolManager(networkConfig.uniswapV4PoolManager),
                deployer,
                initGuardSalt
            );
        } else {
            result.initGuard = networkConfig.liquid.initGuard;
            if (result.initGuard != address(0)) {
                console.log("=== Step 2a: Using existing LiquidInitGuard ===");
                console.log("LiquidInitGuard address:");
                console.logAddress(result.initGuard);
            }
        }
        console.log("");

        // Resolve poolHooks for factory:
        //   1. SwapGuard replaces InitGuard when useSwapGuard is enabled
        //   2. Otherwise use InitGuard as default (init-only protection)
        //   3. Fallback to explicit poolHooks from DeployConfig
        address effectivePoolHooks;
        if (deployConfig.factory.useSwapGuard && result.guard != address(0)) {
            effectivePoolHooks = result.guard;
        } else if (result.initGuard != address(0)) {
            effectivePoolHooks = result.initGuard;
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
            require(
                address(sharedFeeDistributor) != address(0),
                "DEPLOY_ROUTER requires a FeeDistributor module. Set DEPLOY_FEE_DISTRIBUTOR=true or provide FEE_DISTRIBUTOR in env / NetworkConfig."
            );
            require(
                address(sharedLiquidRegistry) != address(0),
                "DEPLOY_ROUTER requires a LiquidRegistry module. Set DEPLOY_LIQUID_REGISTRY=true or provide LIQUID_REGISTRY in env / NetworkConfig."
            );
            (result.router, result.routerImplementation) = DeployLiquidRouter
                .deployWithModules(
                    deployer,
                    sharedFeeDistributor,
                    sharedLiquidRegistry,
                    networkConfig.uniswapUniversalRouter
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
            require(
                address(sharedFeeDistributor) != address(0),
                "DEPLOY_AUCTIONEER requires a FeeDistributor module. Set DEPLOY_FEE_DISTRIBUTOR=true or provide FEE_DISTRIBUTOR in env / NetworkConfig."
            );
            require(
                address(sharedLiquidRegistry) != address(0),
                "DEPLOY_AUCTIONEER requires a LiquidRegistry module. Set DEPLOY_LIQUID_REGISTRY=true or provide LIQUID_REGISTRY in env / NetworkConfig."
            );
            result.auctioneer = DeployLiquidAuctioneer.deployWithModules(
                deployer,
                sharedFeeDistributor,
                sharedLiquidRegistry,
                networkConfig.uniswapUniversalRouter,
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
        if (
            deployConfig.factory.useSwapGuard &&
            result.guard != address(0) &&
            result.factory != address(0)
        ) {
            LiquidSwapGuard guardContract = LiquidSwapGuard(result.guard);
            address configuredFactory = guardContract.factory();
            if (configuredFactory == address(0)) {
                console.log("  Setting guard factory...");
                guardContract.setFactory(result.factory);
            } else if (configuredFactory != result.factory) {
                revert("DeployLiquidSystem: SwapGuard already bound to another factory");
            }
        }

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

        // ============================================
        // Step 6d: Configure LiquidInitGuard (setFactory)
        // ============================================
        if (result.initGuard != address(0) && result.factory != address(0)) {
            LiquidInitGuard initGuardContract = LiquidInitGuard(result.initGuard);
            address igFactory = initGuardContract.factory();
            if (igFactory == address(0)) {
                console.log("=== Step 6d: Configuring LiquidInitGuard ===");
                console.log("  Setting initGuard factory...");
                initGuardContract.setFactory(result.factory);
            } else if (igFactory != result.factory) {
                revert("DeployLiquidSystem: InitGuard already bound to another factory");
            }
            // If factory exists but wasn't deployed this run and we're not using swap guard, update poolHooks
            if (deployInitGuard && !deployFactory && !deployConfig.factory.useSwapGuard) {
                console.log("  Updating existing factory poolHooks to initGuard...");
                LiquidFactory(result.factory).setPoolHooks(result.initGuard);
            }
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
        // Link factory to registry so creation auto-registers tokens.
        if (result.factory != address(0) && address(sharedLiquidRegistry) != address(0)) {
            LiquidFactory factoryContract = LiquidFactory(result.factory);
            factoryContract.setLiquidRegistry(address(sharedLiquidRegistry));
            console.log("=== Step 6e: Configuring auto-registration ===");
            console.log("  factory.setLiquidRegistry(sharedLiquidRegistry)");
        }
        if (
            (deployRouter || deployAuctioneer || deployFactory) &&
            address(sharedLiquidRegistry) != address(0)
        ) {
            console.log("=== Step 6f: Shared module readiness ===");
            if (
                sharedLiquidRegistry.owner() == deployer
            ) {
                if (deployRouter && !sharedLiquidRegistry.isWriter(result.router)) {
                    sharedLiquidRegistry.setWriter(result.router, true);
                    console.log(
                        "  registry writer assigned to router"
                    );
                }
                if (
                    deployAuctioneer &&
                    !sharedLiquidRegistry.isWriter(result.auctioneer)
                ) {
                    sharedLiquidRegistry.setWriter(result.auctioneer, true);
                    console.log(
                        "  registry writer assigned to auctioneer"
                    );
                }
                if (
                    deployFactory &&
                    !sharedLiquidRegistry.isWriter(result.factory)
                ) {
                    sharedLiquidRegistry.setWriter(result.factory, true);
                    console.log(
                        "  registry writer assigned to factory"
                    );
                }
            } else {
                console.log(
                    "  Warning: registry owner is different; skip writer setup."
                );
                console.log(
                    "           Ensure LiquidRegistry writer permissions are configured for new modules manually."
                );
            }
            if (deployRouter || deployAuctioneer || deployFactory) {
                console.log(
                    "  router / auctioneer / factory writes will use shared registry."
                );
            }
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
        if (address(sharedFeeDistributor) != address(0)) {
            console.log("Shared FeeDistributor:");
            console.logAddress(address(sharedFeeDistributor));
            console.log(
                deployFeeDistributor ? "  (deployed)" : "  (existing)"
            );
        }
        if (address(sharedLiquidRegistry) != address(0)) {
            console.log("Shared LiquidRegistry:");
            console.logAddress(address(sharedLiquidRegistry));
            console.log(
                deployLiquidRegistry ? "  (deployed)" : "  (existing)"
            );
        }
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
            deploySwapGuard ||
            deployFeeDistributor ||
            deployLiquidRegistry
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
            if (deployFeeDistributor || feeDistributorAddress != address(0)) {
                console.log("feeDistributor:");
                console.logAddress(feeDistributorAddress);
                console.log(",");
            }
            if (
                deployLiquidRegistry || liquidRegistryAddress != address(0)
            ) {
                console.log("liquidRegistry:");
                console.logAddress(liquidRegistryAddress);
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
