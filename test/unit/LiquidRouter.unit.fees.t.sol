// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {GasHogRecipientForRouter, LiquidRouterUnitTestBase, MockUniversalRouterForRouter, RejectingRecipientForRouter} from "liquid-editions-test/unit/LiquidRouter.unit.base.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";

/// @title LiquidRouter Fees Unit Tests
/// @notice Fee rounding, referrer, beneficiary
contract LiquidRouterUnitFeesTest is LiquidRouterUnitTestBase {
    function _buyWithValidRoute(
        LiquidRouter targetRouter,
        address tradeToken,
        address recipient,
        address referrer_,
        uint256 minTokensOut,
        uint256 ethAmount
    ) internal returns (uint256 tokensReceived) {
        (bytes memory commands, bytes[] memory inputs) = _validRoute();
        return
            targetRouter.buy{value: ethAmount}(
                tradeToken,
                recipient,
                referrer_,
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
        address referrer_,
        uint256 minEthOut
    ) internal returns (uint256 ethReceived) {
        (bytes memory commands, bytes[] memory inputs) = _validRoute();
        return
            targetRouter.sell(
                tradeToken,
                tokenAmount,
                recipient,
                referrer_,
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
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 burnFee
        ) = liquidRouter.quoteFeeBreakdown(totalFee);

        assertEq(beneficiaryFee, (totalFee * 2500) / 10000);

        uint256 remainder = totalFee - beneficiaryFee;
        assertEq(burnFee, (remainder * RARE_BURN_FEE_BPS) / 10000);
        assertEq(referrerFee, (remainder * REFERRER_FEE_BPS) / 10000);
        assertTrue(protocolFee >= (remainder * PROTOCOL_FEE_BPS) / 10000);
    }

    function testFeeConfigUpdatedOnRouter() public {
        LiquidRouter customRouter = deployLiquidRouter(
            address(router),
            protocolFeeRecipient,
            address(burner),
            4000, // rareBurnFeeBPS (40%)
            4000, // protocolFeeBPS (40%)
            2000, // referrerFeeBPS (20%)
            admin
        );
        vm.prank(admin);
        customRouter.registerToken(address(token), beneficiary);

        uint256 ethAmount = 1 ether;
        uint256 totalFee = (ethAmount * TOTAL_FEE_BPS) / 10000; // 4%

        uint256 protocolBalBefore = protocolFeeRecipient.balance;
        uint256 burnerBalBefore = burner.deposited();

        vm.prank(user1);
        _buyWithValidRoute(
            customRouter,
            address(token),
            user1,
            referrer,
            1,
            ethAmount
        );

        uint256 beneficiaryFee = (totalFee * 2500) / 10000; // 25%
        uint256 remainingFee = totalFee - beneficiaryFee;
        uint256 expectedBurnFee = (remainingFee * 4000) / 10000; // 40% of remainder

        assertEq(burner.deposited() - burnerBalBefore, expectedBurnFee);
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testBurnerFailureFallsBackToProtocol() public {
        burner.setShouldFail(true);

        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            referrer,
            1,
            1 ether
        );

        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testNoBurnerConfiguredReverts() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        deployLiquidRouter(
            address(router),
            protocolFeeRecipient,
            address(0), // No burner - contract requires non-zero
            RARE_BURN_FEE_BPS,
            PROTOCOL_FEE_BPS,
            REFERRER_FEE_BPS,
            admin
        );
    }

    function testNoBeneficiaryReverts() public {
        MockERC20 newToken = new MockERC20();
        MockUniversalRouterForRouter newRouter = new MockUniversalRouterForRouter(address(newToken));
        vm.deal(address(newRouter), 1000 ether);

        LiquidRouter newLiquidRouter = deployLiquidRouter(
            address(newRouter),
            protocolFeeRecipient,
            address(burner),
            RARE_BURN_FEE_BPS,
            PROTOCOL_FEE_BPS,
            REFERRER_FEE_BPS,
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
            address(burner),
            RARE_BURN_FEE_BPS,
            PROTOCOL_FEE_BPS,
            REFERRER_FEE_BPS,
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
            referrer,
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
        uint256 totalFee = (ethAmount * liquidRouter.TOTAL_FEE_BPS()) /
            10000;
        (
            uint256 beneficiaryFee,
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 burnFee
        ) = liquidRouter.quoteFeeBreakdown(totalFee);
        uint256 feeSum = beneficiaryFee + protocolFee + referrerFee + burnFee;

        uint256 protocolBalBefore = protocolFeeRecipient.balance;
        uint256 routerBalBefore = address(liquidRouter).balance;

        vm.prank(user1);
        _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            address(0),
            1,
            ethAmount
        );

        uint256 protocolBalAfter = protocolFeeRecipient.balance;
        uint256 expectedProtocolShare = protocolFee + beneficiaryFee + referrerFee;

        assertEq(protocolBalAfter - protocolBalBefore, expectedProtocolShare);
        assertEq(feeSum, totalFee);
        assertEq(
            address(liquidRouter).balance,
            routerBalBefore,
            "No ETH should remain in router after trade"
        );
    }

    function testReferrerTransferGasHogFallsBackToProtocol() public {
        GasHogRecipientForRouter gasHog = new GasHogRecipientForRouter();

        MockERC20 customToken = new MockERC20();
        MockUniversalRouterForRouter customRouter = new MockUniversalRouterForRouter(
            address(customToken)
        );
        vm.deal(address(customRouter), 100 ether);

        LiquidRouter referrerFallbackRouter = deployLiquidRouter(
            address(customRouter),
            protocolFeeRecipient,
            address(burner),
            5000, // all remaining fee goes to burn + referrer split
            0, // protocol gets redirected referrer share on failure
            5000,
            admin
        );

        vm.prank(admin);
        referrerFallbackRouter.registerToken(address(customToken), beneficiary);

        uint256 ethAmount = 1 ether;
        uint256 totalFee = (ethAmount * liquidRouter.TOTAL_FEE_BPS()) / 10000;
        uint256 ignoredBeneficiary;
        uint256 ignoredProtocol;
        uint256 ignoredBurn;
        uint256 expectedRedirectedReferrerFee;
        (
            ignoredBeneficiary,
            ignoredProtocol,
            expectedRedirectedReferrerFee,
            ignoredBurn
        ) = referrerFallbackRouter.quoteFeeBreakdown(totalFee);
        uint256 referrerFeeComponents = ignoredBeneficiary +
            ignoredProtocol +
            expectedRedirectedReferrerFee +
            ignoredBurn;

        uint256 protocolBalBefore = protocolFeeRecipient.balance;
        uint256 routerBalBefore = address(referrerFallbackRouter).balance;

        vm.prank(user1);
        _buyWithValidRoute(
            referrerFallbackRouter,
            address(customToken),
            user1,
            address(gasHog),
            1,
            ethAmount
        );

        uint256 protocolBalAfter = protocolFeeRecipient.balance;

        assertEq(
            protocolBalAfter - protocolBalBefore,
            expectedRedirectedReferrerFee,
            "protocol should receive referrer share when referrer is gas-hog"
        );
        assertEq(referrerFeeComponents, totalFee);
        assertEq(
            address(referrerFallbackRouter).balance,
            routerBalBefore,
            "No ETH should remain in router after trade"
        );
    }

    function testReferrerTransferFailureFallsBackToProtocol() public {
        RejectingRecipientForRouter rejecter = new RejectingRecipientForRouter();

        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            address(rejecter),
            1,
            1 ether
        );

        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testZeroReferrerDefaultsToProtocol() public {
        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            address(0), // No referrer
            1,
            1 ether
        );

        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testNoDoubleTransferWhenReferrerIsZero() public {
        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            address(0),
            1,
            1 ether
        );

        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testNoDoubleTransferWhenReferrerIsProtocol() public {
        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            protocolFeeRecipient,
            1,
            1 ether
        );

        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testRouterBalanceZeroAfterBuy() public {
        uint256 ethAmount = 1 ether;
        uint256 routerBalanceBefore = address(liquidRouter).balance;

        vm.prank(user1);
        _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            referrer,
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
            referrer,
            1
        );

        assertEq(token.balanceOf(address(liquidRouter)), 0);
    }

    function testFeeAccountingInvariant_RandomAmounts() public view {
        for (uint256 i = 0; i < 10; i++) {
            uint256 totalFee = (uint256(1 + i) * 1 ether * TOTAL_FEE_BPS) / 10000;
            (
                uint256 beneficiaryFee,
                uint256 protocolFee,
                uint256 referrerFee,
                uint256 burnFee
            ) = liquidRouter.quoteFeeBreakdown(totalFee);

            uint256 sumOfFees = beneficiaryFee + protocolFee + referrerFee + burnFee;
            assertEq(sumOfFees, totalFee, "Sum of fees must equal totalFee");
        }
    }

    function testFeeAccountingInvariant_RandomFeeSplits() public {
        uint256[] memory rareBurnBPS = new uint256[](3);
        rareBurnBPS[0] = 3000;
        rareBurnBPS[1] = 5000;
        rareBurnBPS[2] = 7000;

        for (uint256 i = 0; i < rareBurnBPS.length; i++) {
            uint256 rb = rareBurnBPS[i];
            uint256 pp = (10000 - rb) / 2;
            uint256 rf = 10000 - rb - pp;

            LiquidRouter testRouter = deployLiquidRouter(
                address(router),
                protocolFeeRecipient,
                address(burner),
                rb,
                pp,
                rf,
                admin
            );
            vm.prank(admin);
            testRouter.registerToken(address(token), beneficiary);

            uint256 totalFee = 1 ether;
            (
                uint256 beneficiaryFee,
                uint256 protocolFee,
                uint256 referrerFee,
                uint256 burnFee
            ) = testRouter.quoteFeeBreakdown(totalFee);

            uint256 sumOfFees = beneficiaryFee + protocolFee + referrerFee + burnFee;
            assertEq(sumOfFees, totalFee, "Sum of fees must equal totalFee for all configs");
        }
    }

    function testFeeAccountingInvariant_EdgeCases() public view {
        uint256 smallAmount = 1 wei;
        uint256 smallTotalFee = (smallAmount * TOTAL_FEE_BPS) / 10000;

        (
            uint256 beneficiaryFee,
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 burnFee
        ) = liquidRouter.quoteFeeBreakdown(smallTotalFee);

        uint256 sumOfFees = beneficiaryFee + protocolFee + referrerFee + burnFee;
        assertEq(sumOfFees, smallTotalFee, "Fee accounting must work for very small amounts");

        uint256 largeAmount = 1000 ether;
        uint256 largeTotalFee = (largeAmount * TOTAL_FEE_BPS) / 10000;

        (beneficiaryFee, protocolFee, referrerFee, burnFee) = liquidRouter
            .quoteFeeBreakdown(largeTotalFee);

        sumOfFees = beneficiaryFee + protocolFee + referrerFee + burnFee;
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
            referrer,
            1,
            msgValue
        );

        assertEq(address(liquidRouter).balance, routerBalanceBefore);
    }

    function testFuzz_FeeAccounting_AllFeesAccountedFor(uint256 msgValue) public view {
        msgValue = bound(msgValue, 1 wei, 1000 ether);

        uint256 totalFee = (msgValue * TOTAL_FEE_BPS) / 10000;

        if (totalFee < 4) return;

        (
            uint256 beneficiaryFee,
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 burnFee
        ) = liquidRouter.quoteFeeBreakdown(totalFee);

        uint256 sumOfFees = beneficiaryFee + protocolFee + referrerFee + burnFee;

        assertLe(sumOfFees, totalFee, "Sum of fees should not exceed total fee");

        uint256 tolerance = totalFee < 100 ? totalFee : 3;
        assertGe(
            sumOfFees,
            totalFee > tolerance ? totalFee - tolerance : 0,
            "Sum should be within tolerance of total fee"
        );
    }

    function test_Buy_WhenReferrerIsProtocolFeeRecipient_NoDoubleTransfer() public {
        address referrerAsProtocol = protocolFeeRecipient;

        uint256 protocolBalanceBefore = referrerAsProtocol.balance;

        vm.prank(user1);
        _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            referrerAsProtocol,
            1,
            1 ether
        );

        uint256 protocolBalanceAfter = referrerAsProtocol.balance;
        uint256 received = protocolBalanceAfter - protocolBalanceBefore;

        uint256 totalFee = (1 ether * TOTAL_FEE_BPS) / 10000;
        (, uint256 protocolFee, uint256 referrerFee, ) = liquidRouter
            .quoteFeeBreakdown(totalFee);

        uint256 expected = protocolFee + referrerFee;

        assertGe(received, expected - 3, "Should receive protocol + referrer fees");
        assertLe(received, expected + 3, "Should receive protocol + referrer fees");
    }

    function test_Sell_WhenReferrerIsProtocolFeeRecipient_ProtocolGetsShare() public {
        address referrerAsProtocol = protocolFeeRecipient;

        uint256 tokenAmount = 1000e18;
        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        uint256 protocolBalanceBefore = referrerAsProtocol.balance;

        vm.prank(user1);
        _sellWithValidRoute(
            liquidRouter,
            address(token),
            tokenAmount,
            user1,
            referrerAsProtocol,
            1
        );

        uint256 protocolBalanceAfter = referrerAsProtocol.balance;
        uint256 received = protocolBalanceAfter - protocolBalanceBefore;

        uint256 ethReceived = (tokenAmount * 1e18) / router.tokenPerEth();
        uint256 totalFee = (ethReceived * TOTAL_FEE_BPS) / 10000;
        (, uint256 protocolFee, uint256 referrerFee, ) = liquidRouter
            .quoteFeeBreakdown(totalFee);

        uint256 expected = protocolFee + referrerFee;

        assertGe(received, expected - 3, "Should receive protocol + referrer fees");
        assertLe(received, expected + 3, "Should receive protocol + referrer fees");
    }
}
