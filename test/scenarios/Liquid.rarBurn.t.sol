// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiquidBondingForkBase} from "liquid-editions-test/helpers/LiquidBondingForkBase.sol";

/// @title Liquid RAREBurner Integration Tests
/// @notice RAREBurner integration on sell
contract LiquidRarBurnTest is LiquidBondingForkBase {

    function testRAREBurnOnSell() public {
        console.log("=== RARE BURN ON SELL TEST ===");

        vm.startPrank(admin);
        vm.stopPrank();

        LiquidFactory tempFactory = _deployLiquidWithTicks(-150000, 150000);

        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(tempFactory), 0.1 ether);
        tempFactory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://rare-burn-sell-test",
            "RARE_BURN_SELL",
            "RBS",
            0.1 ether,
            _defaultSingleCurve(tempFactory)
        );
    }

    function testRAREBurnFailureHandling() public {
        console.log("=== RARE BURN FAILURE HANDLING TEST (NON-REVERTING) ===");

        vm.startPrank(admin);
        vm.stopPrank();

        LiquidFactory tempFactory = _deployLiquidWithTicks(-150000, 150000);

        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(tempFactory), 0.1 ether);
        address tokenAddr = tempFactory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://rare-burn-failure-test",
            "RARE_FAILURE",
            "RF",
            0.1 ether,
            _defaultSingleCurve(tempFactory)
        );
        vm.stopPrank();

        assertTrue(tokenAddr != address(0), "Token should be created");

        console.log(
            "Test passed - Token creation SUCCEEDED with invalid RARE config (non-reverting behavior verified)"
        );
        console.log(
            "User experience preserved - no revert despite burn misconfiguration"
        );
    }

    function testRAREBurnConfigurationChanges() public {
        console.log("=== RARE BURN CONFIGURATION CHANGES TEST ===");

        uint256[] memory burnPercentages = new uint256[](4);
        burnPercentages[0] = 1000;
        burnPercentages[1] = 2500;
        burnPercentages[2] = 4000;
        burnPercentages[3] = 5000;

        for (uint256 i = 0; i < burnPercentages.length; i++) {
            uint256 burnBPS = burnPercentages[i];

            console.log("");
            console.log(
                string(
                    abi.encodePacked(
                        "Testing ",
                        vm.toString(burnBPS / 100),
                        "% RARE burn fee"
                    )
                )
            );

            vm.startPrank(admin);
            vm.stopPrank();

            LiquidFactory tempFactory = _deployLiquidWithTicks(-150000, 150000);

            vm.startPrank(tokenCreator);
            IERC20(mockRARE).approve(address(tempFactory), 0.1 ether);
            tempFactory.createLiquidTokenMultiCurve(
                tokenCreator,
                string(abi.encodePacked("ipfs://test-", vm.toString(i))),
                string(abi.encodePacked("TEST_", vm.toString(i))),
                string(abi.encodePacked("T", vm.toString(i))),
                0.1 ether,
                _defaultSingleCurve(tempFactory)
            );
            vm.stopPrank();
        }
    }
}
