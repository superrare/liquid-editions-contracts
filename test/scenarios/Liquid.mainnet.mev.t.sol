// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {LiquidFactoryForkBase} from "liquid-editions-test/helpers/bases/LiquidFactoryForkBase.sol";

/**
 * @title LiquidMultiCurve MEV Protection Tests
 * @notice Placeholder — quoter-based slippage config was removed from the factory.
 */
contract LiquidInstant_MEV_Protection_Test is LiquidFactoryForkBase {
    function _deployBurner() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        _setupLiquidFactoryFork();
    }
}
