// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LiquidLensDemoV1} from "liquid-editions/examples/LiquidLensDemoV1.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";

/**
 * @title DeployLiquidLensDemo
 * @notice Script to deploy a LiquidLensDemoV1 ERC721 render contract and mint all tokens
 * @dev
 *
 * This script deploys a sample ERC721 render contract that reads market state from
 * a Liquid Edition and generates dynamic SVG artwork. It mints all 10 NFTs in the collection.
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for the deployer
 * - LIQUID_EDITION_ADDRESS: Address of the Liquid Edition contract to link to
 *
 * Environment Variables Optional:
 * - COLLECTION_NAME: Name for the NFT collection (default: "Liquid Lens Collection")
 * - COLLECTION_DESCRIPTION: Description for the NFT collection (default: "A generative art collection that visualizes Liquid Edition market state")
 * - NFT_NAME: ERC721 token name (default: "Liquid Lens Demo")
 * - NFT_SYMBOL: ERC721 token symbol (default: "LLD")
 * - MINT_TO: Address to mint NFTs to (default: deployer address)
 *
 * Usage:
 *   forge script script/DeployLiquidLensDemo.s.sol:DeployLiquidLensDemo --rpc-url $RPC_URL --broadcast
 *
 * Note: If you encounter gas limit errors, use --gas-limit flag:
 *   forge script script/DeployLiquidLensDemo.s.sol:DeployLiquidLensDemo --rpc-url $RPC_URL --broadcast --gas-limit 30000000
 */
contract DeployLiquidLensDemo is Script {
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
            collectionName = "Liquid Lens Collection";
        }

        string memory collectionDescription;
        try vm.envString("COLLECTION_DESCRIPTION") returns (
            string memory desc
        ) {
            collectionDescription = desc;
        } catch {
            collectionDescription = "A generative art collection that visualizes Liquid Edition market state";
        }

        string memory nftName;
        try vm.envString("NFT_NAME") returns (string memory name) {
            nftName = name;
        } catch {
            nftName = "Liquid Lens Demo";
        }

        string memory nftSymbol;
        try vm.envString("NFT_SYMBOL") returns (string memory symbol) {
            nftSymbol = symbol;
        } catch {
            nftSymbol = "LLD";
        }

        // Get mint recipient address (defaults to deployer)
        address deployerAddress = vm.addr(deployerPrivateKey);
        address mintTo;
        try vm.envAddress("MINT_TO") returns (address recipient) {
            mintTo = recipient;
        } catch {
            mintTo = deployerAddress;
        }

        console.log("=== DEPLOYING LIQUID LENS DEMO ===");
        console.log("");
        console.log("Deployer address:");
        console.logAddress(deployerAddress);
        console.log("Liquid Edition address:");
        console.logAddress(liquidEditionAddress);
        console.log("Collection name:", collectionName);
        console.log("Collection description:", collectionDescription);
        console.log("NFT name:", nftName);
        console.log("NFT symbol:", nftSymbol);
        console.log("Mint to address:");
        console.logAddress(mintTo);
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

        // Deploy the LiquidLensDemoV1 contract
        console.log("Deploying LiquidLensDemoV1 contract...");
        LiquidLensDemoV1 lens = new LiquidLensDemoV1(
            liquidEditionAddress,
            nftName,
            nftSymbol,
            collectionName,
            collectionDescription
        );

        console.log("LiquidLensDemoV1 deployed at:");
        console.logAddress(address(lens));
        console.log("");

        // Mint all tokens (MAX_SUPPLY = 10)
        uint256 maxSupply = lens.MAX_SUPPLY();
        console.log("Minting", maxSupply, "tokens...");
        console.log("");

        for (uint256 i = 0; i < maxSupply; i++) {
            lens.mint(mintTo);
            console.log("Minted token #", i + 1, "to:");
            console.logAddress(mintTo);
        }

        console.log("");
        console.log("All tokens minted successfully!");
        console.log("");

        // Register render contract with Liquid Edition (if deployer is token creator)
        if (deployerAddress == tokenCreator) {
            console.log("Registering render contract with Liquid Edition...");
            console.log("(Deployer is token creator)");
            try liquidEdition.setRenderContract(address(lens)) {
                console.log("Render contract successfully registered!");
                console.log(
                    "Liquid Edition tokenURI() will now use the ERC721 render contract"
                );
            } catch Error(string memory reason) {
                console.log("Failed to register render contract:");
                console.log(reason);
                console.log("You can register manually later using:");
                console.log(
                    "  cast send",
                    liquidEditionAddress,
                    "'setRenderContract(address)'",
                    address(lens)
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
                    address(lens)
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
                address(lens)
            );
            console.log("Token creator address:");
            console.logAddress(tokenCreator);
            console.log("");
        }

        vm.stopBroadcast();

        // Display summary
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("");
        console.log("LiquidLensDemoV1 Contract:");
        console.logAddress(address(lens));
        console.log("");
        console.log("Linked Liquid Edition:");
        console.logAddress(liquidEditionAddress);
        console.log("");
        console.log("Collection Details:");
        console.log("-------------------");
        console.log("Name:", collectionName);
        console.log("Description:", collectionDescription);
        console.log("NFT Name:", nftName);
        console.log("NFT Symbol:", nftSymbol);
        console.log("Max Supply:", maxSupply);
        console.log("Tokens Minted:", maxSupply);
        console.log("Mint Recipient:");
        console.logAddress(mintTo);
        console.log("");
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Verify the contract on Etherscan");
        console.log("2. View token metadata:");
        console.log("   - ERC721 Token #0 (ERC20 passthrough): tokenURI(0)");
        console.log(
            "   - ERC721 Token #1-#10: tokenURI(1) through tokenURI(10)"
        );
        if (deployerAddress == tokenCreator) {
            console.log(
                "3. Render contract registered - Liquid Edition tokenURI() will use ERC721 render contract"
            );
        } else {
            console.log(
                "3. Register render contract with Liquid Edition (if desired) so ERC20 tokenURI() uses ERC721"
            );
        }
        console.log(
            "4. The artwork will dynamically update based on Liquid Edition market state"
        );
        console.log(
            "5. Market state changes (swaps, transfers, burns) will trigger metadata refresh"
        );
        console.log("");
        console.log("Example: View ERC721 token #1 metadata");
        console.log("  cast call", address(lens), "'tokenURI(uint256)' 1");
        if (deployerAddress == tokenCreator) {
            console.log("");
            console.log(
                "Example: View ERC20 metadata (uses ERC721 render contract)"
            );
            console.log("  cast call", liquidEditionAddress, "'tokenURI()'");
        }
        console.log("");
    }
}
