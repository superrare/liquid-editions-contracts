// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BoundaryConstants} from "liquid-editions-test/helpers/bases/BoundaryConstants.sol";
import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {LiquidRouterUnitTestBase, MockUniversalRouterWithRefundForRouter} from "liquid-editions-test/unit/LiquidRouter.unit.base.sol";

/// @title LiquidRouter Swap Unit Tests
/// @notice Swap (two-leg) flow
contract LiquidRouterUnitSwapTest is LiquidRouterUnitTestBase {

    function test_Swap_RevertsWhen_BothLegsEmpty() public {
        vm.expectRevert(ILiquidRouter.BothLegsEmpty.selector);
        liquidRouter.swap(
            address(0), // tokenIn (ETH when leg1 empty)
            BoundaryConstants.ZERO,
            address(0), // tokenOut (ETH when leg2 empty)
            user1,
            referrer,
            BoundaryConstants.ONE, // minAmountOut must be > 0
            "", // leg1 empty
            "", // leg2 empty
            block.timestamp + 1 hours
        );
    }

    function test_Swap_RevertsWhen_Leg2ReturnsETH() public {
        MockUniversalRouterWithRefundForRouter refundRouter = new MockUniversalRouterWithRefundForRouter(
                address(token)
            );
        vm.deal(address(refundRouter), 1000 ether);

        LiquidRouter refundRouterInstance = deployLiquidRouter(
            address(refundRouter),
            protocolFeeRecipient,
            address(burner),
            RARE_BURN_FEE_BPS,
            PROTOCOL_FEE_BPS,
            REFERRER_FEE_BPS,
            admin
        );

        vm.prank(admin);
        refundRouterInstance.registerToken(address(token), beneficiary);

        refundRouter.setShouldRefund(true);
        refundRouter.setRefundAmount(0.5 ether);

        bytes memory leg1 = abi.encodeWithSelector(
            refundRouter.execute.selector,
            "",
            new bytes[](0),
            block.timestamp
        );
        bytes memory leg2 = abi.encodeWithSelector(
            refundRouter.execute.selector,
            "",
            new bytes[](0),
            block.timestamp
        );

        vm.prank(user1);
        token.approve(address(refundRouterInstance), 1000e18);

        vm.expectRevert(ILiquidRouter.UnexpectedEthRefund.selector);
        vm.prank(user1);
        refundRouterInstance.swap(
            address(token),
            1000e18,
            address(token),
            user1,
            referrer,
            1, // minAmountOut
            leg1,
            leg2,
            block.timestamp + 1 hours
        );
    }

    function test_Swap_RevertsWhen_Leg2ReturnsPartialRefund() public {
        MockUniversalRouterWithRefundForRouter refundRouter = new MockUniversalRouterWithRefundForRouter(
                address(token)
            );
        vm.deal(address(refundRouter), 1000 ether);

        LiquidRouter refundRouterInstance = deployLiquidRouter(
            address(refundRouter),
            protocolFeeRecipient,
            address(burner),
            RARE_BURN_FEE_BPS,
            PROTOCOL_FEE_BPS,
            REFERRER_FEE_BPS,
            admin
        );

        vm.prank(admin);
        refundRouterInstance.registerToken(address(token), beneficiary);

        refundRouter.setShouldRefund(true);
        refundRouter.setRefundAmount(0.1 ether);

        bytes memory leg1 = abi.encodeWithSelector(
            refundRouter.execute.selector,
            "",
            new bytes[](0),
            block.timestamp
        );
        bytes memory leg2 = abi.encodeWithSelector(
            refundRouter.execute.selector,
            "",
            new bytes[](0),
            block.timestamp
        );

        vm.prank(user1);
        token.approve(address(refundRouterInstance), 1000e18);

        vm.expectRevert(ILiquidRouter.UnexpectedEthRefund.selector);
        vm.prank(user1);
        refundRouterInstance.swap(
            address(token),
            1000e18,
            address(token),
            user1,
            referrer,
            1, // minAmountOut
            leg1,
            leg2,
            block.timestamp + 1 hours
        );
    }

    function test_Swap_SucceedsWithPreexistingETH() public {
        // Simulate donation/dust: send 1 wei to router (trivial griefing vector before fix)
        vm.deal(user2, 100 ether);
        vm.prank(user2);
        (bool sent,) = address(liquidRouter).call{value: 1}("");
        assertTrue(sent);
        assertEq(address(liquidRouter).balance, 1);

        bytes memory leg1 = abi.encodeWithSelector(
            router.execute.selector,
            "",
            new bytes[](0),
            block.timestamp
        );
        bytes memory leg2 = abi.encodeWithSelector(
            router.execute.selector,
            "",
            new bytes[](0),
            block.timestamp
        );

        vm.prank(user1);
        token.approve(address(liquidRouter), 1000e18);

        vm.prank(user1);
        uint256 amountOut = liquidRouter.swap(
            address(token),
            1000e18,
            address(token),
            user1,
            referrer,
            1, // minAmountOut
            leg1,
            leg2,
            block.timestamp + 1 hours
        );

        assertGt(amountOut, 0, "swap should succeed and return tokens");
        assertEq(address(liquidRouter).balance, 1);
    }

    function test_Swap_RevertsOnRefundEvenWithPreexistingETH() public {
        MockUniversalRouterWithRefundForRouter refundRouter = new MockUniversalRouterWithRefundForRouter(
                address(token)
            );
        vm.deal(address(refundRouter), 1000 ether);

        LiquidRouter refundRouterInstance = deployLiquidRouter(
            address(refundRouter),
            protocolFeeRecipient,
            address(burner),
            RARE_BURN_FEE_BPS,
            PROTOCOL_FEE_BPS,
            REFERRER_FEE_BPS,
            admin
        );

        vm.prank(admin);
        refundRouterInstance.registerToken(address(token), beneficiary);

        // Send 1 wei to router (pre-existing ETH)
        vm.deal(user2, 100 ether);
        vm.prank(user2);
        (bool sent,) = address(refundRouterInstance).call{value: 1}("");
        assertTrue(sent);

        refundRouter.setShouldRefund(true);
        refundRouter.setRefundAmount(0.5 ether);

        bytes memory leg1 = abi.encodeWithSelector(
            refundRouter.execute.selector,
            "",
            new bytes[](0),
            block.timestamp
        );
        bytes memory leg2 = abi.encodeWithSelector(
            refundRouter.execute.selector,
            "",
            new bytes[](0),
            block.timestamp
        );

        vm.prank(user1);
        token.approve(address(refundRouterInstance), 1000e18);

        // Refund detection should still work: revert even with pre-existing ETH
        vm.expectRevert(ILiquidRouter.UnexpectedEthRefund.selector);
        vm.prank(user1);
        refundRouterInstance.swap(
            address(token),
            1000e18,
            address(token),
            user1,
            referrer,
            1, // minAmountOut
            leg1,
            leg2,
            block.timestamp + 1 hours
        );

        assertEq(address(refundRouterInstance).balance, 1);
    }
}
