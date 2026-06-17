// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";
import {DeployConfig} from "../config/DeployConfig.sol";
import {NetworkConfig} from "../config/NetworkConfig.sol";

/**
 * @title DeployLiquidRouter
 * @notice Library for deploying LiquidRouter contract
 * @dev LiquidRouter no longer has a FeeDistributor. Fees are collected by LiquidGuard at the pool level.
 */
library DeployLiquidRouter {
    /**
     * @notice Deploy LiquidRouter contract
     * @param owner Owner address
     * @param network Network configuration from NetworkConfig
     * @param liquidRegistryAddress Pre-deployed LiquidRegistry address
     * @return router Address of the deployed LiquidRouter
     * @return implementation Address of the LiquidRouter implementation (same contract)
     */
    function deploy(
        address owner,
        NetworkConfig.Config memory network,
        address liquidRegistryAddress
    ) internal returns (address router, address implementation) {
        return deploy(owner, network.uniswapUniversalRouter, liquidRegistryAddress);
    }

    /**
     * @notice Deploy LiquidRouter contract (explicit addresses)
     * @param owner Owner address
     * @param universalRouter Uniswap Universal Router address
     * @param liquidRegistryAddress Pre-deployed LiquidRegistry address
     * @return router Address of the deployed LiquidRouter
     * @return implementation Address of the LiquidRouter implementation
     */
    function deploy(
        address owner,
        address universalRouter,
        address liquidRegistryAddress
    ) internal returns (address router, address implementation) {
        console.log("=== Deploying LiquidRouter ===");

        require(owner != address(0), "Owner address cannot be zero");
        require(universalRouter != address(0), "Universal Router address not configured");
        require(liquidRegistryAddress != address(0), "LiquidRegistry address cannot be zero");

        console.log("Configuration:");
        console.log("  Owner:");
        console.logAddress(owner);
        console.log("  Universal Router:");
        console.logAddress(universalRouter);
        console.log("  LiquidRegistry:");
        console.logAddress(liquidRegistryAddress);

        LiquidRouter routerContract = new LiquidRouter(
            owner,
            universalRouter,
            liquidRegistryAddress
        );

        router = address(routerContract);
        implementation = router;
        console.log("LiquidRouter deployed at:");
        console.logAddress(router);

        return (router, implementation);
    }

    /// @notice Deploy LiquidRouter with a pre-deployed LiquidRegistry module
    function deployWithModules(
        address owner,
        ILiquidRegistry liquidRegistry,
        address universalRouter
    ) internal returns (address router, address implementation) {
        require(owner != address(0), "Owner address cannot be zero");
        require(universalRouter != address(0), "Universal Router address not configured");
        require(address(liquidRegistry) != address(0), "LiquidRegistry address cannot be zero");

        LiquidRouter routerContract = new LiquidRouter(
            owner,
            universalRouter,
            address(liquidRegistry)
        );

        router = address(routerContract);
        implementation = router;
        console.log("LiquidRouter deployed at:");
        console.logAddress(router);

        return (router, implementation);
    }
}
