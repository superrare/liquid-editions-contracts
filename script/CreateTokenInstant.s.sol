// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";

import {NetworkConfig} from "./config/NetworkConfig.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CreateTokenInstant
 * @notice Script to create a new LiquidInstant token via the factory (permissionless)
 * @dev Creates a two-sided AMM pool seeded with both LIQUID (900K) and RARE tokens.
 *      The pool starts at an optimal price that uses all provided RARE alongside the
 *      900K LIQUID pool supply, across the factory's configured tick range.
 *
 *      Unlike MultiCurve (bonding curve), LiquidInstant creates a traditional AMM:
 *      - Price can move both up and down immediately
 *      - Both LIQUID and RARE are present in the pool from day 1
 *      - Starting price is determined by the RARE/LIQUID ratio at deposit
 *
 * IMPORTANT REQUIREMENTS:
 * - The deployer must have RARE tokens >= INITIAL_RARE_LIQUIDITY
 * - The deployer must approve the factory to spend RARE tokens
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for the deployer (must have RARE tokens)
 * - TOKEN_CREATOR: Address that will receive creator fees and launch reward
 * - TOKEN_URI: Metadata URI for the token
 * - TOKEN_NAME: Name of the token
 * - TOKEN_SYMBOL: Symbol of the token
 *
 * Environment Variables Optional:
 * - INITIAL_RARE_LIQUIDITY: Amount of RARE tokens to seed the pool (default: 250 ether)
 * - FACTORY_ADDRESS: Factory address (defaults to NetworkConfig)
 * - CHAIN_ID: Chain ID (defaults to block.chainid)
 *
 * Usage:
 *   forge script script/CreateTokenInstant.s.sol:CreateTokenInstant --rpc-url $RPC_URL --broadcast --slow
 */
contract CreateTokenInstant is Script {
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
            initialRareLiquidity = 250 ether; // Default to 250 RARE
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
            factoryAddress = config.liquid.factory;
        }

        require(
            factoryAddress != address(0),
            "Factory address not configured. Set FACTORY_ADDRESS env var or update NetworkConfig.liquidFactory"
        );

        console.log("Creating LiquidInstant token...");
        console.log("Chain ID:");
        console.logUint(chainId);
        console.log("Factory address:");
        console.logAddress(factoryAddress);
        console.log("Token creator:");
        console.logAddress(tokenCreator);
        console.log("Token name:", tokenName);
        console.log("Token symbol:", tokenSymbol);
        console.log("Initial RARE liquidity:");
        console.logUint(initialRareLiquidity);
        console.log("");

        address deployerAddress = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        LiquidFactory factory = LiquidFactory(factoryAddress);
        address baseToken = factory.baseToken();
        require(baseToken != address(0), "Base token not set in factory");

        address instantImpl = factory.liquidInstantImplementation();
        if (instantImpl == address(0)) {
            revert("LiquidInstant implementation not set in factory");
        }

        uint256 deployerRareBalance = IERC20(baseToken).balanceOf(deployerAddress);
        if (deployerRareBalance < initialRareLiquidity) {
            revert("Insufficient RARE balance. Deployer needs at least initialRareLiquidity RARE tokens.");
        }

        uint256 currentAllowance = IERC20(baseToken).allowance(deployerAddress, factoryAddress);
        if (currentAllowance < initialRareLiquidity) {
            IERC20(baseToken).approve(factoryAddress, type(uint256).max);
        }

        address newToken = factory.createLiquidTokenInstant(
            tokenCreator,
            tokenURI,
            tokenName,
            tokenSymbol,
            initialRareLiquidity
        );

        console.log("LiquidInstant token created at:", newToken);
        vm.stopBroadcast();

        console.log("Token registered via factory -> LiquidRegistry (automatic).");
        console.log("");
        console.log("=== TOKEN CREATION SUMMARY ===");
        console.log("New LiquidInstant token deployed at:");
        console.logAddress(newToken);
    }
}
