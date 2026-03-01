// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";

/**
 * @title RegisterToken
 * @notice Script to register a Liquid token with LiquidRegistry
 * @dev
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for the deployer (must be registry owner or writer)
 * - TOKEN_ADDRESS: Address of the Liquid token to register
 * - BENEFICIARY_ADDRESS: Address that will receive beneficiary fees (typically the token creator)
 *
 * Environment Variables Optional:
 * - LIQUID_REGISTRY: Registry address (defaults to NetworkConfig)
 * - CHAIN_ID: Chain ID (defaults to block.chainid)
 *
 * Usage:
 *   forge script script/RegisterToken.s.sol:RegisterToken --rpc-url $RPC_URL --broadcast --slow
 */
contract RegisterToken is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");

        // Get beneficiary from env, or default to token creator
        address beneficiaryAddress;
        try vm.envAddress("BENEFICIARY_ADDRESS") returns (address beneficiary) {
            beneficiaryAddress = beneficiary;
        } catch {
            // If not specified, we'll use the token creator (set below)
            beneficiaryAddress = address(0);
        }

        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _chainId) {
            chainId = _chainId;
        } catch {
            chainId = block.chainid;
        }

        NetworkConfig.Config memory config = NetworkConfig.getConfig(chainId);
        address registryAddress;
        try vm.envAddress("LIQUID_REGISTRY") returns (address _registry) {
            registryAddress = _registry;
        } catch {
            registryAddress = config.liquid.liquidRegistry;
        }

        require(registryAddress != address(0), "Registry address not configured");

        address deployerAddress = vm.addr(deployerPrivateKey);

        console.log("=== REGISTERING TOKEN WITH LIQUID REGISTRY ===");
        console.log("");
        console.log("Deployer address:");
        console.logAddress(deployerAddress);
        console.log("Token address:");
        console.logAddress(tokenAddress);
        console.log("Beneficiary address:");
        console.logAddress(beneficiaryAddress);
        console.log("Registry address:");
        console.logAddress(registryAddress);
        console.log("");

        // Validate token and get token creator
        ILiquid token = ILiquid(tokenAddress);
        address tokenCreator;
        try token.tokenCreator() returns (address creator) {
            tokenCreator = creator;
            console.log("Token creator:");
            console.logAddress(tokenCreator);
        } catch {
            revert("Invalid token address - contract does not implement ILiquid interface");
        }

        // If beneficiary not specified, default to token creator
        if (beneficiaryAddress == address(0)) {
            beneficiaryAddress = tokenCreator;
            console.log("Beneficiary not specified, defaulting to token creator");
        }

        console.log("");

        // Register token with registry
        vm.startBroadcast(deployerPrivateKey);

        try ILiquidRegistry(registryAddress).setBeneficiary(tokenAddress, beneficiaryAddress) {
            console.log("Token successfully registered with registry!");
        } catch Error(string memory reason) {
            console.log("Failed to register token:");
            console.log(reason);
        } catch {
            console.log("Failed to register token (unknown error)");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== REGISTRATION COMPLETE ===");
    }
}
