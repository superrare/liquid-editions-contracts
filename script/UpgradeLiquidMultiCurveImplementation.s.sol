// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {DeployLiquidMultiCurve} from "./deployers/DeployLiquidMultiCurve.s.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";

/**
 * @title UpgradeLiquidMultiCurveImplementation
 * @notice Deploys a new LiquidMultiCurve implementation and wires it into an existing factory
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for the factory owner
 *
 * Environment Variables Optional:
 * - FACTORY_ADDRESS: Existing LiquidFactory address to update
 * - LIQUID_FACTORY: Alias for FACTORY_ADDRESS
 *
 * The target chain is derived from the `--rpc-url` network via block.chainid.
 * If FACTORY_ADDRESS / LIQUID_FACTORY is not provided, the script falls back to NetworkConfig.
 *
 * Usage:
 *   forge script script/UpgradeLiquidMultiCurveImplementation.s.sol:UpgradeLiquidMultiCurveImplementation --rpc-url $RPC_URL --broadcast
 */
contract UpgradeLiquidMultiCurveImplementation is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        uint256 chainId = block.chainid;

        NetworkConfig.Config memory networkConfig = NetworkConfig.getConfig(chainId);

        address factoryAddress = networkConfig.liquid.factory;
        try vm.envAddress("FACTORY_ADDRESS") returns (address configuredFactory) {
            factoryAddress = configuredFactory;
        } catch {}
        try vm.envAddress("LIQUID_FACTORY") returns (address configuredFactory) {
            factoryAddress = configuredFactory;
        } catch {
            // Keep NetworkConfig-derived address when alias override is unset.
        }

        require(
            factoryAddress != address(0),
            "Factory address not configured. Set FACTORY_ADDRESS / LIQUID_FACTORY or update NetworkConfig."
        );

        LiquidFactory factory = LiquidFactory(factoryAddress);

        address factoryOwner;
        try factory.owner() returns (address owner_) {
            factoryOwner = owner_;
        } catch {
            revert("Invalid LiquidFactory address");
        }

        require(deployerAddress == factoryOwner, "Deployer is not the factory owner");

        address previousImplementation = factory.liquidMultiCurveImplementation();

        console.log("=== UPGRADING LIQUID MULTICURVE IMPLEMENTATION ===");
        console.log("");
        console.log("Chain ID:");
        console.logUint(chainId);
        console.log("Deployer:");
        console.logAddress(deployerAddress);
        console.log("Factory:");
        console.logAddress(factoryAddress);
        console.log("Factory owner:");
        console.logAddress(factoryOwner);
        console.log("Current LiquidMultiCurve implementation:");
        console.logAddress(previousImplementation);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        address newImplementation = DeployLiquidMultiCurve.deploy();

        console.log("Updating factory implementation pointer...");
        factory.setLiquidMultiCurveImplementation(newImplementation);

        address updatedImplementation = factory.liquidMultiCurveImplementation();
        require(updatedImplementation == newImplementation, "Factory implementation update failed");

        vm.stopBroadcast();

        console.log("");
        console.log("=== UPGRADE SUMMARY ===");
        console.log("Factory:");
        console.logAddress(factoryAddress);
        console.log("Previous implementation:");
        console.logAddress(previousImplementation);
        console.log("New implementation:");
        console.logAddress(newImplementation);
        console.log("");
        console.log("Future multicurve token launches will clone the new implementation.");
    }
}
