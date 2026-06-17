// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CreateToken
 * @notice Script to create a new Liquid token via the factory (permissionless)
 * @dev
 *
 * IMPORTANT REQUIREMENTS:
 * - If INITIAL_RARE_LIQUIDITY is non-zero, the deployer must have and approve that much RARE.
 *
 * NOTE: Token creation is permissionless - anyone can create tokens.
 * The deployer calls createLiquidTokenMultiCurve, so optional RARE is pulled from the deployer.
 * If tokenCreator is different from deployer, ensure the deployer has any RARE needed.
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for the deployer
 * - TOKEN_CREATOR: Address that will receive creator fees and launch reward
 * - TOKEN_URI: Metadata URI for the token
 * - TOKEN_NAME: Name of the token
 * - TOKEN_SYMBOL: Symbol of the token
 *
 * Environment Variables Optional:
 * - INITIAL_RARE_LIQUIDITY: Optional RARE for head liquidity beyond the curve range (default: 0.001 ether)
 * - MAX_TOTAL_SUPPLY: Optional custom token supply for this launch (default: factory maxTotalSupply)
 * - FACTORY_ADDRESS: Factory address (defaults to NetworkConfig)
 * - ROUTER_ADDRESS: Router address for token registration (defaults to NetworkConfig)
 * - CHAIN_ID: Chain ID (defaults to block.chainid)
 *
 * Usage:
 *   forge script script/CreateToken.s.sol:CreateToken --rpc-url $RPC_URL --broadcast --slow
 *
 * Note: The --slow flag is recommended to ensure transactions are sent sequentially
 * and avoid nonce conflicts. This script sends two transactions:
 *   1. Token creation (createLiquidTokenMultiCurve)
 *   2. Router registration (registerToken)
 *
 * If you encounter "exceeds block gas limit" errors, try:
 *   - Using --gas-limit flag to set explicit limit (e.g., --gas-limit 30000000)
 *   - Or use --legacy flag if your RPC doesn't support EIP-1559
 *
 * If you encounter "future transaction tries to replace pending" errors:
 *   - Use --slow flag to wait for each transaction to be mined before sending the next
 *   - Or run registration separately after token creation completes
 */
