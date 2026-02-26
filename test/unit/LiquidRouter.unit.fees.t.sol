// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {GasHogRecipientForRouter, LiquidRouterUnitTestBase, MockUniversalRouterForRouter, RejectingRecipientForRouter} from "liquid-editions-test/unit/LiquidRouter.unit.base.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";

/// @title LiquidRouter Fees Unit Tests
/// @notice Fee rounding, beneficiary
contract LiquidRouterUnitFeesTest is LiquidRouterUnitTestBase {
    function _buyWithValidRoute(
        LiquidRouter targetRouter,
        address tradeToken,
        address recipient,
        uint256 minTokensOut,
        uint256 ethAmount
    ) internal returns (uint256 tokensReceived) {
        (bytes memory commands, bytes[] memory inputs) = _validRoute();
        return
            targetRouter.buy{value: ethAmount}(
                tradeToken,
                recipient,
                minTokensOut,
                commands,
                inputs,
                block.timestamp + 1 hours
            );
    }

    function _sellWithValidRoute(
        LiquidRouter targetRouter,
        address tradeToken,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut
    ) internal returns (uint256 ethReceived) {
        (bytes memory commands, bytes[] memory inputs) = _validRoute();
        return
            targetRouter.sell(
                tradeToken,
                tokenAmount,
                recipient,
                minEthOut,
                commands,
                inputs,
                block.timestamp + 1 hours
            );
    }

    function testQuoteFeeBreakdown() public view {
        uint256 totalFee = 1 ether;
        (
            uint256 beneficiaryFee,
            uint256 protocolFee
        ) = liquidRouter.quoteFeeBreakdown(totalFee);

        assertEq(beneficiaryFee + protocolFee, totalFee);
        assertGt(beneficiaryFee, 0);
        assertGt(protocolFee, 0);
    }

    function testFeeConfigUpdatedOnRouter() public {
        LiquidRouter customRouter = deployLiquidRouter(
            address(router),
            protocolFeeRecipient,
            admin
        );
        vm.prank(admin);
        customRouter.registerToken(address(token), beneficiary);

        uint256 ethAmount = 1 ether;

        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        _buyWithValidRoute(
            customRouter,
            address(token),
            user1,
            1,
            ethAmount
        );

        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testNoBeneficiaryReverts() public {
        MockERC20 newToken = new MockERC20();
        MockUniversalRouterForRouter newRouter = new MockUniversalRouterForRouter(address(newToken));
        vm.deal(address(newRouter), 1000 ether);

        LiquidRouter newLiquidRouter = deployLiquidRouter(
            address(newRouter),
            protocolFeeRecipient,
            admin
        );

        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(admin);
        newLiquidRouter.registerToken(address(newToken), address(0)); // No beneficiary - contract requires non-zero
    }

    function testBeneficiaryTransferFailureFallsBackToProtocol() public {
        RejectingRecipientForRouter rejecter = new RejectingRecipientForRouter();

        MockERC20 newToken = new MockERC20();
        MockUniversalRouterForRouter newRouter = new MockUniversalRouterForRouter(
            address(newToken)
        );
        vm.deal(address(newRouter), 100 ether);

        LiquidRouter newLiquidRouter = deployLiquidRouter(
            address(newRouter),
            protocolFeeRecipient,
            admin
        );

        vm.prank(admin);
        newLiquidRouter.registerToken(address(newToken), address(rejecter));

        newToken.mint(user1, 10000e18);

        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        _buyWithValidRoute(
            newLiquidRouter,
            address(newToken),
            user1,
            1,
            1 ether
        );

        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testBeneficiaryTransferGasHogFallsBackToProtocol() public {
        GasHogRecipientForRouter gasHog = new GasHogRecipientForRouter();

        vm.prank(admin);
        liquidRouter.updateBeneficiary(address(token), address(gasHog));

        uint256 ethAmount = 1 ether;
        uint256 totalFee = (ethAmount * _totalFeeBpsForRouter(liquidRouter)) /
            10000;
        (
            uint256 beneficiaryFee,
            uint256 protocolFee
        ) = liquidRouter.quoteFeeBreakdown(totalFee);
        uint256 feeSum = beneficiaryFee + protocolFee;

        uint256 protocolBalBefore = protocolFeeRecipient.balance;
        uint256 routerBalBefore = address(liquidRouter).balance;

        vm.prank(user1);
        _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            1,
            ethAmount
        );

        uint256 protocolBalAfter = protocolFeeRecipient.balance;
        uint256 expectedProtocolShare = protocolFee + beneficiaryFee;

        assertEq(protocolBalAfter - protocolBalBefore, expectedProtocolShare);
        assertEq(feeSum, totalFee);
        assertEq(
            address(liquidRouter).balance,
            routerBalBefore,
            "No ETH should remain in router after trade"
        );
    }

    function testRouterBalanceZeroAfterBuy() public {
        uint256 ethAmount = 1 ether;
        uint256 routerBalanceBefore = address(liquidRouter).balance;

        vm.prank(user1);
        _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            1,
            ethAmount
        );

        assertEq(address(liquidRouter).balance, routerBalanceBefore);
    }

    function testRouterTokenBalanceZeroAfterSell() public {
        uint256 tokenAmount = 1000e18;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.prank(user1);
        _sellWithValidRoute(
            liquidRouter,
            address(token),
            tokenAmount,
            user1,
            1
        );

        assertEq(token.balanceOf(address(liquidRouter)), 0);
    }

    function testFeeAccountingInvariant_RandomAmounts() public view {
        for (uint256 i = 0; i < 10; i++) {
            uint256 totalFee = (uint256(1 + i) * 1 ether * TOTAL_FEE_BPS) / 10000;
            (
                uint256 beneficiaryFee,
                uint256 protocolFee
            ) = liquidRouter.quoteFeeBreakdown(totalFee);

            uint256 sumOfFees = beneficiaryFee + protocolFee;
            assertEq(sumOfFees, totalFee, "Sum of fees must equal totalFee");
        }
    }

    function testFeeAccountingInvariant_EdgeCases() public view {
        uint256 smallAmount = 1 wei;
        uint256 smallTotalFee = (smallAmount * TOTAL_FEE_BPS) / 10000;

        (
            uint256 beneficiaryFee,
            uint256 protocolFee
        ) = liquidRouter.quoteFeeBreakdown(smallTotalFee);

        uint256 sumOfFees = beneficiaryFee + protocolFee;
        assertEq(sumOfFees, smallTotalFee, "Fee accounting must work for very small amounts");

        uint256 largeAmount = 1000 ether;
        uint256 largeTotalFee = (largeAmount * TOTAL_FEE_BPS) / 10000;

        (beneficiaryFee, protocolFee) = liquidRouter
            .quoteFeeBreakdown(largeTotalFee);

        sumOfFees = beneficiaryFee + protocolFee;
        assertEq(sumOfFees, largeTotalFee, "Fee accounting must work for very large amounts");
    }

    function testFuzz_FeeAccounting_NoStuckETH(uint256 msgValue) public {
        if (msgValue > 100 ether || msgValue == 0) return;
        msgValue = bound(msgValue, 1 wei, 100 ether);

        uint256 routerBalanceBefore = address(liquidRouter).balance;

        vm.prank(user1);
        _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            1,
            msgValue
        );

        assertEq(address(liquidRouter).balance, routerBalanceBefore);
    }

    function testFuzz_FeeAccounting_AllFeesAccountedFor(uint256 msgValue) public view {
        msgValue = bound(msgValue, 1 wei, 1000 ether);

        uint256 totalFee = (msgValue * TOTAL_FEE_BPS) / 10000;

        if (totalFee < 2) return;

        (
            uint256 beneficiaryFee,
            uint256 protocolFee
        ) = liquidRouter.quoteFeeBreakdown(totalFee);

        uint256 sumOfFees = beneficiaryFee + protocolFee;

        assertLe(sumOfFees, totalFee, "Sum of fees should not exceed total fee");

        uint256 tolerance = totalFee < 100 ? totalFee : 3;
        assertGe(
            sumOfFees,
            totalFee > tolerance ? totalFee - tolerance : 0,
            "Sum should be within tolerance of total fee"
        );
    }

    function test_Buy_ProtocolReceivesFees() public {
        uint256 protocolBalanceBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            1,
            1 ether
        );

        uint256 protocolBalanceAfter = protocolFeeRecipient.balance;
        uint256 received = protocolBalanceAfter - protocolBalanceBefore;

        uint256 totalFee = (1 ether * TOTAL_FEE_BPS) / 10000;
        (, uint256 protocolFee) = liquidRouter
            .quoteFeeBreakdown(totalFee);

        assertGe(received, protocolFee - 3, "Should receive protocol fees");
        assertLe(received, protocolFee + 3, "Should receive protocol fees");
    }

    function test_Sell_ProtocolGetsShare() public {
        uint256 tokenAmount = 1000e18;
        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        uint256 protocolBalanceBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        _sellWithValidRoute(
            liquidRouter,
            address(token),
            tokenAmount,
            user1,
            1
        );

        uint256 protocolBalanceAfter = protocolFeeRecipient.balance;
        uint256 received = protocolBalanceAfter - protocolBalanceBefore;

        uint256 ethReceived = (tokenAmount * 1e18) / router.tokenPerEth();
        uint256 totalFee = (ethReceived * TOTAL_FEE_BPS) / 10000;
        (, uint256 protocolFee) = liquidRouter
            .quoteFeeBreakdown(totalFee);

        assertGe(received, protocolFee - 3, "Should receive protocol fees");
        assertLe(received, protocolFee + 3, "Should receive protocol fees");
    }
}
