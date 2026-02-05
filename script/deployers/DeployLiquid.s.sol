// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Liquid} from "../../src/Liquid.sol";

/**
 * @title DeployLiquid
 * @notice Library for deploying Liquid implementation contract
 * @dev This is a library-style deployer that can be used standalone or composed
 */
library DeployLiquid {
    /**
     * @notice Deploy Liquid implementation contract
     * @return implementation Address of the deployed Liquid implementation
     */
    function deploy() internal returns (address implementation) {
        console.log("Deploying Liquid implementation...");
        Liquid liquidImplementation = new Liquid();
        implementation = address(liquidImplementation);
        console.log("Liquid implementation deployed at:");
        console.logAddress(implementation);
        return implementation;
    }
}
