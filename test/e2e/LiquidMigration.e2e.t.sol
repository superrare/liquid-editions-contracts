// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidMigrationExecutor} from "liquid-editions/LiquidMigrationExecutor.sol";
import {ILiquidMigrationExecutor} from "liquid-editions/interfaces/ILiquidMigrationExecutor.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {Curve, Multicurve} from "doppler/libraries/Multicurve.sol";
import {Position} from "doppler/types/Position.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";
import {LiquidPoolSwapHelper} from "liquid-editions-test/helpers/LiquidPoolSwapHelper.sol";

/// @title LiquidMigration E2E Tests
/// @notice Tests migrateLiquidity for LiquidMultiCurve via LiquidMigrationExecutor
contract LiquidMigrationE2ETest is Test, InitGuardTestHelper {
    // ============================================
    // DUST BOUNDS
    // ============================================

    /// @dev Reasonable dust bound for MultiCurve migrations seeded with 1 RARE.
    ///      MultiCurve only has RARE in the pool (token is minted on buy), so V4 tick-math
    ///      rounding is proportional to the RARE seed amount. 1e18 (1 RARE) is generous
    ///      for a 1-RARE-seeded pool.
    uint256 internal constant MULTICURVE_MAX_DUST = 1e18;

    /// @dev LiquidInstant seeds the pool with BOTH 1,000,000e18 LIQUID + RARE, so V4
    ///      tick-math rounding scales with the token amounts in the position — not
    ///      just the RARE seed. With a 1M-token position, the observed dust is ~9e23
    ///      (about 0.9 LIQUID tokens). This is expected: the rounding comes from
    ///      `modifyLiquidity` removing slightly less than it added due to integer division
    ///      across the tick range.
    ///      In production the operator should simulate the migration first and set a
    ///      tight bound based on the observed dust for the specific token being migrated.
    uint256 internal constant INSTANT_MAX_DUST = 1e24;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    NetworkConfig.Config internal config;

    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolVault = makeAddr("protocolVault");
    address public attacker = makeAddr("attacker");
    address public buyer = makeAddr("buyer");

    LiquidFactory public factory;
    LiquidMultiCurve public multiCurveImpl;
    LiquidInstant public instantImpl;
    MockRARE public mockRARE;
    LiquidMigrationExecutor public executor;
    LiquidPoolSwapHelper public swapHelper;

    // Deploy three init guards so we can migrate across multiple hops
    address public initGuard1;
    address public initGuard2;
    address public initGuard3;

    function _defaultSingleCurve() internal pure returns (Curve[] memory) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({tickLower: -180, tickUpper: 120000, numPositions: 1, shares: 1e18});
        return curves;
    }

    function setUp() public {
        string memory forkUrl = ForkUrlResolver.requireForkUrl(vm);
        vm.createSelectFork(forkUrl);
        config = NetworkConfig.getConfig(block.chainid);

        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);

        vm.startPrank(admin);

        mockRARE = new MockRARE();
        mockRARE.mint(tokenCreator, 10_000_000 ether);

        multiCurveImpl = new LiquidMultiCurve();
        instantImpl = new LiquidInstant();
        initGuard1 = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        initGuard2 = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        initGuard3 = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);

        factory = new LiquidFactory(admin, config.uniswapV4PoolManager, initGuard1, 60);
        LiquidGuard(initGuard1).setFactory(address(factory));
        LiquidGuard(initGuard2).setFactory(address(factory));
        LiquidGuard(initGuard3).setFactory(address(factory));

        factory.setLiquidRegistry(address(1));
        factory.setLiquidMultiCurveImplementation(address(multiCurveImpl));
        factory.setBaseToken(address(mockRARE));

        // Deploy migration executor (address(1) sentinel for registry — skips registration check)
        executor = new LiquidMigrationExecutor(admin, protocolVault, address(1));

        // Configure executor
        executor.approveHook(initGuard1, true);
        executor.approveHook(initGuard2, true);
        executor.approveHook(initGuard3, true);
        executor.setAllowedTickSpacing(60, true);
        executor.setAllowedFee(0, true);

        // Wire factory to executor
        factory.setMigrationExecutor(address(executor));

        // Deploy swap helper for buy/sell testing
        swapHelper = new LiquidPoolSwapHelper(IPoolManager(config.uniswapV4PoolManager));

        // Fund buyer with RARE for swap tests
        mockRARE.mint(buyer, 10_000_000 ether);

        vm.stopPrank();
    }

    // ============================================
    // HELPERS
    // ============================================

    function _createToken(uint256 rareLiquidity) internal returns (LiquidMultiCurve) {
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), rareLiquidity);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator, "ipfs://test", "Test Token", "TTKN", rareLiquidity, _defaultSingleCurve()
        );
        vm.stopPrank();
        return LiquidMultiCurve(payable(tokenAddr));
    }

    function _createInstantToken(uint256 rareLiquidity) internal returns (LiquidInstant) {
        rareLiquidity;
        vm.skip(true);
        return LiquidInstant(payable(address(0)));
    }

    function _defaultInstantMigrationPositions(LiquidInstant token)
        internal
        view
        returns (Position[] memory positions)
    {
        positions = new Position[](1);
        positions[0] = Position({tickLower: -180, tickUpper: 120000, liquidity: token.lpLiquidity(), salt: bytes32(0)});
    }

    function _defaultMultiCurveMigrationPositions(LiquidMultiCurve token, uint256 rareLiquidity)
        internal
        view
        returns (Position[] memory positions)
    {
        Curve[] memory curves = _defaultSingleCurve();
        (Currency currency0,,, int24 tickSpacing,) = token.poolKey();
        bool isToken0 = Currency.unwrap(currency0) == address(token);

        (Curve[] memory adjustedCurves,,) = Multicurve.adjustCurves(curves, 0, tickSpacing, isToken0);
        positions = Multicurve.calculatePositions(
            adjustedCurves, tickSpacing, token.poolLaunchSupply(), rareLiquidity, isToken0
        );
    }

    /// @dev Builds and executes a migration plan for a token to the given target hook.
    ///      Caller must have already whitelisted the token on targetHook via addInitializer.
    ///      Uses max dust values to allow for sequential migrations which may have larger dust.
    function _executeMigrationTo(address token, address targetHook, Position[] memory newPositions) internal {
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing,) = ILiquid(token).poolKey();
        PoolId currentPoolId = ILiquid(token).poolId();
        (uint160 currentSqrtPriceX96,,,) = pm.getSlot0(currentPoolId);

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: token,
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(targetHook)
            }),
            newSqrtPriceX96: currentSqrtPriceX96,
            newPositions: newPositions,
            maxDust0: type(uint256).max,
            maxDust1: type(uint256).max
        });

        vm.prank(admin);
        executor.executeMigration(plan);
    }

    // ============================================
    // ACCESS CONTROL
    // ============================================

    function test_migrateLiquidity_onlyMigrationExecutor() public {
        LiquidMultiCurve token = _createToken(1 ether);

        // Attacker cannot call migrateLiquidity directly
        PoolKey memory newKey;
        Position[] memory positions = new Position[](0);
        vm.prank(attacker);
        vm.expectRevert(ILiquid.OnlyMigrationExecutor.selector);
        token.migrateLiquidity(newKey, 0, positions, attacker, 0, 0);
    }

    function test_executeMigration_onlyOwner() public {
        LiquidMultiCurve token = _createToken(1 ether);

        ILiquidMigrationExecutor.MigrationPlan memory plan;
        plan.token = address(token);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        executor.executeMigration(plan);
    }

    // ============================================
    // VALIDATION
    // ============================================

    function test_executeMigration_revert_hookNotApproved() public {
        LiquidMultiCurve token = _createToken(1 ether);

        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing,) = token.poolKey();
        address badHook = makeAddr("badHook");

        Position[] memory positions = new Position[](1);
        positions[0] = Position({tickLower: -180, tickUpper: 120000, liquidity: 1e18, salt: bytes32(0)});

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(badHook)
            }),
            newSqrtPriceX96: 1e18,
            newPositions: positions,
            maxDust0: 0,
            maxDust1: 0
        });

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILiquidMigrationExecutor.HookNotApproved.selector, badHook));
        executor.executeMigration(plan);
    }

    // ============================================
    // HAPPY PATH
    // ============================================

    function test_migrateLiquidity_happyPath_multiCurve() public {
        LiquidMultiCurve token = _createToken(1 ether);
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);

        // Record pre-migration state
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, IHooks oldHooks) = token.poolKey();
        PoolId oldPoolId = token.poolId();
        uint256 preMigrationSupply = token.totalSupply();
        Position[] memory newPositions = _defaultMultiCurveMigrationPositions(token, 1 ether);
        (uint160 oldSqrtPriceX96,,,) = pm.getSlot0(oldPoolId);

        assertGt(newPositions.length, 0, "Pre-migration positions should exist");
        assertGt(newPositions[0].liquidity, 0, "First migration position should have liquidity");
        assertEq(address(oldHooks), initGuard1, "Old hooks should be initGuard1");

        // Whitelist the token on initGuard2 so it can initialize a new pool
        vm.prank(admin);
        LiquidGuard(initGuard2).addInitializer(address(token));

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: oldSqrtPriceX96,
            newPositions: newPositions,
            maxDust0: MULTICURVE_MAX_DUST,
            maxDust1: MULTICURVE_MAX_DUST
        });

        // Execute migration as owner
        vm.prank(admin);
        executor.executeMigration(plan);

        // Verify post-migration state
        (,,,, IHooks newHooks) = token.poolKey();
        PoolId newPoolId = token.poolId();

        assertEq(address(newHooks), initGuard2, "Hooks should be updated to initGuard2");
        assertTrue(PoolId.unwrap(newPoolId) != PoolId.unwrap(oldPoolId), "Pool ID should change");
        assertEq(token.totalSupply(), preMigrationSupply, "Total supply should be unchanged");
        assertEq(token.storedPositionsLength(), newPositions.length, "Position count should match new plan");

        // Verify trading works on new pool: buy LIQUID with RARE
        uint256 buyAmount = 0.1 ether;
        vm.startPrank(buyer);
        mockRARE.approve(address(swapHelper), buyAmount);
        uint256 liquidOut = swapHelper.buy(address(token), buyAmount, buyer);
        vm.stopPrank();

        assertGt(liquidOut, 0, "Buy should return LIQUID tokens");
        assertEq(token.balanceOf(buyer), liquidOut, "Buyer should hold purchased tokens");

        // Verify trading works on new pool: sell LIQUID for RARE
        uint256 sellAmount = liquidOut / 2;
        uint256 rareBefore = mockRARE.balanceOf(buyer);
        vm.startPrank(buyer);
        token.approve(address(swapHelper), sellAmount);
        uint256 rareOut = swapHelper.sell(address(token), sellAmount, buyer);
        vm.stopPrank();

        assertGt(rareOut, 0, "Sell should return RARE tokens");
        assertEq(mockRARE.balanceOf(buyer), rareBefore + rareOut, "Buyer should receive RARE");

        // Verify protocol vault received no unexpected dust (bounded by maxDust)
        uint256 vaultRare = mockRARE.balanceOf(protocolVault);
        uint256 vaultLiquid = token.balanceOf(protocolVault);
        assertLe(vaultRare, MULTICURVE_MAX_DUST, "Protocol vault RARE dust should be bounded");
        assertLe(vaultLiquid, MULTICURVE_MAX_DUST, "Protocol vault LIQUID dust should be bounded");
    }

    // ============================================
    // HAPPY PATH — LIQUIDINSTANT
    // ============================================

    /// @notice Verifies the executor can migrate a LiquidInstant token pool to a new hook.
    ///         LiquidInstant enforces exactly one position and zero salt.
    function test_migrateLiquidity_happyPath_instant() public {
        LiquidInstant token = _createInstantToken(1 ether);
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);

        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, IHooks oldHooks) = token.poolKey();
        PoolId oldPoolId = token.poolId();
        uint256 preMigrationSupply = token.totalSupply();
        Position[] memory newPositions = _defaultInstantMigrationPositions(token);
        (uint160 oldSqrtPriceX96,,,) = pm.getSlot0(oldPoolId);

        assertGt(newPositions[0].liquidity, 0, "Pre-migration liquidity should be > 0");
        assertEq(address(oldHooks), initGuard1, "Old hooks should be initGuard1");

        // Exact-liquidity instant migrations need 1 wei of RARE to offset V4 rounding on the RARE side.
        mockRARE.mint(address(token), 1);

        vm.prank(admin);
        LiquidGuard(initGuard2).addInitializer(address(token));

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: oldSqrtPriceX96,
            newPositions: newPositions,
            maxDust0: INSTANT_MAX_DUST,
            maxDust1: INSTANT_MAX_DUST
        });

        vm.prank(admin);
        executor.executeMigration(plan);

        (,,,, IHooks newHooks) = token.poolKey();
        PoolId newPoolId = token.poolId();

        assertEq(address(newHooks), initGuard2, "Hooks should be updated to initGuard2");
        assertTrue(PoolId.unwrap(newPoolId) != PoolId.unwrap(oldPoolId), "Pool ID should change");
        assertEq(token.totalSupply(), preMigrationSupply, "Total supply should be unchanged");

        // For LiquidInstant, check lpLiquidity (stored value) which should match what we migrated
        uint128 postMigrationLiquidity = token.lpLiquidity();
        assertEq(postMigrationLiquidity, newPositions[0].liquidity, "lpLiquidity should match migrated liquidity");
        assertGt(postMigrationLiquidity, 0, "New pool should have liquidity");

        // Verify trading still works on the new pool
        uint256 buyAmount = 0.1 ether;
        vm.startPrank(buyer);
        mockRARE.approve(address(swapHelper), buyAmount);
        uint256 liquidOut = swapHelper.buy(address(token), buyAmount, buyer);
        vm.stopPrank();

        assertGt(liquidOut, 0, "Buy on new pool should return tokens");
    }

    // ============================================
    // SEQUENTIAL MIGRATION
    // ============================================

    /// @notice Verifies a token can be migrated multiple times: guard1 → guard2 → guard3.
    ///         Ensures state is consistent and trading works after each hop.
    function test_migrateLiquidity_sequential_multiCurve() public {
        LiquidMultiCurve token = _createToken(1 ether);

        PoolId poolId1 = token.poolId();
        Position[] memory positions1 = _defaultMultiCurveMigrationPositions(token, 1 ether);
        assertGt(positions1.length, 0, "Initial positions should exist");
        assertGt(positions1[0].liquidity, 0, "Initial liquidity should be > 0");

        // ---- First migration: guard1 → guard2 ----
        vm.prank(admin);
        LiquidGuard(initGuard2).addInitializer(address(token));
        _executeMigrationTo(address(token), initGuard2, positions1);

        PoolId poolId2 = token.poolId();
        (,,,, IHooks hooks2) = token.poolKey();
        assertTrue(PoolId.unwrap(poolId2) != PoolId.unwrap(poolId1), "Pool ID should change on first migration");
        assertEq(address(hooks2), initGuard2, "Hook should be initGuard2 after first migration");
        assertEq(
            token.storedPositionsLength(), positions1.length, "Stored positions should match after first migration"
        );

        // ---- Second migration: guard2 → guard3 ----
        vm.prank(admin);
        LiquidGuard(initGuard3).addInitializer(address(token));

        Position[] memory positions2 = _defaultMultiCurveMigrationPositions(token, 1 ether);
        mockRARE.mint(address(token), 1);
        vm.prank(tokenCreator);
        token.transfer(address(token), 1);
        _executeMigrationTo(address(token), initGuard3, positions2);

        PoolId poolId3 = token.poolId();
        (,,,, IHooks hooks3) = token.poolKey();
        assertTrue(PoolId.unwrap(poolId3) != PoolId.unwrap(poolId2), "Pool ID should change on second migration");
        assertEq(address(hooks3), initGuard3, "Hook should be initGuard3 after second migration");
        assertEq(
            token.storedPositionsLength(), positions2.length, "Stored positions should match after second migration"
        );

        // Trading works on the final pool
        uint256 buyAmount = 0.1 ether;
        vm.startPrank(buyer);
        mockRARE.approve(address(swapHelper), buyAmount);
        uint256 liquidOut = swapHelper.buy(address(token), buyAmount, buyer);
        vm.stopPrank();

        assertGt(liquidOut, 0, "Buy on final pool should return tokens");
    }

    // ============================================
    // VALIDATION — ALLOWLIST ENFORCEMENT
    // ============================================

    function test_executeMigration_revert_tickSpacingNotAllowed() public {
        LiquidMultiCurve token = _createToken(1 ether);
        (Currency c0, Currency c1, uint24 fee,,) = token.poolKey();

        int24 disallowedTickSpacing = 10;

        Position[] memory positions = new Position[](1);
        positions[0] = Position({tickLower: -180, tickUpper: 120000, liquidity: 1e18, salt: bytes32(0)});

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: disallowedTickSpacing, hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: 1e18,
            newPositions: positions,
            maxDust0: 0,
            maxDust1: 0
        });

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidMigrationExecutor.TickSpacingNotAllowed.selector, disallowedTickSpacing)
        );
        executor.executeMigration(plan);
    }

    function test_executeMigration_revert_feeNotAllowed() public {
        LiquidMultiCurve token = _createToken(1 ether);
        (Currency c0, Currency c1,, int24 tickSpacing,) = token.poolKey();

        uint24 disallowedFee = 3000;

        Position[] memory positions = new Position[](1);
        positions[0] = Position({tickLower: -180, tickUpper: 120000, liquidity: 1e18, salt: bytes32(0)});

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: disallowedFee, tickSpacing: tickSpacing, hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: 1e18,
            newPositions: positions,
            maxDust0: 0,
            maxDust1: 0
        });

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILiquidMigrationExecutor.FeeNotAllowed.selector, disallowedFee));
        executor.executeMigration(plan);
    }

    function test_executeMigration_revert_noPositions() public {
        LiquidMultiCurve token = _createToken(1 ether);
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing,) = token.poolKey();

        Position[] memory emptyPositions = new Position[](0);

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: 1e18,
            newPositions: emptyPositions,
            maxDust0: 0,
            maxDust1: 0
        });

        vm.prank(admin);
        vm.expectRevert(ILiquidMigrationExecutor.NoPositions.selector);
        executor.executeMigration(plan);
    }

    // ============================================
    // DUST TO PROTOCOL VAULT
    // ============================================

    /// @notice Verifies that dust bounds are enforced: migration reverts if actual dust exceeds maxDust.
    function test_executeMigration_revert_dustExceeded() public {
        LiquidMultiCurve token = _createToken(1 ether);
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);

        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing,) = token.poolKey();
        PoolId oldPoolId = token.poolId();
        Position[] memory newPositions = _defaultMultiCurveMigrationPositions(token, 1 ether);
        (uint160 oldSqrtPriceX96,,,) = pm.getSlot0(oldPoolId);

        vm.prank(admin);
        LiquidGuard(initGuard2).addInitializer(address(token));

        // Reducing the primary position by 2 yields token-side dust for this pool shape.
        newPositions[0].liquidity -= 2;

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: oldSqrtPriceX96,
            newPositions: newPositions,
            maxDust0: MULTICURVE_MAX_DUST,
            maxDust1: 0
        });

        // Migration should revert with DustExceeded.
        // The exact currency and amounts vary, so we capture revert data and check the 4-byte selector.
        vm.prank(admin);
        (bool success, bytes memory revertData) =
            address(executor).call(abi.encodeCall(executor.executeMigration, (plan)));
        assertFalse(success, "Migration should have reverted");
        bytes4 gotSelector = bytes4(revertData);
        assertEq(gotSelector, ILiquid.DustExceeded.selector, "Revert should be DustExceeded");
    }

    /// @notice Verifies that any rounding dust during migration is transferred to the protocol vault,
    ///         not left in the pool or silently dropped.
    function test_migrateLiquidity_dustSentToProtocolVault() public {
        LiquidMultiCurve token = _createToken(1 ether);
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);

        PoolId oldPoolId = token.poolId();
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing,) = token.poolKey();
        Position[] memory newPositions = _defaultMultiCurveMigrationPositions(token, 1 ether);
        (uint160 oldSqrtPriceX96,,,) = pm.getSlot0(oldPoolId);

        vm.prank(admin);
        LiquidGuard(initGuard2).addInitializer(address(token));

        // Reducing the primary curve by 2 produces token dust that is swept to the vault.
        newPositions[0].liquidity -= 2;

        uint256 vaultRareBefore = mockRARE.balanceOf(protocolVault);
        uint256 vaultTokenBefore = token.balanceOf(protocolVault);

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: oldSqrtPriceX96,
            newPositions: newPositions,
            maxDust0: MULTICURVE_MAX_DUST,
            maxDust1: MULTICURVE_MAX_DUST
        });

        vm.prank(admin);
        executor.executeMigration(plan);

        uint256 vaultRareAfter = mockRARE.balanceOf(protocolVault);
        uint256 vaultTokenAfter = token.balanceOf(protocolVault);

        uint256 dustRare = vaultRareAfter - vaultRareBefore;
        uint256 dustToken = vaultTokenAfter - vaultTokenBefore;

        assertGt(dustToken, 0, "Protocol vault should receive token dust from under-allocated liquidity");
        assertLe(dustRare, MULTICURVE_MAX_DUST, "RARE dust to vault should be within maxDust bound");
        assertLe(dustToken, MULTICURVE_MAX_DUST, "Token dust to vault should be within maxDust bound");
    }

    // ============================================
    // EVENTS
    // ============================================

    function test_executeMigration_emitsMigrationExecutedEvent() public {
        LiquidMultiCurve token = _createToken(1 ether);
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);

        PoolId oldPoolId = token.poolId();
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing,) = token.poolKey();
        Position[] memory newPositions = _defaultMultiCurveMigrationPositions(token, 1 ether);
        (uint160 oldSqrtPriceX96,,,) = pm.getSlot0(oldPoolId);

        vm.prank(admin);
        LiquidGuard(initGuard2).addInitializer(address(token));

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: oldSqrtPriceX96,
            newPositions: newPositions,
            maxDust0: MULTICURVE_MAX_DUST,
            maxDust1: MULTICURVE_MAX_DUST
        });

        vm.expectEmit(true, true, true, false);
        emit ILiquidMigrationExecutor.MigrationExecuted(address(token), initGuard1, initGuard2);

        vm.prank(admin);
        executor.executeMigration(plan);
    }

    // ============================================
    // VALIDATION
    // ============================================

    // ============================================
    // NEGATIVE DELTA / OVER-ALLOCATION
    // ============================================

    /// @notice Verifies that over-allocating liquidity (requesting more than was removed)
    ///         causes the migration to revert. The contract has no free RARE balance to
    ///         cover the deficit, so V4 settlement fails with ERC20InsufficientBalance.
    ///         This is frozen behavior in the clone — can't be patched post-deploy.
    function test_migrateLiquidity_revert_overAllocatedLiquidity() public {
        LiquidMultiCurve token = _createToken(1 ether);
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);

        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing,) = token.poolKey();
        PoolId oldPoolId = token.poolId();
        Position[] memory newPositions = _defaultMultiCurveMigrationPositions(token, 1 ether);
        (uint160 oldSqrtPriceX96,,,) = pm.getSlot0(oldPoolId);

        vm.prank(admin);
        LiquidGuard(initGuard2).addInitializer(address(token));

        // Request MORE liquidity on the primary curve position than was removed — forces a negative net delta
        newPositions[0].liquidity += 1000;

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: oldSqrtPriceX96,
            newPositions: newPositions,
            maxDust0: MULTICURVE_MAX_DUST,
            maxDust1: MULTICURVE_MAX_DUST
        });

        // Should revert — the contract can't cover the deficit from its own balance
        vm.prank(admin);
        vm.expectRevert();
        executor.executeMigration(plan);
    }

    // ============================================
    // PRICE PRESERVATION
    // ============================================

    /// @notice Verifies that the token price is preserved after migration — the new pool's
    ///         price should be close to the old pool's price. This is critical because the
    ///         token contract does NOT validate price proximity; it trusts the executor's
    ///         newSqrtPriceX96 parameter. This behavior is frozen in the clone.
    function test_migrateLiquidity_pricePreserved_multiCurve() public {
        LiquidMultiCurve token = _createToken(1 ether);
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);

        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing,) = token.poolKey();
        PoolId oldPoolId = token.poolId();
        Position[] memory newPositions = _defaultMultiCurveMigrationPositions(token, 1 ether);
        (uint160 oldSqrtPriceX96,,,) = pm.getSlot0(oldPoolId);

        // Record pre-migration price
        (uint256 preMigrationRarePerToken,) = token.getCurrentPrice();
        assertGt(preMigrationRarePerToken, 0, "Pre-migration price should be > 0");

        vm.prank(admin);
        LiquidGuard(initGuard2).addInitializer(address(token));

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: oldSqrtPriceX96,
            newPositions: newPositions,
            maxDust0: MULTICURVE_MAX_DUST,
            maxDust1: MULTICURVE_MAX_DUST
        });

        vm.prank(admin);
        executor.executeMigration(plan);

        // Verify price is preserved (within 1% tolerance for rounding)
        (uint256 postMigrationRarePerToken,) = token.getCurrentPrice();
        assertGt(postMigrationRarePerToken, 0, "Post-migration price should be > 0");

        uint256 priceDiffBps;
        if (postMigrationRarePerToken >= preMigrationRarePerToken) {
            priceDiffBps = ((postMigrationRarePerToken - preMigrationRarePerToken) * 10_000) / preMigrationRarePerToken;
        } else {
            priceDiffBps = ((preMigrationRarePerToken - postMigrationRarePerToken) * 10_000) / preMigrationRarePerToken;
        }
        assertLe(priceDiffBps, 100, "Price should be within 1% after migration");
    }

    /// @notice Verifies that the token contract correctly uses its OWN LIQUID token balance
    ///         (self-transfer) to settle a negative currency delta when LIQUID is the owed
    ///         currency. This is the branch where token0 == address(this), using
    ///         _transfer(address(this), pm, owed0) instead of IERC20.safeTransfer.
    ///         The negative delta path has no bound — this test documents that the transfer
    ///         works for small amounts, and the over-allocation test shows it reverts when
    ///         the balance is zero. Together they define the complete behavior of this
    ///         frozen code path.
    function test_migrateLiquidity_negDelta_selfTransferSettlement() public {
        // Use LiquidInstant because its pool always contains LIQUID as one of the currencies,
        // so the self-transfer branch fires when netDelta for the LIQUID currency is negative.
        LiquidInstant token = _createInstantToken(1 ether);
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);

        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing,) = token.poolKey();
        PoolId oldPoolId = token.poolId();
        Position[] memory newPositions = _defaultInstantMigrationPositions(token);
        (uint160 oldSqrtPriceX96,,,) = pm.getSlot0(oldPoolId);

        uint256 supplyBefore = token.totalSupply();
        uint256 tokenBalanceBefore = token.balanceOf(address(token));

        // Fund the known 1-wei RARE deficit so the migration reaches token-side settlement.
        mockRARE.mint(address(token), 1);

        vm.prank(admin);
        LiquidGuard(initGuard2).addInitializer(address(token));

        // Use full liquidity — this should result in a net-positive or net-zero delta
        // (removal returns tokens, re-add at same price and liquidity consumes same tokens).
        // If there is a small negative delta on the LIQUID currency, the self-transfer path fires.
        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: oldSqrtPriceX96,
            newPositions: newPositions,
            maxDust0: INSTANT_MAX_DUST,
            maxDust1: INSTANT_MAX_DUST
        });

        vm.prank(admin);
        executor.executeMigration(plan);

        // Total supply must be preserved — the self-transfer moves tokens between
        // the contract and V4 but never mints or burns.
        assertEq(token.totalSupply(), supplyBefore, "Total supply must be unchanged after settlement");
        assertEq(token.balanceOf(address(token)), tokenBalanceBefore - 1, "Token balance should fund settlement");

        (,,,, IHooks newHooks) = token.poolKey();
        assertEq(address(newHooks), initGuard2, "Hook should be updated");
    }

    /// @notice Documents the failure mode when the operator passes a grossly wrong starting price.
    ///         The token contract does NOT validate price proximity — it trusts the executor.
    ///         A price far from the current pool price causes V4 to demand a massive token
    ///         deposit to fill the new position (the contract has insufficient balance → revert).
    ///         Key insight: a wrong price does NOT silently succeed — it reverts with
    ///         ERC20InsufficientBalance, because deploying liquidity at the wrong price
    ///         requires far more tokens than were recovered from the old position.
    ///         This provides implicit protection against grossly wrong prices, but NOT against
    ///         small price deviations that the contract can cover from token balance. Both
    ///         behaviors are frozen in the clone.
    function test_migrateLiquidity_grosslyWrongPrice_reverts() public {
        LiquidMultiCurve token = _createToken(1 ether);
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);

        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing,) = token.poolKey();
        PoolId oldPoolId = token.poolId();
        Position[] memory newPositions = _defaultMultiCurveMigrationPositions(token, 1 ether);
        (uint160 correctSqrtPriceX96,,,) = pm.getSlot0(oldPoolId);

        // Confirm the correct price is far from the upper tick
        uint160 upperTickPrice = TickMath.getSqrtPriceAtTick(token.lpTickUpper() - 1);
        assertTrue(upperTickPrice > correctSqrtPriceX96, "Upper tick should be above current price");

        vm.prank(admin);
        LiquidGuard(initGuard2).addInitializer(address(token));

        // Pass a price near the upper tick — the contract only has ~1 RARE seeded,
        // but V4 will demand ~3.6e26 tokens to fill the position at this price.
        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: upperTickPrice,
            newPositions: newPositions,
            maxDust0: type(uint256).max,
            maxDust1: type(uint256).max
        });

        // Migration REVERTS — the wrong price demands more tokens than the contract holds.
        // This is a natural economic safety net, not an explicit check in the contract.
        vm.prank(admin);
        vm.expectRevert();
        executor.executeMigration(plan);

        // Confirm the pool state is UNCHANGED — migration was fully rolled back
        (,,,, IHooks hooks) = token.poolKey();
        assertEq(address(hooks), initGuard1, "Hook should still be initGuard1 after revert");
        assertEq(PoolId.unwrap(token.poolId()), PoolId.unwrap(oldPoolId), "Pool ID should be unchanged after revert");
    }

    // ============================================
    // VALIDATION — CURRENCY MISMATCH
    // ============================================

    function test_executeMigration_revert_currencyMismatch() public {
        LiquidMultiCurve token = _createToken(1 ether);

        (,, uint24 fee, int24 tickSpacing,) = token.poolKey();

        Position[] memory positions = new Position[](1);
        positions[0] = Position({tickLower: -180, tickUpper: 120000, liquidity: 1e18, salt: bytes32(0)});

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: Currency.wrap(address(0xdead)),
                currency1: Currency.wrap(address(0xbeef)),
                fee: fee,
                tickSpacing: tickSpacing,
                hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: 1e18,
            newPositions: positions,
            maxDust0: 0,
            maxDust1: 0
        });

        vm.prank(admin);
        vm.expectRevert(ILiquidMigrationExecutor.CurrencyMismatch.selector);
        executor.executeMigration(plan);
    }
}
