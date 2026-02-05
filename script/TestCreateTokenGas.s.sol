// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LiquidFactory} from "../src/LiquidFactory.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestCreateTokenGas
 * @notice Minimal script to test gas consumption of createLiquidToken
 */
contract TestCreateTokenGas is Script {
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

        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _chainId) {
            chainId = _chainId;
        } catch {
            chainId = block.chainid;
        }

        NetworkConfig.Config memory config = NetworkConfig.getConfig(chainId);
        address factoryAddress;
        try vm.envAddress("FACTORY_ADDRESS") returns (address _factory) {
            factoryAddress = _factory;
        } catch {
            factoryAddress = config.liquidFactory;
        }

        address deployerAddress = vm.addr(deployerPrivateKey);
        LiquidFactory factory = LiquidFactory(factoryAddress);
        address baseToken = factory.baseToken();

        console.log("=== GAS TEST ===");
        console.log("Factory:", factoryAddress);
        console.log("Deployer:", deployerAddress);
        console.log("Base token:", baseToken);
        console.log("Initial RARE liquidity:", initialRareLiquidity);
        console.log("");

        // Check allowance
        uint256 currentAllowance = IERC20(baseToken).allowance(deployerAddress, factoryAddress);
        console.log("Current allowance:", currentAllowance);
        
        if (currentAllowance < initialRareLiquidity) {
            console.log("Approving...");
            vm.startBroadcast(deployerPrivateKey);
            IERC20(baseToken).approve(factoryAddress, type(uint256).max);
            vm.stopBroadcast();
            console.log("Approval complete");
        } else {
            console.log("Allowance sufficient, skipping approval");
        }

        // Test createLiquidToken with gas measurement
        console.log("");
        console.log("Creating token and measuring gas...");
        
        vm.startBroadcast(deployerPrivateKey);
        
        uint256 gasStart = gasleft();
        address newToken = factory.createLiquidToken(
            tokenCreator,
            tokenURI,
            tokenName,
            tokenSymbol,
            initialRareLiquidity
        );
        uint256 gasUsed = gasStart - gasleft();
        
        vm.stopBroadcast();

        console.log("Token created:", newToken);
        console.log("Gas used:", gasUsed);
        console.log("Gas used (hex):");
        console.logBytes32(bytes32(gasUsed));
    }
}
