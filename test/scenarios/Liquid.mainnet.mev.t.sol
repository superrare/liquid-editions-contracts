// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {LiquidFactoryForkBase} from "liquid-editions-test/helpers/bases/LiquidFactoryForkBase.sol";

/**
 * @title LiquidInstant MEV Protection Tests
 * @notice Tests to verify MEV protection on reward conversions
 * @dev Quoter-based slippage protection is used for LP fee conversions (LIQUID → WETH).
 *      Initialize auto-buy intentionally has NO slippage protection (atomic transaction, no MEV risk).
 */
contract LiquidInstant_MEV_Protection_Test is LiquidFactoryForkBase {
    function _deployBurner() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        _setupLiquidFactoryFork();
    }

    /**
     * @notice Test that configs without quoter are rejected (security requirement)
     * @dev Quoter is mandatory to protect reward conversions (LIQUID → WETH) from MEV drainage
     */
    function test_revertWhen_ConfigWithoutQuoter() public {
        vm.startPrank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setV4Quoter(address(0));
        vm.stopPrank();
    }
}
