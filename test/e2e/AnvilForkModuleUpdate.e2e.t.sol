// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {AnvilForkTestBase} from "liquid-editions-test/AnvilForkTestBase.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";
import {FeeDistributor} from "liquid-editions/FeeDistributor.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";

/// @title AnvilForkModuleUpdateTest
/// @notice Fork integration test for hot-swapping fee policy/beneficiary modules.
contract AnvilForkModuleUpdateTest is AnvilForkTestBase {
    function test_DeployModulesAndUpdateSystemPointers() public {
        FeeDistributor replacementDistributor = new FeeDistributor(
            admin,
            800,
            protocolFeeRecipient
        );
        LiquidRegistry replacementRegistry = new LiquidRegistry(admin);
        address newBeneficiary = makeAddr("moduleUpdateBeneficiary");

        vm.prank(admin);
        replacementRegistry.setWriter(address(router), true);
        vm.prank(admin);
        replacementRegistry.setWriter(address(auctioneer), true);

        vm.startPrank(admin);
        router.setFeeDistributor(address(replacementDistributor));
        router.setLiquidRegistry(address(replacementRegistry));
        auctioneer.setFeeDistributor(address(replacementDistributor));
        auctioneer.setLiquidRegistry(address(replacementRegistry));
        vm.stopPrank();

        assertEq(router.feeDistributor(), address(replacementDistributor));
        assertEq(auctioneer.feeDistributor(), address(replacementDistributor));
        assertEq(router.liquidRegistry(), address(replacementRegistry));
        assertEq(auctioneer.liquidRegistry(), address(replacementRegistry));
        assertEq(
            IFeeDistributor(router.feeDistributor()).totalFeeBPS(),
            replacementDistributor.totalFeeBPS()
        );
        assertEq(
            IFeeDistributor(auctioneer.feeDistributor()).totalFeeBPS(),
            replacementDistributor.totalFeeBPS()
        );

        // Existing token registration does not migrate automatically to the new registry.
        assertEq(router.tokenBeneficiaries(address(liquidToken)), address(0));
        assertEq(
            auctioneer.tokenBeneficiaries(address(liquidToken)),
            address(0)
        );

        vm.prank(admin);
        replacementRegistry.setBeneficiary(
            address(liquidToken),
            newBeneficiary
        );
        assertEq(
            router.tokenBeneficiaries(address(liquidToken)),
            newBeneficiary
        );
        assertEq(
            auctioneer.tokenBeneficiaries(address(liquidToken)),
            newBeneficiary
        );

        // Ensure the new TOTAL_FEE_BPS applies to actual trade execution.
        uint256 ethAmount = 1 ether;
        uint256 totalFee = (ethAmount * replacementDistributor.totalFeeBPS()) / 10_000;
        (
            uint256 expectedBeneficiaryFee,
            uint256 expectedProtocolFee
        ) = replacementDistributor.quoteFeeBreakdown(totalFee);

        uint256 protocolBefore = protocolFeeRecipient.balance;
        vm.prank(buyer);
        _doBuy(buyer, address(liquidToken), buyer, ethAmount);
        uint256 protocolAfter = protocolFeeRecipient.balance - protocolBefore;

        assertEq(protocolAfter, expectedProtocolFee);
        assertGt(expectedBeneficiaryFee, 0);
    }
}
