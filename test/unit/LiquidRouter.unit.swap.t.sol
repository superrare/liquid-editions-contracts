// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BoundaryConstants} from "liquid-editions-test/helpers/bases/BoundaryConstants.sol";
import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";
import {LiquidRouterUnitTestBase, MockUniversalRouterForRouter, MockUniversalRouterWithRefundForRouter} from "liquid-editions-test/unit/LiquidRouter.unit.base.sol";

/// @title LiquidRouter Swap Unit Tests
/// @notice Swap (two-leg) flow and edge cases
contract LiquidRouterUnitSwapTest is LiquidRouterUnitTestBase {
    MockERC20 public tokenB;

    function setUp() public override {
        super.setUp();
        tokenB = new MockERC20();
        vm.prank(admin);
        liquidRegistry.setBeneficiary(address(tokenB), beneficiary);
    }

    function _mergeRoutes(
        bytes memory leg1Commands,
        bytes[] memory leg1Inputs,
        bytes memory leg2Commands,
        bytes[] memory leg2Inputs
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        commands = bytes.concat(leg1Commands, leg2Commands);
        inputs = new bytes[](leg1Inputs.length + leg2Inputs.length);
        uint256 idx;
        for (uint256 i = 0; i < leg1Inputs.length; i++) {
            inputs[idx++] = leg1Inputs[i];
        }
        for (uint256 i = 0; i < leg2Inputs.length; i++) {
            inputs[idx++] = leg2Inputs[i];
        }
    }

    function _swapVia(
        LiquidRouter targetRouter,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        address recipient,
        uint256 minAmountOut,
        bytes memory leg1Commands,
        bytes[] memory leg1Inputs,
        bytes memory leg2Commands,
        bytes[] memory leg2Inputs,
        uint256 deadline,
        uint256 ethValue
    ) internal returns (uint256 amountOut) {
        (bytes memory commands, bytes[] memory inputs) =
            _mergeRoutes(leg1Commands, leg1Inputs, leg2Commands, leg2Inputs);
        return targetRouter.swap{value: ethValue}(
            tokenIn,
            amountIn,
            tokenOut,
            recipient,
            minAmountOut,
            commands,
            inputs,
            deadline
        );
    }

    function test_Swap_RevertsWhen_EmptyRoute() public {
        vm.expectRevert(ILiquidRouter.InvalidRouteData.selector);
        _swapVia(
            liquidRouter,
            address(0), // tokenIn (ETH when leg1 empty)
            BoundaryConstants.ZERO,
            address(0), // tokenOut (ETH when leg2 empty)
            user1,
            BoundaryConstants.ONE, // minAmountOut must be > 0
            "", // leg1 empty
            new bytes[](0),
            "", // leg2 empty
            new bytes[](0),
            block.timestamp + 1 hours,
            1 ether
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
            admin
        );

        vm.prank(admin);
        liquidRegistry.setBeneficiary(address(token), beneficiary);
        vm.prank(admin);
        liquidRegistry.setBeneficiary(address(tokenB), beneficiary);

        refundRouter.setOutputToken(address(tokenB));
        refundRouter.setShouldRefund(true);
        refundRouter.setRefundAmount(0.5 ether);

        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();

        vm.prank(user1);
        token.approve(address(refundRouterInstance), 1000e18);

        vm.expectRevert(ILiquidRouter.UnexpectedEthRefund.selector);
        vm.prank(user1);
        _swapVia(
            refundRouterInstance,
            address(token),
            1000e18,
            address(tokenB),
            user1,
            1, // minAmountOut
            leg1Commands,
            leg1Inputs,
            leg2Commands,
            leg2Inputs,
            block.timestamp + 1 hours,
            0
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
            admin
        );

        vm.prank(admin);
        liquidRegistry.setBeneficiary(address(token), beneficiary);
        vm.prank(admin);
        liquidRegistry.setBeneficiary(address(tokenB), beneficiary);

        refundRouter.setOutputToken(address(tokenB));
        refundRouter.setShouldRefund(true);
        refundRouter.setRefundAmount(0.1 ether);

        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();

        vm.prank(user1);
        token.approve(address(refundRouterInstance), 1000e18);

        vm.expectRevert(ILiquidRouter.UnexpectedEthRefund.selector);
        vm.prank(user1);
        _swapVia(
            refundRouterInstance,
            address(token),
            1000e18,
            address(tokenB),
            user1,
            1, // minAmountOut
            leg1Commands,
            leg1Inputs,
            leg2Commands,
            leg2Inputs,
            block.timestamp + 1 hours,
            0
        );
    }

    function test_Swap_SucceedsWithPreexistingETH() public {
        // Simulate donation/dust: send 1 wei to router (trivial griefing vector before fix)
        vm.deal(user2, 100 ether);
        vm.prank(user2);
        (bool sent,) = address(liquidRouter).call{value: 1}("");
        assertTrue(sent);
        assertEq(address(liquidRouter).balance, 1);

        router.setOutputToken(address(tokenB));

        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();

        vm.prank(user1);
        token.approve(address(liquidRouter), 1000e18);

        vm.prank(user1);
        uint256 amountOut = _swapVia(
            liquidRouter,
            address(token),
            1000e18,
            address(tokenB),
            user1,
            1, // minAmountOut
            leg1Commands,
            leg1Inputs,
            leg2Commands,
            leg2Inputs,
            block.timestamp + 1 hours,
            0
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
            admin
        );

        vm.prank(admin);
        liquidRegistry.setBeneficiary(address(token), beneficiary);
        vm.prank(admin);
        liquidRegistry.setBeneficiary(address(tokenB), beneficiary);

        // Send 1 wei to router (pre-existing ETH)
        vm.deal(user2, 100 ether);
        vm.prank(user2);
        (bool sent,) = address(refundRouterInstance).call{value: 1}("");
        assertTrue(sent);

        refundRouter.setOutputToken(address(tokenB));
        refundRouter.setShouldRefund(true);
        refundRouter.setRefundAmount(0.5 ether);

        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();

        vm.prank(user1);
        token.approve(address(refundRouterInstance), 1000e18);

        // Refund detection should still work: revert even with pre-existing ETH
        vm.expectRevert(ILiquidRouter.UnexpectedEthRefund.selector);
        vm.prank(user1);
        _swapVia(
            refundRouterInstance,
            address(token),
            1000e18,
            address(tokenB),
            user1,
            1, // minAmountOut
            leg1Commands,
            leg1Inputs,
            leg2Commands,
            leg2Inputs,
            block.timestamp + 1 hours,
            0
        );

        assertEq(address(refundRouterInstance).balance, 1);
    }

    // ============================================
    // swap() — positive paths (ETH→ERC20, ERC20→ETH, ERC20→ERC20)
    // ============================================

    function test_Swap_EthToToken_PositivePath() public {
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();
        uint256 ethIn = 1 ether;
        uint256 expectedTokens = (ethIn * router.tokenPerEth()) / 1e18;

        uint256 user1TokensBefore = token.balanceOf(user1);

        vm.prank(user1);
        uint256 amountOut = _swapVia(
            liquidRouter,
            address(0),    // ETH input
            0,             // amountIn ignored for ETH
            address(token),
            user1,
            1,             // minAmountOut
            "",            // leg1 empty (input is already ETH)
            new bytes[](0),
            leg2Commands,
            leg2Inputs,
            block.timestamp + 1 hours,
            ethIn
        );

        assertEq(amountOut, expectedTokens, "swap: wrong tokens out");
        assertEq(token.balanceOf(user1) - user1TokensBefore, expectedTokens, "swap: token balance mismatch");
        assertEq(address(liquidRouter).balance, 0, "swap: router should not retain ETH");
    }

    function test_Swap_TokenToEth_PositivePath() public {
        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        uint256 tokenIn = 1000e18;
        uint256 expectedEth = (tokenIn * 1e18) / router.tokenPerEth();

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenIn);

        uint256 user1EthBefore = user1.balance;

        vm.prank(user1);
        uint256 amountOut = _swapVia(
            liquidRouter,
            address(token),
            tokenIn,
            address(0),    // ETH output
            user1,
            1,             // minAmountOut
            leg1Commands,
            leg1Inputs,
            "",            // leg2 empty (output is ETH)
            new bytes[](0),
            block.timestamp + 1 hours,
            0
        );

        assertEq(amountOut, expectedEth, "swap: wrong ETH out");
        assertEq(user1.balance - user1EthBefore, expectedEth, "swap: ETH balance mismatch");
        assertEq(token.balanceOf(address(liquidRouter)), 0, "swap: router should not retain tokens");
    }

    function test_Swap_TokenToToken_PositivePath() public {
        router.setOutputToken(address(tokenB));

        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();
        uint256 tokenIn = 1000e18;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenIn);

        vm.prank(user1);
        uint256 amountOut = _swapVia(
            liquidRouter,
            address(token),
            tokenIn,
            address(tokenB),
            user1,
            1,
            leg1Commands,
            leg1Inputs,
            leg2Commands,
            leg2Inputs,
            block.timestamp + 1 hours,
            0
        );

        assertGt(amountOut, 0, "swap: must receive tokens");
        assertEq(address(liquidRouter).balance, 0, "swap: no ETH retained");
    }

    // ============================================
    // swap() — event emission
    // ============================================

    function test_Swap_EthToToken_EmitsRouterSwap() public {
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();
        uint256 ethIn = 1 ether;

        vm.expectEmit(true, true, true, false);
        emit ILiquidRouter.RouterSwap(
            address(0),
            address(token),
            user1,
            user1,
            ethIn,
            0, 0, 0, 0, 0, 0
        );

        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(0),
            0,
            address(token),
            user1,
            1,
            "",
            new bytes[](0),
            leg2Commands,
            leg2Inputs,
            block.timestamp + 1 hours,
            ethIn
        );
    }

    function test_Swap_TokenToEth_EmitsRouterSwapWithExactValues() public {
        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        uint256 tokenIn = 1000e18;
        uint256 expectedEth = (tokenIn * 1e18) / router.tokenPerEth();

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenIn);

        vm.expectEmit(true, true, true, true);
        emit ILiquidRouter.RouterSwap(
            address(token),
            address(0),
            user1,
            user1,
            tokenIn,
            0,             // ethValue is 0 for ERC20→ETH swaps (no ETH sent in)
            0,
            expectedEth,
            0, 0, 0
        );

        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(token),
            tokenIn,
            address(0),
            user1,
            1,
            leg1Commands,
            leg1Inputs,
            "",
            new bytes[](0),
            block.timestamp + 1 hours,
            0
        );
    }

    // ============================================
    // swap() — revert: edge cases
    // ============================================

    function test_Swap_RevertsWhen_ZeroRecipient() public {
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(0), 0, address(token), address(0), 1,
            "", new bytes[](0), leg2Commands, leg2Inputs, block.timestamp + 1 hours, 1 ether
        );
    }

    function test_Swap_RevertsWhen_ZeroMinAmountOut() public {
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();
        vm.expectRevert(ILiquidRouter.InvalidAmount.selector);
        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(0), 0, address(token), user1, 0,
            "", new bytes[](0), leg2Commands, leg2Inputs, block.timestamp + 1 hours, 1 ether
        );
    }

    function test_Swap_RevertsWhen_UnexpectedMsgValue_WithERC20Input() public {
        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();

        vm.prank(user1);
        token.approve(address(liquidRouter), 1000e18);

        vm.expectRevert(ILiquidRouter.UnexpectedMsgValue.selector);
        vm.prank(user1);
        _swapVia( // msg.value must be 0 when tokenIn is ERC20
            liquidRouter,
            address(token), 1000e18, address(token), user1, 1,
            leg1Commands, leg1Inputs, leg2Commands, leg2Inputs, block.timestamp + 1 hours, 0.5 ether
        );
    }

    function test_Swap_RevertsWhen_AmountZero_ERC20Input() public {
        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();

        vm.expectRevert(ILiquidRouter.InvalidAmount.selector);
        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(token), 0, address(token), user1, 1, // amountIn = 0 with ERC20
            leg1Commands, leg1Inputs, leg2Commands, leg2Inputs, block.timestamp + 1 hours, 0
        );
    }

    function test_Swap_RevertsWhen_ExtraInputsCauseLengthMismatch_A() public {
        bytes[] memory nonEmptyInputs = new bytes[](1);
        nonEmptyInputs[0] = abi.encode("junk");
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();

        vm.expectRevert(ILiquidRouter.CommandInputLengthMismatch.selector);
        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(0), 0, address(token), user1, 1,
            "", nonEmptyInputs, // leg1Commands empty but leg1Inputs non-empty
            leg2Commands, leg2Inputs, block.timestamp + 1 hours, 1 ether
        );
    }

    function test_Swap_RevertsWhen_ExtraInputsCauseLengthMismatch_B() public {
        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        bytes[] memory nonEmptyInputs = new bytes[](1);
        nonEmptyInputs[0] = abi.encode("junk");

        vm.prank(user1);
        token.approve(address(liquidRouter), 1000e18);

        vm.expectRevert(ILiquidRouter.CommandInputLengthMismatch.selector);
        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(token), 1000e18, address(0), user1, 1,
            leg1Commands, leg1Inputs,
            "", nonEmptyInputs, // leg2Commands empty but leg2Inputs non-empty
            block.timestamp + 1 hours,
            0
        );
    }

    function test_Swap_RevertsWhen_CommandInputLengthMismatch() public {
        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();
        
        bytes[] memory mismatchedInputs = new bytes[](leg1Inputs.length + 1);
        for (uint256 i = 0; i < leg1Inputs.length; i++) {
            mismatchedInputs[i] = leg1Inputs[i];
        }
        mismatchedInputs[leg1Inputs.length] = "";

        vm.prank(user1);
        token.approve(address(liquidRouter), 1000e18);

        vm.expectRevert(ILiquidRouter.CommandInputLengthMismatch.selector);
        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(token), 1000e18, address(token), user1, 1,
            leg1Commands, mismatchedInputs, // mismatch on leg1
            leg2Commands, leg2Inputs,
            block.timestamp + 1 hours,
            0
        );
    }

    function test_Swap_RevertsWhen_Leg1Empty_But_TokenInIsERC20() public {
        // tokenIn is ERC20 with amountIn=0 and msg.value provided — InvalidAmount fires first
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();

        vm.expectRevert(ILiquidRouter.InvalidAmount.selector);
        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(token),
            0,
            address(tokenB),
            user1, 1,
            "", new bytes[](0),
            leg2Commands, leg2Inputs,
            block.timestamp + 1 hours,
            1 ether
        );
    }

    function test_Swap_RevertsWhen_SlippageExceeded() public {
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();

        vm.expectRevert(ILiquidRouter.SlippageExceeded.selector);
        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(0), 0, address(token), user1,
            type(uint256).max, // impossibly high minAmountOut
            "", new bytes[](0), leg2Commands, leg2Inputs, block.timestamp + 1 hours, 1 ether
        );
    }

    function test_Swap_RevertsWhen_DeadlineExpired() public {
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(ILiquidRouter.DeadlineExpired.selector);
        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(0), 0, address(token), user1, 1,
            "", new bytes[](0), leg2Commands, leg2Inputs,
            block.timestamp - 1,  // already expired
            1 ether
        );
    }

    function test_Swap_RevertsWhen_TokenIn_NotRegistered() public {
        MockERC20 unregistered = new MockERC20();
        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();
        unregistered.mint(user1, 1000e18);

        vm.prank(user1);
        unregistered.approve(address(liquidRouter), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(ILiquidRouter.TokenNotAllowed.selector, address(unregistered)));
        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(unregistered), 1000e18, address(token), user1, 1,
            leg1Commands, leg1Inputs, leg2Commands, leg2Inputs, block.timestamp + 1 hours, 0
        );
    }

    function test_Swap_RevertsWhen_TokenOut_NotRegistered() public {
        MockERC20 unregistered = new MockERC20();
        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();

        vm.prank(user1);
        token.approve(address(liquidRouter), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(ILiquidRouter.TokenNotAllowed.selector, address(unregistered)));
        vm.prank(user1);
        _swapVia(
            liquidRouter,
            address(token), 1000e18, address(unregistered), user1, 1,
            leg1Commands, leg1Inputs, leg2Commands, leg2Inputs, block.timestamp + 1 hours, 0
        );
    }

    function test_Swap_AllowsWhitelistedTokenIn_WhenOutputRegistered() public {
        // Remove token from registry and add it to the currency whitelist so it is
        // still allowed by the router, proving `_isAllowedToken` fallback logic.
        vm.prank(admin);
        liquidRegistry.removeBeneficiary(address(token));
        vm.prank(admin);
        liquidRouter.addCurrency(address(token));
        router.setOutputToken(address(tokenB));

        vm.prank(user1);
        token.approve(address(liquidRouter), 1000e18);

        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();

        vm.prank(user1);
        uint256 amountOut = _swapVia(
            liquidRouter,
            address(token),
            1000e18,
            address(tokenB),
            user1,
            1,
            leg1Commands,
            leg1Inputs,
            leg2Commands,
            leg2Inputs,
            block.timestamp + 1 hours,
            0
        );

        assertGt(amountOut, 0, "swap should succeed with whitelisted token input");
        assertGt(
            tokenB.balanceOf(user1),
            0,
            "recipient should receive output tokens"
        );
    }

    function test_Swap_AllowsWhitelistedTokenOut_WhenInputRegistered() public {
        MockERC20 whitelistedOut = new MockERC20();

        vm.prank(admin);
        liquidRouter.addCurrency(address(whitelistedOut));
        router.setOutputToken(address(whitelistedOut));

        vm.prank(user1);
        token.approve(address(liquidRouter), 1000e18);

        (bytes memory leg1Commands, bytes[] memory leg1Inputs) = _validRoute();
        (bytes memory leg2Commands, bytes[] memory leg2Inputs) = _validRoute();

        vm.prank(user1);
        uint256 amountOut = _swapVia(
            liquidRouter,
            address(token),
            1000e18,
            address(whitelistedOut),
            user1,
            1,
            leg1Commands,
            leg1Inputs,
            leg2Commands,
            leg2Inputs,
            block.timestamp + 1 hours,
            0
        );

        assertGt(amountOut, 0, "swap should succeed with whitelisted token output");
        assertGt(
            whitelistedOut.balanceOf(user1),
            0,
            "recipient should receive output tokens"
        );
    }

    // ============================================
    // addCurrency / removeCurrency — currency whitelist tests
    // ============================================

    function test_AddCurrency_HappyPath() public {
        address currency = makeAddr("currencyToken");
        vm.etch(currency, hex"00"); // make it a contract

        vm.prank(admin);
        liquidRouter.addCurrency(currency);

        assertTrue(liquidRouter.isCurrencyWhitelisted(currency));
    }

    function test_AddCurrency_EmitsCurrencyAdded() public {
        address currency = makeAddr("currencyToken");
        vm.etch(currency, hex"00");

        vm.expectEmit(true, false, false, false);
        emit ILiquidRouter.CurrencyAdded(currency);

        vm.prank(admin);
        liquidRouter.addCurrency(currency);
    }

    function test_AddCurrency_RevertsOnZeroAddress() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(admin);
        liquidRouter.addCurrency(address(0));
    }

    function test_RemoveCurrency_HappyPath() public {
        address currency = makeAddr("currencyToken");
        vm.etch(currency, hex"00");

        vm.prank(admin);
        liquidRouter.addCurrency(currency);
        assertTrue(liquidRouter.isCurrencyWhitelisted(currency));

        vm.prank(admin);
        liquidRouter.removeCurrency(currency);
        assertFalse(liquidRouter.isCurrencyWhitelisted(currency));
    }

    function test_RemoveCurrency_EmitsCurrencyRemoved() public {
        address currency = makeAddr("currencyToken");
        vm.etch(currency, hex"00");

        vm.prank(admin);
        liquidRouter.addCurrency(currency);

        vm.expectEmit(true, false, false, false);
        emit ILiquidRouter.CurrencyRemoved(currency);

        vm.prank(admin);
        liquidRouter.removeCurrency(currency);
    }

    function test_RemoveCurrency_RevertsOnZeroAddress() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(admin);
        liquidRouter.removeCurrency(address(0));
    }

    function test_IsCurrencyWhitelisted_ReturnsTrueAfterAdd_FalseAfterRemove() public {
        address currency = makeAddr("currencyToken");
        vm.etch(currency, hex"00");

        assertFalse(liquidRouter.isCurrencyWhitelisted(currency));

        vm.prank(admin);
        liquidRouter.addCurrency(currency);
        assertTrue(liquidRouter.isCurrencyWhitelisted(currency));

        vm.prank(admin);
        liquidRouter.removeCurrency(currency);
        assertFalse(liquidRouter.isCurrencyWhitelisted(currency));
    }

    function test_OnlyOwnerCanAddCurrency() public {
        address currency = makeAddr("currencyToken");
        vm.etch(currency, hex"00");

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1)
        );
        liquidRouter.addCurrency(currency);
    }

    function test_OnlyOwnerCanRemoveCurrency() public {
        address currency = makeAddr("currencyToken");
        vm.etch(currency, hex"00");

        vm.prank(admin);
        liquidRouter.addCurrency(currency);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1)
        );
        liquidRouter.removeCurrency(currency);
    }

    // ============================================
    // buy() — sell() event assertions with exact values
    // ============================================

    function test_Buy_EmitsRouterBuy_WithExactValues() public {
        uint256 ethAmount = 1 ether;
        uint256 expectedTokens = (ethAmount * router.tokenPerEth()) / 1e18;
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.expectEmit(true, true, true, true);
        emit ILiquidRouter.RouterBuy(
            address(token),
            user1,
            user1,
            ethAmount,
            0,             // ethFee = 0 (fees are in LiquidGuard)
            ethAmount,     // ethSwapped = full amount
            expectedTokens,
            0,             // protocolFee = 0
            0              // beneficiaryFee = 0
        );

        vm.prank(user1);
        liquidRouter.buy{value: ethAmount}(
            address(token), user1, 1, commands, inputs, block.timestamp + 1 hours
        );
    }

    function test_Sell_EmitsRouterSell_WithExactValues() public {
        uint256 tokenAmount = 1000e18;
        uint256 expectedEth = (tokenAmount * 1e18) / router.tokenPerEth();
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.expectEmit(true, true, true, true);
        emit ILiquidRouter.RouterSell(
            address(token),
            user1,
            user1,
            tokenAmount,
            expectedEth,
            0,           // ethFee = 0
            expectedEth, // netEthReceived = full amount
            0,           // protocolFee = 0
            0            // beneficiaryFee = 0
        );

        vm.prank(user1);
        liquidRouter.sell(
            address(token), tokenAmount, user1, 1, commands, inputs, block.timestamp + 1 hours
        );
    }
}
