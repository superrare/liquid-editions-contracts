// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidFactory Unit Tests
 * @notice No fork; admin, setImplementation, setBaseToken, revert cases
 * @dev Uses MockV4PoolManager, MockV4Quoter for unit testing without fork
 */

import "forge-std/Test.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {MockV4PoolManager} from "liquid-editions-test/helpers/MockV4PoolManager.sol";
import {MockV4Quoter} from "liquid-editions-test/helpers/MockV4Quoter.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";

contract LiquidFactoryUnitTest is Test {
    address public admin = makeAddr("admin");
    address public user1 = makeAddr("user1");

    MockV4PoolManager public poolManager;
    MockV4Quoter public quoter;
    MockERC20 public weth;
    MockERC20 public baseToken;

    LiquidFactory public factory;
    LiquidMultiCurve public liquidImplementation;

    function setUp() public {
        poolManager = new MockV4PoolManager();
        quoter = new MockV4Quoter();
        weth = new MockERC20();
        baseToken = new MockERC20();
        factory = new LiquidFactory(
            admin,
            address(weth),
            address(poolManager),
            -180,
            120000,
            address(quoter),
            address(0),
            60,
            300,
            1e15
        );

        vm.prank(admin);

        factory.setLiquidRouter(address(1));

        liquidImplementation = new LiquidMultiCurve();
        vm.prank(admin);
        factory.setLiquidMultiCurveImplementation(address(liquidImplementation));
        vm.prank(admin);
        factory.setBaseToken(address(baseToken));

        baseToken.mint(admin, 1000 ether);
        baseToken.mint(user1, 1000 ether);
    }

    function test_RevertWhen_NonAdmin_SetImplementation() public {
        LiquidMultiCurve newImpl = new LiquidMultiCurve();
        vm.prank(user1);
        vm.expectRevert();
        factory.setLiquidMultiCurveImplementation(address(newImpl));
    }

    function test_RevertWhen_NonAdmin_SetWeth() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.setWeth(address(0x123));
    }

    function test_RevertWhen_NonAdmin_SetBaseToken() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.setBaseToken(address(0x123));
    }

    function test_RevertWhen_UpdateImplementationToZero() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setLiquidMultiCurveImplementation(address(0));
    }

    function test_RevertWhen_SetWethZero() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setWeth(address(0));
    }

    function test_RevertWhen_SetBaseTokenZero() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setBaseToken(address(0));
    }

    function test_RevertWhen_InvalidTickRange_LowerEqualsUpper() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidTickRange.selector);
        factory.setLpTickLower(120000);
    }

    function test_RevertWhen_InvalidTickRange_LowerGreaterThanUpper() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidTickRange.selector);
        factory.setLpTickLower(120001);
    }

    function test_RevertWhen_SetLpTickLower_InvalidTickSpacing() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidTickSpacing.selector);
        factory.setLpTickLower(-200);
    }

    function test_RevertWhen_SetLpTickUpper_InvalidTickSpacing() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidTickSpacing.selector);
        factory.setLpTickUpper(120050);
    }

    function test_RevertWhen_Constructor_InvalidTickSpacing() public {
        vm.expectRevert(ILiquidFactory.InvalidTickSpacing.selector);
        new LiquidFactory(
            admin,
            address(weth),
            address(poolManager),
            -200,
            120000,
            address(quoter),
            address(0),
            60,
            300,
            1e15
        );
    }

    function test_SetPoolManager_RevertsWhen_AddressZero() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setPoolManager(address(0));
    }

    function test_SetV4Quoter_RevertsWhen_AddressZero() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setV4Quoter(address(0));
    }

    function test_SetInternalMaxSlippageBps_RevertsWhen_TooHigh() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidFactory.SlippageTooHigh.selector,
                10001,
                5000
            )
        );
        factory.setInternalMaxSlippageBps(10001);
    }

    function testUpdateImplementation() public {
        LiquidMultiCurve newImpl = new LiquidMultiCurve();
        vm.prank(admin);
        factory.setLiquidMultiCurveImplementation(address(newImpl));
        assertEq(factory.liquidMultiCurveImplementation(), address(newImpl));
    }

    function testUpdateConfig() public {
        address newWeth = makeAddr("newWeth");
        vm.prank(admin);
        factory.setWeth(newWeth);
        assertEq(factory.weth(), newWeth);
    }
}
