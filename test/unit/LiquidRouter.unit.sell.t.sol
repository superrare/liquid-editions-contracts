// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {LiquidRouterUnitTestBase, MockUniversalRouterForRouter, MockPermit2ForRouter} from "liquid-editions-test/unit/LiquidRouter.unit.base.sol";
import {MockFeeOnTransferToken} from "liquid-editions-test/helpers/MockERC20.sol";

/// @title Mock Universal Router with token-sell ETH refund capability
contract MockUniversalRouterWithSellETHRefundForRouter is
    MockUniversalRouterForRouter
{
    bool public shouldRefund;
    uint256 public refundAmount;

    constructor(address _token) MockUniversalRouterForRouter(_token) {}

    function setShouldRefund(bool _should) external {
        shouldRefund = _should;
    }

    function setRefundAmount(uint256 _amount) external {
        refundAmount = _amount;
    }

    function execute(
        bytes calldata,
        bytes[] calldata,
        uint256
    ) external payable override {
        if (shouldFail) revert("Router: swap failed");

        if (msg.value > 0) {
            uint256 tokensOut = (msg.value * tokenPerEth) / 1e18;
            token.mint(msg.sender, tokensOut);
        } else {
            uint256 approved = token.allowance(msg.sender, PERMIT2);
            if (approved > 0) {
                uint256 amountToPull = pullAmountOverride > 0
                    ? pullAmountOverride
                    : approved;
                if (amountToPull > approved) amountToPull = approved;

                token.transferFrom(msg.sender, address(this), amountToPull);
                uint256 ethOut = (amountToPull * 1e18) / tokenPerEth;
                (bool success, ) = msg.sender.call{value: ethOut}("");
                require(success, "ETH transfer failed");
            }
        }

        if (shouldRefund && refundAmount > 0) {
            (bool success, ) = msg.sender.call{value: refundAmount}("");
            require(success, "Refund failed");
        }
    }
}

