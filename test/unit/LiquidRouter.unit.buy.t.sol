// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BoundaryConstants} from "liquid-editions-test/helpers/bases/BoundaryConstants.sol";
import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {LiquidRouterUnitTestBase, MockUniversalRouterForRouter, MockUniversalRouterWithRefundForRouter} from "liquid-editions-test/unit/LiquidRouter.unit.base.sol";
import {MockFeeOnTransferToken} from "liquid-editions-test/helpers/MockERC20.sol";

/// @title LiquidRouter Buy Unit Tests
/// @notice Buy flow, slippage, refund guards
contract LiquidRouterUnitBuyTest is LiquidRouterUnitTestBase {

    function testBuyBasic() public {
        uint256 ethAmount = 1 ether;
        uint256 expectedFee = (ethAmount * TOTAL_FEE_BPS) / 10000; // 4%
        uint256 ethForSwap = ethAmount - expectedFee;
        uint256 expectedTokens = (ethForSwap * router.tokenPerEth()) / 1e18;
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.prank(user1);
        uint256 tokensReceived = liquidRouter.buy{value: ethAmount}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        assertEq(tokensReceived, expectedTokens);
        assertEq(token.balanceOf(user1), 10000e18 + expectedTokens); // Initial + bought
    }

    function testBuyEmitsEvent() public {
        uint256 ethAmount = 1 ether;
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.expectEmit(true, true, true, false);
        emit ILiquidRouter.RouterBuy(
            address(token),
            user1,
            user1,
            referrer,
            ethAmount,
            0, // ethFee (checked loosely)
            0, // ethSwapped
            0, // tokensReceived
            0, // protocolFee
            0, // referrerFee
            0, // beneficiaryFee
            0 // burnFee
        );

        vm.prank(user1);
        liquidRouter.buy{value: ethAmount}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function testBuyDistributesFees() public {
        uint256 ethAmount = 1 ether;
        uint256 totalFee = (ethAmount * TOTAL_FEE_BPS) / 10000; // 4%
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        uint256 protocolBalBefore = protocolFeeRecipient.balance;
        uint256 referrerBalBefore = referrer.balance;
        uint256 beneficiaryBalBefore = beneficiary.balance;
        uint256 burnerBalBefore = burner.deposited();

        vm.prank(user1);
        liquidRouter.buy{value: ethAmount}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        // Beneficiary gets 25% (BENEFICIARY_FEE_BPS = 2500)
        assertTrue(beneficiary.balance > beneficiaryBalBefore);

        // Remaining 75% fee split among burn/protocol/referrer
        uint256 beneficiaryFee = (totalFee * 2500) / 10000;
        uint256 remainingFee = totalFee - beneficiaryFee;
        uint256 burnFee = (remainingFee * RARE_BURN_FEE_BPS) / 10000;
        uint256 referrerFee = (remainingFee * REFERRER_FEE_BPS) / 10000;

        assertEq(burner.deposited() - burnerBalBefore, burnFee);
        assertEq(referrer.balance - referrerBalBefore, referrerFee);
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testBuyRevertsOnZeroToken() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(0),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            "",
            new bytes[](0),
            block.timestamp + 1 hours
        );
    }

    function testBuyRevertsOnZeroRecipient() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            address(0),
            referrer,
            1, // minTokensOut (must be > 0)
            "",
            new bytes[](0),
            block.timestamp + 1 hours
        );
    }

    function testBuyRevertsOnSlippageExceeded() public {
        uint256 ethAmount = 1 ether;
        uint256 unreasonablyHighMinOut = 1000000e18;
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.expectRevert(ILiquidRouter.SlippageExceeded.selector);
        vm.prank(user1);
        liquidRouter.buy{value: ethAmount}(
            address(token),
            user1,
            referrer,
            unreasonablyHighMinOut,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function testBuyRevertsOnSwapFailure() public {
        router.setShouldFail(true);
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.expectRevert("Router: swap failed");
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function testBuyRevertsOnZeroMinTokensOut() public {
        (bytes memory commands, bytes[] memory inputs) = _validRoute();
        vm.expectRevert(ILiquidRouter.InvalidAmount.selector);
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            BoundaryConstants.ZERO, // minTokensOut must be > 0
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function testBuyRevertsOnFeeOnTransferToken() public {
        uint256 ethAmount = 1 ether;

        // Deploy fee-on-transfer token and dedicated router/universal router pair
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken();
        MockUniversalRouterForRouter fotRouter = new MockUniversalRouterForRouter(address(fot));
        vm.deal(address(fotRouter), 1000 ether);

        LiquidRouter fotLiquidRouter = deployLiquidRouter(
            address(fotRouter),
            protocolFeeRecipient,
            address(burner),
            RARE_BURN_FEE_BPS,
            PROTOCOL_FEE_BPS,
            REFERRER_FEE_BPS,
            admin
        );

        vm.prank(admin);
        fotLiquidRouter.registerToken(address(fot), beneficiary);

        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        // Calculate expected amounts after swap
        uint256 fee = (ethAmount * TOTAL_FEE_BPS) / 10000; // 4%
        uint256 ethForSwap = ethAmount - fee;
        uint256 tokensFromSwap = (ethForSwap * fotRouter.tokenPerEth()) / 1e18;

        // When router transfers to user1, FOT token takes 1% fee
        uint256 expectedReceived = tokensFromSwap -
            ((tokensFromSwap * fot.FEE_BPS()) / 10_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidRouter.FeeOnTransferDetected.selector,
                tokensFromSwap,
                expectedReceived
            )
        );

        vm.prank(user1);
        fotLiquidRouter.buy{value: ethAmount}(
            address(fot),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function testBuyRevertsOnExpiredDeadline() public {
        vm.warp(block.timestamp + 2 hours);
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.expectRevert(ILiquidRouter.DeadlineExpired.selector);
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            commands,
            inputs,
            block.timestamp - 1 // Expired
        );
    }

    function testBuyRevertsOnEmptyRouteData() public {
        vm.expectRevert(ILiquidRouter.InvalidRouteData.selector);
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0 to reach routeData check)
            "",
            new bytes[](0),
            block.timestamp + 1 hours
        );
    }

    function testBuyToDifferentRecipient() public {
        uint256 ethAmount = 1 ether;
        uint256 user2TokensBefore = token.balanceOf(user2);
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        // user1 buys for user2
        vm.prank(user1);
        uint256 tokensReceived = liquidRouter.buy{value: ethAmount}(
            address(token),
            user2, // recipient is user2
            referrer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        // user2 should have received the tokens
        assertEq(token.balanceOf(user2) - user2TokensBefore, tokensReceived);
    }

    /// @notice Test that buy() reverts when router returns ETH (refund scenario)
    function test_Buy_RevertsWhen_RouterReturnsETH() public {
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
        refundRouter.setRefundAmount(1 wei); // Refund 1 wei
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.expectRevert(ILiquidRouter.UnexpectedEthRefund.selector);
        vm.prank(user1);
        refundRouterInstance.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    /// @notice Test that buy() reverts when router returns partial refund
    function test_Buy_RevertsWhen_RouterReturnsPartialRefund() public {
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
        refundRouter.setRefundAmount(0.1 ether); // Refund 10% of 1 ether
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.expectRevert(ILiquidRouter.UnexpectedEthRefund.selector);
        vm.prank(user1);
        refundRouterInstance.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function test_Buy_SucceedsWithPreexistingETH() public {
        uint256 forcedEth = 1;
        vm.deal(user2, 100 ether);
        vm.prank(user2);
        (bool sent, ) = address(liquidRouter).call{value: forcedEth}("");
        assertTrue(sent);
        assertEq(address(liquidRouter).balance, forcedEth);

        uint256 ethAmount = 1 ether;
        uint256 expectedFee = (ethAmount * TOTAL_FEE_BPS) / 10000;
        uint256 expectedTokens = ((ethAmount - expectedFee) * router.tokenPerEth()) /
            1e18;
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.prank(user1);
        uint256 tokensReceived = liquidRouter.buy{value: ethAmount}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        assertEq(tokensReceived, expectedTokens);
        assertEq(token.balanceOf(user1), 10000e18 + expectedTokens);
        assertEq(address(liquidRouter).balance, forcedEth);
    }

    function test_Buy_RevertsWhen_RouterReturnsETH_WithPreexistingETH() public {
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

        uint256 forcedEth = 1;
        vm.deal(user2, 100 ether);
        vm.prank(user2);
        (bool sent, ) = address(refundRouterInstance).call{value: forcedEth}("");
        assertTrue(sent);
        assertEq(address(refundRouterInstance).balance, forcedEth);

        refundRouter.setShouldRefund(true);
        refundRouter.setRefundAmount(1 wei); // Refund 1 wei
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.expectRevert(ILiquidRouter.UnexpectedEthRefund.selector);
        vm.prank(user1);
        refundRouterInstance.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        assertEq(address(refundRouterInstance).balance, forcedEth);
    }
}
