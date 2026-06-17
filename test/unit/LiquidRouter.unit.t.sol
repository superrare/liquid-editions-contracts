// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {LiquidRouterUnitTestBase, MockUniversalRouterForRouter} from "liquid-editions-test/unit/LiquidRouter.unit.base.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";

/// @title LiquidRouter Unit Tests (Core)
/// @notice Init, allowlist, admin, pause, rescue, remove token.
///         Fees are no longer handled by the router — they are skimmed at the V4 pool
///         level by LiquidGuard. Fee-related assertions have been removed.
contract LiquidRouterUnitTest is LiquidRouterUnitTestBase {

    // ============================================
    // INITIALIZER TESTS
    // ============================================

    function testInitializeSetsParameters() public view {
        assertEq(liquidRouter.universalRouter(), address(router));
        assertNotEq(liquidRouter.liquidRegistry(), address(0));
    }

    function testInitializeRevertsOnZeroRouter() public {
        LiquidRegistry registry = new LiquidRegistry(admin);
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        new LiquidRouter(admin, address(0), address(registry));
    }

    function testInitializeRevertsOnEOA() public {
        LiquidRegistry registry = new LiquidRegistry(admin);
        vm.expectRevert(ILiquidRouter.InvalidModule.selector);
        new LiquidRouter(admin, makeAddr("eoaUniversalRouter"), address(registry));
    }

    function testInitializeRevertsOnZeroRegistry() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        new LiquidRouter(admin, address(router), address(0));
    }

    function testOnlyOwnerCanSetLiquidRegistry() public {
        LiquidRegistry newRegistry = new LiquidRegistry(admin);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1)
        );
        liquidRouter.setLiquidRegistry(address(newRegistry));
    }

    function testSetLiquidRegistryRevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        liquidRouter.setLiquidRegistry(address(0));
    }

    function testSetLiquidRegistryRevertsOnEOA() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidRouter.InvalidModule.selector);
        liquidRouter.setLiquidRegistry(makeAddr("eoaLiquidRegistry"));
    }

    function testSetLiquidRegistryUpdatesTokenBeneficiarySource() public {
        address oldLiquidRegistry = liquidRouter.liquidRegistry();
        LiquidRegistry newRegistry = new LiquidRegistry(admin);
        address replacementBeneficiary = makeAddr("replacementBeneficiary");
        MockERC20 newToken = new MockERC20();

        vm.expectEmit(true, true, false, true);
        emit ILiquidRouter.LiquidRegistryUpdated(
            oldLiquidRegistry,
            address(newRegistry)
        );

        vm.prank(admin);
        liquidRouter.setLiquidRegistry(address(newRegistry));

        // Existing token registration is from the old registry and should not carry over.
        assertEq(newRegistry.beneficiaryOf(address(token)), address(0));

        vm.prank(admin);
        newRegistry.setBeneficiary(address(newToken), replacementBeneficiary);

        assertEq(
            newRegistry.beneficiaryOf(address(newToken)),
            replacementBeneficiary
        );
    }

    // ============================================
    // ALLOWLIST TESTS
    // ============================================

    function testUnregisteredTokenBlocked() public {
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
            1,
            "",
            new bytes[](0),
            block.timestamp + 1 hours
        );
    }

    function testRegisteredTokenAllowed() public {
        uint256 recipientBalBefore = token.balanceOf(user1);
        (bytes memory commands, bytes[] memory inputs) = _validRoute();

        vm.prank(user1);
        uint256 tokensReceived = liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        assertGt(tokensReceived, 0, "Recipient should receive tokens");
        assertEq(token.balanceOf(user1), recipientBalBefore + tokensReceived);
        assertEq(token.balanceOf(address(liquidRouter)), 0, "Router should not retain tokens");
    }

    // ============================================
    // ADMIN TESTS
    // ============================================

    function testOnlyOwnerCanAddCurrency() public {
        address currency = makeAddr("currencyToken");
        vm.etch(currency, hex"00");

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1)
        );
        liquidRouter.addCurrency(currency);

        vm.prank(admin);
        liquidRouter.addCurrency(currency);
        assertTrue(liquidRouter.isCurrencyWhitelisted(currency));
    }

    function testOnlyOwnerCanRemoveCurrency() public {
        address currency = makeAddr("currencyToken");
        vm.etch(currency, hex"00");

        vm.prank(admin);
        liquidRouter.addCurrency(currency);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1)
        );
        liquidRouter.removeCurrency(currency);

        vm.prank(admin);
        liquidRouter.removeCurrency(currency);
        assertFalse(liquidRouter.isCurrencyWhitelisted(currency));
    }

    function testIsCurrencyWhitelistedReflectsState() public {
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

    function testOnlyOwnerCanSetUniversalRouter() public {
        MockUniversalRouterForRouter newRouter = new MockUniversalRouterForRouter(
            address(token)
        );

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1)
        );
        liquidRouter.setUniversalRouter(address(newRouter));
    }

    function testSetUniversalRouterUpdatesAndEmitsEvent() public {
        MockUniversalRouterForRouter newRouter = new MockUniversalRouterForRouter(
            address(token)
        );

        vm.expectEmit(true, true, false, true);
        emit ILiquidRouter.UniversalRouterUpdated(
            address(router),
            address(newRouter)
        );

        vm.prank(admin);
        liquidRouter.setUniversalRouter(address(newRouter));
        assertEq(liquidRouter.universalRouter(), address(newRouter));
    }

    function testSetUniversalRouterRevertsOnZeroAddress() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(admin);
        liquidRouter.setUniversalRouter(address(0));
    }

    function testSetUniversalRouterRevertsOnEOA() public {
        vm.expectRevert(ILiquidRouter.InvalidModule.selector);
        vm.prank(admin);
        liquidRouter.setUniversalRouter(makeAddr("eoaUniversalRouter"));
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
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function testOnlyOwnerCanPause() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1)
        );
        liquidRouter.pause();
    }

    function testOnlyOwnerCanUnpause() public {
        vm.prank(admin);
        liquidRouter.pause();

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1)
        );
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

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1)
        );
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

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1)
        );
        liquidRouter.rescueETH(user1, 1 ether);
    }

    // ============================================
    // REGISTRY REMOVAL BLOCKS ROUTER TESTS
    // ============================================

    function testRegistryRemoveBeneficiaryClearsRegistration() public {
        assertEq(liquidRegistry.beneficiaryOf(address(token)), beneficiary);

        vm.prank(admin);
        liquidRegistry.removeBeneficiary(address(token));

        assertEq(liquidRegistry.beneficiaryOf(address(token)), address(0));
        assertFalse(liquidRegistry.isRegistered(address(token)));
    }

    function testTokenRemovedFromRegistryBlockedByRouter() public {
        vm.prank(admin);
        liquidRegistry.removeBeneficiary(address(token));

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
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function testTokenReregisteredAfterRemovalAllowedByRouter() public {
        vm.prank(admin);
        liquidRegistry.removeBeneficiary(address(token));

        // Re-register
        vm.prank(admin);
        liquidRegistry.setBeneficiary(address(token), beneficiary);

        (bytes memory commands, bytes[] memory inputs) = _validRoute();
        vm.prank(user1);
        uint256 tokensReceived = liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
        assertGt(tokensReceived, 0, "Buy should succeed after re-registration");
    }
}
