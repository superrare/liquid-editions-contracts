// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidMigrationExecutor} from "liquid-editions/LiquidMigrationExecutor.sol";
import {ILiquidMigrationExecutor} from "liquid-editions/interfaces/ILiquidMigrationExecutor.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {Position} from "doppler/types/Position.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
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
    MockRARE public mockRARE;
    LiquidMigrationExecutor public executor;
    LiquidPoolSwapHelper public swapHelper;

    // Deploy two init guards so we can migrate between different hooks
    address public initGuard1;
    address public initGuard2;

    function _defaultSingleCurve() internal view returns (Curve[] memory) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({
            tickLower: factory.lpTickLower(),
            tickUpper: factory.lpTickUpper(),
            numPositions: 1,
            shares: 1e18
        });
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
        initGuard1 = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        initGuard2 = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);

        factory = new LiquidFactory(
            admin,
            config.uniswapV4PoolManager,
            -180, // lpTickLower
            120000, // lpTickUpper
            initGuard1, // poolHooks
            60, // poolTickSpacing
            1e15 // minRareLiquidityWei
        );
        LiquidGuard(initGuard1).setFactory(address(factory));
        LiquidGuard(initGuard2).setFactory(address(factory));

        factory.setLiquidRegistry(address(1));
        factory.setLiquidMultiCurveImplementation(address(multiCurveImpl));
        factory.setBaseToken(address(mockRARE));

        // Deploy migration executor (address(1) sentinel for registry — skips registration check)
        executor = new LiquidMigrationExecutor(
            admin,
            protocolVault,
            address(1)
        );

        // Configure executor
        executor.approveHook(initGuard1, true);
        executor.approveHook(initGuard2, true);
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
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TTKN",
            rareLiquidity,
            _defaultSingleCurve()
        );
        vm.stopPrank();
        return LiquidMultiCurve(payable(tokenAddr));
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

        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, ) = token.poolKey();
        address badHook = makeAddr("badHook");

        Position[] memory positions = new Position[](1);
        positions[0] = Position({tickLower: -180, tickUpper: 120000, liquidity: 1e18, salt: bytes32(0)});

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0,
                currency1: c1,
                fee: fee,
                tickSpacing: tickSpacing,
                hooks: IHooks(badHook)
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
        uint128 preMigrationLiquidity = token.totalLiquidity();
        (uint160 oldSqrtPriceX96, , , ) = pm.getSlot0(oldPoolId);

        assertGt(preMigrationLiquidity, 0, "Pre-migration liquidity should be > 0");
        assertEq(address(oldHooks), initGuard1, "Old hooks should be initGuard1");

        // Whitelist the token on initGuard2 so it can initialize a new pool
        vm.prank(admin);
        LiquidGuard(initGuard2).addInitializer(address(token));

        // Build migration plan: same currencies, same fee/tickSpacing, different hook, same price
        Position[] memory newPositions = new Position[](1);
        newPositions[0] = Position({
            tickLower: factory.lpTickLower(),
            tickUpper: factory.lpTickUpper(),
            liquidity: preMigrationLiquidity,
            salt: bytes32(0)
        });

        ILiquidMigrationExecutor.MigrationPlan memory plan = ILiquidMigrationExecutor.MigrationPlan({
            token: address(token),
            newPoolKey: PoolKey({
                currency0: c0,
                currency1: c1,
                fee: fee,
                tickSpacing: tickSpacing,
                hooks: IHooks(initGuard2)
            }),
            newSqrtPriceX96: oldSqrtPriceX96,
            newPositions: newPositions,
            maxDust0: 1e18,
            maxDust1: 1e18
        });

        // Execute migration as owner
        vm.prank(admin);
        executor.executeMigration(plan);

        // Verify post-migration state
        (, , , , IHooks newHooks) = token.poolKey();
        PoolId newPoolId = token.poolId();

        assertEq(address(newHooks), initGuard2, "Hooks should be updated to initGuard2");
        assertTrue(PoolId.unwrap(newPoolId) != PoolId.unwrap(oldPoolId), "Pool ID should change");
        assertEq(token.totalSupply(), preMigrationSupply, "Total supply should be unchanged");
        assertEq(token.storedPositionsLength(), newPositions.length, "Position count should match new plan");
        assertGt(token.totalLiquidity(), 0, "New pool should have liquidity");

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
        // protocolVault should have 0 or tiny amounts
        uint256 vaultRare = mockRARE.balanceOf(protocolVault);
        uint256 vaultLiquid = token.balanceOf(protocolVault);
        assertLe(vaultRare, 1e18, "Protocol vault RARE dust should be bounded");
        assertLe(vaultLiquid, 1e18, "Protocol vault LIQUID dust should be bounded");
    }

    // ============================================
    // VALIDATION
    // ============================================

    function test_executeMigration_revert_currencyMismatch() public {
        LiquidMultiCurve token = _createToken(1 ether);

        (, , uint24 fee, int24 tickSpacing, ) = token.poolKey();

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
