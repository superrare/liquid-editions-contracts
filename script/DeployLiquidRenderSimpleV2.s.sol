// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LiquidRenderSimpleV2} from "liquid-editions/examples/LiquidRenderSimpleV3.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";

/**
 * @title DeployLiquidRenderSimpleV2
 * @notice Script to deploy a LiquidRenderSimpleV2 render contract
 * @dev
 *
 * This script deploys a simple render contract that implements IRender interface
 * and provides dynamic tokenURI() for Liquid Edition contracts. V2 is hyper-reactive:
 * tiny market-state changes should produce visibly different rendered output.
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for the deployer
 * - LIQUID_EDITION_ADDRESS: Address of the Liquid Edition contract to link to
 *
 * Environment Variables Optional:
 * - COLLECTION_NAME: Name for the collection (default: "Liquid Lens Simple V2")
 * - COLLECTION_DESCRIPTION: Description for the collection (default: "Hyper-reactive generative collection where tiny market-state changes trigger major visual shifts")
 *
 * Usage:
 *   forge script script/DeployLiquidRenderSimpleV2.s.sol:DeployLiquidRenderSimpleV2 --rpc-url $RPC_URL --broadcast
 */
contract DeployLiquidRenderSimpleV2 is Script {
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
            collectionName = "Liquid Lens Simple V2";
        }

        string memory collectionDescription;
        try vm.envString("COLLECTION_DESCRIPTION") returns (
            string memory desc
        ) {
            collectionDescription = desc;
        } catch {
            collectionDescription = "Hyper-reactive generative collection where tiny market-state changes trigger major visual shifts";
        }

        address deployerAddress = vm.addr(deployerPrivateKey);

        console.log("=== DEPLOYING LIQUID RENDER SIMPLE V2 ===");
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

        // Deploy the LiquidRenderSimpleV2 contract
        console.log("Deploying LiquidRenderSimpleV2 contract...");
        LiquidRenderSimpleV2 render = new LiquidRenderSimpleV2(
            liquidEditionAddress,
            collectionName,
            collectionDescription
        );

        console.log("LiquidRenderSimpleV2 deployed at:");
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
        console.log("LiquidRenderSimpleV2 Contract:");
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
            "3. Tiny market-state changes should produce visibly different rendered output"
        );
        console.log("");
        if (deployerAddress == tokenCreator) {
            console.log("Example: View ERC20 metadata (uses render contract)");
            console.log("  cast call", liquidEditionAddress, "'tokenURI()'");
        }
        console.log("");
    }
}
