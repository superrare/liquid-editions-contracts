// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidRouter} from "../../src/LiquidRouter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeployConfig} from "../config/DeployConfig.sol";
import {NetworkConfig} from "../config/NetworkConfig.sol";

/**
 * @title DeployLiquidRouter
 * @notice Library for deploying LiquidRouter contract with UUPS proxy
 * @dev This is a library-style deployer that can be used standalone or composed
 *      Deploys implementation + proxy for upgradeability
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
        address protocolFeeRecipient,
        DeployConfig.RouterConfig memory config,
        NetworkConfig.Config memory network,
        address rareBurner
    ) internal returns (address router, address implementation) {
        console.log("=== Deploying LiquidRouter (UUPS Proxy) ===");

        // Validate required addresses
        require(
            network.uniswapUniversalRouter != address(0),
            "Universal Router address not configured"
        );
        require(rareBurner != address(0), "RAREBurner address cannot be zero");

        console.log("Configuration:");
        console.log("  Protocol Fee Recipient:");
        console.logAddress(protocolFeeRecipient);
        console.log("  Universal Router:");
        console.logAddress(network.uniswapUniversalRouter);
        console.log("  RAREBurner:");
        console.logAddress(rareBurner);
        console.log("  RARE Burn Fee BPS:");
        console.logUint(config.rareBurnFeeBPS);
        console.log("  Protocol Fee BPS:");
        console.logUint(config.protocolFeeBPS);
        console.log("  Referrer Fee BPS:");
        console.logUint(config.referrerFeeBPS);

        // Deploy LiquidRouter implementation
        LiquidRouter implementationContract = new LiquidRouter();
        implementation = address(implementationContract);
        console.log("LiquidRouter implementation deployed at:");
        console.logAddress(implementation);

        // Encode initialization data
        bytes memory initData = abi.encodeWithSelector(
            LiquidRouter.initialize.selector,
            network.uniswapUniversalRouter,
            protocolFeeRecipient,
            rareBurner,
            config.rareBurnFeeBPS,
            config.protocolFeeBPS,
            config.referrerFeeBPS
        );

        // Deploy ERC1967 proxy pointing to implementation
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, initData);
        router = address(proxy);
        console.log("LiquidRouter proxy deployed at:");
        console.logAddress(router);

        return (router, implementation);
    }
}
