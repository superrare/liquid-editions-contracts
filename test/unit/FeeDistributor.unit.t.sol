// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {FeeDistributor} from "liquid-editions/FeeDistributor.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";

/// @title FeeDistributor Unit Tests
/// @notice Tests for mutable fee configuration and validation.
contract FeeDistributorUnitTest is Test {
    address public owner = makeAddr("owner");
    address public user = makeAddr("user");

    FeeDistributor public distributor;

    function setUp() public {
        distributor = new FeeDistributor(
            owner,
            400,
            makeAddr("protocol")
        );
    }

    function testInitializeUsesConfiguredValues() public view {
        assertEq(distributor.totalFeeBPS(), 400);
    }

    function testOnlyOwnerCanSetTotalFeeBPS() public {
        vm.prank(user);
        vm.expectRevert();
        distributor.setTotalFeeBPS(500);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IFeeDistributor.TotalFeeUpdated(400, 500);

        distributor.setTotalFeeBPS(500);
        assertEq(distributor.totalFeeBPS(), 500);
    }

    function testSetTotalFeeBPSRevertsWhenInvalid() public {
        vm.prank(owner);
        vm.expectRevert(IFeeDistributor.InvalidTotalFee.selector);
        distributor.setTotalFeeBPS(0);

        vm.prank(owner);
        vm.expectRevert(IFeeDistributor.InvalidTotalFee.selector);
        distributor.setTotalFeeBPS(10_001);
    }

    function testInitializeRevertsOnZeroProtocolFeeRecipient() public {
        vm.expectRevert(IFeeDistributor.InvalidAddress.selector);
        new FeeDistributor(
            owner,
            400,
            address(0)
        );
    }

    function testQuoteFeeBreakdownReflectsCurrentConfig() public {
        vm.prank(owner);
        distributor.setTotalFeeBPS(800);

        (
            uint256 expectedBeneficiaryFee,
            uint256 expectedProtocolFee
        ) = distributor.quoteFeeBreakdown(1 ether);

        uint256 totalFee = 1 ether;

        assertEq(totalFee, 1 ether);
        assertEq(
            expectedBeneficiaryFee + expectedProtocolFee,
            totalFee
        );
    }
}
