// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {LiquidLensDemoV2} from "liquid-editions/examples/LiquidLensDemoV2.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CreateTokenWithLens
 * @notice Comprehensive script to create a Liquid token, deploy LiquidLensDemoV2, and register it as the render contract
 * @dev
 *
 * This script performs three operations in sequence:
 * 1. Creates a new Liquid token via the factory
 * 2. Deploys a LiquidLensDemoV2 ERC721 render contract
 * 3. Registers the lens as the render contract on the Liquid token
 *
 * IMPORTANT REQUIREMENTS:
 * - The deployer must have RARE tokens >= INITIAL_RARE_LIQUIDITY
 * - The deployer must approve the factory to spend RARE tokens
 * - The deployer must be the token creator (or have permission to set render contract)
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for the deployer (must have RARE tokens and be token creator)
 * - TOKEN_CREATOR: Address that will receive creator fees and launch reward (must match deployer for render registration)
 * - TOKEN_URI: Metadata URI for the token
 * - TOKEN_NAME: Name of the token
 * - TOKEN_SYMBOL: Symbol of the token
 *
 * Environment Variables Optional:
 * - INITIAL_RARE_LIQUIDITY: Amount of RARE tokens for initial liquidity (default: 0.001 ether)
 * - FACTORY_ADDRESS: Factory address (defaults to NetworkConfig)
 * - ROUTER_ADDRESS: Router address for token registration (defaults to NetworkConfig)
 * - CHAIN_ID: Chain ID (defaults to block.chainid)
 * - COLLECTION_NAME: Name for the NFT collection (default: "Liquid Topology Collection")
 * - COLLECTION_DESCRIPTION: Description for the NFT collection (default: provided description)
 * - NFT_NAME: ERC721 token name (default: "Liquid Topology")
 * - NFT_SYMBOL: ERC721 token symbol (default: "LTOP")
 * - MINT_TO: Address to mint NFTs to (default: deployer address)
 *
 * Usage:
 *   forge script script/CreateTokenWithLens.s.sol:CreateTokenWithLens --rpc-url $RPC_URL --broadcast --slow
 *
 * Note: The --slow flag is recommended to ensure transactions are sent sequentially
 * and avoid nonce conflicts.
 */
