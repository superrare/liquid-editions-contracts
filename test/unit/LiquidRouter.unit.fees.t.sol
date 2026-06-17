// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {GasHogRecipientForRouter, LiquidRouterUnitTestBase, MockUniversalRouterForRouter, RejectingRecipientForRouter} from "liquid-editions-test/unit/LiquidRouter.unit.base.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";

/// @title LiquidRouter Routing Unit Tests
/// @notice Verifies core routing behavior. Fees are no longer collected at the router level;
///         they are skimmed at the V4 pool level by LiquidGuard. These tests verify that
///         the full input amount is routed and output is delivered to the recipient.
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

    // ============================================
    // Routing correctness (no ETH fee deducted at router)
    // ============================================

    function test_Buy_FullEthRoutedToSwap() public {
        uint256 ethAmount = 1 ether;
        uint256 routerEthBefore = address(liquidRouter).balance;

        vm.prank(user1);
        uint256 tokensReceived = _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            1,
            ethAmount
        );

        // No ETH should remain in the router after a buy
        assertEq(address(liquidRouter).balance, routerEthBefore, "No ETH should remain in router");
        // Tokens should have been minted to user
        assertGt(tokensReceived, 0, "Should receive tokens");
    }

    function test_Sell_FullEthReturnedToRecipient() public {
        uint256 tokenAmount = 1000e18;
        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        uint256 ethBefore = user1.balance;
        vm.prank(user1);
        uint256 ethReceived = _sellWithValidRoute(
            liquidRouter,
            address(token),
            tokenAmount,
            user1,
            1
        );

        assertGt(ethReceived, 0, "Should receive ETH from sell");
        assertEq(user1.balance, ethBefore + ethReceived, "Recipient should receive full ETH");
    }

    function test_Buy_RouterTokenBalanceZero() public {
        vm.prank(user1);
        _buyWithValidRoute(liquidRouter, address(token), user1, 1, 1 ether);
        assertEq(token.balanceOf(address(liquidRouter)), 0, "No tokens should remain in router");
    }

    function test_Sell_RouterTokenBalanceZero() public {
        uint256 tokenAmount = 1000e18;
        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.prank(user1);
        _sellWithValidRoute(liquidRouter, address(token), tokenAmount, user1, 1);

        assertEq(token.balanceOf(address(liquidRouter)), 0, "No tokens should remain in router");
    }

    function test_NewRouterCanBeDeployedAndUsed() public {
        LiquidRouter customRouter = deployLiquidRouter(
            address(router),
            protocolFeeRecipient,
            admin
        );
        vm.prank(admin);
        liquidRegistry.setBeneficiary(address(token), beneficiary);

        vm.prank(user1);
        uint256 tokensReceived = _buyWithValidRoute(
            customRouter,
            address(token),
            user1,
            1,
            1 ether
        );
        assertGt(tokensReceived, 0);
    }

    function test_NoBeneficiaryReverts() public {
        MockERC20 newToken = new MockERC20();
        MockUniversalRouterForRouter newRouter = new MockUniversalRouterForRouter(address(newToken));
        vm.deal(address(newRouter), 1000 ether);

        deployLiquidRouter(
            address(newRouter),
            protocolFeeRecipient,
            admin
        );

        vm.expectRevert(ILiquidRegistry.ZeroAddress.selector);
        vm.prank(admin);
        liquidRegistry.setBeneficiary(address(newToken), address(0));
    }

    function testFuzz_Buy_NoStuckEth(uint256 msgValue) public {
        msgValue = bound(msgValue, 1 wei, 100 ether);

        uint256 routerBalBefore = address(liquidRouter).balance;
        vm.prank(user1);
        _buyWithValidRoute(liquidRouter, address(token), user1, 1, msgValue);
        assertEq(address(liquidRouter).balance, routerBalBefore, "No ETH should remain in router");
    }

    function testFuzz_Sell_NoStuckTokens(uint256 tokenAmount) public {
        tokenAmount = bound(tokenAmount, 1e6, 1000e18);

        token.mint(user1, tokenAmount);

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.prank(user1);
        _sellWithValidRoute(liquidRouter, address(token), tokenAmount, user1, 1);

        assertEq(token.balanceOf(address(liquidRouter)), 0, "No tokens should remain in router after sell");
    }

    function testFuzz_Buy_TokensReceivedMatchRate(uint256 msgValue) public {
        msgValue = bound(msgValue, 1 wei, 10 ether);

        uint256 expectedTokens = (msgValue * router.tokenPerEth()) / 1e18;

        vm.prank(user1);
        uint256 tokensReceived = _buyWithValidRoute(liquidRouter, address(token), user1, 1, msgValue);

        assertEq(tokensReceived, expectedTokens, "tokens received should match mock rate");
    }

    function testFuzz_Sell_EthReceivedMatchesRate(uint256 tokenAmount) public {
        tokenAmount = bound(tokenAmount, 1e6, 1000e18);

        uint256 expectedEth = (tokenAmount * 1e18) / router.tokenPerEth();

        token.mint(user1, tokenAmount);
        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.prank(user1);
        uint256 ethReceived = _sellWithValidRoute(liquidRouter, address(token), tokenAmount, user1, 1);

        assertEq(ethReceived, expectedEth, "ETH received should match mock rate");
    }

    function testFuzz_Buy_SlippageCheck(uint256 msgValue, uint256 minTokensOut) public {
        msgValue = bound(msgValue, 1 wei, 10 ether);
        uint256 expectedTokens = (msgValue * router.tokenPerEth()) / 1e18;
        minTokensOut = bound(minTokensOut, 1, expectedTokens); // valid range: 1 to expected

        vm.prank(user1);
        uint256 tokensReceived = _buyWithValidRoute(liquidRouter, address(token), user1, minTokensOut, msgValue);

        assertGe(tokensReceived, minTokensOut, "tokens received must be >= minTokensOut");
    }

    function testFuzz_Sell_SlippageCheck(uint256 tokenAmount, uint256 minEthOut) public {
        tokenAmount = bound(tokenAmount, 1e6, 1000e18);
        uint256 expectedEth = (tokenAmount * 1e18) / router.tokenPerEth();
        minEthOut = bound(minEthOut, 1, expectedEth);

        token.mint(user1, tokenAmount);
        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        (bytes memory commands, bytes[] memory inputs) = _validRoute();
        vm.prank(user1);
        uint256 ethReceived = liquidRouter.sell(
            address(token), tokenAmount, user1, minEthOut, commands, inputs, block.timestamp + 1 hours
        );

        assertGe(ethReceived, minEthOut, "ETH received must be >= minEthOut");
    }

    function test_Buy_SucceedsAfterBeneficiaryUpdate() public {
        uint256 routerBalBefore = address(liquidRouter).balance;
        vm.prank(user1);
        uint256 firstSwapTokens = _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            1,
            1 ether
        );

        assertGt(firstSwapTokens, 0);
        assertEq(liquidRegistry.beneficiaryOf(address(token)), beneficiary);

        address nextBeneficiary = makeAddr("nextBeneficiary");
        vm.prank(admin);
        liquidRegistry.setBeneficiary(address(token), nextBeneficiary);
        assertEq(liquidRegistry.beneficiaryOf(address(token)), nextBeneficiary);

        vm.prank(user1);
        uint256 secondSwapTokens = _buyWithValidRoute(
            liquidRouter,
            address(token),
            user1,
            1,
            1 ether
        );

        assertGt(secondSwapTokens, 0);
        assertEq(address(liquidRouter).balance, routerBalBefore, "No ETH should remain in router");
        assertTrue(token.balanceOf(address(liquidRouter)) == 0, "No tokens should remain in router");
    }
}