/// @title LiquidRouter Sell Unit Tests
/// @notice Sell flow, Permit2, fee-on-transfer
contract LiquidRouterUnitSellTest is LiquidRouterUnitTestBase {

    function testSellBasic() public {
        uint256 tokenAmount = 1000e18;
        uint256 grossEth = (tokenAmount * 1e18) / router.tokenPerEth();
        uint256 fee = (grossEth * TOTAL_FEE_BPS) / 10000; // 4%
        uint256 expectedEth = grossEth - fee;

        // Approve tokens
        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        uint256 balBefore = user1.balance;

        vm.prank(user1);
        uint256 ethReceived = liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1, // minEthOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        assertEq(ethReceived, expectedEth);
        assertEq(user1.balance - balBefore, expectedEth);
    }

    function testSellDistributesFees() public {
        uint256 tokenAmount = 1000e18;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        uint256 protocolBalBefore = protocolFeeRecipient.balance;
        uint256 referrerBalBefore = referrer.balance;
        uint256 beneficiaryBalBefore = beneficiary.balance;
        uint256 burnerBalBefore = burner.deposited();

        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        assertTrue(beneficiary.balance > beneficiaryBalBefore);
        assertTrue(burner.deposited() > burnerBalBefore);
        assertTrue(referrer.balance > referrerBalBefore);
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testSellRevertsOnZeroAmount() public {
        vm.expectRevert(ILiquidRouter.InvalidAmount.selector);
        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            0,
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            "",
            block.timestamp + 1 hours
        );
    }

    function testSellRevertsOnSlippageExceeded() public {
        uint256 tokenAmount = 1000e18;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.expectRevert(ILiquidRouter.SlippageExceeded.selector);
        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1000 ether, // Unreasonably high min out
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    function testSellRevertsOnUnexpectedTokenRefund() public {
        uint256 tokenAmount = 1000e18;
        uint256 amountToPull = tokenAmount / 2;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        router.setPullAmountOverride(amountToPull);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidRouter.UnexpectedTokenRefund.selector,
                tokenAmount,
                tokenAmount - amountToPull
            )
        );

        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1, // minEthOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    function testSellRevertsOnFeeOnTransferToken() public {
        uint256 tokenAmount = 1000e18;

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

        fot.mint(user1, tokenAmount);
        vm.prank(user1);
        fot.approve(address(fotLiquidRouter), tokenAmount);

        bytes memory routeData = abi.encodeWithSelector(
            fotRouter.execute.selector,
            "",
            new bytes[](0),
            block.timestamp
        );

        uint256 expectedReceived = tokenAmount -
            ((tokenAmount * fot.FEE_BPS()) / 10_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidRouter.FeeOnTransferDetected.selector,
                tokenAmount,
                expectedReceived
            )
        );

        vm.prank(user1);
        fotLiquidRouter.sell(
            address(fot),
            tokenAmount,
            user1,
            referrer,
            1, // minEthOut (must be > 0)
            routeData,
            block.timestamp + 1 hours
        );
    }

    function testSellRevertsOnExpiredDeadline() public {
        uint256 tokenAmount = 1000e18;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(ILiquidRouter.DeadlineExpired.selector);
        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1, // minEthOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp - 1 hours
            ),
            block.timestamp - 1 // Expired
        );
    }

    function testSellHandlesMaxDeadline() public {
        uint256 tokenAmount = 1000e18;
        uint256 maxDeadline = type(uint256).max;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        uint256 grossEth = (tokenAmount * 1e18) / router.tokenPerEth();
        uint256 fee = (grossEth * TOTAL_FEE_BPS) / 10000;
        uint256 expectedEth = grossEth - fee;

        uint256 balBefore = user1.balance;

        vm.prank(user1);
        uint256 ethReceived = liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1, // minEthOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            maxDeadline
        );

        assertEq(ethReceived, expectedEth);
        assertEq(user1.balance - balBefore, expectedEth);
    }

    function testSellRevertsOnEmptyRouteData() public {
        uint256 tokenAmount = 1000e18;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.expectRevert(ILiquidRouter.InvalidRouteData.selector);
        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1, // minEthOut (must be > 0)
            "", // Empty routeData
            block.timestamp + 1 hours
        );
    }

    function testSellToDifferentRecipient() public {
        uint256 tokenAmount = 1000e18;
        uint256 user2EthBefore = user2.balance;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.prank(user1);
        uint256 ethReceived = liquidRouter.sell(
            address(token),
            tokenAmount,
            user2, // recipient is user2
            referrer,
            1,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        assertEq(user2.balance - user2EthBefore, ethReceived);
    }

    function testSellMinEthOutIsGrossAmount() public {
        uint256 tokenAmount = 1000e18;
        uint256 grossEth = (tokenAmount * 1e18) / router.tokenPerEth();
        uint256 minEthOut = grossEth;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.prank(user1);
        uint256 ethReceived = liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            minEthOut,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        uint256 fee = (grossEth * TOTAL_FEE_BPS) / 10000;
        assertEq(ethReceived, grossEth - fee);
    }

    function testSellSlippageWithGrossMinEthOut() public {
        uint256 tokenAmount = 1000e18;
        uint256 grossEth = (tokenAmount * 1e18) / router.tokenPerEth();
        uint256 minEthOut = grossEth + 1;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.expectRevert(ILiquidRouter.SlippageExceeded.selector);
        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            minEthOut,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    function test_Sell_SetsPermit2ApprovalBeforeSwap() public {
        address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        MockPermit2ForRouter permit2 = MockPermit2ForRouter(PERMIT2);

        uint256 tokenAmount = 1000e18;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        (uint160 amountBefore, , ) = permit2.allowance(
            user1,
            address(token),
            address(router)
        );
        assertEq(amountBefore, 0, "Permit2 approval should be zero before sell");

        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        (uint160 amountAfter, , ) = permit2.allowance(
            user1,
            address(token),
            address(router)
        );
        assertEq(amountAfter, 0, "Permit2 approval should be cleared after sell");
    }

    function test_Sell_ClearsPermit2ApprovalAfterSuccess() public {
        address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        MockPermit2ForRouter permit2 = MockPermit2ForRouter(PERMIT2);

        uint256 tokenAmount = 1000e18;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        (uint160 amount, , ) = permit2.allowance(
            user1,
            address(token),
            address(router)
        );
        assertEq(amount, 0, "Permit2 approval must be cleared after sell");
    }

    function test_Sell_ClearsTokenApprovalAfterSuccess() public {
        uint256 tokenAmount = 1000e18;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        uint256 approvalBefore = token.allowance(user1, address(liquidRouter));
        assertGt(approvalBefore, 0, "Approval should be set before sell");

        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        uint256 approvalAfter = token.allowance(user1, address(liquidRouter));
        assertLe(
            approvalAfter,
            approvalBefore - tokenAmount,
            "Approval should be reduced"
        );
    }

    function test_Sell_SucceedsWithPreexistingETH() public {
        uint256 forcedEth = 1;
        vm.deal(user2, 100 ether);
        vm.prank(user2);
        (bool sent, ) = address(liquidRouter).call{value: forcedEth}("");
        assertTrue(sent);
        assertEq(address(liquidRouter).balance, forcedEth);

        uint256 tokenAmount = 1000e18;
        uint256 grossEthOut = (tokenAmount * 1e18) / router.tokenPerEth();
        uint256 expectedFee = (grossEthOut * TOTAL_FEE_BPS) / 10000;
        uint256 expectedEthOut = grossEthOut - expectedFee;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        uint256 user1EthBefore = user1.balance;
        vm.prank(user1);
        uint256 ethReceived = liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            grossEthOut,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        assertEq(ethReceived, expectedEthOut);
        assertEq(user1.balance - user1EthBefore, expectedEthOut);
        assertEq(address(liquidRouter).balance, forcedEth);
    }

    function test_Sell_ReceivesUnexpectedETHFromRouterWithoutRevert() public {
        MockUniversalRouterWithSellETHRefundForRouter refundRouter = new MockUniversalRouterWithSellETHRefundForRouter(
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

        uint256 tokenAmount = 1000e18;
        uint256 grossEthOut = (tokenAmount * 1e18) / refundRouter.tokenPerEth();
        uint256 unexpectedEthRefund = 1 wei;
        uint256 expectedGross = grossEthOut + unexpectedEthRefund;
        uint256 expectedFee = (expectedGross * TOTAL_FEE_BPS) / 10000;
        uint256 expectedEthOut = expectedGross - expectedFee;

        refundRouter.setShouldRefund(true);
        refundRouter.setRefundAmount(unexpectedEthRefund);

        vm.prank(user1);
        token.approve(address(refundRouterInstance), tokenAmount);

        vm.prank(user1);
        uint256 ethReceived = refundRouterInstance.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            expectedGross,
            abi.encodeWithSelector(
                refundRouter.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        assertEq(ethReceived, expectedEthOut);
        assertEq(address(refundRouterInstance).balance, forcedEth);
    }
}
