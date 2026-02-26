// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {FeeDistributor} from "liquid-editions/FeeDistributor.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";
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
        FeeDistributor distributor = FeeDistributor(liquidRouter.feeDistributor());
        assertEq(distributor.protocolFeeRecipient(), protocolFeeRecipient);
    }

    function testInitializeRevertsOnZeroRouter() public {
        FeeDistributor feeDistributor = new FeeDistributor(
            admin,
            uint16(TOTAL_FEE_BPS),
            protocolFeeRecipient
        );
        LiquidRegistry registry = new LiquidRegistry(admin);
        bool didRevert = false;
        try new LiquidRouter(
            admin,
            address(0),
            address(feeDistributor),
            address(registry)
        ) {} catch {
            didRevert = true;
        }
        assertTrue(didRevert);
    }

    function testInitializeRevertsOnZeroProtocolFeeRecipient() public {
        vm.expectRevert();
        deployLiquidRouter(
            address(router),
            address(0),
            admin
        );
    }

    function testSetFeeDistributorUpdatesAndReadsFromModule() public {
        address previousDistributor = liquidRouter.feeDistributor();
        FeeDistributor newFeeDistributor = new FeeDistributor(
            admin,
            500,
            protocolFeeRecipient
        );

        vm.expectEmit(true, true, false, true);
        emit ILiquidRouter.FeeDistributorUpdated(
            previousDistributor,
            address(newFeeDistributor)
        );

        vm.prank(admin);
        liquidRouter.setFeeDistributor(address(newFeeDistributor));

        assertEq(liquidRouter.feeDistributor(), address(newFeeDistributor));
        FeeDistributor distributor = FeeDistributor(newFeeDistributor);
        assertEq(distributor.totalFeeBPS(), 500);
    }

    function testOnlyOwnerCanSetFeeDistributor() public {
        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.setFeeDistributor(address(0));
    }

    function testSetFeeDistributorRevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        liquidRouter.setFeeDistributor(address(0));
    }

    function testSetFeeDistributorRevertsOnEOA() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidRouter.InvalidModule.selector);
        liquidRouter.setFeeDistributor(makeAddr("eoaFeeDistributor"));
    }

    function testSetFeeDistributorRevertsIfCalledWrong() public {
        vm.prank(admin);
        vm.expectRevert();
        liquidRouter.setFeeDistributor(address(0));
    }

    function testOnlyOwnerCanSetLiquidRegistry() public {
        LiquidRegistry newRegistry = new LiquidRegistry(admin);

        vm.prank(user1);
        vm.expectRevert();
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

        vm.prank(admin);
        newRegistry.setWriter(address(liquidRouter), true);

        vm.expectEmit(true, true, false, true);
        emit ILiquidRouter.LiquidRegistryUpdated(
            oldLiquidRegistry,
            address(newRegistry)
        );

        vm.prank(admin);
        liquidRouter.setLiquidRegistry(address(newRegistry));

        // Existing token registration is from the old registry and should not carry over.
        assertEq(liquidRouter.tokenBeneficiaries(address(token)), address(0));

        vm.prank(admin);
        liquidRouter.registerToken(address(newToken), replacementBeneficiary);

        assertEq(
            liquidRouter.tokenBeneficiaries(address(newToken)),
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
        uint256 protocolBalBefore = protocolFeeRecipient.balance;
        uint256 beneficiaryBalBefore = beneficiary.balance;
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
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore, "Protocol fee recipient should receive ETH");
        assertTrue(beneficiary.balance > beneficiaryBalBefore, "Beneficiary should receive ETH");
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

    function testOnlyOwnerCanSetUniversalRouter() public {
        MockUniversalRouterForRouter newRouter = new MockUniversalRouterForRouter(
            address(token)
        );

        vm.expectRevert();
        vm.prank(user1);
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
        assertEq(liquidRouter.tokenBeneficiaries(address(token)), beneficiary);

        vm.prank(admin);
        liquidRouter.removeToken(address(token));

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

    function testRemovedTokenBlocked() public {
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
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }
}
