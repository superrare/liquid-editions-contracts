// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";

/// @title LiquidRegistry Unit Tests
/// @notice Tests for write authorization and beneficiary lifecycle.
contract LiquidRegistryUnitTest is Test {
    address public owner = makeAddr("owner");
    address public writer = makeAddr("writer");
    address public user = makeAddr("user");

    LiquidRegistry public registry;

    function setUp() public {
        registry = new LiquidRegistry(owner);
    }

    function testOwnerCanSetBeneficiary() public {
        address token = makeAddr("token");
        address beneficiary = makeAddr("beneficiary");

        vm.prank(owner);
        registry.setBeneficiary(token, beneficiary);

        assertEq(registry.beneficiaryOf(token), beneficiary);
    }

    function testOnlyOwnerCanSetBeneficiary() public {
        address token = makeAddr("token");
        address beneficiary = makeAddr("beneficiary");

        vm.prank(user);
        vm.expectRevert(ILiquidRegistry.UnauthorizedWriter.selector);
        registry.setBeneficiary(token, beneficiary);
    }

    function testWriterCanSetBeneficiaryAfterPermissioned() public {
        address token = makeAddr("token");
        address beneficiary = makeAddr("beneficiary");

        vm.prank(owner);
        registry.setWriter(writer, true);

        vm.prank(writer);
        registry.setBeneficiary(token, beneficiary);

        assertEq(registry.beneficiaryOf(token), beneficiary);
    }

    function testWriterCanBeRemovedFromRegistry() public {
        address token = makeAddr("token");
        address beneficiary = makeAddr("beneficiary");

        vm.prank(owner);
        registry.setWriter(writer, true);
        vm.prank(writer);
        registry.setBeneficiary(token, beneficiary);

        vm.prank(owner);
        registry.setWriter(writer, false);

        vm.prank(writer);
        vm.expectRevert(ILiquidRegistry.UnauthorizedWriter.selector);
        registry.setBeneficiary(token, makeAddr("blockedBeneficiary"));
    }

    function testWriterCanReassignBeneficiary() public {
        address token = makeAddr("token");
        address firstBeneficiary = makeAddr("firstBeneficiary");
        address secondBeneficiary = makeAddr("secondBeneficiary");

        vm.prank(owner);
        registry.setWriter(writer, true);

        vm.prank(writer);
        registry.setBeneficiary(token, firstBeneficiary);
        assertEq(registry.beneficiaryOf(token), firstBeneficiary);
        assertEq(registry.isRegistered(token), true);

        vm.prank(writer);
        registry.setBeneficiary(token, secondBeneficiary);
        assertEq(registry.beneficiaryOf(token), secondBeneficiary);
        assertEq(registry.isRegistered(token), true);
    }

    function testOnlyOwnerCanSetWriter() public {
        vm.prank(user);
        vm.expectRevert();
        registry.setWriter(writer, true);
    }

    function testOnlyOwnerCanRemoveBeneficiary() public {
        address token = makeAddr("token");
        address beneficiary = makeAddr("beneficiary");

        vm.prank(owner);
        registry.setBeneficiary(token, beneficiary);

        vm.prank(user);
        vm.expectRevert(ILiquidRegistry.UnauthorizedWriter.selector);
        registry.removeBeneficiary(token);

        vm.prank(owner);
        registry.removeBeneficiary(token);
        assertEq(registry.beneficiaryOf(token), address(0));
    }

    // ============================================
    // Event assertions
    // ============================================

    function testSetBeneficiary_EmitsBeneficiarySet() public {
        address token = makeAddr("eventToken");
        address beneficiary = makeAddr("eventBeneficiary");

        vm.expectEmit(true, true, true, false);
        emit ILiquidRegistry.BeneficiarySet(token, beneficiary, owner);

        vm.prank(owner);
        registry.setBeneficiary(token, beneficiary);
    }

    function testSetBeneficiary_ByWriter_EmitsBeneficiarySet_WithWriterAsActor() public {
        address token = makeAddr("writerEventToken");
        address beneficiary = makeAddr("writerEventBeneficiary");

        vm.prank(owner);
        registry.setWriter(writer, true);

        vm.expectEmit(true, true, true, false);
        emit ILiquidRegistry.BeneficiarySet(token, beneficiary, writer);

        vm.prank(writer);
        registry.setBeneficiary(token, beneficiary);
    }

    function testRemoveBeneficiary_EmitsBeneficiaryRemoved() public {
        address token = makeAddr("removeEventToken");
        address beneficiary = makeAddr("removeEventBeneficiary");

        vm.prank(owner);
        registry.setBeneficiary(token, beneficiary);

        vm.expectEmit(true, true, false, false);
        emit ILiquidRegistry.BeneficiaryRemoved(token, owner);

        vm.prank(owner);
        registry.removeBeneficiary(token);
    }

    function testSetWriter_EmitsWriterUpdated_Enable() public {
        vm.expectEmit(true, false, false, true);
        emit ILiquidRegistry.WriterUpdated(writer, true);

        vm.prank(owner);
        registry.setWriter(writer, true);
    }

    function testSetWriter_EmitsWriterUpdated_Disable() public {
        vm.prank(owner);
        registry.setWriter(writer, true);

        vm.expectEmit(true, false, false, true);
        emit ILiquidRegistry.WriterUpdated(writer, false);

        vm.prank(owner);
        registry.setWriter(writer, false);
    }

    // ============================================
    // isRegistered and isWriter state assertions
    // ============================================

    function testIsRegistered_FalseAfterRemoval() public {
        address token = makeAddr("regToken");
        address beneficiary = makeAddr("regBen");

        vm.prank(owner);
        registry.setBeneficiary(token, beneficiary);
        assertTrue(registry.isRegistered(token), "should be registered after setBeneficiary");

        vm.prank(owner);
        registry.removeBeneficiary(token);
        assertFalse(registry.isRegistered(token), "should NOT be registered after removal");
        assertEq(registry.beneficiaryOf(token), address(0), "beneficiary should be zero after removal");
    }

    function testIsWriter_TrueAfterSet_FalseAfterRevoke() public {
        assertFalse(registry.isWriter(writer), "writer should not be set initially");

        vm.prank(owner);
        registry.setWriter(writer, true);
        assertTrue(registry.isWriter(writer), "writer should be set");

        vm.prank(owner);
        registry.setWriter(writer, false);
        assertFalse(registry.isWriter(writer), "writer should be revoked");
    }

    // ============================================
    // Zero-address input edge cases
    // ============================================

    function testSetBeneficiary_RevertsOnZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(ILiquidRegistry.ZeroAddress.selector);
        registry.setBeneficiary(address(0), makeAddr("ben"));
    }

    function testSetBeneficiary_RevertsOnZeroBeneficiary() public {
        vm.prank(owner);
        vm.expectRevert(ILiquidRegistry.ZeroAddress.selector);
        registry.setBeneficiary(makeAddr("tok"), address(0));
    }

    function testRemoveBeneficiary_RevertsOnZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(ILiquidRegistry.ZeroAddress.selector);
        registry.removeBeneficiary(address(0));
    }

    // ============================================
    // setWriter — explicit revert for non-owner (OwnableUnauthorizedAccount)
    // ============================================

    function testOnlyOwnerCanSetWriter_RevertsForNonOwner() public {
        // setWriter is onlyOwner so it throws OZ Ownable's error, not UnauthorizedWriter
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user)
        );
        registry.setWriter(writer, true);
    }

    // ============================================
    // Idempotency / edge cases
    // ============================================

    function testSetBeneficiary_Idempotent() public {
        address token = makeAddr("idempotentToken");
        address beneficiary = makeAddr("idempotentBen");

        vm.prank(owner);
        registry.setBeneficiary(token, beneficiary);
        assertEq(registry.beneficiaryOf(token), beneficiary);

        // Setting same beneficiary again should succeed without reverting
        vm.prank(owner);
        registry.setBeneficiary(token, beneficiary);
        assertEq(registry.beneficiaryOf(token), beneficiary, "idempotent set should not change value");
    }

    function testRemoveBeneficiary_NonExistent_Succeeds() public {
        address token = makeAddr("nonExistentToken");
        // Removing a token that was never set should not revert
        vm.prank(owner);
        registry.removeBeneficiary(token);
        assertEq(registry.beneficiaryOf(token), address(0));
        assertFalse(registry.isRegistered(token));
    }

    // ============================================
    // Fuzz tests
    // ============================================

    function testFuzz_BeneficiaryOf_IsRegistered_Consistent(
        address token,
        address beneficiary
    ) public {
        vm.assume(token != address(0));
        vm.assume(beneficiary != address(0));

        vm.prank(owner);
        registry.setBeneficiary(token, beneficiary);

        assertEq(registry.beneficiaryOf(token), beneficiary, "beneficiaryOf should match what was set");
        assertTrue(registry.isRegistered(token), "isRegistered should be true after setBeneficiary");
    }

    function testFuzz_AfterRemoval_NotRegistered(
        address token,
        address beneficiary
    ) public {
        vm.assume(token != address(0));
        vm.assume(beneficiary != address(0));

        vm.prank(owner);
        registry.setBeneficiary(token, beneficiary);

        vm.prank(owner);
        registry.removeBeneficiary(token);

        assertEq(registry.beneficiaryOf(token), address(0), "beneficiaryOf should be zero after removal");
        assertFalse(registry.isRegistered(token), "isRegistered should be false after removal");
    }

    function testFuzz_WriterSetBeneficiary_Succeeds(
        address token,
        address beneficiary
    ) public {
        vm.assume(token != address(0));
        vm.assume(beneficiary != address(0));

        vm.prank(owner);
        registry.setWriter(writer, true);

        vm.prank(writer);
        registry.setBeneficiary(token, beneficiary);

        assertEq(registry.beneficiaryOf(token), beneficiary, "writer should be able to set beneficiary");
    }
}
