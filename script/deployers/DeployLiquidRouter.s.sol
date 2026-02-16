// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {DeployConfig} from "../config/DeployConfig.sol";
import {NetworkConfig} from "../config/NetworkConfig.sol";

/**
 * @title DeployLiquidRouter
 * @notice Library for deploying LiquidRouter contract
 * @dev This is a library-style deployer that can be used standalone or composed
 *      Deploys LiquidRouter directly (no proxy)
 */
library DeployLiquidRouter {
    /**
     * @notice Deploy LiquidRouter contract with UUPS proxy
     * @param protocolFeeRecipient Address to receive protocol fees
     * @param config Router configuration from DeployConfig
     * @param network Network configuration from NetworkConfig
     * @param rareBurner Address of the RAREBurner contract
     * @return router Address of the deployed LiquidRouter proxy
     * @return implementation Address of the LiquidRouter implementation
     */
    function deploy(
        address owner,
        address protocolFeeRecipient,
        DeployConfig.FeeConfig memory config,
        NetworkConfig.Config memory network,
        address rareBurner
    ) internal returns (address router, address implementation) {
        return deploy(owner, protocolFeeRecipient, config, network.uniswapUniversalRouter, rareBurner);
    }

    /**
     * @notice Deploy LiquidRouter contract (minimal signature to avoid stack depth issues)
     * @param owner Owner address
     * @param protocolFeeRecipient Address to receive protocol fees
     * @param config Router configuration from DeployConfig
     * @param universalRouter Uniswap Universal Router address
     * @param rareBurner Address of the RAREBurner contract
     * @return router Address of the deployed LiquidRouter proxy
     * @return implementation Address of the LiquidRouter implementation
     */
    function deploy(
        address owner,
        address protocolFeeRecipient,
        DeployConfig.FeeConfig memory config,
        address universalRouter,
        address rareBurner
    ) internal returns (address router, address implementation) {
        console.log("=== Deploying LiquidRouter (UUPS Proxy) ===");

        // Validate required addresses
        require(owner != address(0), "Owner address cannot be zero");
        require(
            universalRouter != address(0),
            "Universal Router address not configured"
        );
        require(rareBurner != address(0), "RAREBurner address cannot be zero");

        console.log("Configuration:");
        console.log("  Owner:");
        console.logAddress(owner);
        console.log("  Protocol Fee Recipient:");
        console.logAddress(protocolFeeRecipient);
        console.log("  Universal Router:");
        console.logAddress(universalRouter);
        console.log("  RAREBurner:");
        console.logAddress(rareBurner);
        console.log("  RARE Burn Fee BPS:");
        console.logUint(config.rareBurnFeeBPS);
        console.log("  Protocol Fee BPS:");
        console.logUint(config.protocolFeeBPS);
        console.log("  Referrer Fee BPS:");
        console.logUint(config.referrerFeeBPS);

        // Deploy LiquidRouter
        LiquidRouter routerContract = new LiquidRouter(
            owner,
            universalRouter,
            protocolFeeRecipient,
            rareBurner,
            config.rareBurnFeeBPS,
            config.protocolFeeBPS,
            config.referrerFeeBPS
        );

        router = address(routerContract);
        implementation = router;
        console.log("LiquidRouter deployed at:");
        console.logAddress(router);

        return (router, implementation);
    }
}
