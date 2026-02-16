// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {DeployConfig} from "../config/DeployConfig.sol";
import {NetworkConfig} from "../config/NetworkConfig.sol";
import {DeployLiquid} from "./DeployLiquid.s.sol";
import {DeployLiquidMultiCurve} from "./DeployLiquidMultiCurve.s.sol";
import {DeployLiquidGraduated} from "./DeployLiquidGraduated.s.sol";

/**
 * @title DeployLiquidFactory
 * @notice Library for deploying LiquidFactory and all implementation contracts
 * @dev This is a library-style deployer that can be used standalone or composed
 */
library DeployLiquidFactory {
    /// @notice Minimal network addresses needed for LiquidFactory deployment
    struct NetworkAddresses {
        address weth;
        address uniswapV4PoolManager;
        address uniswapV4Quoter;
        address rareToken;
    }

    /// @notice All addresses produced by a full factory deployment
    struct DeployResult {
        address factory;
        address implementation;
        address multiCurveImplementation;
        address graduatedImplementation;
    }

    /**
     * @notice Deploy LiquidFactory and all implementations
     * @param admin Admin address for the factory
     * @param config Factory configuration from DeployConfig
     * @param network Network configuration from NetworkConfig
     */
    function deploy(
        address admin,
        DeployConfig.FactoryConfig memory config,
        NetworkConfig.Config memory network
    ) internal returns (DeployResult memory result) {
        return deploy(
            admin,
            config,
            NetworkAddresses({
                weth: network.weth,
                uniswapV4PoolManager: network.uniswapV4PoolManager,
                uniswapV4Quoter: network.uniswapV4Quoter,
                rareToken: network.rareToken
            })
        );
    }

    /**
     * @notice Deploy LiquidFactory and all implementations (minimal signature)
     * @param admin Admin address for the factory
     * @param config Factory configuration from DeployConfig
     * @param network Minimal network addresses
     */
    function deploy(
        address admin,
        DeployConfig.FactoryConfig memory config,
        NetworkAddresses memory network
    ) internal returns (DeployResult memory result) {
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

        // Deploy all implementations
        result.implementation = DeployLiquid.deploy();
        result.multiCurveImplementation = DeployLiquidMultiCurve.deploy();
        result.graduatedImplementation = DeployLiquidGraduated.deploy(false);

        // Deploy factory
        result.factory = _deployFactory(admin, config, network);

        // Register implementations and base token
        _configureFactory(
            result.factory,
            result.implementation,
            result.multiCurveImplementation,
            result.graduatedImplementation,
            network.rareToken
        );
    }

    function _deployFactory(
        address admin,
        DeployConfig.FactoryConfig memory config,
        NetworkAddresses memory network
    ) private returns (address factory) {
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
            admin,
            network.weth,
            network.uniswapV4PoolManager,
            config.lpTickLower,
            config.lpTickUpper,
            network.uniswapV4Quoter,
            config.poolHooks,
            config.poolTickSpacing,
            config.internalMaxSlippageBps,
            config.minRareLiquidityWei
        );

        factory = address(factoryContract);
        console.log("LiquidFactory deployed at:");
        console.logAddress(factory);
    }

    function _configureFactory(
        address factory,
        address implementation,
        address multiCurveImpl,
        address graduatedImpl,
        address rareToken
    ) private {
        LiquidFactory factoryContract = LiquidFactory(factory);

        console.log("Setting LiquidInstant implementation in factory...");
        factoryContract.setImplementation(implementation);
        console.log("Setting LiquidMultiCurve implementation in factory...");
        factoryContract.setLiquidMultiCurveImplementation(multiCurveImpl);
        console.log("Setting LiquidGraduated implementation in factory...");
        factoryContract.setLiquidGraduatedImplementation(graduatedImpl);

        if (rareToken != address(0)) {
            console.log("Setting base token (RARE)...");
            factoryContract.setBaseToken(rareToken);
            console.log("Base token set to:");
            console.logAddress(rareToken);
        }
    }
}
