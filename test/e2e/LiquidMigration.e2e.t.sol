// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";

/// @title LiquidMigration E2E Tests
/// @notice Tests removeLiquidity for LiquidMultiCurve and LiquidMultiCurve, plus migration flow
contract LiquidMigrationE2ETest is Test, InitGuardTestHelper {
    using StateLibrary for IPoolManager;

    NetworkConfig.Config internal config;

    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public attacker = makeAddr("attacker");

    LiquidFactory public factory;
    LiquidMultiCurve public liquidImpl;
    LiquidMultiCurve public multiCurveImpl;
    MockRARE public mockRARE;

    function setUp() public {
        string memory forkUrl = ForkUrlResolver.requireForkUrl(vm);
        vm.createSelectFork(forkUrl);
        config = NetworkConfig.getConfig(block.chainid);

        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(protocolFeeRecipient, 100 ether);

        vm.startPrank(admin);

        mockRARE = new MockRARE();
        mockRARE.mint(tokenCreator, 10_000_000 ether);
        mockRARE.mint(protocolFeeRecipient, 10_000_000 ether);

        liquidImpl = new LiquidMultiCurve();
        multiCurveImpl = new LiquidMultiCurve();
        address initGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        factory = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager,
            -180, // lpTickLower
            120000, // lpTickUpper
            config.uniswapV4Quoter,
            initGuardAddr, // poolHooks
            60, // poolTickSpacing
            300, // internalMaxSlippageBps (3%)
            1e15 // minRareLiquidityWei
        );
        LiquidInitGuard(initGuardAddr).setFactory(address(factory));

        
        factory.setLiquidRegistry(address(1));

        factory.setLiquidMultiCurveImplementation(address(liquidImpl));
        factory.setLiquidMultiCurveImplementation(address(multiCurveImpl));
        factory.setBaseToken(address(mockRARE));
        factory.setProtocolFeeRecipient(protocolFeeRecipient);

        vm.stopPrank();
    }

    // ============================================
    // HELPERS
    // ============================================

    function _createInstantToken(uint256 rareLiquidity) internal returns (LiquidMultiCurve) {
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), rareLiquidity);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test-instant",
            "Test Instant",
            "TINST",
            rareLiquidity
        );
        vm.stopPrank();
        return LiquidMultiCurve(payable(tokenAddr));
    }

    function _createMultiCurveToken(uint256 rareLiquidity) internal returns (LiquidMultiCurve) {
        DeployConfig.MultiCurveConfig memory cfg = DeployConfig.getDefaultMultiCurveConfig();
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

        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), rareLiquidity);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test-multicurve",
            "Test MultiCurve",
            "TMC",
            rareLiquidity,
            curves
        );
        vm.stopPrank();
        return LiquidMultiCurve(payable(tokenAddr));
    }

    // ============================================
    // INSTANT: removeLiquidity
    // ============================================

    function test_removeLiquidity_instant() public {
        uint256 rareLiquidity = 1 ether;
        LiquidMultiCurve token = _createInstantToken(rareLiquidity);

        // Verify pool is live
        IPoolManager pm = IPoolManager(token.poolManager());
        uint128 liq = pm.getLiquidity(token.poolId());
        assertTrue(liq > 0, "Pool should have liquidity");

        (uint160 sqrtPrice, , , ) = pm.getSlot0(token.poolId());
        assertTrue(sqrtPrice > 0, "Pool should be initialized");

        // Record balances before removal
        uint256 rareBefore = mockRARE.balanceOf(protocolFeeRecipient);
        uint256 liquidBefore = IERC20(address(token)).balanceOf(protocolFeeRecipient);

        // Remove liquidity as protocolFeeRecipient
        vm.prank(protocolFeeRecipient);
        token.removeLiquidity(protocolFeeRecipient);

        // Verify liquidity removed
        assertEq(token.lpLiquidity(), 0, "lpLiquidity should be 0 after removal");

        // Verify recipient received tokens
        uint256 rareAfter = mockRARE.balanceOf(protocolFeeRecipient);
        uint256 liquidAfter = IERC20(address(token)).balanceOf(protocolFeeRecipient);

        assertTrue(rareAfter > rareBefore, "protocolFeeRecipient should receive RARE");
        assertTrue(liquidAfter > liquidBefore, "protocolFeeRecipient should receive LIQUID");
    }

    function test_removeLiquidity_instant_onlyProtocolFeeRecipient() public {
        LiquidMultiCurve token = _createInstantToken(1 ether);

        // Attacker cannot call removeLiquidity
        vm.prank(attacker);
        vm.expectRevert(ILiquid.OnlyProtocolFeeRecipient.selector);
        token.removeLiquidity(attacker);

        // Token creator cannot call removeLiquidity
        vm.prank(tokenCreator);
        vm.expectRevert(ILiquid.OnlyProtocolFeeRecipient.selector);
        token.removeLiquidity(tokenCreator);
    }

    function test_removeLiquidity_instant_cannotCallTwice() public {
        LiquidMultiCurve token = _createInstantToken(1 ether);

        vm.prank(protocolFeeRecipient);
        token.removeLiquidity(protocolFeeRecipient);

        // Second call should revert (zero liquidity)
        vm.prank(protocolFeeRecipient);
        vm.expectRevert(ILiquid.ZeroLiquidity.selector);
        token.removeLiquidity(protocolFeeRecipient);
    }

    function test_removeLiquidity_instant_recipientCanBeDifferent() public {
        LiquidMultiCurve token = _createInstantToken(1 ether);
        address recipient = makeAddr("recipient");

        uint256 rareBefore = mockRARE.balanceOf(recipient);

        vm.prank(protocolFeeRecipient);
        token.removeLiquidity(recipient);

        assertTrue(mockRARE.balanceOf(recipient) > rareBefore, "recipient should receive RARE");
    }

    // ============================================
    // MULTICURVE: removeLiquidity
    // ============================================

    function test_removeLiquidity_multicurve() public {
        uint256 rareLiquidity = 2000 ether;
        LiquidMultiCurve token = _createMultiCurveToken(rareLiquidity);

        // Verify pool is live
        IPoolManager pm = IPoolManager(token.poolManager());
        (uint160 sqrtPrice, , , ) = pm.getSlot0(token.poolId());
        assertTrue(sqrtPrice > 0, "Pool should be initialized");
        assertTrue(token.storedPositionsLength() > 0, "Should have stored positions");

        // Record balances before removal
        uint256 rareBefore = mockRARE.balanceOf(protocolFeeRecipient);
        uint256 liquidBefore = IERC20(address(token)).balanceOf(protocolFeeRecipient);

        // Remove liquidity as protocolFeeRecipient
        vm.prank(protocolFeeRecipient);
        token.removeLiquidity(protocolFeeRecipient);

        // Verify positions cleared
        assertEq(token.storedPositionsLength(), 0, "Stored positions should be cleared");

        // Verify recipient received tokens
        uint256 rareAfter = mockRARE.balanceOf(protocolFeeRecipient);
        uint256 liquidAfter = IERC20(address(token)).balanceOf(protocolFeeRecipient);

        assertTrue(rareAfter > rareBefore, "protocolFeeRecipient should receive RARE");
        assertTrue(liquidAfter > liquidBefore, "protocolFeeRecipient should receive LIQUID");
    }

    function test_removeLiquidity_multicurve_onlyProtocolFeeRecipient() public {
        LiquidMultiCurve token = _createMultiCurveToken(2000 ether);

        vm.prank(attacker);
        vm.expectRevert(ILiquid.OnlyProtocolFeeRecipient.selector);
        token.removeLiquidity(attacker);
    }

    function test_removeLiquidity_multicurve_cannotCallTwice() public {
        LiquidMultiCurve token = _createMultiCurveToken(2000 ether);

        vm.prank(protocolFeeRecipient);
        token.removeLiquidity(protocolFeeRecipient);

        vm.prank(protocolFeeRecipient);
        vm.expectRevert(ILiquid.ZeroLiquidity.selector);
        token.removeLiquidity(protocolFeeRecipient);
    }

    // ============================================
    // MIGRATION: remove + redeploy
    // ============================================

    function test_removeLiquidity_and_migrate_instant() public {
        uint256 rareLiquidity = 1 ether;
        LiquidMultiCurve token1 = _createInstantToken(rareLiquidity);

        // Verify first pool is live
        IPoolManager token1Pm = IPoolManager(token1.poolManager());
        assertTrue(
            token1Pm.getLiquidity(token1.poolId()) > 0,
            "Token1 pool should have liquidity"
        );

        // Remove liquidity
        vm.prank(protocolFeeRecipient);
        token1.removeLiquidity(protocolFeeRecipient);

        // protocolFeeRecipient now holds recovered RARE
        uint256 recoveredRare = mockRARE.balanceOf(protocolFeeRecipient);
        assertTrue(recoveredRare > 0, "Should have recovered RARE");

        // Use recovered RARE to create a new token (simulating migration)
        vm.startPrank(protocolFeeRecipient);
        IERC20(mockRARE).approve(address(factory), recoveredRare);
        address token2Addr = factory.createLiquidTokenMultiCurve(
            tokenCreator, // same creator
            "ipfs://test-migrated",
            "Migrated Token",
            "TMIG",
            recoveredRare
        );
        vm.stopPrank();

        LiquidMultiCurve token2 = LiquidMultiCurve(payable(token2Addr));

        // Verify new pool is live
        IPoolManager token2Pm = IPoolManager(token2.poolManager());
        assertTrue(
            token2Pm.getLiquidity(token2.poolId()) > 0,
            "Token2 pool should have liquidity"
        );
        (uint160 sqrtPrice, , , ) = token2Pm.getSlot0(token2.poolId());
        assertTrue(sqrtPrice > 0, "Token2 pool should be initialized");

        // Verify old pool has no liquidity
        assertEq(token1.lpLiquidity(), 0, "Token1 pool should have no liquidity");
    }
}
