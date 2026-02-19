// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidMultiCurve Unit Tests
 * @notice Tests for LiquidMultiCurve with mock pool manager
 * @dev Uses MockV4PoolManager, MockV4Quoter for unit testing without fork
 */

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {ILiquidBase} from "liquid-editions/interfaces/ILiquidBase.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {MockV4PoolManager} from "liquid-editions-test/helpers/MockV4PoolManager.sol";
import {MockV4Quoter} from "liquid-editions-test/helpers/MockV4Quoter.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract LiquidMultiCurveUnitTest is Test {
    address public admin = makeAddr("admin");
    address public creator = makeAddr("creator");

    MockV4PoolManager public poolManager;
    MockV4Quoter public quoter;
    MockERC20 public weth;
    MockERC20 public baseToken;

    LiquidFactory public factory;
    LiquidMultiCurve public multiCurveImplementation;

    uint256 constant MIN_RARE = 250e18;

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
            MIN_RARE
        );

        vm.startPrank(admin);
        factory.setLiquidRouter(address(1));
        multiCurveImplementation = new LiquidMultiCurve();
        factory.setLiquidMultiCurveImplementation(address(multiCurveImplementation));
        factory.setBaseToken(address(baseToken));
        vm.stopPrank();

        baseToken.mint(admin, 10_000 ether);
        baseToken.mint(creator, 10_000 ether);
    }

    function _defaultCurves() internal pure returns (Curve[] memory) {
        DeployConfig.MultiCurveConfig memory cfg =
            DeployConfig.getDefaultMultiCurveConfig();

        Curve[] memory curves = new Curve[](3);
        curves[0] = Curve({
            tickLower: cfg.tripWireTickLower,
            tickUpper: cfg.tripWireTickUpper,
            numPositions: cfg.tripWirePositions,
            shares: cfg.tripWireShares
        });
        curves[1] = Curve({
            tickLower: cfg.distributionTickLower,
            tickUpper: cfg.distributionTickUpper,
            numPositions: cfg.distributionPositions,
            shares: cfg.distributionShares
        });
        curves[2] = Curve({
            tickLower: cfg.steadyStateTickLower,
            tickUpper: cfg.steadyStateTickUpper,
            numPositions: cfg.steadyStatePositions,
            shares: cfg.steadyStateShares
        });
        return curves;
    }

    function test_Initialize_Success() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(creator);
        baseToken.approve(address(factory), MIN_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://test",
            "Test MultiCurve",
            "TMC",
            MIN_RARE,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        assertEq(token.name(), "Test MultiCurve");
        assertEq(token.symbol(), "TMC");
        assertEq(token.initialTokenUri(), "ipfs://test");
        assertEq(token.tokenCreator(), creator);
        assertEq(token.baseToken(), address(baseToken));
        (ILiquidBase.LaunchType launchType, , , ) = token.getLaunchState();
        assertTrue(launchType == ILiquidBase.LaunchType.MULTICURVE);
        assertEq(token.lpLiquidity(), 0);
    }

    function test_Initialize_Revert_InsufficientRare() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(creator);
        baseToken.approve(address(factory), MIN_RARE - 1);
        vm.expectRevert(ILiquidFactory.InvalidAmount.selector);
        factory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://test",
            "Test",
            "TMC",
            MIN_RARE - 1,
            curves
        );
        vm.stopPrank();
    }

    function test_Initialize_Revert_ZeroCurves() public {
        Curve[] memory curves;

        vm.startPrank(creator);
        baseToken.approve(address(factory), MIN_RARE);
        vm.expectRevert();
        factory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://test",
            "Test",
            "TMC",
            MIN_RARE,
            curves
        );
        vm.stopPrank();
    }

    function test_Initialize_Revert_ImplementationNotSet() public {
        LiquidFactory newFactory = new LiquidFactory(
            admin,
            address(weth),
            address(poolManager),
            -180,
            120000,
            address(quoter),
            address(0),
            60,
            300,
            MIN_RARE
        );
        vm.startPrank(admin);
        newFactory.setLiquidRouter(address(1));
        newFactory.setBaseToken(address(baseToken));
        vm.stopPrank();
        // Don't set liquidMultiCurveImplementation

        Curve[] memory curves = _defaultCurves();
        vm.startPrank(creator);
        baseToken.mint(creator, MIN_RARE);
        baseToken.approve(address(newFactory), MIN_RARE);
        vm.expectRevert(ILiquidFactory.ImplementationNotSet.selector);
        newFactory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://test",
            "Test",
            "TMC",
            MIN_RARE,
            curves
        );
        vm.stopPrank();
    }

    function test_GetLaunchState_ReturnsMULTICURVE() public {
        Curve[] memory curves = _defaultCurves();
        vm.startPrank(creator);
        baseToken.approve(address(factory), MIN_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://test",
            "Test",
            "TMC",
            MIN_RARE,
            curves
        );
        vm.stopPrank();

        (ILiquidBase.LaunchType launchType, , , ) =
            LiquidMultiCurve(payable(tokenAddr)).getLaunchState();
        assertTrue(launchType == ILiquidBase.LaunchType.MULTICURVE);
    }

    function test_LpLiquidity_ReturnsZero() public {
        Curve[] memory curves = _defaultCurves();
        vm.startPrank(creator);
        baseToken.approve(address(factory), MIN_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://test",
            "Test",
            "TMC",
            MIN_RARE,
            curves
        );
        vm.stopPrank();

        assertEq(LiquidMultiCurve(payable(tokenAddr)).lpLiquidity(), 0);
    }

    function test_LpTickBounds_MatchCurveRange() public {
        Curve[] memory curves = _defaultCurves();
        vm.startPrank(creator);
        baseToken.approve(address(factory), MIN_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://test",
            "Test",
            "TMC",
            MIN_RARE,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        // Default config: lower -81_840, upper 32_220 (after adjustCurves)
        // Token ordering may flip - bounds should span the full curve range
        assertTrue(token.lpTickLower() < token.lpTickUpper());
    }

    function test_SetLiquidMultiCurveImplementation() public {
        LiquidMultiCurve newImpl = new LiquidMultiCurve();
        vm.prank(admin);
        factory.setLiquidMultiCurveImplementation(address(newImpl));
        assertEq(factory.liquidMultiCurveImplementation(), address(newImpl));
    }

    function test_RevertWhen_NonAdmin_SetLiquidMultiCurveImplementation() public {
        LiquidMultiCurve newImpl = new LiquidMultiCurve();
        vm.prank(creator);
        vm.expectRevert();
        factory.setLiquidMultiCurveImplementation(address(newImpl));
    }

    function test_RevertWhen_SetLiquidMultiCurveImplementation_Zero() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setLiquidMultiCurveImplementation(address(0));
    }
}
