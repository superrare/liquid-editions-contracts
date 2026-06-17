// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidGraduated} from "liquid-editions/LiquidGraduated.sol";

/**
 * @title DeployLiquidGraduated
 * @notice Library for deploying LiquidGraduated implementation (CCA auction launches)
 * @dev Retained for legacy or standalone graduated deployments; current LiquidFactory deploys only multicurve.
 */
library DeployLiquidGraduated {
    /**
     * @notice Deploy LiquidGraduated implementation contract
     * @param silent If true, suppress deployment logs (for tests)
     * @return implementation Address of the deployed LiquidGraduated implementation
     */
    function deploy(bool silent) internal returns (address implementation) {
        if (!silent) {
            console.log("Deploying LiquidGraduated implementation...");
        }
        LiquidGraduated graduatedImplementation = new LiquidGraduated();
        implementation = address(graduatedImplementation);
        if (!silent) {
            console.log("LiquidGraduated implementation deployed at:");
            console.logAddress(implementation);
        }
        return implementation;
    }
}
