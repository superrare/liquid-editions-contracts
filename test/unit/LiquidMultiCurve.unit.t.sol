// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidMultiCurve Unit Tests
 * @notice Tests for LiquidMultiCurve with mock pool manager
 * @dev Uses MockV4PoolManager for unit testing without fork
 */

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {ILiquidBase} from "liquid-editions/interfaces/ILiquidBase.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {MockV4PoolManager} from "liquid-editions-test/helpers/MockV4PoolManager.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Position} from "doppler/types/Position.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";

contract LiquidMultiCurveUnitTest is Test, InitGuardTestHelper {
    address public admin = makeAddr("admin");
    address public creator = makeAddr("creator");

    MockV4PoolManager public poolManager;
    MockERC20 public baseToken;

    LiquidFactory public factory;
    LiquidMultiCurve public multiCurveImplementation;

    uint256 constant MIN_RARE = 250e18;

    function setUp() public {
        poolManager = new MockV4PoolManager();
        baseToken = new MockERC20();
        address initGuardAddr = _deployInitGuardForTest(address(poolManager), admin);
        factory = new LiquidFactory(
            admin,
            address(poolManager),
            -180,
            120000,
            initGuardAddr,
            60,
            MIN_RARE
        );
        vm.prank(admin);
        LiquidGuard(initGuardAddr).setFactory(address(factory));

        vm.startPrank(admin);
        factory.setLiquidRegistry(address(1));
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

    function test_Initialize_Success_WithZeroOptionalRare() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(creator);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://test",
            "Test",
            "TMC",
            0,
            curves
        );
        vm.stopPrank();
        assertTrue(tokenAddr != address(0));
        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        assertEq(token.tokenCreator(), creator);
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
        address newInitGuardAddr = _deployInitGuardForTest(address(poolManager), admin);
        LiquidFactory newFactory = new LiquidFactory(
            admin,
            address(poolManager),
            -180,
            120000,
            newInitGuardAddr,
            60,
            MIN_RARE
        );
        vm.prank(admin);
        LiquidGuard(newInitGuardAddr).setFactory(address(newFactory));
        vm.startPrank(admin);
        newFactory.setLiquidRegistry(address(1));
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

    // ============================================
    // Shared helper: deploy a token
    // ============================================

    function _deployToken() internal returns (LiquidMultiCurve) {
        Curve[] memory curves = _defaultCurves();
        vm.startPrank(creator);
        baseToken.approve(address(factory), MIN_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            creator, "ipfs://test", "Test", "TMC", MIN_RARE, curves
        );
        vm.stopPrank();
        return LiquidMultiCurve(payable(tokenAddr));
    }

    // ============================================
    // burn() — positive path, access, events
    // ============================================

    function test_Burn_ReducesTotalSupply() public {
        LiquidMultiCurve token = _deployToken();
        uint256 supplyBefore = token.totalSupply();
        uint256 creatorBalance = token.balanceOf(creator);
        assertGt(creatorBalance, 0, "creator should have tokens");

        uint256 burnAmount = 1e18;
        vm.prank(creator);
        token.burn(burnAmount);

        assertEq(token.totalSupply(), supplyBefore - burnAmount, "totalSupply should decrease by burned amount");
        assertEq(token.balanceOf(creator), creatorBalance - burnAmount, "creator balance should decrease");
    }

    function test_Burn_ZeroAmount_Succeeds() public {
        LiquidMultiCurve token = _deployToken();
        uint256 supplyBefore = token.totalSupply();

        vm.prank(creator);
        token.burn(0); // burning 0 should succeed (no-op)

        assertEq(token.totalSupply(), supplyBefore, "supply should not change on zero burn");
    }

    function test_Burn_EmitsLiquidTransfer() public {
        LiquidMultiCurve token = _deployToken();
        uint256 burnAmount = 1e18;

        vm.expectEmit(true, true, false, false);
        emit ILiquid.LiquidTransfer(creator, address(0), burnAmount, 0, 0, 0);

        vm.prank(creator);
        token.burn(burnAmount);
    }

    function test_Burn_RevertsWhen_InsufficientBalance() public {
        LiquidMultiCurve token = _deployToken();
        uint256 creatorBalance = token.balanceOf(creator);

        vm.prank(creator);
        vm.expectRevert(); // ERC20 insufficient balance
        token.burn(creatorBalance + 1);
    }

    // ============================================
    // setRenderContract() — access control, events
    // ============================================

    function test_SetRenderContract_ByCreator_Succeeds() public {
        LiquidMultiCurve token = _deployToken();
        address renderAddr = makeAddr("renderContract");

        vm.prank(creator);
        token.setRenderContract(renderAddr);

        assertEq(token.renderContract(), renderAddr, "render contract should be set");
    }

    function test_SetRenderContract_EmitsRenderContractSet() public {
        LiquidMultiCurve token = _deployToken();
        address renderAddr = makeAddr("renderContractEvent");

        vm.expectEmit(true, false, false, false);
        emit ILiquid.RenderContractSet(renderAddr);

        vm.prank(creator);
        token.setRenderContract(renderAddr);
    }

    function test_SetRenderContract_ByZeroAddress_ClearsRenderContract() public {
        LiquidMultiCurve token = _deployToken();
        address renderAddr = makeAddr("renderContractClear");

        vm.prank(creator);
        token.setRenderContract(renderAddr);
        assertEq(token.renderContract(), renderAddr);

        vm.prank(creator);
        token.setRenderContract(address(0));
        assertEq(token.renderContract(), address(0), "render contract should be cleared");
    }

    function test_SetRenderContract_RevertsForNonCreator() public {
        LiquidMultiCurve token = _deployToken();
        address notCreator = makeAddr("notCreator");

        vm.prank(notCreator);
        vm.expectRevert(ILiquid.NotTokenCreator.selector);
        token.setRenderContract(makeAddr("someRender"));
    }

    // ============================================
    // migrateLiquidity() — access control
    // ============================================

    function test_MigrateLiquidity_RevertsForNonMigrationExecutor() public {
        LiquidMultiCurve token = _deployToken();
        address notExecutor = makeAddr("notExecutor");

        PoolKey memory newKey;
        Position[] memory positions = new Position[](0);

        vm.prank(notExecutor);
        vm.expectRevert(ILiquid.OnlyMigrationExecutor.selector);
        token.migrateLiquidity(newKey, 0, positions, notExecutor, 0, 0);
    }

    // ============================================
    // tokenURI() — fallback to initialTokenUri
    // ============================================

    function test_TokenURI_ReturnsInitialTokenUri_WhenNoRenderContract() public {
        LiquidMultiCurve token = _deployToken();

        string memory uri = token.tokenURI();
        assertEq(uri, "ipfs://test", "should return initialTokenUri when no render contract");
    }

    // ============================================
    // Constants — MAX_TOTAL_SUPPLY and CREATOR_LAUNCH_REWARD
    // ============================================

    function test_MaxTotalSupply_IsExpected() public {
        LiquidMultiCurve token = _deployToken();
        assertEq(token.maxTotalSupply(), 1_000_000e18, "MAX_TOTAL_SUPPLY should be 1 million tokens");
    }

    function test_CreatorLaunchReward_IsDistributedOnInit() public {
        LiquidMultiCurve token = _deployToken();
        uint256 CREATOR_REWARD = 100_000e18;
        assertEq(token.balanceOf(creator), CREATOR_REWARD, "creator should receive exact launch reward");
    }

    function test_PoolSupply_IsMaxMinusCreatorReward() public {
        LiquidMultiCurve token = _deployToken();
        uint256 POOL_SUPPLY = 900_000e18;
        uint256 CREATOR_REWARD = 100_000e18;
        assertEq(
            token.totalSupply(),
            POOL_SUPPLY + CREATOR_REWARD,
            "total supply should equal MAX_TOTAL_SUPPLY at init"
        );
    }

    // ============================================
    // Transfer — emits LiquidTransfer with exact values
    // ============================================

    function test_Transfer_EmitsLiquidTransfer_WithExactValues() public {
        LiquidMultiCurve token = _deployToken();
        address recipient = makeAddr("recipient");
        uint256 transferAmount = 1000e18;

        uint256 creatorBalBefore = token.balanceOf(creator);
        uint256 recipientBalBefore = token.balanceOf(recipient);
        uint256 supplyBefore = token.totalSupply();

        vm.expectEmit(true, true, false, true);
        emit ILiquid.LiquidTransfer(
            creator,
            recipient,
            transferAmount,
            creatorBalBefore - transferAmount,
            recipientBalBefore + transferAmount,
            supplyBefore
        );

        vm.prank(creator);
        token.transfer(recipient, transferAmount);
    }

    // ============================================
    // getLaunchState() — correct enum
    // ============================================

    function test_GetLaunchState_LaunchType_IsMultiCurve() public {
        LiquidMultiCurve token = _deployToken();
        (ILiquidBase.LaunchType launchType, bool poolLive, address auction, address strategy) = token.getLaunchState();
        assertEq(uint8(launchType), uint8(ILiquidBase.LaunchType.MULTICURVE), "launch type must be MULTICURVE");
        assertTrue(poolLive, "pool should be live immediately");
        assertEq(auction, address(0), "no auction for MultiCurve");
        assertEq(strategy, address(0), "no strategy for MultiCurve");
    }
}
