// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidFactory} from "../../src/LiquidFactory.sol";
import {Liquid} from "../../src/Liquid.sol";
import {DeployConfig} from "../config/DeployConfig.sol";
import {NetworkConfig} from "../config/NetworkConfig.sol";
import {DeployLiquid} from "./DeployLiquid.s.sol";

/**
 * @title DeployLiquidFactory
 * @notice Library for deploying LiquidFactory and Liquid implementation
 * @dev This is a library-style deployer that can be used standalone or composed
 */
library DeployLiquidFactory {
    /**
     * @notice Deploy LiquidFactory and Liquid implementation
     * @param admin Admin address for the factory
     * @param config Factory configuration from DeployConfig
     * @param network Network configuration from NetworkConfig
     * @return factory Address of the deployed LiquidFactory
     * @return implementation Address of the deployed Liquid implementation
     */
    function deploy(
        address admin,
        DeployConfig.FactoryConfig memory config,
        NetworkConfig.Config memory network
    ) internal returns (address factory, address implementation) {
        console.log("=== Deploying LiquidFactory ===");

        // Validate required addresses
        require(
            network.weth != address(0),
            "WETH address not configured for this network"
        );
        require(
            network.uniswapV4PoolManager != address(0),
            "V4 PoolManager not configured for this network"
        );
        require(
            network.uniswapV4Quoter != address(0),
            "V4 Quoter not configured for this network"
        );

        // Deploy Liquid implementation
        implementation = DeployLiquid.deploy();

        // Deploy LiquidFactory
        console.log("Deploying LiquidFactory...");
        console.log("Configuration:");
        console.log("  Admin:");
        console.logAddress(admin);
        console.log("  LP Tick Lower:");
        console.logInt(config.lpTickLower);
        console.log("  LP Tick Upper:");
        console.logInt(config.lpTickUpper);
        console.log("  Pool Hooks:");
        console.logAddress(config.poolHooks);
        console.log("  Pool Tick Spacing:");
        console.logInt(config.poolTickSpacing);
        console.log("  Internal Max Slippage BPS:");
        console.logUint(config.internalMaxSlippageBps);
        console.log("  Min RARE Liquidity Wei:");
        console.logUint(config.minRareLiquidityWei);

        LiquidFactory factoryContract = new LiquidFactory(
            admin, // admin
            network.weth,
            network.uniswapV4PoolManager,
            config.lpTickLower,
            config.lpTickUpper,
            network.uniswapV4Quoter, // v4 quoter for price discovery
            config.poolHooks, // pool hooks
            config.poolTickSpacing, // pool tick spacing
            config.internalMaxSlippageBps, // internalMaxSlippageBps
            config.minRareLiquidityWei // minRareLiquidityWei
        );

        // Set the implementation in the factory
        console.log("Setting implementation in factory...");
        factoryContract.setImplementation(implementation);

        factory = address(factoryContract);
        console.log("LiquidFactory deployed at:");
        console.logAddress(factory);

        // Set base token if configured
        if (network.rareToken != address(0)) {
            console.log("Setting base token (RARE)...");
            factoryContract.setBaseToken(network.rareToken);
            console.log("Base token set to:");
            console.logAddress(network.rareToken);
        }

        return (factory, implementation);
    }
}
