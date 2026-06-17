// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidSwapGuard} from "liquid-editions/LiquidSwapGuard.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {ILiquidSwapGuard} from "liquid-editions/interfaces/ILiquidSwapGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @title LiquidSwapGuardPreInitTest
/// @notice Tests for pool pre-initialization DoS protection
/// @dev Verifies that attackers cannot front-run pool initialization
contract LiquidSwapGuardPreInitTest is Test {
    using CurrencyLibrary for Currency;

    LiquidSwapGuard public guard;
    LiquidFactory public factory;
    IPoolManager public poolManager;
    address public baseToken;
    address public admin;
    address public attacker;
    address public tokenCreator;

    function setUp() public {
        // Deploy mock pool manager (simplified for testing)
        // In real tests, you'd use the actual V4 PoolManager
        poolManager = IPoolManager(address(0x1234567890123456789012345678901234567890));
        
        admin = address(0x1111);
        attacker = address(0x2222);
        tokenCreator = address(0x3333);
        baseToken = address(0x4444);

        // Deploy guard with skipValidation=true for testing
        vm.prank(admin);
        guard = new LiquidSwapGuard(poolManager, admin, true);

        // Deploy factory (simplified - you'd use actual factory deployment)
        // For this test, we'll just verify the guard behavior
    }

    /// @notice Test that unauthorized addresses cannot initialize pools
    function test_UnauthorizedInitializer_Reverts() public {
        // Attacker tries to initialize a pool directly
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(baseToken),
            currency1: Currency.wrap(address(0x9999)), // Some token address
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(guard))
        });

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        // Attacker is not whitelisted - should revert
        // In real scenario, attacker calls pm.initialize(), then PoolManager calls hook.beforeInitialize(attacker, ...)
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidSwapGuard.UnauthorizedInitializer.selector,
                attacker
            )
        );
        
        // Simulate the hook call: PoolManager calls this with attacker as the sender parameter
        vm.prank(address(poolManager));
        guard.beforeInitialize(attacker, poolKey, sqrtPriceX96);
    }

    /// @notice Test that whitelisted token contracts can initialize pools
    function test_AuthorizedInitializer_Succeeds() public {
        address tokenContract = address(0xAAAA);

        // Owner whitelists the token contract
        vm.prank(admin);
        guard.addInitializer(tokenContract);

        // Verify it's whitelisted
        assertTrue(guard.allowedInitializers(tokenContract));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(baseToken),
            currency1: Currency.wrap(tokenContract),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(guard))
        });

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        // Token contract can initialize - should succeed
        vm.prank(address(poolManager));
        bytes4 selector = guard.beforeInitialize(tokenContract, poolKey, sqrtPriceX96);
        assertEq(selector, IHooks.beforeInitialize.selector);
    }

    /// @notice Test that factory can add initializers after being set
    function test_FactoryCanAddInitializer() public {
        address factoryAddr = address(0xBBBB);
        address tokenContract = address(0xCCCC);

        // Owner sets factory
        vm.prank(admin);
        guard.setFactory(factoryAddr);

        // Factory can now add initializers
        vm.prank(factoryAddr);
        guard.addInitializer(tokenContract);

        assertTrue(guard.allowedInitializers(tokenContract));
    }

    /// @notice Test that only owner can set factory and factory can be updated
    function test_SetFactory_OwnerOnlyAndUpdatable() public {
        address factoryAddr = address(0xBBBB);
        address anotherFactory = address(0xCCCC);
        address tokenFromFirstFactory = address(0xDDDD);
        address tokenFromSecondFactory = address(0xEEEE);

        vm.prank(attacker);
        vm.expectRevert();
        guard.setFactory(factoryAddr);

        vm.prank(admin);
        guard.setFactory(factoryAddr);
        assertEq(guard.factory(), factoryAddr);

        vm.prank(factoryAddr);
        guard.addInitializer(tokenFromFirstFactory);
        assertTrue(guard.allowedInitializers(tokenFromFirstFactory));

        vm.prank(admin);
        guard.setFactory(anotherFactory);
        assertEq(guard.factory(), anotherFactory);

        vm.prank(factoryAddr);
        vm.expectRevert(ILiquidSwapGuard.NotOwnerOrFactory.selector);
        guard.addInitializer(tokenFromSecondFactory);

        vm.prank(admin);
        guard.setFactory(factoryAddr);
        vm.prank(factoryAddr);
        guard.addInitializer(tokenFromSecondFactory);
        assertTrue(guard.allowedInitializers(tokenFromSecondFactory));
    }

    /// @notice Test that non-factory addresses cannot add initializers
    function test_NonFactoryCannotAddInitializer() public {
        address factoryAddr = address(0xBBBB);
        address tokenContract = address(0xCCCC);
        address randomAddr = address(0xDDDD);

        // Owner sets factory
        vm.prank(admin);
        guard.setFactory(factoryAddr);

        // Random address cannot add initializers
        vm.prank(randomAddr);
        vm.expectRevert(ILiquidSwapGuard.NotOwnerOrFactory.selector);
        guard.addInitializer(tokenContract);
    }

    /// @notice Test that owner can remove initializers
    function test_OwnerCanRemoveInitializer() public {
        address tokenContract = address(0xEEEE);

        // Owner adds initializer
        vm.prank(admin);
        guard.addInitializer(tokenContract);
        assertTrue(guard.allowedInitializers(tokenContract));

        // Owner removes initializer
        vm.prank(admin);
        guard.removeInitializer(tokenContract);
        assertFalse(guard.allowedInitializers(tokenContract));
    }

    /// @notice Test attack scenario: attacker tries to pre-initialize before token deployment
    /// @dev This simulates the exact attack vector described in the audit
    function test_AttackScenario_PreInitializeFails() public {
        // Scenario: Attacker predicts token address (e.g., from CREATE2 or mempool)
        address predictedToken = address(0xFFFF);

        // Attacker tries to initialize pool first with hostile price
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(baseToken),
            currency1: Currency.wrap(predictedToken),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(guard))
        });

        // Attacker chooses a hostile price (very high, making tokens expensive)
        uint160 hostilePrice = TickMath.getSqrtPriceAtTick(10000);

        // Attacker attempts initialization - should fail
        // In real scenario, attacker calls pm.initialize(), then PoolManager calls hook.beforeInitialize(attacker, ...)
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidSwapGuard.UnauthorizedInitializer.selector,
                attacker
            )
        );
        vm.prank(address(poolManager));
        guard.beforeInitialize(attacker, poolKey, hostilePrice);

        // Now legitimate token deployment happens
        // Factory whitelists the token
        vm.prank(admin);
        guard.addInitializer(predictedToken);

        // Legitimate initialization succeeds
        uint160 legitimatePrice = TickMath.getSqrtPriceAtTick(0);
        vm.prank(address(poolManager));
        bytes4 selector = guard.beforeInitialize(predictedToken, poolKey, legitimatePrice);
        assertEq(selector, IHooks.beforeInitialize.selector);
    }
}
