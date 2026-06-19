// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {SovereignERC20} from "liquid-editions/SovereignERC20.sol";
import {SovereignERC20Market} from "liquid-editions/SovereignERC20Market.sol";
import {SovereignERC20MarketRewards} from "liquid-editions/SovereignERC20MarketRewards.sol";
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
        address usdc;
    }

    /// @notice Addresses produced by a factory deployment
    struct DeployResult {
        address factory;
        address multiCurveImplementation;
        address sovereignERC20Implementation;
        address sovereignERC20MarketImplementation;
        address sovereignERC20MarketRewardsImplementation;
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
            NetworkAddresses({
                uniswapV4PoolManager: network.uniswapV4PoolManager, rareToken: network.rareToken, usdc: network.usdc
            })
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

        // Deploy factory-facing implementations
        result.multiCurveImplementation = DeployLiquidMultiCurve.deploy();
        result.sovereignERC20Implementation = _deploySovereignERC20Implementation();
        result.sovereignERC20MarketImplementation = _deploySovereignERC20MarketImplementation();
        result.sovereignERC20MarketRewardsImplementation = _deploySovereignERC20MarketRewardsImplementation();

        // Deploy factory
        result.factory = _deployFactory(admin, config, network);

        // Register implementations and base token
        _configureFactory(result, network);

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

    function _deploySovereignERC20Implementation() private returns (address implementation) {
        console.log("Deploying SovereignERC20 implementation...");
        implementation = address(new SovereignERC20());
        console.log("SovereignERC20 implementation deployed at:");
        console.logAddress(implementation);
    }

    function _deploySovereignERC20MarketImplementation() private returns (address implementation) {
        console.log("Deploying SovereignERC20Market implementation...");
        implementation = address(new SovereignERC20Market());
        console.log("SovereignERC20Market implementation deployed at:");
        console.logAddress(implementation);
    }

    function _deploySovereignERC20MarketRewardsImplementation() private returns (address implementation) {
        console.log("Deploying SovereignERC20MarketRewards implementation...");
        implementation = address(new SovereignERC20MarketRewards());
        console.log("SovereignERC20MarketRewards implementation deployed at:");
        console.logAddress(implementation);
    }

    function _configureFactory(DeployResult memory result, NetworkAddresses memory network) private {
        LiquidFactory factoryContract = LiquidFactory(result.factory);

        console.log("Setting LiquidMultiCurve implementation in factory...");
        factoryContract.setLiquidMultiCurveImplementation(result.multiCurveImplementation);

        console.log("Setting SovereignERC20 implementation in factory...");
        factoryContract.setSovereignTokenImplementation(
            factoryContract.KIND_SOVEREIGN_ERC20(), result.sovereignERC20Implementation, true
        );

        console.log("Setting SovereignERC20Market implementation in factory...");
        factoryContract.setSovereignTokenImplementation(
            factoryContract.KIND_SOVEREIGN_ERC20_MARKET(), result.sovereignERC20MarketImplementation, true
        );

        console.log("Setting SovereignERC20MarketRewards implementation in factory...");
        factoryContract.setSovereignTokenImplementation(
            factoryContract.KIND_SOVEREIGN_ERC20_MARKET_REWARDS(),
            result.sovereignERC20MarketRewardsImplementation,
            true
        );

        if (network.rareToken != address(0)) {
            console.log("Setting base token (RARE)...");
            factoryContract.setBaseToken(network.rareToken);
            console.log("Base token set to:");
            console.logAddress(network.rareToken);

            console.log("Allowlisting RARE as Sovereign reward token...");
            factoryContract.setSovereignRewardTokenAllowed(network.rareToken, true);
        }

        if (network.usdc != address(0) && network.usdc != network.rareToken) {
            console.log("Allowlisting USDC as Sovereign reward token...");
            factoryContract.setSovereignRewardTokenAllowed(network.usdc, true);
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
