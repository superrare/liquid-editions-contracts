// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Curve} from "doppler/libraries/Multicurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";

import {DeployConfig} from "./config/DeployConfig.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CreateTokenMultiCurve
 * @notice Script to create a new LiquidMultiCurve token via the factory (permissionless)
 * @dev Uses default curve configuration from DeployConfig (250 RARE anchor, ~$500K FDV ceiling).
 *
 * IMPORTANT REQUIREMENTS:
 * - The deployer must approve the factory to spend RARE tokens (if providing initial RARE)
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for the deployer
 * - TOKEN_CREATOR: Address that will receive creator fees and launch reward
 * - TOKEN_URI: Metadata URI for the token
 * - TOKEN_NAME: Name of the token
 * - TOKEN_SYMBOL: Symbol of the token
 *
 * Environment Variables Optional:
 * - INITIAL_RARE_LIQUIDITY: Optional RARE for head position beyond curve range (default: 0)
 * - FACTORY_ADDRESS: Factory address (defaults to NetworkConfig)
 * - ROUTER_ADDRESS: Router address for token registration (defaults to NetworkConfig)
 * - CHAIN_ID: Chain ID (defaults to block.chainid)
 *
 * Usage:
 *   forge script script/CreateTokenMultiCurve.s.sol:CreateTokenMultiCurve --rpc-url $RPC_URL --broadcast --slow
 */
contract CreateTokenMultiCurve is Script {
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
            initialRareLiquidity = 0; // No RARE required — bonding curve is funded by LIQUID tokens
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

        address routerAddress;
        try vm.envAddress("ROUTER_ADDRESS") returns (address _router) {
            routerAddress = _router;
        } catch {
            routerAddress = config.liquid.router;
        }

        console.log("Creating LiquidMultiCurve token...");
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

        if (initialRareLiquidity > 0) {
            uint256 currentAllowance = IERC20(baseToken).allowance(
                deployerAddress,
                factoryAddress
            );
            if (currentAllowance < initialRareLiquidity) {
                IERC20(baseToken).approve(factoryAddress, type(uint256).max);
            }

            uint256 deployerRareBalance = IERC20(baseToken).balanceOf(
                deployerAddress
            );
            if (deployerRareBalance < initialRareLiquidity) {
                revert(
                    "Insufficient RARE balance for initial liquidity."
                );
            }
        }

        address multiCurveImpl = factory.liquidMultiCurveImplementation();
        if (multiCurveImpl == address(0)) {
            revert("LiquidMultiCurve implementation not set in factory");
        }

        Curve[] memory curves = _buildCurvesFromConfig();

        address newToken = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            tokenURI,
            tokenName,
            tokenSymbol,
            initialRareLiquidity,
            curves
        );

        console.log("LiquidMultiCurve token created at:", newToken);
        vm.stopBroadcast();

        // Token registration is handled automatically by LiquidFactory via LiquidRegistry.
        console.log("Token registered via factory -> LiquidRegistry (automatic).");

        console.log("");
        console.log("=== TOKEN CREATION SUMMARY ===");
        console.log("New LiquidMultiCurve token deployed at:");
        console.logAddress(newToken);
    }

    function _buildCurvesFromConfig() internal pure returns (Curve[] memory) {
        DeployConfig.MultiCurveConfig memory cfg = DeployConfig
            .getDefaultMultiCurveConfig();

        Curve[] memory curves = new Curve[](3);
        curves[0] = Curve({
            tickLower: cfg.tripWireTickLower,
            tickUpper: cfg.tripWireTickUpper,
            numPositions: cfg.tripWirePositions,
            shares: cfg.tripWireShares
        });
        curves[1] = Curve({
            tickLower: cfg.distributionTickLower,
            tickUpper: cfg.distributionTickUpper,
            numPositions: cfg.distributionPositions,
            shares: cfg.distributionShares
        });
        curves[2] = Curve({
            tickLower: cfg.steadyStateTickLower,
            tickUpper: cfg.steadyStateTickUpper,
            numPositions: cfg.steadyStatePositions,
            shares: cfg.steadyStateShares
        });
        return curves;
    }
}
