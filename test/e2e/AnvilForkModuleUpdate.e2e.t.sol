// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {AnvilForkTestBase} from "liquid-editions-test/AnvilForkTestBase.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";

/// @title AnvilForkModuleUpdateTest
/// @notice Fork integration test for hot-swapping the LiquidRegistry module.
///         Note: FeeDistributor is no longer a module on LiquidRouter.
///         Fees are now skimmed at the V4 pool level by LiquidGuard.
contract AnvilForkModuleUpdateTest is AnvilForkTestBase {
    function test_SwapLiquidRegistryOnRouter() public {
        LiquidRegistry replacementRegistry = new LiquidRegistry(admin);
        address newBeneficiary = makeAddr("moduleUpdateBeneficiary");

        vm.prank(admin);
        replacementRegistry.setWriter(address(auctioneer), true);

        vm.startPrank(admin);
        router.setLiquidRegistry(address(replacementRegistry));
        auctioneer.setLiquidRegistry(address(replacementRegistry));
        vm.stopPrank();

        assertEq(router.liquidRegistry(), address(replacementRegistry));
        assertEq(auctioneer.liquidRegistry(), address(replacementRegistry));

        // Existing token registration does not migrate automatically to the new registry.
        assertEq(replacementRegistry.beneficiaryOf(address(liquidToken)), address(0));

        vm.prank(admin);
        replacementRegistry.setBeneficiary(address(liquidToken), newBeneficiary);

        assertEq(replacementRegistry.beneficiaryOf(address(liquidToken)), newBeneficiary);
        assertEq(auctioneer.tokenBeneficiaries(address(liquidToken)), newBeneficiary);
    }

    function test_BuyStillWorksAfterRegistrySwap() public {
        LiquidRegistry replacementRegistry = new LiquidRegistry(admin);
        address newBeneficiary = makeAddr("moduleUpdateBeneficiary");

        vm.prank(admin);
        router.setLiquidRegistry(address(replacementRegistry));

        vm.prank(admin);
        replacementRegistry.setBeneficiary(address(liquidToken), newBeneficiary);

        // Buy should work with the new registry
        uint256 ethAmount = 1 ether;
        uint256 tokensBefore = liquidToken.balanceOf(buyer);
        vm.prank(buyer);
        _doBuy(buyer, address(liquidToken), buyer, ethAmount);
        assertGt(liquidToken.balanceOf(buyer), tokensBefore, "Buy should succeed after registry swap");
    }
}
