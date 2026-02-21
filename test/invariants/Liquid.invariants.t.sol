// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";

/// @title LiquidMultiCurve Mainnet Invariant Tests
/// @notice Critical invariant and integration tests for LiquidMultiCurve token system on Base mainnet fork
contract LiquidInstantMainnetInvariantTest is Test {
    using StateLibrary for IPoolManager;

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
    event LiquidFees(
        address indexed tokenCreator,
        address indexed orderReferrer,
        address indexed protocolFeeRecipient,
        uint256 rareBurnFee,
        uint256 tokenCreatorFee,
        uint256 orderReferrerFee,
        uint256 protocolFee
    );

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
        string memory forkUrl = vm.envOr(
            "FORK_URL",
            string("https://mainnet.base.org")
        );
        vm.createSelectFork(forkUrl);

        // Get network configuration (Base mainnet chain ID = 8453)
        config = NetworkConfig.getConfig(block.chainid);

        // Fund test accounts
        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(protocolFeeRecipient, 100 ether);
        vm.deal(referrer, 100 ether);

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

        // Deploy factory with 0% burn fee initially
        factory = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            LP_TICK_LOWER,
            LP_TICK_UPPER,
            config.uniswapV4Quoter, // Use wrapper instead of raw quoter
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            300, // internalMaxSlippageBps (3%)
            1e15 // minRareLiquidityWei (0.001 RARE)
        );
                factory.setLiquidRouter(address(1));

        factory.setLiquidMultiCurveImplementation(address(liquidImpl));

        // Deploy mock RARE token
        mockRARE = new MockRARE();

        // Set base token (RARE) in factory
        factory.setBaseToken(address(mockRARE));

        // Fund test accounts with RARE tokens
        mockRARE.mint(tokenCreator, 1000 ether);
        mockRARE.mint(user1, 1000 ether);
        mockRARE.mint(referrer, 1000 ether);

        vm.stopPrank();
    }

    /// @notice Helper function to create a factory with RARE burn enabled
    /// @dev Creates a new factory with rareBurnFeeBPS=2500, protocolFeeBPS=3750, referrerFeeBPS=3750
    function _createFactoryWithRAREBurn()
        internal
        returns (LiquidFactory factoryWithBurn)
    {
        vm.startPrank(admin);        factoryWithBurn = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            LP_TICK_LOWER,
            LP_TICK_UPPER,
            config.uniswapV4Quoter, // Use wrapper instead of raw quoter
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            300, // internalMaxSlippageBps
            1e15 // minRareLiquidityWei (0.001 RARE)
        );
                factoryWithBurn.setLiquidRouter(address(1));
        factoryWithBurn.setLiquidMultiCurveImplementation(address(liquidImpl));

        // Deploy mock RARE token if not already deployed
        if (address(mockRARE) == address(0)) {
            mockRARE = new MockRARE();
        }

        // Set base token (RARE) in factory
        factoryWithBurn.setBaseToken(address(mockRARE));

        vm.stopPrank();
    }

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
        vm.expectRevert(RAREBurner.OnlyPoolManager.selector);
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
        vm.startPrank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            false, // tryOnDeposit
            config.rareToken,
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
        factoryWithBurn = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            LP_TICK_LOWER,
            LP_TICK_UPPER,
            config.uniswapV4Quoter, // Use wrapper instead of raw quoter
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            300, // internalMaxSlippageBps
            1e15 // minRareLiquidityWei (0.001 RARE)
        );
                factoryWithBurn.setLiquidRouter(address(1));
        factoryWithBurn.setLiquidMultiCurveImplementation(address(liquidImpl));

        // Set base token (RARE) in factory
        factoryWithBurn.setBaseToken(address(mockRARE));

        vm.stopPrank();

        // Create token and accumulate ETH
        uint256 initialRareLiquidity = 0.1 ether;
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(
            address(factoryWithBurn),
            initialRareLiquidity
        );
        address tokenAddr = factoryWithBurn.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            initialRareLiquidity
        );
        vm.stopPrank();
        token = LiquidMultiCurve(payable(tokenAddr));

        vm.prank(user1);
        testBurner.depositForBurn{value: 1 ether}();

        // Attempt to call unlockCallback from non-PoolManager
        // This represents an attacker trying to bypass the unlock guard
        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(config.rareToken);

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
        vm.expectRevert(RAREBurner.OnlyPoolManager.selector);
        burner.unlockCallback(callbackData);

        console.log(
            "Reentrancy guard: callback only accepts calls from PoolManager"
        );
    }

    // NOTE: Unlock callback happy path tested in RAREBurner.unit.t.sol::test_UnlockCallback_HappyPath_EmitsBurnedEvent
}
