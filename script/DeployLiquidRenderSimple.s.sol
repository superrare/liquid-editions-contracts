// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LiquidRenderSimple} from "liquid-editions/examples/LiquidRenderSimple.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";

/**
 * @title DeployLiquidRenderSimple
 * @notice Script to deploy a LiquidRenderSimple render contract
 * @dev
 *
 * This script deploys a simple render contract that implements IRender interface
 * and provides dynamic tokenURI() for Liquid Edition contracts. Unlike the V2
 * version, this is NOT an ERC721 contract - it's just a simple render contract
 * that exposes tokenURI() for the Liquid contract to call.
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for the deployer
 * - LIQUID_EDITION_ADDRESS: Address of the Liquid Edition contract to link to
 *
 * Environment Variables Optional:
 * - COLLECTION_NAME: Name for the collection (default: "Liquid Topology")
 * - COLLECTION_DESCRIPTION: Description for the collection (default: "Plotter art-inspired generative collection visualizing Liquid Edition market dynamics")
 *
 * Usage:
 *   forge script script/DeployLiquidRenderSimple.s.sol:DeployLiquidRenderSimple --rpc-url $RPC_URL --broadcast
 */
contract DeployLiquidRenderSimple is Script {
    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address liquidEditionAddress = vm.envAddress("LIQUID_EDITION_ADDRESS");

        // Validate Liquid Edition address
        require(
            liquidEditionAddress != address(0),
            "LIQUID_EDITION_ADDRESS must be set"
        );

        // Get optional environment variables with defaults
        string memory collectionName;
        try vm.envString("COLLECTION_NAME") returns (string memory name) {
            collectionName = name;
        } catch {
            collectionName = "Liquid Topology";
        }

        string memory collectionDescription;
        try vm.envString("COLLECTION_DESCRIPTION") returns (
            string memory desc
        ) {
            collectionDescription = desc;
        } catch {
            collectionDescription = "Plotter art-inspired generative collection visualizing Liquid Edition market dynamics";
        }

        address deployerAddress = vm.addr(deployerPrivateKey);

        console.log("=== DEPLOYING LIQUID RENDER SIMPLE ===");
        console.log("");
        console.log("Deployer address:");
        console.logAddress(deployerAddress);
        console.log("Liquid Edition address:");
        console.logAddress(liquidEditionAddress);
        console.log("Collection name:", collectionName);
        console.log("Collection description:", collectionDescription);
        console.log("");

        // Validate that the Liquid Edition contract exists and is valid
        console.log("Validating Liquid Edition contract...");
        ILiquid liquidEdition = ILiquid(liquidEditionAddress);
        address tokenCreator;
        try liquidEdition.tokenCreator() returns (address creator) {
            tokenCreator = creator;
            console.log("Liquid Edition creator:");
            console.logAddress(tokenCreator);
        } catch {
            revert(
                "Invalid Liquid Edition address - contract does not implement ILiquid interface"
            );
        }

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the LiquidRenderSimple contract
        console.log("Deploying LiquidRenderSimple contract...");
        LiquidRenderSimple render = new LiquidRenderSimple(
            liquidEditionAddress,
            collectionName,
            collectionDescription
        );

        console.log("LiquidRenderSimple deployed at:");
        console.logAddress(address(render));
        console.log("");

        // Register render contract with Liquid Edition (if deployer is token creator)
        if (deployerAddress == tokenCreator) {
            console.log("Registering render contract with Liquid Edition...");
            console.log("(Deployer is token creator)");
            try liquidEdition.setRenderContract(address(render)) {
                console.log("Render contract successfully registered!");
                console.log(
                    "Liquid Edition tokenURI() will now use the render contract"
                );
            } catch Error(string memory reason) {
                console.log("Failed to register render contract:");
                console.log(reason);
                console.log("You can register manually later using:");
                console.log(
                    "  cast send",
                    liquidEditionAddress,
                    "'setRenderContract(address)'",
                    address(render)
                );
            } catch {
                console.log(
                    "Failed to register render contract (unknown error)"
                );
                console.log("You can register manually later using:");
                console.log(
                    "  cast send",
                    liquidEditionAddress,
                    "'setRenderContract(address)'",
                    address(render)
                );
            }
            console.log("");
        } else {
            console.log("Skipping render contract registration");
            console.log("(Deployer is not token creator)");
            console.log("Token creator can register manually using:");
            console.log(
                "  cast send",
                liquidEditionAddress,
                "'setRenderContract(address)'",
                address(render)
            );
            console.log("Token creator address:");
            console.logAddress(tokenCreator);
            console.log("");
        }

        vm.stopBroadcast();

        // Display summary
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("");
        console.log("LiquidRenderSimple Contract:");
        console.logAddress(address(render));
        console.log("");
        console.log("Linked Liquid Edition:");
        console.logAddress(liquidEditionAddress);
        console.log("");
        console.log("Collection Details:");
        console.log("-------------------");
        console.log("Name:", collectionName);
        console.log("Description:", collectionDescription);
        console.log("");
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Verify the contract on Etherscan");
        if (deployerAddress == tokenCreator) {
            console.log(
                "2. Render contract registered - Liquid Edition tokenURI() will use render contract"
            );
        } else {
            console.log(
                "2. Register render contract with Liquid Edition (if desired) so tokenURI() uses render contract"
            );
        }
        console.log(
            "3. The artwork will dynamically update based on Liquid Edition market state"
        );
        console.log(
            "4. Market state changes (swaps, transfers, burns) will trigger metadata refresh"
        );
        console.log("");
        if (deployerAddress == tokenCreator) {
            console.log("Example: View ERC20 metadata (uses render contract)");
            console.log("  cast call", liquidEditionAddress, "'tokenURI()'");
        }
        console.log("");
    }
}
