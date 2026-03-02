// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {IRAREBurner} from "liquid-editions/interfaces/IRAREBurner.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";

/// @title LiquidMultiCurve Mainnet Invariant Tests
/// @notice Critical invariant and integration tests for LiquidMultiCurve token system on Base mainnet fork
contract LiquidInstantMainnetInvariantTest is Test, InitGuardTestHelper {
    // Network configuration
    NetworkConfig.Config internal config;

    address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Test accounts
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public user1 = makeAddr("user1");
    address public referrer = makeAddr("referrer");

    // Contracts
    LiquidFactory public factory;
    LiquidMultiCurve public liquidImpl;
    LiquidMultiCurve public token;
    RAREBurner public burner;
    MockRARE public mockRARE;

    // LP tick range
    int24 constant LP_TICK_LOWER = -180; // Max expensive (after price rises) - multiple of 60
    int24 constant LP_TICK_UPPER = 120000; // Starting point - cheap tokens - multiple of 60

    // Fee constants from LiquidMultiCurve.sol
    uint256 constant TOTAL_FEE_BPS = 100; // 1% = 100 BPS
    uint256 constant TOKEN_CREATOR_FEE_BPS = 5000; // 50% of total fee
    uint256 constant PROTOCOL_FEE_BPS = 3500; // 35% of total fee
    uint256 constant ORDER_REFERRER_FEE_BPS = 1500; // 15% of total fee

    // Events to test
    event ConfigSynced(uint32 epoch);
    event TradingKnobsSynced(uint32 epoch, uint16 slippageBps, uint128 minWei);
    event LiquidFees(
        address indexed tokenCreator,
        address indexed orderReferrer,
        address indexed protocolFeeRecipient,
        uint256 rareBurnFee,
        uint256 tokenCreatorFee,
        uint256 orderReferrerFee,
        uint256 protocolFee
    );

    function _defaultSingleCurve(LiquidFactory _factory) internal view returns (Curve[] memory) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({
            tickLower: _factory.lpTickLower(),
            tickUpper: _factory.lpTickUpper(),
            numPositions: 1,
            shares: 1e18
        });
        return curves;
    }

    // Helper function to compute correct PoolId from parameters
    function _computePoolId(
        address rareToken,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) internal pure returns (bytes32) {
        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(rareToken);
        bool ethIs0 = uint160(address(0)) < uint160(rareToken);

        PoolKey memory key = PoolKey({
            currency0: ethIs0 ? ethC : rareC,
            currency1: ethIs0 ? rareC : ethC,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        return PoolId.unwrap(PoolIdLibrary.toId(key));
    }

    function setUp() public {
        // Fork Base mainnet for realistic testing
        string memory forkUrl = ForkUrlResolver.requireForkUrl(vm);
        vm.createSelectFork(forkUrl);

        // Get network configuration (Base mainnet chain ID = 8453)
        config = NetworkConfig.getConfig(block.chainid);

        // Fund test accounts
        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(protocolFeeRecipient, 100 ether);
        vm.deal(referrer, 100 ether);

        // Deploy MockRARE and fund accounts
        mockRARE = new MockRARE();
        mockRARE.mint(admin, 10_000_000 ether);
        mockRARE.mint(tokenCreator, 10_000_000 ether);
        mockRARE.mint(user1, 10_000_000 ether);
        mockRARE.mint(referrer, 10_000_000 ether);

        // Deploy contracts
        vm.startPrank(admin);

        liquidImpl = new LiquidMultiCurve();

        // Deploy burner (disabled initially for most tests, but fully configured)
        burner = new RAREBurner(
            admin,
            false, // tryOnDeposit
            config.rareToken, // Use real RARE token but disabled
            config.uniswapV4PoolManager,
            3000, // 0.3% fee
            60, // tick spacing
            address(0), // no hooks
            BURN_ADDRESS,
            address(0), // no quoter initially
            0, // 0% slippage
            false // disabled initially
        );

        // Deploy init guard and factory
        address initGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        factory = new LiquidFactory(
            admin,
            config.uniswapV4PoolManager, // V4 PoolManager
            LP_TICK_LOWER,
            LP_TICK_UPPER,
            initGuardAddr, // poolHooks
            60, // poolTickSpacing (standard for 0.3% fee tier)
            1e15 // minRareLiquidityWei (0.001 RARE)
        );
        LiquidGuard(initGuardAddr).setFactory(address(factory));
                factory.setLiquidRegistry(address(1));

        factory.setLiquidMultiCurveImplementation(address(liquidImpl));

        // Set base token to MockRARE
        factory.setBaseToken(address(mockRARE));

        vm.stopPrank();
    }

    /// @notice Helper function to create a factory with RARE burn enabled
    /// @dev Creates a new factory with rareBurnFeeBPS=2500, protocolFeeBPS=3750, referrerFeeBPS=3750
    function _createFactoryWithRAREBurn()
        internal
        returns (LiquidFactory factoryWithBurn)
    {
        vm.startPrank(admin);
        address burnInitGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        factoryWithBurn = new LiquidFactory(
            admin,
            config.uniswapV4PoolManager, // V4 PoolManager
            LP_TICK_LOWER,
            LP_TICK_UPPER,
            burnInitGuardAddr, // poolHooks
            60, // poolTickSpacing (standard for 0.3% fee tier)
            1e15 // minRareLiquidityWei (0.001 RARE)
        );
        LiquidGuard(burnInitGuardAddr).setFactory(address(factoryWithBurn));
                factoryWithBurn.setLiquidRegistry(address(1));
        factoryWithBurn.setLiquidMultiCurveImplementation(address(liquidImpl));

        // Set base token to MockRARE
        factoryWithBurn.setBaseToken(address(mockRARE));

        vm.stopPrank();
    }

    // ============================================
    // TEST 1: FEE-SPLIT INVARIANT
    // ============================================

    /// @notice Verifies fee distribution including both primary fees and LP fees
    /// @dev Total fees = 1% primary fee + ~1% LP fee (collected from pool)
    ///      LP_FEE constant = 10000 BPS = 1%
    ///      IMPORTANT: This test accounts for accumulated LP fees from token creation

    // ============================================
    // TEST 3: UNLOCK CALLBACK GUARD
    // ============================================

    /// @notice Tests that hostile direct call to unlockCallback reverts
    /// @dev Verifies the accumulator properly guards against unauthorized unlock calls
    function testUnlockCallbackGuardHostileCall() public {
        // Deploy burner with full configuration for this test
        vm.startPrank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            false, // tryOnDeposit
            config.rareToken,
            config.uniswapV4PoolManager,
            3000, // poolFee
            60, // tickSpacing
            address(0), // hooks
            BURN_ADDRESS,
            address(0), // no quoter
            0, // 0% slippage
            true // enabled
        );
        vm.stopPrank();

        // Attempt to call unlockCallback directly (not from PoolManager)
        // This should revert with OnlyPoolManager error

        // Build fake callback data
        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(config.rareToken);

        PoolKey memory fakeKey = PoolKey({
            currency0: ethC,
            currency1: rareC,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bytes memory fakeCallbackData = abi.encode(
            1 ether,
            fakeKey,
            uint160(1),
            0,
            rareC,
            BURN_ADDRESS
        );

        // Attempt hostile direct call from user
        vm.prank(user1);
        vm.expectRevert(IRAREBurner.OnlyPoolManager.selector);
        testBurner.unlockCallback(fakeCallbackData);

        console.log(
            "Unlock callback guard: correctly rejected hostile direct call"
        );
    }

    /// @notice Tests that callback guard prevents reentrancy attacks
    function testUnlockCallbackGuardReentrancy() public {
        // Even if attacker somehow gets the right _v4BurnCtx,
        // calling from wrong address should fail

        // Configure burn with correct PoolId
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);

        // Create a factory with RARE burn enabled
        LiquidFactory factoryWithBurn = _createFactoryWithRAREBurn();

        // Deploy new burner with full configuration for this test
        // Use mockRARE to match factory setup
        vm.startPrank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            false, // tryOnDeposit
            address(mockRARE), // Use mockRARE to match factory
            config.uniswapV4PoolManager,
            poolFee,
            tickSpacing,
            hooks,
            BURN_ADDRESS,
            address(0), // no quoter
            0, // 0% slippage (no quoter available)
            true // enabled
        );

        // Create new factory with configured burner
        address reentryInitGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        factoryWithBurn = new LiquidFactory(
            admin,
            config.uniswapV4PoolManager, // V4 PoolManager
            LP_TICK_LOWER,
            LP_TICK_UPPER,
            reentryInitGuardAddr, // poolHooks
            60, // poolTickSpacing (standard for 0.3% fee tier)
            1e15 // minRareLiquidityWei (0.001 RARE)
        );
        LiquidGuard(reentryInitGuardAddr).setFactory(address(factoryWithBurn));
                factoryWithBurn.setLiquidRegistry(address(1));
        factoryWithBurn.setLiquidMultiCurveImplementation(address(liquidImpl));
        factoryWithBurn.setBaseToken(address(mockRARE)); // Set base token to match burner
        vm.stopPrank();

        // Create token with 0.1 RARE
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factoryWithBurn), 0.1 ether);
        address tokenAddr = factoryWithBurn.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether,
            _defaultSingleCurve(factoryWithBurn)
        );
        vm.stopPrank();
        token = LiquidMultiCurve(payable(tokenAddr));

        vm.prank(user1);
        testBurner.depositForBurn{value: 1 ether}();

        // Attempt to call unlockCallback from non-PoolManager
        // This represents an attacker trying to bypass the unlock guard
        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(address(mockRARE)); // Use mockRARE to match burner config

        PoolKey memory key = PoolKey({
            currency0: ethC,
            currency1: rareC,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bytes memory callbackData = abi.encode(
            1 ether,
            key,
            uint160(1),
            0,
            rareC,
            BURN_ADDRESS
        );

        // Should revert when called from attacker address
        vm.prank(user1);
        vm.expectRevert(IRAREBurner.OnlyPoolManager.selector);
        testBurner.unlockCallback(callbackData);

        console.log(
            "Reentrancy guard: callback only accepts calls from PoolManager"
        );
    }

    // NOTE: Unlock callback happy path tested in RAREBurner.unit.t.sol::test_UnlockCallback_HappyPath_EmitsBurnedEvent
}
