// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {LiquidRouterUnitTestBase} from "liquid-editions-test/unit/LiquidRouter.unit.base.sol";
import {RoutePolicy} from "liquid-editions/RoutePolicy.sol";

/// @title LiquidRouter RoutePolicy Regression Tests
/// @notice Ensures malicious route payloads are rejected before swap execution.
contract LiquidRouterRoutePolicyRegressionTest is LiquidRouterUnitTestBase {
    address internal constant ROUTER_ADDRESS =
        address(0x0000000000000000000000000000000000000002);

    function testBuyRevertsOnBlockedSweepCommand() public {
        bytes memory commands = hex"04"; // SWEEP
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = "";

        vm.expectRevert(
            abi.encodeWithSelector(RoutePolicy.DisallowedCommand.selector, bytes1(0x04))
        );
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function testBuyRevertsOnRecipientRedirection() public {
        bytes memory commands = hex"00"; // V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](1);
        address attacker = makeAddr("attacker");
        inputs[0] = abi.encode(attacker, uint256(1), uint256(1), bytes(""), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                RoutePolicy.InvalidRouteRecipient.selector,
                bytes1(0x00),
                attacker
            )
        );
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function testSellRevertsWhenWethToRouterMissingUnwrap() public {
        uint256 tokenAmount = 100e18;
        bytes memory commands = hex"00"; // V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            ROUTER_ADDRESS,
            tokenAmount,
            uint256(1),
            bytes(""),
            true
        );

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.expectRevert(RoutePolicy.MissingUnwrapWeth.selector);
        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }
}
