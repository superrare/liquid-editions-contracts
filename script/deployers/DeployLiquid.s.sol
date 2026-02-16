// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";

/**
 * @title DeployLiquid
 * @notice Library for deploying LiquidInstant implementation contract
 * @dev This is a library-style deployer that can be used standalone or composed
 */
library DeployLiquid {
    /**
     * @notice Deploy LiquidInstant implementation contract
     * @return implementation Address of the deployed LiquidInstant implementation
     */
    function deploy() internal returns (address implementation) {
        console.log("Deploying LiquidInstant implementation...");
        LiquidInstant liquidImplementation = new LiquidInstant();
        implementation = address(liquidImplementation);
        console.log("LiquidInstant implementation deployed at:");
        console.logAddress(implementation);
        return implementation;
    }
}
