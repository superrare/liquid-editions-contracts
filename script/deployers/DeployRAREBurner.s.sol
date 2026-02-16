// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {DeployConfig} from "../config/DeployConfig.sol";
import {NetworkConfig} from "../config/NetworkConfig.sol";

/**
 * @title DeployRAREBurner
 * @notice Library for deploying RAREBurner contract
 * @dev This is a library-style deployer that can be used standalone or composed
 */
library DeployRAREBurner {
    /// @notice Minimal network addresses needed for RAREBurner deployment
    struct NetworkAddresses {
        address rareToken;
        address uniswapV4PoolManager;
        address uniswapV4Quoter;
    }

    /**
     * @notice Deploy RAREBurner contract
     * @param owner Owner/admin address for the burner
     * @param config Burner configuration from DeployConfig
     * @param network Network configuration from NetworkConfig
     * @return burner Address of the deployed RAREBurner
     */
    function deploy(
        address owner,
        DeployConfig.BurnerConfig memory config,
        NetworkConfig.Config memory network
    ) internal returns (address burner) {
        return deploy(
            owner,
            config,
            NetworkAddresses({
                rareToken: network.rareToken,
                uniswapV4PoolManager: network.uniswapV4PoolManager,
                uniswapV4Quoter: network.uniswapV4Quoter
            })
        );
    }

    /**
     * @notice Deploy RAREBurner contract (minimal signature to avoid stack depth issues)
     * @param owner Owner/admin address for the burner
     * @param config Burner configuration from DeployConfig
     * @param network Minimal network addresses
     * @return burner Address of the deployed RAREBurner
     */
    function deploy(
        address owner,
        DeployConfig.BurnerConfig memory config,
        NetworkAddresses memory network
    ) internal returns (address burner) {
        console.log("=== Deploying RAREBurner ===");

        // Validate required addresses
        require(
            network.rareToken != address(0),
            "RARE token address not configured for this network"
        );
        require(
            network.uniswapV4PoolManager != address(0),
            "V4 PoolManager not configured for this network"
        );
        require(
            config.burnAddress != address(0),
            "Burn address cannot be zero"
        );

        // Always use network's v4Quoter
        address v4Quoter = network.uniswapV4Quoter;

        if (config.maxSlippageBPS > 0) {
            require(
                v4Quoter != address(0),
                "V4 Quoter required when slippage protection is enabled"
            );
        }

        console.log("Configuration:");
        console.log("  Try On Deposit:", config.tryOnDeposit);
        console.log("  Pool Fee:");
        console.logUint(config.poolFee);
        console.log("  Tick Spacing:");
        console.logInt(config.tickSpacing);
        console.log("  Hooks:");
        console.logAddress(config.hooks);
        console.log("  Burn Address:");
        console.logAddress(config.burnAddress);
        console.log("  V4 Quoter:");
        console.logAddress(v4Quoter);
        console.log("  Max Slippage BPS:");
        console.logUint(config.maxSlippageBPS);
        console.log("  Enabled:", config.enabled);

        // Deploy RAREBurner
        RAREBurner rareBurner = new RAREBurner(
            owner, // owner (admin)
            config.tryOnDeposit, // attempt burn on deposit
            network.rareToken, // RARE token address
            network.uniswapV4PoolManager, // V4 PoolManager
            config.poolFee, // fee
            config.tickSpacing, // tickSpacing
            config.hooks, // hooks
            config.burnAddress, // burnAddress
            v4Quoter, // v4Quoter
            config.maxSlippageBPS, // maxSlippageBPS
            config.enabled // enabled
        );

        burner = address(rareBurner);
        console.log("RAREBurner deployed at:");
        console.logAddress(burner);

        // Validate deployment
        bool isActive = rareBurner.isRAREBurnActive();
        bool isValid = rareBurner.validatePoolConfig();
        console.log("  RARE Burn Active:", isActive);
        console.log("  Pool Config Valid:", isValid);

        return burner;
    }
}
