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
}
