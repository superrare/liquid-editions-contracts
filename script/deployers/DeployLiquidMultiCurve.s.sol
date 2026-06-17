// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";

/**
 * @title DeployLiquidMultiCurve
 * @notice Library for deploying LiquidMultiCurve implementation contract
 * @dev This is a library-style deployer that can be used standalone or composed
 */
library DeployLiquidMultiCurve {
    /**
     * @notice Deploy LiquidMultiCurve implementation contract
     * @return implementation Address of the deployed LiquidMultiCurve implementation
     */
    function deploy() internal returns (address implementation) {
        console.log("Deploying LiquidMultiCurve implementation...");
        LiquidMultiCurve liquidImplementation = new LiquidMultiCurve();
        implementation = address(liquidImplementation);
        console.log("LiquidMultiCurve implementation deployed at:");
        console.logAddress(implementation);
        return implementation;
    }
}
