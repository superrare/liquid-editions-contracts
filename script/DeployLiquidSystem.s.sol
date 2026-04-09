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
import {DeployLiquidGuard} from "./deployers/DeployLiquidGuard.s.sol";
import {DeployLiquidMigrationExecutor} from "./deployers/DeployLiquidMigrationExecutor.s.sol";
import {DeployLiquidSystemReconcile} from "./deployers/DeployLiquidSystemReconcile.s.sol";
import {LiquidSwapGuard} from "liquid-editions/LiquidSwapGuard.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidMigrationExecutor} from "liquid-editions/LiquidMigrationExecutor.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {LiquidAuctioneer} from "liquid-editions/LiquidAuctioneer.sol";
import {FeeDistributor} from "liquid-editions/FeeDistributor.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/**
 * @title DeployLiquidSystem
 * @notice Orchestrates deployment of all Liquid system contracts
 * @dev Uses individual deployer libraries and supports partial deployments via flags
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for deployment
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
 * - DEPLOY_LIQUID_GUARD: Set true to deploy LiquidGuard (default: false)
 *                        Requires DEPLOY_FEE_DISTRIBUTOR=true or an existing FeeDistributor
 *                        in NetworkConfig / FEE_DISTRIBUTOR env. Does NOT self-deploy a distributor.
 * - DEPLOY_MIGRATION_EXECUTOR: Set true to deploy LiquidMigrationExecutor (default: false)
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
 *   # Deploy only swap guard (MultiCurve/Graduated pool protection)
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
        address liquidGuard;
        address factory;
        address multiCurveImplementation;
        address graduatedImplementation;
        address router;
        address routerImplementation;
        address auctioneer;
        address migrationExecutor;
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
        // Deployment flow:
        // 1) resolve env + chain configs + target modules
        // 2) deploy or resolve each module (flags control each component)
        // 3) bind cross-module pointers for deployed/new modules
        // 4) reconcile shared-module wiring for partial redeploy safety

        // Load required environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

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
        address protocolFeeRecipient = networkConfig.protocolFeeRecipient;

        // Load deployment flags (default to false — set to true explicitly for each component to deploy)
        bool deployFeeDistributor = vm.envOr("DEPLOY_FEE_DISTRIBUTOR", false);
        bool deployLiquidRegistry = vm.envOr("DEPLOY_LIQUID_REGISTRY", false);
        bool deployBurner = vm.envOr("DEPLOY_BURNER", false);
        bool deployFactory = vm.envOr("DEPLOY_FACTORY", false);
        bool deployRouter = vm.envOr("DEPLOY_ROUTER", false);
        bool deployAuctioneer = vm.envOr("DEPLOY_AUCTIONEER", false);
        bool deploySwapGuard = vm.envOr("DEPLOY_SWAP_GUARD", false);
        bool deployInitGuard = vm.envOr("DEPLOY_INIT_GUARD", false);
        bool deployLiquidGuard = vm.envOr("DEPLOY_LIQUID_GUARD", false);
        bool deployMigrationExecutor = vm.envOr(
            "DEPLOY_MIGRATION_EXECUTOR",
            false
        );
        bool deployLegacyFeeDistributor = !deployConfig
            .factory
            .useLiquidGuard && !deployLiquidGuard;

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
        console.log("  DEPLOY_LIQUID_REGISTRY:", deployLiquidRegistry);
        console.log("  DEPLOY_BURNER:", deployBurner);
        console.log("  DEPLOY_FACTORY:", deployFactory);
        console.log("  DEPLOY_ROUTER:", deployRouter);
        console.log("  DEPLOY_AUCTIONEER:", deployAuctioneer);
        console.log("  DEPLOY_SWAP_GUARD:", deploySwapGuard);
        console.log("  DEPLOY_INIT_GUARD:", deployInitGuard);
        console.log("  DEPLOY_LIQUID_GUARD:", deployLiquidGuard);
        console.log("  DEPLOY_MIGRATION_EXECUTOR:", deployMigrationExecutor);
        console.log("");

        // Preflight validation: if we are not redeploying shared modules, ensure required
        // dependencies exist before attempting partial wiring.
        if (!deployLiquidRegistry && liquidRegistryAddress == address(0)) {
            if (deployRouter) {
                revert(
                    "DEPLOY_LIQUID_REGISTRY=false and LIQUID_REGISTRY=0x0 but DEPLOY_ROUTER=true"
                );
            }
            if (deployAuctioneer) {
                revert(
                    "DEPLOY_LIQUID_REGISTRY=false and LIQUID_REGISTRY=0x0 but DEPLOY_AUCTIONEER=true"
                );
            }
        }
        if (!deployFeeDistributor && feeDistributorAddress == address(0)) {
            if (deployAuctioneer) {
                revert(
                    "DEPLOY_FEE_DISTRIBUTOR=false and FEE_DISTRIBUTOR=0x0 but DEPLOY_AUCTIONEER=true"
                );
            }
            if (deployLiquidGuard) {
                revert(
                    "DEPLOY_FEE_DISTRIBUTOR=false and FEE_DISTRIBUTOR=0x0 but DEPLOY_LIQUID_GUARD=true"
                );
            }
        }
        if (deployFeeDistributor && protocolFeeRecipient == address(0)) {
            require(
                protocolFeeRecipient != address(0),
                "DEPLOY_FEE_DISTRIBUTOR=true requires protocolFeeRecipient in NetworkConfig"
            );
        }
        if (deployFactory) {
            require(
                networkConfig.weth != address(0),
                "DEPLOY_FACTORY=true requires WETH address in NetworkConfig"
            );
            require(
                networkConfig.uniswapV4PoolManager != address(0),
                "DEPLOY_FACTORY=true requires uniswapV4PoolManager in NetworkConfig"
            );
            require(
                networkConfig.uniswapV4Quoter != address(0),
                "DEPLOY_FACTORY=true requires uniswapV4Quoter in NetworkConfig"
            );
        }
        if (deployRouter) {
            require(
                networkConfig.uniswapUniversalRouter != address(0),
                "DEPLOY_ROUTER=true requires uniswapUniversalRouter in NetworkConfig"
            );
        }
        if (deployAuctioneer) {
            require(
                networkConfig.uniswapUniversalRouter != address(0),
                "DEPLOY_AUCTIONEER=true requires uniswapUniversalRouter in NetworkConfig"
            );
            require(
                networkConfig.rareToken != address(0),
                "DEPLOY_AUCTIONEER=true requires RARE token in NetworkConfig"
            );
            require(
                networkConfig.weth != address(0),
                "DEPLOY_AUCTIONEER=true requires WETH in NetworkConfig"
            );
        }
        if (deploySwapGuard || deployInitGuard || deployLiquidGuard) {
            require(
                networkConfig.uniswapV4PoolManager != address(0),
                "DEPLOY_SWAP_GUARD/INIT_GUARD/LIQUID_GUARD requires uniswapV4PoolManager in NetworkConfig"
            );
        }
        if (deployLiquidGuard && networkConfig.rareToken == address(0)) {
            revert(
                "DEPLOY_LIQUID_GUARD=true requires RARE token in NetworkConfig"
            );
        }
        if (
            deploySwapGuard &&
            !deployRouter &&
            networkConfig.liquid.router == address(0)
        ) {
            revert(
                "DEPLOY_ROUTER=false and LIQUID_ROUTER=0x0 but DEPLOY_SWAP_GUARD=true"
            );
        }
        // Warn when a newly deployed FeeDistributor won't be auto-wired to an existing LiquidGuard.
        // reconcileLiquidGuardFeeDistributor in Step 6i is gated on useLiquidGuard || deployLiquidGuard,
        // so if both are false the existing guard keeps its old distributor pointer.
        if (
            deployFeeDistributor &&
            networkConfig.liquid.liquidGuard != address(0) &&
            !deployConfig.factory.useLiquidGuard &&
            !deployLiquidGuard
        ) {
            console.log(
                "Warning: DEPLOY_FEE_DISTRIBUTOR=true but the existing LiquidGuard will NOT be"
            );
            console.log(
                "         auto-wired to the new FeeDistributor (useLiquidGuard=false and"
            );
            console.log(
                "         DEPLOY_LIQUID_GUARD=false). Wire manually or re-run with DEPLOY_LIQUID_GUARD=true."
            );
            console.log("");
        }

        vm.startBroadcast(deployerPrivateKey);

        DeploymentResult memory result;

        if (deployFeeDistributor) {
            console.log("=== Step 0: Deploying FeeDistributor ===");
            if (!deployLegacyFeeDistributor) {
                require(
                    networkConfig.uniswapV4PoolManager != address(0) &&
                        networkConfig.rareToken != address(0),
                    "DEPLOY_FEE_DISTRIBUTOR requires V4 config when not legacy mode"
                );
            }
            uint16 totalFeeBPS = deployConfig.fees.totalFeeBPS;
            sharedFeeDistributor = new FeeDistributor(
                deployer,
                deployLegacyFeeDistributor
                    ? address(0)
                    : networkConfig.uniswapV4PoolManager, // poolManager
                deployLegacyFeeDistributor
                    ? address(0)
                    : networkConfig.rareToken, // rareToken
                protocolFeeRecipient,
                5000, // 50% beneficiary share (legacy default)
                totalFeeBPS
            );
            feeDistributorAddress = address(sharedFeeDistributor);
            console.log("FeeDistributor:");
            console.logAddress(address(sharedFeeDistributor));
            if (!deployLegacyFeeDistributor) {
                _tryConfigureRareEthPoolKey(
                    sharedFeeDistributor,
                    networkConfig
                );
            }
            console.log("");
        } else if (feeDistributorAddress != address(0)) {
            sharedFeeDistributor = FeeDistributor(
                payable(feeDistributorAddress)
            );
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
            sharedLiquidRegistry = LiquidRegistry(liquidRegistryAddress);
            console.log("=== Step 0: Using existing LiquidRegistry ===");
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

        // ============================================
        // Step 2b: LiquidGuard - deploy or use existing (before factory)
        // ============================================
        if (deployLiquidGuard) {
            console.log("=== Step 2b: Deploying LiquidGuard ===");
            bytes32 liquidGuardSalt;
            try vm.envBytes32("LIQUID_GUARD_SALT") returns (bytes32 s) {
                liquidGuardSalt = s;
            } catch {
                liquidGuardSalt = bytes32(0);
            }
            // Optional: set LIQUID_GUARD_SALT_START_FROM to skip past salts whose addresses are
            // already deployed on-chain (e.g. from a prior dry-run or cancelled broadcast).
            // Default 0 starts mining from the beginning. Set to 1 to start from 1_000_000, etc.
            uint256 liquidGuardSaltStartFrom;
            try vm.envUint("LIQUID_GUARD_SALT_START_FROM") returns (uint256 s) {
                liquidGuardSaltStartFrom = s;
            } catch {
                liquidGuardSaltStartFrom = 0;
            }
            result.liquidGuard = DeployLiquidGuard.deploy(
                IPoolManager(networkConfig.uniswapV4PoolManager),
                deployer,
                networkConfig.rareToken,
                liquidGuardSalt,
                DeployLiquidGuard.CREATE2_DEPLOYER,
                liquidGuardSaltStartFrom
            );
            console.log("LiquidGuard:");
            console.logAddress(result.liquidGuard);
            // FeeDistributor wiring is handled by reconcileLiquidGuardFeeDistributor in Step 6i,
            // using sharedFeeDistributor resolved in Step 0 (DEPLOY_FEE_DISTRIBUTOR=true required).
            console.log("");
        } else {
            result.liquidGuard = networkConfig.liquid.liquidGuard;
            if (result.liquidGuard != address(0)) {
                console.log("=== Step 2b: Using existing LiquidGuard ===");
                console.log("LiquidGuard address:");
                console.logAddress(result.liquidGuard);
            }
        }
        console.log("");

        // Resolve poolHooks for factory:
        //   1. LiquidGuard is the canonical path when enabled
        //   2. Otherwise fall back to explicit poolHooks from DeployConfig (legacy/manual setup)
        address effectivePoolHooks;
        if (deployConfig.factory.useLiquidGuard) {
            require(
                result.liquidGuard != address(0),
                "DeployLiquidSystem: useLiquidGuard=true requires a LiquidGuard address"
            );
            effectivePoolHooks = result.liquidGuard;
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
                address(sharedLiquidRegistry) != address(0),
                "DEPLOY_ROUTER requires a LiquidRegistry module. Set DEPLOY_LIQUID_REGISTRY=true or provide LIQUID_REGISTRY in env / NetworkConfig."
            );
            (result.router, result.routerImplementation) = DeployLiquidRouter
                .deployWithModules(
                    deployer,
                    sharedLiquidRegistry,
                    networkConfig.uniswapUniversalRouter
                );

            // Whitelist currency tokens on the router
            LiquidRouter routerContract = LiquidRouter(payable(result.router));
            routerContract.addCurrency(networkConfig.rareToken);
            console.log("  Whitelisted RARE as currency");
            if (networkConfig.usdc != address(0)) {
                routerContract.addCurrency(networkConfig.usdc);
                console.log("  Whitelisted USDC as currency");
            }
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
                protocolFeeRecipient != address(0),
                "DEPLOY_AUCTIONEER requires protocolFeeRecipient in NetworkConfig"
            );
            require(
                address(sharedLiquidRegistry) != address(0),
                "DEPLOY_AUCTIONEER requires a LiquidRegistry module. Set DEPLOY_LIQUID_REGISTRY=true or provide LIQUID_REGISTRY in env / NetworkConfig."
            );
            result.auctioneer = DeployLiquidAuctioneer.deployWithModules(
                deployer,
                protocolFeeRecipient,
                sharedLiquidRegistry,
                networkConfig.uniswapUniversalRouter,
                networkConfig.rareToken,
                networkConfig.weth,
                400, // 4% ETH fee for native ETH bids
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
        // Step 5b: LiquidMigrationExecutor - deploy or use existing
        // ============================================
        if (deployMigrationExecutor) {
            console.log("=== Step 5b: Deploying LiquidMigrationExecutor ===");
            require(
                result.factory != address(0),
                "DEPLOY_MIGRATION_EXECUTOR=true requires a LiquidFactory address"
            );
            // Registry is required. For phase-0 testing without a real registry,
            // set LIQUID_REGISTRY to a non-contract sentinel (e.g. address(1))
            // which causes the executor to skip the isRegistered check.
            require(
                liquidRegistryAddress != address(0),
                "DEPLOY_MIGRATION_EXECUTOR=true requires a LiquidRegistry address (use sentinel address(1) to skip registration check)"
            );
            require(
                protocolFeeRecipient != address(0),
                "DEPLOY_MIGRATION_EXECUTOR=true requires protocolFeeRecipient in NetworkConfig"
            );

            result.migrationExecutor = DeployLiquidMigrationExecutor.deploy(
                deployer, // owner (update post-deploy to multisig)
                protocolFeeRecipient, // protocolVault
                liquidRegistryAddress
            );

            // Wire factory to executor
            LiquidFactory(result.factory).setMigrationExecutor(
                result.migrationExecutor
            );
            console.log("  factory.setMigrationExecutor(migrationExecutor)");

            // Approve current pool hooks for migration targets
            LiquidMigrationExecutor executorContract = LiquidMigrationExecutor(
                result.migrationExecutor
            );
            if (effectivePoolHooks != address(0)) {
                executorContract.approveHook(effectivePoolHooks, true);
                console.log("  approveHook(effectivePoolHooks)");
            }
            executorContract.setAllowedTickSpacing(
                deployConfig.factory.poolTickSpacing,
                true
            );
            console.log("  setAllowedTickSpacing(poolTickSpacing)");
            executorContract.setAllowedFee(0, true);
            console.log("  setAllowedFee(0)");
        } else {
            result.migrationExecutor = networkConfig.liquid.migrationExecutor;
            if (result.migrationExecutor != address(0)) {
                console.log(
                    "=== Step 5b: Using existing LiquidMigrationExecutor ==="
                );
                console.log("LiquidMigrationExecutor address:");
                console.logAddress(result.migrationExecutor);
            }
        }
        console.log("");

        // ============================================
        // Step 6: Configure LiquidSwapGuard (addRouter, addCaller) and factory
        // ============================================
        if (
            deployConfig.factory.useLiquidGuard &&
            result.liquidGuard != address(0) &&
            result.factory != address(0)
        ) {
            DeployLiquidSystemReconcile.reconcileLiquidGuardFactory(
                deployer,
                LiquidGuard(result.liquidGuard),
                result.factory
            );
        }
        if (
            !deployConfig.factory.useLiquidGuard &&
            result.guard != address(0) &&
            result.factory != address(0)
        ) {
            DeployLiquidSystemReconcile.reconcileLiquidSwapGuardFactory(
                deployer,
                LiquidSwapGuard(result.guard),
                result.factory
            );
        }
        if (
            !deployConfig.factory.useLiquidGuard &&
            result.initGuard != address(0) &&
            result.factory != address(0)
        ) {
            DeployLiquidSystemReconcile.reconcileLiquidInitGuardFactory(
                deployer,
                LiquidInitGuard(result.initGuard),
                result.factory
            );
        }

        if (
            deployLiquidGuard &&
            !deployFactory &&
            deployConfig.factory.useLiquidGuard &&
            result.factory != address(0) &&
            result.liquidGuard != address(0)
        ) {
            console.log(
                "  Updating existing factory poolHooks to liquidGuard..."
            );
            LiquidFactory(result.factory).setPoolHooks(result.liquidGuard);
        }
        if (
            deployInitGuard &&
            !deployFactory &&
            !deployConfig.factory.useLiquidGuard &&
            result.factory != address(0) &&
            result.initGuard != address(0)
        ) {
            console.log(
                "  Updating existing factory poolHooks to initGuard..."
            );
            LiquidFactory(result.factory).setPoolHooks(result.initGuard);
        }

        if (
            deploySwapGuard &&
            !deployConfig.factory.useLiquidGuard &&
            result.guard != address(0)
        ) {
            console.log("=== Step 6: Configuring LiquidSwapGuard ===");
            require(
                networkConfig.uniswapUniversalRouter != address(0),
                "DEPLOY_SWAP_GUARD=true requires uniswapUniversalRouter in NetworkConfig"
            );
            require(
                result.router != address(0),
                "DEPLOY_SWAP_GUARD=true requires a LiquidRouter address"
            );
            LiquidSwapGuard guardContract = LiquidSwapGuard(result.guard);
            guardContract.addRouter(networkConfig.uniswapUniversalRouter);
            guardContract.addCaller(result.router);
            if (result.auctioneer != address(0)) {
                guardContract.addCaller(result.auctioneer);
            }
            console.log("  addRouter(universalRouter)");
            console.log("  addCaller(liquidRouter)");
            if (result.auctioneer != address(0)) {
                console.log("  addCaller(liquidAuctioneer)");
            }
            // If factory exists but wasn't deployed this run, set poolHooks on it
            if (!deployFactory && deployConfig.factory.useSwapGuard) {
                console.log("  Updating existing factory poolHooks...");
                LiquidFactory(result.factory).setPoolHooks(result.guard);
            }
        }
        // When only router is redeployed, whitelist it on existing guard
        if (
            deployRouter &&
            !deploySwapGuard &&
            !deployConfig.factory.useLiquidGuard &&
            result.guard != address(0)
        ) {
            console.log(
                "=== Step 6b: Adding new router to existing SwapGuard ==="
            );
            LiquidSwapGuard(result.guard).addCaller(result.router);
            console.log("  addCaller(liquidRouter)");
        }
        // When only auctioneer is redeployed, whitelist it on existing guard
        if (
            deployAuctioneer &&
            !deploySwapGuard &&
            !deployConfig.factory.useLiquidGuard &&
            result.guard != address(0)
        ) {
            console.log(
                "=== Step 6c: Adding new auctioneer to existing SwapGuard ==="
            );
            LiquidSwapGuard(result.guard).addCaller(result.auctioneer);
            console.log("  addCaller(liquidAuctioneer)");
        }

        // ============================================
        // Step 6e: Configure LiquidInitGuard / LiquidGuard initialization wiring
        // ============================================
        // Factory bindings are handled above via reconcile...Factory helpers.

        // Step 6f: Configure factory for Graduated (CCA) tokens when chain supports it
        if (
            result.factory != address(0) &&
            networkConfig.ccaFactory != address(0) &&
            networkConfig.lbpStrategyFactory != address(0)
        ) {
            LiquidFactory factoryContract = LiquidFactory(result.factory);
            if (factoryContract.lbpStrategyFactory() == address(0)) {
                console.log(
                    "=== Step 6f: Configuring factory for Graduated (CCA) tokens ==="
                );
                factoryContract.setCcaFactory(networkConfig.ccaFactory);
                factoryContract.setLbpStrategyFactory(
                    networkConfig.lbpStrategyFactory
                );
                factoryContract.setProtocolFeeRecipient(protocolFeeRecipient);
                console.log(
                    "  setCcaFactory, setLbpStrategyFactory, setProtocolFeeRecipient"
                );
            }
        }
        // Step 6g: Link factory to registry so creation auto-registers tokens.
        if (
            result.factory != address(0) &&
            address(sharedLiquidRegistry) != address(0)
        ) {
            LiquidFactory factoryContract = LiquidFactory(result.factory);
            factoryContract.setLiquidRegistry(address(sharedLiquidRegistry));
            console.log("=== Step 6g: Configuring auto-registration ===");
            console.log("  factory.setLiquidRegistry(sharedLiquidRegistry)");
        }
        // Step 6h: Note: Router<->FeeDistributor price-forwarding wiring is no longer needed.
        //         FeeDistributor reads RARE/ETH spot price directly from pool slot0.
        if (
            address(sharedFeeDistributor) != address(0) &&
            address(sharedLiquidRegistry) != address(0)
        ) {
            DeployLiquidSystemReconcile
                .reconcileFeeDistributorBeneficiaryRegistry(
                    deployer,
                    sharedFeeDistributor,
                    sharedLiquidRegistry
                );
        }

        if (
            address(sharedFeeDistributor) != address(0) ||
            address(sharedLiquidRegistry) != address(0) ||
            result.auctioneer != address(0) ||
            result.router != address(0)
        ) {
            console.log("=== Step 6i: Rewiring shared modules ===");

            DeployLiquidSystemReconcile.reconcileAuctioneerModules(
                deployer,
                LiquidAuctioneer(payable(result.auctioneer)),
                protocolFeeRecipient,
                sharedLiquidRegistry
            );
            DeployLiquidSystemReconcile.reconcileRouterRegistry(
                deployer,
                LiquidRouter(payable(result.router)),
                sharedLiquidRegistry
            );
            DeployLiquidSystemReconcile.reconcileFactoryMigrationExecutor(
                deployer,
                LiquidFactory(result.factory),
                result.migrationExecutor
            );
            DeployLiquidSystemReconcile.reconcileMigrationExecutorRegistry(
                deployer,
                LiquidMigrationExecutor(result.migrationExecutor),
                sharedLiquidRegistry
            );

            if (deployConfig.factory.useLiquidGuard || deployLiquidGuard) {
                DeployLiquidSystemReconcile.reconcileLiquidGuardFeeDistributor(
                    deployer,
                    LiquidGuard(result.liquidGuard),
                    sharedFeeDistributor
                );
            }
            console.log("");
        }

        if (
            (deployRouter ||
                deployAuctioneer ||
                deployFactory ||
                deployLiquidRegistry ||
                deployFeeDistributor) &&
            address(sharedLiquidRegistry) != address(0)
        ) {
            console.log("=== Step 6j: Shared module readiness ===");
            if (sharedLiquidRegistry.owner() == deployer) {
                DeployLiquidSystemReconcile.ensureRegistryWriter(
                    sharedLiquidRegistry,
                    result.auctioneer,
                    "auctioneer"
                );
                DeployLiquidSystemReconcile.ensureRegistryWriter(
                    sharedLiquidRegistry,
                    result.factory,
                    "factory"
                );
                if (result.factory != address(0)) {
                    console.log(
                        "  auctioneer / factory writes will use shared registry."
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
            console.log(deployFeeDistributor ? "  (deployed)" : "  (existing)");
        }
        if (address(sharedLiquidRegistry) != address(0)) {
            console.log("Shared LiquidRegistry:");
            console.logAddress(address(sharedLiquidRegistry));
            console.log(deployLiquidRegistry ? "  (deployed)" : "  (existing)");
        }
        if (result.liquidGuard != address(0)) {
            console.log("LiquidGuard:");
            console.logAddress(result.liquidGuard);
            console.log(deployLiquidGuard ? "  (deployed)" : "  (existing)");
        }
        if (result.guard != address(0)) {
            console.log("LiquidSwapGuard:");
            console.logAddress(result.guard);
            console.log(deploySwapGuard ? "  (deployed)" : "  (existing)");
        }
        if (result.migrationExecutor != address(0)) {
            console.log("LiquidMigrationExecutor:");
            console.logAddress(result.migrationExecutor);
            console.log(
                deployMigrationExecutor ? "  (deployed)" : "  (existing)"
            );
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
            deployLiquidGuard ||
            deployMigrationExecutor ||
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
            if (deployLiquidGuard && result.liquidGuard != address(0)) {
                console.log("liquidGuard:");
                console.logAddress(result.liquidGuard);
                console.log(",");
            }
            if (deployFeeDistributor) {
                console.log("feeDistributor:");
                console.logAddress(feeDistributorAddress);
                console.log(",");
            }
            if (deployLiquidRegistry) {
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
            if (
                deployMigrationExecutor &&
                result.migrationExecutor != address(0)
            ) {
                console.log("migrationExecutor:");
                console.logAddress(result.migrationExecutor);
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
            "   MultiCurve: forge script script/CreateToken.s.sol --rpc-url $RPC_URL --broadcast"
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

    function _tryConfigureRareEthPoolKey(
        FeeDistributor feeDistributor,
        NetworkConfig.Config memory networkConfig
    ) internal {
        // Fetch the RARE/ETH pool key live from the V4 PositionManager using the stored poolId.
        // The PositionManager exposes poolKeys(bytes25) where the argument is the truncated poolId.
        // rareEthPoolId is stored as bytes32; truncate to bytes25 for the lookup.
        bytes32 rareEthPoolId = networkConfig.rareEthPoolId;
        if (
            rareEthPoolId != bytes32(0) &&
            networkConfig.uniswapV4PositionManager != address(0)
        ) {
            bytes25 truncatedId = bytes25(rareEthPoolId);
            (bool ok, bytes memory data) = networkConfig
                .uniswapV4PositionManager
                .staticcall(
                    abi.encodeWithSignature("poolKeys(bytes25)", truncatedId)
                );
            if (ok && data.length >= 160) {
                (
                    Currency c0,
                    Currency c1,
                    uint24 fee,
                    int24 tickSpacing,
                    IHooks hooks
                ) = abi.decode(
                        data,
                        (Currency, Currency, uint24, int24, IHooks)
                    );
                PoolKey memory rareEthKey = PoolKey({
                    currency0: c0,
                    currency1: c1,
                    fee: fee,
                    tickSpacing: tickSpacing,
                    hooks: hooks
                });
                feeDistributor.setRareEthPoolKey(rareEthKey);
                console.log(
                    "FeeDistributor: RARE/ETH pool key set from PositionManager"
                );
            } else {
                console.log(
                    "FeeDistributor: RARE/ETH pool key lookup failed - set manually via setRareEthPoolKey()"
                );
            }
        } else {
            console.log(
                "FeeDistributor: no rareEthPoolId configured - set pool key manually via setRareEthPoolKey()"
            );
        }
    }
}
