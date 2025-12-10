// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LiquidFactory} from "../src/LiquidFactory.sol";
import {NetworkConfig} from "./NetworkConfig.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";

contract CreateToken is Script {
    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenCreator = vm.envAddress("TOKEN_CREATOR");
        string memory tokenURI = vm.envString("TOKEN_URI");
        string memory tokenName = vm.envString("TOKEN_NAME");
        string memory tokenSymbol = vm.envString("TOKEN_SYMBOL");
        uint256 initialEth;
        try vm.envUint("INITIAL_ETH") returns (uint256 eth) {
            initialEth = eth;
        } catch {
            initialEth = 0.001 ether; // Default to 0.001 ETH if not specified
        }

        // Get chain ID from environment or use block.chainid
        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _chainId) {
            chainId = _chainId;
        } catch {
            chainId = block.chainid;
        }

        // Get factory address from NetworkConfig or environment override
        address factoryAddress;
        try vm.envAddress("FACTORY_ADDRESS") returns (address _factory) {
            factoryAddress = _factory;
        } catch {
            NetworkConfig.Config memory config = NetworkConfig.getConfig(chainId);
            factoryAddress = config.liquidFactory;
        }

        require(
            factoryAddress != address(0),
            "Factory address not configured. Set FACTORY_ADDRESS env var or update NetworkConfig.liquidFactory"
        );

        console.log("Creating Liquid token...");
        console.log("Chain ID:", chainId);
        console.log("Factory address:", factoryAddress);
        console.log("Token creator:", tokenCreator);
        console.log("Token name:", tokenName);
        console.log("Token symbol:", tokenSymbol);
        console.log("Token URI:", tokenURI);
        console.log("Initial ETH:", initialEth);
        console.log("");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Get factory instance
        LiquidFactory factory = LiquidFactory(factoryAddress);

        // Create the token
        address newToken = factory.createLiquidToken{value: initialEth}(
            tokenCreator,
            tokenURI,
            tokenName,
            tokenSymbol
        );

        vm.stopBroadcast();

        console.log("=== TOKEN CREATION SUMMARY ===");
        console.log("New Liquid token deployed at:", newToken);
        console.log("");
        console.log("Token Details:");
        console.log("--------------");
        console.log("Creator:", tokenCreator);
        console.log("Name:", tokenName);
        console.log("Symbol:", tokenSymbol);
        console.log("URI:", tokenURI);
        console.log("");
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Verify the token contract on Etherscan");
        console.log("2. The token is now ready for trading on Uniswap V4");
        console.log(
            "3. Users can buy/sell the token using the buy() and sell() functions"
        );
    }
}
