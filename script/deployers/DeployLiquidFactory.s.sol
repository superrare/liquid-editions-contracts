// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {DeployConfig} from "../config/DeployConfig.sol";
import {NetworkConfig} from "../config/NetworkConfig.sol";
import {DeployLiquidMultiCurve} from "./DeployLiquidMultiCurve.s.sol";

/**
 * @title DeployLiquidFactory
 * @notice Library for deploying LiquidFactory and its factory-facing multicurve implementation
 * @dev This is a library-style deployer that can be used standalone or composed
 */
library DeployLiquidFactory {
    /// @notice Minimal network addresses needed for LiquidFactory deployment
    struct NetworkAddresses {
        address uniswapV4PoolManager;
        address rareToken;
    }

    /// @notice Addresses produced by a factory deployment
    struct DeployResult {
        address factory;
        address multiCurveImplementation;
    }

    /**
     * @notice Deploy LiquidFactory and the multicurve implementation
     * @param admin Admin address for the factory
     * @param config Factory configuration from DeployConfig
     * @param network Network configuration from NetworkConfig
     */
    function deploy(address admin, DeployConfig.FactoryConfig memory config, NetworkConfig.Config memory network)
        internal
        returns (DeployResult memory result)
    {
        return deploy(
            admin,
            config,
            NetworkAddresses({uniswapV4PoolManager: network.uniswapV4PoolManager, rareToken: network.rareToken})
        );
    }

    /**
     * @notice Deploy LiquidFactory and the multicurve implementation (minimal signature)
     * @param admin Admin address for the factory
     * @param config Factory configuration from DeployConfig
     * @param network Minimal network addresses
     */
    function deploy(address admin, DeployConfig.FactoryConfig memory config, NetworkAddresses memory network)
        internal
        returns (DeployResult memory result)
    {
        console.log("=== Deploying LiquidFactory ===");

        require(network.uniswapV4PoolManager != address(0), "V4 PoolManager not configured for this network");

        // Deploy factory-facing implementation
        result.multiCurveImplementation = DeployLiquidMultiCurve.deploy();

        // Deploy factory
        result.factory = _deployFactory(admin, config, network);

        // Register implementations and base token
        _configureFactory(result.factory, result.multiCurveImplementation, network.rareToken);

        // Apply supply params if they differ from the hardcoded storage defaults
        configureSupplyParams(result.factory, config);
    }

    function _deployFactory(address admin, DeployConfig.FactoryConfig memory config, NetworkAddresses memory network)
        private
        returns (address factory)
    {
        console.log("Deploying LiquidFactory...");
        console.log("Configuration:");
        console.log("  Admin:");
        console.logAddress(admin);
        console.log("  Pool Hooks:");
        console.logAddress(config.poolHooks);
        console.log("  Pool Tick Spacing:");
        console.logInt(config.poolTickSpacing);

        LiquidFactory factoryContract =
            new LiquidFactory(admin, network.uniswapV4PoolManager, config.poolHooks, config.poolTickSpacing);

        factory = address(factoryContract);
        console.log("LiquidFactory deployed at:");
        console.logAddress(factory);
    }

    function _configureFactory(address factory, address multiCurveImpl, address rareToken) private {
        LiquidFactory factoryContract = LiquidFactory(factory);

        console.log("Setting LiquidMultiCurve implementation in factory...");
        factoryContract.setLiquidMultiCurveImplementation(multiCurveImpl);

        if (rareToken != address(0)) {
            console.log("Setting base token (RARE)...");
            factoryContract.setBaseToken(rareToken);
            console.log("Base token set to:");
            console.logAddress(rareToken);
        }
    }

    function configureSupplyParams(address factory, DeployConfig.FactoryConfig memory config) internal {
        LiquidFactory factoryContract = LiquidFactory(factory);

        uint256 defaultMaxSupply = 1_000_000e18;
        uint256 defaultCreatorReward = 100_000e18;

        if (config.maxTotalSupplyWei != 0 && config.maxTotalSupplyWei != defaultMaxSupply) {
            console.log("Setting maxTotalSupply...");
            console.logUint(config.maxTotalSupplyWei);
            factoryContract.setMaxTotalSupply(config.maxTotalSupplyWei);
        }

        // creatorLaunchReward: call setter when explicitly configured and differs from default.
        // Zero is a valid value (no carve-out), so we check against the default 100K.
        if (config.creatorLaunchRewardWei != defaultCreatorReward) {
            console.log("Setting creatorLaunchReward...");
            console.logUint(config.creatorLaunchRewardWei);
            factoryContract.setCreatorLaunchReward(config.creatorLaunchRewardWei);
        }
    }
}
