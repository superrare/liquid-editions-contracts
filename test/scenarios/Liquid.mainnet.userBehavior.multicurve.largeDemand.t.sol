// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Curve} from "doppler/libraries/Multicurve.sol";
import {LiquidMainnetMultiCurveBehaviorBaseTest} from "./Liquid.mainnet.userBehavior.multicurve.t.sol";

contract LiquidMainnetMultiCurveBehaviorLargeDemandTest is
    LiquidMainnetMultiCurveBehaviorBaseTest
{
    function _profileName() internal pure override returns (string memory) {
        return "LARGE DEMAND";
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
            tickLower: 30180,
            tickUpper: 37140,
            numPositions: 4,
            shares: 0.1e18
        });
        curves[1] = Curve({
            tickLower: 37140,
            tickUpper: 53220,
            numPositions: 3,
            shares: 0.4e18
        });
        curves[2] = Curve({
            tickLower: 53220,
            tickUpper: 76260,
            numPositions: 3,
            shares: 0.48e18
        });
        curves[3] = Curve({
            tickLower: 76260,
            tickUpper: 122280,
            numPositions: 1,
            shares: 0.02e18
        });
    }
}