contract CreateTokenWithLens is Script {
    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenCreator = vm.envAddress("TOKEN_CREATOR");
        string memory tokenURI = vm.envString("TOKEN_URI");
        string memory tokenName = vm.envString("TOKEN_NAME");
        string memory tokenSymbol = vm.envString("TOKEN_SYMBOL");

        uint256 initialRareLiquidity;
        try vm.envUint("INITIAL_RARE_LIQUIDITY") returns (uint256 rare) {
            initialRareLiquidity = rare;
        } catch {
            initialRareLiquidity = 0.001 ether; // Default to 0.001 RARE if not specified
        }

        // Get optional NFT collection parameters
        string memory collectionName;
        try vm.envString("COLLECTION_NAME") returns (string memory name) {
            collectionName = name;
        } catch {
            collectionName = "Liquid Topology Collection";
        }

        string memory collectionDescription;
        try vm.envString("COLLECTION_DESCRIPTION") returns (
            string memory desc
        ) {
            collectionDescription = desc;
        } catch {
            collectionDescription = "Plotter art-inspired generative collection visualizing Liquid Edition market dynamics";
        }

        string memory nftName;
        try vm.envString("NFT_NAME") returns (string memory name) {
            nftName = name;
        } catch {
            nftName = "Liquid Topology";
        }

        string memory nftSymbol;
        try vm.envString("NFT_SYMBOL") returns (string memory symbol) {
            nftSymbol = symbol;
        } catch {
            nftSymbol = "LTOP";
        }

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

        // Get mint recipient address (defaults to deployer)
        address deployerAddress = vm.addr(deployerPrivateKey);
        address mintTo;
        try vm.envAddress("MINT_TO") returns (address recipient) {
            mintTo = recipient;
        } catch {
            mintTo = deployerAddress;
        }

        console.log("=== CREATING LIQUID TOKEN WITH LENS ===");
        console.log("");
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
        console.log("Initial RARE liquidity:");
        console.logUint(initialRareLiquidity);
        console.log("Deployer address:");
        console.logAddress(deployerAddress);
        console.log("");

        // ============================================
        // STEP 1: CREATE LIQUID TOKEN
        // ============================================
        console.log("=== STEP 1: CREATING LIQUID TOKEN ===");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Get factory instance
        LiquidFactory factory = LiquidFactory(factoryAddress);

        // Get base token (RARE) address
        address baseToken = factory.baseToken();
        require(baseToken != address(0), "Base token not set in factory");

        // Check and approve RARE tokens if needed
        uint256 currentAllowance = IERC20(baseToken).allowance(
            deployerAddress,
            factoryAddress
        );
        if (currentAllowance < initialRareLiquidity) {
            console.log(
                "Approving factory to transfer RARE tokens from deployer..."
            );
            console.log(
                "NOTE: Deployer must have RARE tokens balance >= initialRareLiquidity"
            );
            IERC20(baseToken).approve(factoryAddress, type(uint256).max);
        } else {
            console.log("Approval already sufficient, skipping approval step");
        }

        // Check deployer has sufficient RARE balance
        uint256 deployerRareBalance = IERC20(baseToken).balanceOf(
            deployerAddress
        );
        console.log("Deployer RARE balance:");
        console.logUint(deployerRareBalance);
        console.log("Required RARE liquidity:");
        console.logUint(initialRareLiquidity);

        if (deployerRareBalance < initialRareLiquidity) {
            revert(
                "Insufficient RARE balance. Deployer needs at least initialRareLiquidity RARE tokens."
            );
        }

        // Verify factory configuration
        address factoryImpl = factory.liquidImplementation();
        address factoryBaseToken = factory.baseToken();
        address factoryPoolManager = factory.poolManager();

        console.log("Factory implementation:");
        console.logAddress(factoryImpl);
        console.log("Factory base token:");
        console.logAddress(factoryBaseToken);
        console.log("Factory pool manager:");
        console.logAddress(factoryPoolManager);

        if (factoryImpl == address(0)) {
            revert("Factory implementation not set");
        }
        if (factoryBaseToken == address(0)) {
            revert("Factory base token not set");
        }
        if (factoryPoolManager == address(0)) {
            revert("Factory pool manager not set");
        }

        // Create the token
        console.log("Creating Liquid token...");
        address newToken = factory.createLiquidToken(
            tokenCreator,
            tokenURI,
            tokenName,
            tokenSymbol,
            initialRareLiquidity
        );

        console.log("Token created at:");
        console.logAddress(newToken);
        console.log("");

        // Stop broadcasting after token creation
        vm.stopBroadcast();

        // ============================================
        // STEP 2: DEPLOY LIQUID LENS DEMO V2
        // ============================================
        console.log("=== STEP 2: DEPLOYING LIQUID LENS DEMO V2 ===");
        console.log("");

        // Validate that the Liquid Edition contract exists and is valid
        console.log("Validating Liquid Edition contract...");
        ILiquid liquidEdition = ILiquid(newToken);
        address actualTokenCreator;
        try liquidEdition.tokenCreator() returns (address creator) {
            actualTokenCreator = creator;
            console.log("Liquid Edition creator:");
            console.logAddress(actualTokenCreator);
        } catch {
            revert(
                "Invalid Liquid Edition address - contract does not implement ILiquid interface"
            );
        }

        // Verify deployer is token creator (required for render contract registration)
        if (deployerAddress != actualTokenCreator) {
            console.log("WARNING: Deployer is not token creator!");
            console.log("Deployer:");
            console.logAddress(deployerAddress);
            console.log("Token creator:");
            console.logAddress(actualTokenCreator);
            console.log("Render contract registration will be skipped.");
            console.log("Token creator must register manually using:");
            string memory castCmd1 = string(
                abi.encodePacked(
                    "  cast send ",
                    vm.toString(newToken),
                    " 'setRenderContract(address)' <LENS_ADDRESS>"
                )
            );
            console.log(castCmd1);
            console.log("");
        }

        // Start broadcasting for lens deployment
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the LiquidLensDemoV2 contract
        console.log("Deploying LiquidLensDemoV2 contract...");
        LiquidLensDemoV2 lens = new LiquidLensDemoV2(
            newToken,
            nftName,
            nftSymbol,
            collectionName,
            collectionDescription
        );

        console.log("LiquidLensDemoV2 deployed at:");
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

        // ============================================
        // STEP 3: REGISTER RENDER CONTRACT
        // ============================================
        console.log("=== STEP 3: REGISTERING RENDER CONTRACT ===");
        console.log("");

        // Register render contract with Liquid Edition (if deployer is token creator)
        if (deployerAddress == actualTokenCreator) {
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
                string memory castCmd2 = string(
                    abi.encodePacked(
                        "  cast send ",
                        vm.toString(newToken),
                        " 'setRenderContract(address)' ",
                        vm.toString(address(lens))
                    )
                );
                console.log(castCmd2);
            } catch {
                console.log(
                    "Failed to register render contract (unknown error)"
                );
                console.log("You can register manually later using:");
                string memory castCmd2 = string(
                    abi.encodePacked(
                        "  cast send ",
                        vm.toString(newToken),
                        " 'setRenderContract(address)' ",
                        vm.toString(address(lens))
                    )
                );
                console.log(castCmd2);
            }
            console.log("");
        } else {
            console.log("Skipping render contract registration");
            console.log("(Deployer is not token creator)");
            console.log("Token creator can register manually using:");
            string memory castCmd3 = string(
                abi.encodePacked(
                    "  cast send ",
                    vm.toString(newToken),
                    " 'setRenderContract(address)' ",
                    vm.toString(address(lens))
                )
            );
            console.log(castCmd3);
            console.log("Token creator address:");
            console.logAddress(actualTokenCreator);
            console.log("");
        }

        vm.stopBroadcast();

        // ============================================
        // OPTIONAL: REGISTER TOKEN WITH ROUTER
        // ============================================
        if (routerAddress != address(0)) {
            console.log("=== OPTIONAL: REGISTERING TOKEN WITH ROUTER ===");
            console.log("");
            console.log(
                "Note: Router registration requires deployer to be router owner"
            );
            console.log("Attempting registration...");
            vm.startBroadcast(deployerPrivateKey);
            try
                ILiquidRouter(routerAddress).registerToken(
                    newToken,
                    actualTokenCreator
                )
            {
                console.log("Token successfully registered with router!");
                console.log(
                    "Creator will receive beneficiary fees (25% of total fee)"
                );
            } catch Error(string memory reason) {
                console.log("Failed to register token with router:");
                console.log(reason);
                console.log("You can register manually later using:");
                string memory castCmd4 = string(
                    abi.encodePacked(
                        "  cast send ",
                        vm.toString(routerAddress),
                        " 'registerToken(address,address)' ",
                        vm.toString(newToken),
                        " ",
                        vm.toString(actualTokenCreator)
                    )
                );
                console.log(castCmd4);
            } catch {
                console.log(
                    "Failed to register token with router (unknown error)"
                );
                console.log("You can register manually later using:");
                string memory castCmd4 = string(
                    abi.encodePacked(
                        "  cast send ",
                        vm.toString(routerAddress),
                        " 'registerToken(address,address)' ",
                        vm.toString(newToken),
                        " ",
                        vm.toString(actualTokenCreator)
                    )
                );
                console.log(castCmd4);
            }
            vm.stopBroadcast();
            console.log("");
        }

        // ============================================
        // SUMMARY
        // ============================================
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("");
        console.log("Liquid Token:");
        console.logAddress(newToken);
        console.log("");
        console.log("LiquidLensDemoV2 Contract:");
        console.logAddress(address(lens));
        console.log("");
        console.log("Token Details:");
        console.log("--------------");
        console.log("Creator:");
        console.logAddress(actualTokenCreator);
        console.log("Name:", tokenName);
        console.log("Symbol:", tokenSymbol);
        console.log("URI:", tokenURI);
        console.log("");
        console.log("Lens Details:");
        console.log("------------");
        console.log("Collection Name:", collectionName);
        console.log("Collection Description:", collectionDescription);
        console.log("NFT Name:", nftName);
        console.log("NFT Symbol:", nftSymbol);
        console.log("Max Supply:", maxSupply);
        console.log("Tokens Minted:", maxSupply);
        console.log("Mint Recipient:");
        console.logAddress(mintTo);
        console.log("");
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Verify the contracts on Etherscan");
        console.log("2. View token metadata:");
        string memory castCall1 = string(
            abi.encodePacked(
                "   - ERC721 Token #0 (ERC20 passthrough): cast call ",
                vm.toString(address(lens)),
                " 'tokenURI(uint256)' 0"
            )
        );
        console.log(castCall1);
        string memory castCall2 = string(
            abi.encodePacked(
                "   - ERC721 Token #1-#10: cast call ",
                vm.toString(address(lens)),
                " 'tokenURI(uint256)' 1-10"
            )
        );
        console.log(castCall2);
        if (deployerAddress == actualTokenCreator) {
            console.log(
                "3. Render contract registered - Liquid Edition tokenURI() will use ERC721 render contract"
            );
            string memory castCall3 = string(
                abi.encodePacked(
                    "   - ERC20 metadata: cast call ",
                    vm.toString(newToken),
                    " 'tokenURI()'"
                )
            );
            console.log(castCall3);
        } else {
            console.log(
                "3. Register render contract with Liquid Edition (if desired):"
            );
            string memory castCmd5 = string(
                abi.encodePacked(
                    "   cast send ",
                    vm.toString(newToken),
                    " 'setRenderContract(address)' ",
                    vm.toString(address(lens))
                )
            );
            console.log(castCmd5);
        }
        console.log(
            "4. The artwork will dynamically update based on Liquid Edition market state"
        );
        console.log(
            "5. Market state changes (swaps, transfers, burns) will trigger metadata refresh"
        );
        console.log("");
    }
}
