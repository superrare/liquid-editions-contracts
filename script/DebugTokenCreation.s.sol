// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LiquidFactory} from "../src/LiquidFactory.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DebugTokenCreation
 * @notice Script to debug token creation failures by testing each step individually
 */
contract DebugTokenCreation is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenCreator = vm.envAddress("TOKEN_CREATOR");
        string memory tokenURI = vm.envString("TOKEN_URI");
        string memory tokenName = vm.envString("TOKEN_NAME");
        string memory tokenSymbol = vm.envString("TOKEN_SYMBOL");
        
        uint256 initialRareLiquidity;
        try vm.envUint("INITIAL_RARE_LIQUIDITY") returns (uint256 rare) {
            initialRareLiquidity = rare;
        } catch {
            initialRareLiquidity = 0.001 ether;
        }

        uint256 chainId = block.chainid;
        NetworkConfig.Config memory config = NetworkConfig.getConfig(chainId);
        address factoryAddress = config.liquidFactory;

        require(factoryAddress != address(0), "Factory address not configured");

        address deployerAddress = vm.addr(deployerPrivateKey);
        LiquidFactory factory = LiquidFactory(factoryAddress);
        address baseToken = factory.baseToken();

        console.log("=== DEBUGGING TOKEN CREATION ===");
        console.log("Factory:", factoryAddress);
        console.log("Base Token (RARE):", baseToken);
        console.log("Deployer:", deployerAddress);
        console.log("Token Creator:", tokenCreator);
        console.log("Initial RARE Liquidity:", initialRareLiquidity);
        console.log("");

        // Check 1: Factory configuration
        console.log("1. Checking factory configuration...");
        address factoryImpl = factory.liquidImplementation();
        address factoryBaseToken = factory.baseToken();
        address factoryPoolManager = factory.poolManager();
        uint256 minRareLiquidityWei = factory.minRareLiquidityWei();
        
        console.log("   Implementation:", factoryImpl);
        console.log("   Base Token:", factoryBaseToken);
        console.log("   Pool Manager:", factoryPoolManager);
        console.log("   Min RARE Liquidity Wei:", minRareLiquidityWei);
        
        if (factoryImpl == address(0)) {
            console.log("   ERROR: Implementation not set!");
            return;
        }
        if (factoryBaseToken == address(0)) {
            console.log("   ERROR: Base token not set!");
            return;
        }
        if (factoryPoolManager == address(0)) {
            console.log("   ERROR: Pool manager not set!");
            return;
        }
        if (initialRareLiquidity < minRareLiquidityWei) {
            console.log("   ERROR: Initial liquidity", initialRareLiquidity, "is less than minimum", minRareLiquidityWei);
            return;
        }
        console.log("   [OK] Factory configuration OK");
        console.log("");

        // Check 2: Deployer RARE balance
        console.log("2. Checking deployer RARE balance...");
        uint256 deployerBalance = IERC20(baseToken).balanceOf(deployerAddress);
        console.log("   Deployer Balance:", deployerBalance);
        console.log("   Required:", initialRareLiquidity);
        
        if (deployerBalance < initialRareLiquidity) {
            console.log("   ERROR: Insufficient RARE balance!");
            return;
        }
        console.log("   [OK] RARE balance sufficient");
        console.log("");

        // Check 3: Approval
        console.log("3. Checking approval...");
        uint256 allowance = IERC20(baseToken).allowance(deployerAddress, factoryAddress);
        console.log("   Current Allowance:", allowance);
        
        if (allowance < initialRareLiquidity) {
            console.log("   WARNING: Approval insufficient, will approve...");
        } else {
            console.log("   [OK] Approval sufficient");
        }
        console.log("");

        // Check 4: Token URI validation
        console.log("4. Checking token URI...");
        bytes memory uriBytes = bytes(tokenURI);
        console.log("   URI Length:", uriBytes.length);
        if (uriBytes.length == 0) {
            console.log("   ERROR: Token URI is empty!");
            return;
        }
        console.log("   [OK] Token URI valid");
        console.log("");

        // Check 5: Factory tick configuration
        console.log("5. Checking factory tick configuration...");
        int24 tickLower = factory.lpTickLower();
        int24 tickUpper = factory.lpTickUpper();
        int24 tickSpacing = factory.poolTickSpacing();
        address hooks = factory.poolHooks();
        
        console.log("   Tick Lower:", tickLower);
        console.log("   Tick Upper:", tickUpper);
        console.log("   Tick Spacing:", tickSpacing);
        console.log("   Hooks:", hooks);
        
        if (tickLower >= tickUpper) {
            console.log("   ERROR: Invalid tick range (lower >= upper)!");
            return;
        }
        if (tickSpacing <= 0) {
            console.log("   ERROR: Invalid tick spacing!");
            return;
        }
        console.log("   [OK] Tick configuration OK");
        console.log("");

        // Check 6: Try to simulate the call (dry run)
        console.log("6. Simulating token creation (dry run)...");
        vm.startBroadcast(deployerPrivateKey);
        
        // Approve if needed
        if (allowance < initialRareLiquidity) {
            IERC20(baseToken).approve(factoryAddress, type(uint256).max);
        }
        
        // Try to call createLiquidToken (this will revert but we can catch it)
        try factory.createLiquidToken(
            tokenCreator,
            tokenURI,
            tokenName,
            tokenSymbol,
            initialRareLiquidity
        ) returns (address newToken) {
            console.log("   [OK] Token created successfully at:", newToken);
            
            // Check if pool was initialized by trying to get price
            ILiquid liquid = ILiquid(newToken);
            try liquid.getCurrentPrice() returns (uint256 rarePerToken, uint256 tokenPerRare) {
                console.log("   [OK] Pool initialized successfully");
                console.log("   Price - RARE per token:", rarePerToken);
                console.log("   Price - Token per RARE:", tokenPerRare);
            } catch Error(string memory reason) {
                console.log("   WARNING: Pool may not be initialized:", reason);
            } catch {
                console.log("   WARNING: Failed to read pool state");
            }
        } catch Error(string memory reason) {
            console.log("   ERROR:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("   ERROR: Low-level revert");
            console.log("   Data length:", lowLevelData.length);
            if (lowLevelData.length >= 4) {
                bytes4 selector = bytes4(lowLevelData);
                console.log("   Error selector:", vm.toString(selector));
            }
        }
        
        vm.stopBroadcast();
        console.log("");
        console.log("=== DEBUG COMPLETE ===");
    }
}