contract CreateToken is Script {
    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenCreator = vm.envAddress("TOKEN_CREATOR");

        // NOTE: The deployer (from DEPLOYER_PRIVATE_KEY) must have:
        // 1. Optional RARE for head liquidity (must approve factory when non-zero)
        string memory tokenURI = vm.envString("TOKEN_URI");
        string memory tokenName = vm.envString("TOKEN_NAME");
        string memory tokenSymbol = vm.envString("TOKEN_SYMBOL");
        uint256 initialRareLiquidity;
        try vm.envUint("INITIAL_RARE_LIQUIDITY") returns (uint256 rare) {
            initialRareLiquidity = rare;
        } catch {
            initialRareLiquidity = 0.001 ether; // Default to 0.001 RARE if not specified
        }

        uint256 customMaxTotalSupply;
        bool hasCustomMaxTotalSupply;
        try vm.envUint("MAX_TOTAL_SUPPLY") returns (uint256 supply) {
            customMaxTotalSupply = supply;
            hasCustomMaxTotalSupply = true;
        } catch {}

        // Get chain ID from environment or use block.chainid
        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _chainId) {
            chainId = _chainId;
        } catch {
            chainId = block.chainid;
        }

        // Get network configuration
        NetworkConfig.Config memory config = NetworkConfig.getConfig(chainId);

        // Get factory address from NetworkConfig or environment override
        address factoryAddress;
        try vm.envAddress("FACTORY_ADDRESS") returns (address _factory) {
            factoryAddress = _factory;
        } catch {
            factoryAddress = config.liquid.factory;
        }

        require(
            factoryAddress != address(0),
            "Factory address not configured. Set FACTORY_ADDRESS env var or update NetworkConfig.liquidFactory"
        );

        // Get router address from NetworkConfig or environment override (optional)
        address routerAddress;
        try vm.envAddress("ROUTER_ADDRESS") returns (address _router) {
            routerAddress = _router;
        } catch {
            routerAddress = config.liquid.router;
        }

        console.log("Creating Liquid token...");
        console.log("Chain ID:");
        console.logUint(chainId);
        console.log("Factory address:");
        console.logAddress(factoryAddress);
        console.log("Router address:");
        console.logAddress(routerAddress);
        console.log("Token creator:");
        console.logAddress(tokenCreator);
        console.log("Token name:", tokenName);
        console.log("Token symbol:", tokenSymbol);
        console.log("Token URI:", tokenURI);
        console.log("Optional RARE liquidity:");
        console.logUint(initialRareLiquidity);
        if (hasCustomMaxTotalSupply) {
            console.log("Custom max total supply:");
            console.logUint(customMaxTotalSupply);
        }
        console.log("");

        // Get deployer address (from DEPLOYER_PRIVATE_KEY)
        // Token creation is permissionless - this address just needs RARE tokens
        address deployerAddress = vm.addr(deployerPrivateKey);

        console.log("Deployer address:");
        console.logAddress(deployerAddress);
        console.log("");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Get factory instance
        LiquidFactory factory = LiquidFactory(factoryAddress);

        // Get base token (RARE) address
        address baseToken = factory.baseToken();
        require(baseToken != address(0), "Base token not set in factory");

        // Optional RARE is pulled from msg.sender, so the deployer needs balance and approval
        // only when initialRareLiquidity is non-zero.
        uint256 currentAllowance = IERC20(baseToken).allowance(deployerAddress, factoryAddress);
        if (currentAllowance < initialRareLiquidity) {
            console.log("Approving factory to transfer RARE tokens from deployer...");
            console.log("NOTE: Deployer must have RARE tokens balance >= initialRareLiquidity");
            // Approve with type(uint256).max to avoid approval issues (factory only transfers initialRareLiquidity)
            IERC20(baseToken).approve(factoryAddress, type(uint256).max);
        } else {
            console.log("Approval already sufficient, skipping approval step");
        }

        // Create the token (permissionless; optional RARE is supplied by the deployer)
        console.log("Creating Liquid token...");

        // Check deployer has sufficient RARE balance
        uint256 deployerRareBalance = IERC20(baseToken).balanceOf(deployerAddress);
        console.log("Deployer RARE balance:");
        console.logUint(deployerRareBalance);
        console.log("Optional RARE liquidity:");
        console.logUint(initialRareLiquidity);

        if (deployerRareBalance < initialRareLiquidity) {
            revert("Insufficient RARE balance. Deployer needs at least initialRareLiquidity RARE tokens.");
        }

        // Verify factory configuration
        address factoryImpl = factory.liquidMultiCurveImplementation();
        address factoryBaseToken = factory.baseToken();
        address factoryPoolManager = factory.poolManager();

        console.log("Factory MultiCurve implementation:");
        console.logAddress(factoryImpl);
        console.log("Factory base token:");
        console.logAddress(factoryBaseToken);
        console.log("Factory pool manager:");
        console.logAddress(factoryPoolManager);

        if (factoryImpl == address(0)) {
            revert("Factory MultiCurve implementation not set");
        }
        if (factoryBaseToken == address(0)) {
            revert("Factory base token not set");
        }
        if (factoryPoolManager == address(0)) {
            revert("Factory pool manager not set");
        }

        // Build default single-curve config (equivalent to former LiquidMultiCurve)
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({tickLower: -180, tickUpper: 120000, numPositions: 1, shares: 1e18});

        address newToken = hasCustomMaxTotalSupply
            ? factory.createLiquidTokenMultiCurveWithSupply(
                tokenCreator, tokenURI, tokenName, tokenSymbol, initialRareLiquidity, curves, customMaxTotalSupply
            )
            : factory.createLiquidTokenMultiCurve(
                tokenCreator, tokenURI, tokenName, tokenSymbol, initialRareLiquidity, curves
            );

        console.log("Token created at:", newToken);
        console.log("");

        // Stop broadcasting after token creation
        vm.stopBroadcast();

        // Token registration is handled automatically by LiquidFactory via LiquidRegistry.
        // No separate router registration step needed.
        console.log("Token registered via factory -> LiquidRegistry (automatic).");
        console.log("");

        console.log("=== TOKEN CREATION SUMMARY ===");
        console.log("New Liquid token deployed at:");
        console.logAddress(newToken);
        console.log("");
        console.log("Token Details:");
        console.log("--------------");
        console.log("Creator:");
        console.logAddress(tokenCreator);
        console.log("Name:", tokenName);
        console.log("Symbol:", tokenSymbol);
        console.log("URI:", tokenURI);
        console.log("");
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Verify the token contract on Etherscan");
        console.log("2. The token is now ready for trading on Uniswap V4");
        if (routerAddress != address(0)) {
            console.log("3. Register token with router to enable creator fees:");
            console.log("   Use script/RegisterToken.s.sol or cast send command shown above");
        }
        console.log("4. Users can trade the token using LiquidRouter for multi-hop swaps");
    }
}
