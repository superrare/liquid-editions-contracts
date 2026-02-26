// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {FeeDistributor} from "liquid-editions/FeeDistributor.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";
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
     * @notice Deploy LiquidRouter contract
     * @param protocolFeeRecipient Address to receive protocol fees
     * @param config Router fee configuration
     * @param network Network configuration from NetworkConfig
     * @return router Address of the deployed LiquidRouter
     * @return implementation Address of the LiquidRouter implementation
     */
    function deploy(
        address owner,
        address protocolFeeRecipient,
        DeployConfig.FeeConfig memory config,
        NetworkConfig.Config memory network
    ) internal returns (address router, address implementation) {
        return deploy(owner, protocolFeeRecipient, config, network.uniswapUniversalRouter);
    }

    /**
     * @notice Deploy LiquidRouter contract (minimal signature)
     * @param owner Owner address
     * @param protocolFeeRecipient Address to receive protocol fees
     * @param config Router configuration from DeployConfig
     * @param universalRouter Uniswap Universal Router address
     * @return router Address of the deployed LiquidRouter
     * @return implementation Address of the LiquidRouter implementation
     */
    function deploy(
        address owner,
        address protocolFeeRecipient,
        DeployConfig.FeeConfig memory config,
        address universalRouter
    ) internal returns (address router, address implementation) {
        console.log("=== Deploying LiquidRouter ===");

        // Validate required addresses
        require(owner != address(0), "Owner address cannot be zero");
        require(
            universalRouter != address(0),
            "Universal Router address not configured"
        );

        console.log("Configuration:");
        console.log("  Owner:");
        console.logAddress(owner);
        console.log("  Protocol Fee Recipient:");
        console.logAddress(protocolFeeRecipient);
        console.log("  Universal Router:");
        console.logAddress(universalRouter);
        console.log("  Total Fee BPS:");
        console.logUint(config.totalFeeBPS);

        // Deploy LiquidRouter
        FeeDistributor feeDistributor = new FeeDistributor(
            owner,
            config.totalFeeBPS,
            protocolFeeRecipient
        );
        LiquidRegistry liquidRegistry = new LiquidRegistry(owner);

        LiquidRouter routerContract = new LiquidRouter(
            owner,
            universalRouter,
            address(feeDistributor),
            address(liquidRegistry)
        );

        router = address(routerContract);
        implementation = router;
        console.log("LiquidRouter deployed at:");
        console.logAddress(router);

        return (router, implementation);
    }

    /// @notice Deploy LiquidRouter with pre-deployed fee modules
    /// @param owner Owner address
    /// @param feeDistributor Fee distribution module
    /// @param liquidRegistry Liquid registry module
    /// @param universalRouter Uniswap Universal Router address
    /// @return router Address of deployed LiquidRouter
    /// @return implementation Address of deployed LiquidRouter implementation
    function deployWithModules(
        address owner,
        IFeeDistributor feeDistributor,
        ILiquidRegistry liquidRegistry,
        address universalRouter
    ) internal returns (address router, address implementation) {
        require(owner != address(0), "Owner address cannot be zero");
        require(
            universalRouter != address(0),
            "Universal Router address not configured"
        );
        require(
            address(feeDistributor) != address(0),
            "FeeDistributor address cannot be zero"
        );
        require(
            address(liquidRegistry) != address(0),
            "LiquidRegistry address cannot be zero"
        );

        LiquidRouter routerContract = new LiquidRouter(
            owner,
            universalRouter,
            address(feeDistributor),
            address(liquidRegistry)
        );

        router = address(routerContract);
        implementation = router;
        console.log("LiquidRouter deployed at:");
        console.logAddress(router);

        return (router, implementation);
    }
}
