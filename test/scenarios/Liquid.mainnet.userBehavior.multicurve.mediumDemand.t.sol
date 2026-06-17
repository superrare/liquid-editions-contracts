// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Curve} from "doppler/libraries/Multicurve.sol";
import {LiquidMainnetMultiCurveBehaviorBaseTest} from "./Liquid.mainnet.userBehavior.multicurve.t.sol";

contract LiquidMainnetMultiCurveBehaviorMediumDemandTest is
    LiquidMainnetMultiCurveBehaviorBaseTest
{
    function _profileName() internal pure override returns (string memory) {
        return "MEDIUM DEMAND";
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
            tickLower: 26160,
            tickUpper: 33060,
            numPositions: 3,
            shares: 0.1e18
        });
        curves[1] = Curve({
            tickLower: 33060,
            tickUpper: 49140,
            numPositions: 2,
            shares: 0.65e18
        });
        curves[2] = Curve({
            tickLower: 49140,
            tickUpper: 72180,
            numPositions: 2,
            shares: 0.23e18
        });
        curves[3] = Curve({
            tickLower: 72180,
            tickUpper: 118260,
            numPositions: 1,
            shares: 0.02e18
        });
    }
}
