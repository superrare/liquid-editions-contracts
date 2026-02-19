// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {LiquidRouterUnitTestBase, MockUniversalRouterForRouter} from "liquid-editions-test/unit/LiquidRouter.unit.base.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";

/// @title LiquidRouter Unit Tests (Core)
/// @notice Init, allowlist, admin, pause, rescue, remove token
/// @dev Tests use TOTAL_FEE_BPS = 400 (4%) and BENEFICIARY_FEE_BPS = 2500 (25%)
contract LiquidRouterUnitTest is LiquidRouterUnitTestBase {

    // ============================================
    // INITIALIZER TESTS
    // ============================================

    function testInitializeSetsParameters() public view {
        assertEq(liquidRouter.universalRouter(), address(router));
        assertEq(liquidRouter.protocolFeeRecipient(), protocolFeeRecipient);
        assertEq(liquidRouter.rareBurner(), address(burner));
        assertEq(liquidRouter.rareBurnFeeBPS(), RARE_BURN_FEE_BPS);
        assertEq(liquidRouter.protocolFeeBPS(), PROTOCOL_FEE_BPS);
        assertEq(liquidRouter.referrerFeeBPS(), REFERRER_FEE_BPS);
    }

    function testInitializeRevertsOnZeroRouter() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        new LiquidRouter(
            admin,
            address(0),
            protocolFeeRecipient,
            address(burner),
            RARE_BURN_FEE_BPS,
            PROTOCOL_FEE_BPS,
            REFERRER_FEE_BPS
        );
    }

    function testInitializeRevertsOnZeroProtocolFeeRecipient() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        new LiquidRouter(
            admin,
            address(router),
            address(0),
            address(burner),
            RARE_BURN_FEE_BPS,
            PROTOCOL_FEE_BPS,
            REFERRER_FEE_BPS
        );
    }

    function testInitializeRevertsOnZeroRareBurner() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        new LiquidRouter(
            admin,
            address(router),
            protocolFeeRecipient,
            address(0),
            RARE_BURN_FEE_BPS,
            PROTOCOL_FEE_BPS,
            REFERRER_FEE_BPS
        );
    }

    function testInitializeRevertsOnInvalidFeeDistribution() public {
        vm.expectRevert(ILiquidRouter.InvalidFeeDistribution.selector);
        new LiquidRouter(
            admin,
            address(router),
            protocolFeeRecipient,
            address(burner),
            5000,
            5000,
            5000 // 15000 != 10000
        );
    }

    // ============================================
    // ALLOWLIST TESTS
    // ============================================

    function testAllowlistBlocksUnregisteredToken() public {
        vm.prank(admin);
        liquidRouter.setAllowlistEnabled(true);

        MockERC20 newToken = new MockERC20();

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidRouter.TokenNotAllowed.selector,
                address(newToken)
            )
        );
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(newToken),
            user1,
            referrer,
            1,
            "",
            new bytes[](0),
            block.timestamp + 1 hours
        );
    }

    function testAllowlistAllowsRegisteredToken() public {
        vm.prank(admin);
        liquidRouter.setAllowlistEnabled(true);

        uint256 recipientBalBefore = token.balanceOf(user1);
        uint256 protocolBalBefore = protocolFeeRecipient.balance;
        uint256 referrerBalBefore = referrer.balance;
        uint256 beneficiaryBalBefore = beneficiary.balance;
        uint256 burnerBalBefore = burner.deposited();
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.prank(user1);
        uint256 tokensReceived = liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        assertGt(tokensReceived, 0, "Recipient should receive tokens");
        assertEq(token.balanceOf(user1), recipientBalBefore + tokensReceived);
        assertEq(token.balanceOf(address(liquidRouter)), 0, "Router should not retain tokens");
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore, "Protocol fee recipient should receive ETH");
        assertTrue(referrer.balance > referrerBalBefore, "Referrer should receive ETH");
        assertTrue(beneficiary.balance > beneficiaryBalBefore, "Beneficiary should receive ETH");
        assertTrue(burner.deposited() > burnerBalBefore, "Burner should receive ETH");
    }

    function testDisabledAllowlistAllowsAnyToken() public {
        assertFalse(liquidRouter.allowlistEnabled());

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
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.prank(user1);
        newLiquidRouter.buy{value: 1 ether}(
            address(newToken),
            user1,
            referrer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    // ============================================
    // ADMIN TESTS
    // ============================================

    function testOnlyOwnerCanRegisterToken() public {
        MockERC20 newToken = new MockERC20();

        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.registerToken(address(newToken), beneficiary);

        vm.prank(admin);
        liquidRouter.registerToken(address(newToken), beneficiary);
        assertEq(
            liquidRouter.tokenBeneficiaries(address(newToken)),
            beneficiary
        );
    }

    function testOnlyOwnerCanUpdateBeneficiary() public {
        address newBeneficiary = makeAddr("newBeneficiary");

        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.updateBeneficiary(address(token), newBeneficiary);

        vm.prank(admin);
        liquidRouter.updateBeneficiary(address(token), newBeneficiary);
        assertEq(
            liquidRouter.tokenBeneficiaries(address(token)),
            newBeneficiary
        );
    }

    // ============================================
    // PAUSE TESTS
    // ============================================

    function testPauseBlocksBuy() public {
        vm.prank(admin);
        liquidRouter.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user1);
        (bytes memory commands, bytes[] memory inputs) = _validRoute();
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function testPauseBlocksSell() public {
        vm.prank(admin);
        liquidRouter.pause();

        vm.prank(user1);
        token.approve(address(liquidRouter), 1000e18);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user1);
        (bytes memory commands, bytes[] memory inputs) = _validRoute();
        liquidRouter.sell(
            address(token),
            1000e18,
            user1,
            referrer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function testUnpauseAllowsTrading() public {
        vm.prank(admin);
        liquidRouter.pause();
        vm.prank(admin);
        liquidRouter.unpause();

        vm.prank(user1);
        (bytes memory commands, bytes[] memory inputs) = _validRoute();
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function testOnlyOwnerCanPause() public {
        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.pause();
    }

    function testOnlyOwnerCanUnpause() public {
        vm.prank(admin);
        liquidRouter.pause();

        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.unpause();
    }

    // ============================================
    // RESCUE TESTS
    // ============================================

    function testRescueTokens() public {
        uint256 rescueAmount = 500e18;
        token.mint(address(liquidRouter), rescueAmount);

        uint256 adminBalBefore = token.balanceOf(admin);

        vm.prank(admin);
        liquidRouter.rescueTokens(address(token), admin, rescueAmount);

        assertEq(token.balanceOf(admin) - adminBalBefore, rescueAmount);
        assertEq(token.balanceOf(address(liquidRouter)), 0);
    }

    function testRescueTokensEmitsEvent() public {
        uint256 rescueAmount = 500e18;
        token.mint(address(liquidRouter), rescueAmount);

        vm.expectEmit(true, true, false, true);
        emit ILiquidRouter.TokensRescued(address(token), admin, rescueAmount);

        vm.prank(admin);
        liquidRouter.rescueTokens(address(token), admin, rescueAmount);
    }

    function testRescueTokensRevertsOnZeroTo() public {
        token.mint(address(liquidRouter), 100e18);

        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(admin);
        liquidRouter.rescueTokens(address(token), address(0), 100e18);
    }

    function testRescueTokensRevertsOnZeroAmount() public {
        vm.expectRevert(ILiquidRouter.InvalidAmount.selector);
        vm.prank(admin);
        liquidRouter.rescueTokens(address(token), admin, 0);
    }

    function testOnlyOwnerCanRescueTokens() public {
        token.mint(address(liquidRouter), 100e18);

        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.rescueTokens(address(token), user1, 100e18);
    }

    function testRescueETH() public {
        uint256 rescueAmount = 1 ether;
        vm.deal(address(liquidRouter), rescueAmount);

        uint256 adminBalBefore = admin.balance;

        vm.prank(admin);
        liquidRouter.rescueETH(admin, rescueAmount);

        assertEq(admin.balance - adminBalBefore, rescueAmount);
        assertEq(address(liquidRouter).balance, 0);
    }

    function testRescueETHEmitsEvent() public {
        uint256 rescueAmount = 1 ether;
        vm.deal(address(liquidRouter), rescueAmount);

        vm.expectEmit(true, false, false, true);
        emit ILiquidRouter.EthRescued(admin, rescueAmount);

        vm.prank(admin);
        liquidRouter.rescueETH(admin, rescueAmount);
    }

    function testRescueETHRevertsOnZeroTo() public {
        vm.deal(address(liquidRouter), 1 ether);

        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(admin);
        liquidRouter.rescueETH(address(0), 1 ether);
    }

    function testRescueETHRevertsOnZeroAmount() public {
        vm.expectRevert(ILiquidRouter.InvalidAmount.selector);
        vm.prank(admin);
        liquidRouter.rescueETH(admin, 0);
    }

    function testRescueETHRevertsOnInsufficientBalance() public {
        vm.expectRevert(ILiquidRouter.InsufficientBalance.selector);
        vm.prank(admin);
        liquidRouter.rescueETH(admin, 1 ether);
    }

    function testOnlyOwnerCanRescueETH() public {
        vm.deal(address(liquidRouter), 1 ether);

        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.rescueETH(user1, 1 ether);
    }

    // ============================================
    // REMOVE TOKEN TESTS
    // ============================================

    function testRemoveToken() public {
        assertTrue(liquidRouter.allowedTokens(address(token)));
        assertEq(liquidRouter.tokenBeneficiaries(address(token)), beneficiary);

        vm.prank(admin);
        liquidRouter.removeToken(address(token));

        assertFalse(liquidRouter.allowedTokens(address(token)));
        assertEq(liquidRouter.tokenBeneficiaries(address(token)), address(0));
    }

    function testRemoveTokenEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit ILiquidRouter.TokenRemoved(address(token));

        vm.prank(admin);
        liquidRouter.removeToken(address(token));
    }

    function testRemoveTokenRevertsOnZeroAddress() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(admin);
        liquidRouter.removeToken(address(0));
    }

    function testOnlyOwnerCanRemoveToken() public {
        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.removeToken(address(token));
    }

    function testRemovedTokenBlockedWhenAllowlistEnabled() public {
        vm.prank(admin);
        liquidRouter.setAllowlistEnabled(true);
        vm.prank(admin);
        liquidRouter.removeToken(address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidRouter.TokenNotAllowed.selector,
                address(token)
            )
        );
        vm.prank(user1);
        (bytes memory commands, bytes[] memory inputs) = _validRoute();
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }
}
