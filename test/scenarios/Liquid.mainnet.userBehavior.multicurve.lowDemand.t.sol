// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Curve} from "doppler/libraries/Multicurve.sol";
import {LiquidMainnetMultiCurveBehaviorBaseTest} from "./Liquid.mainnet.userBehavior.multicurve.t.sol";

contract LiquidMainnetMultiCurveBehaviorLowDemandTest is
    LiquidMainnetMultiCurveBehaviorBaseTest
{
    function _profileName() internal pure override returns (string memory) {
        return "LOW DEMAND";
    }

    function _buyAmountEth() internal pure override returns (uint256) {
        return 0.2e18;
    }

    function _numBuys() internal pure override returns (uint256) {
        return 100;
    }

    function _buildCurves()
        internal
        pure
        override
        returns (Curve[] memory curves)
    {
        curves = new Curve[](4);
        curves[0] = Curve({
            tickLower: 16980,
            tickUpper: 23880,
            numPositions: 2,
            shares: 0.3e18
        });
        curves[1] = Curve({
            tickLower: 23880,
            tickUpper: 40020,
            numPositions: 2,
            shares: 0.5e18
        });
        curves[2] = Curve({
            tickLower: 40020,
            tickUpper: 63000,
            numPositions: 1,
            shares: 0.18e18
        });
        curves[3] = Curve({
            tickLower: 63000,
            tickUpper: 109080,
            numPositions: 1,
            shares: 0.02e18
        });
    }
}
