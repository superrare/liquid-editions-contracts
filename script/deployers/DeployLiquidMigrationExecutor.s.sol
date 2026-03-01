// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidMigrationExecutor} from "liquid-editions/LiquidMigrationExecutor.sol";

/**
 * @title DeployLiquidMigrationExecutor
 * @notice Library for deploying LiquidMigrationExecutor contract
 * @dev This is a library-style deployer that can be used standalone or composed
 */
library DeployLiquidMigrationExecutor {
    /**
     * @notice Deploy LiquidMigrationExecutor
     * @param owner Owner of the executor (can update config and execute migrations)
     * @param protocolVault Fixed destination for migration dust
     * @param liquidRegistry Registry address for token validation
     * @return executor Address of the deployed LiquidMigrationExecutor
     */
    function deploy(
        address owner,
        address protocolVault,
        address liquidRegistry
    ) internal returns (address executor) {
        require(owner != address(0), "Owner address cannot be zero");
        require(protocolVault != address(0), "Protocol vault address cannot be zero");
        require(liquidRegistry != address(0), "LiquidRegistry address cannot be zero");

        console.log("=== Deploying LiquidMigrationExecutor ===");
        console.log("Configuration:");
        console.log("  Owner:");
        console.logAddress(owner);
        console.log("  Protocol Vault:");
        console.logAddress(protocolVault);
        console.log("  LiquidRegistry:");
        console.logAddress(liquidRegistry);

        LiquidMigrationExecutor executorContract = new LiquidMigrationExecutor(
            owner,
            protocolVault,
            liquidRegistry
        );

        executor = address(executorContract);
        console.log("LiquidMigrationExecutor deployed at:");
        console.logAddress(executor);

        return executor;
    }
}
