// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {ILiquidSwapGuard} from "liquid-editions/interfaces/ILiquidSwapGuard.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

contract LiquidInitGuardUnitTest is Test {
    using CurrencyLibrary for Currency;

    LiquidInitGuard public guard;
    IPoolManager public poolManager;

    address owner = makeAddr("owner");
    address factoryAddr = makeAddr("factory");
    address attacker = makeAddr("attacker");
    address tokenContract = makeAddr("tokenContract");
    address randomAddr = makeAddr("random");
    address baseToken = makeAddr("baseToken");

    PoolKey poolKey;

    function setUp() public {
        poolManager = IPoolManager(makeAddr("poolManager"));

        vm.prank(owner);
        guard = new LiquidInitGuard(poolManager, owner, true);

        poolKey = PoolKey({
            currency0: Currency.wrap(baseToken),
            currency1: Currency.wrap(tokenContract),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(guard))
        });
    }

    // ============ beforeInitialize ============

    function test_AuthorizedInitializer_Succeeds() public {
        vm.prank(owner);
        guard.addInitializer(tokenContract);
        assertTrue(guard.allowedInitializers(tokenContract));

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        vm.prank(address(poolManager));
        bytes4 selector = guard.beforeInitialize(tokenContract, poolKey, sqrtPriceX96);
        assertEq(selector, IHooks.beforeInitialize.selector);
    }

    function test_UnauthorizedInitializer_Reverts() public {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidSwapGuard.UnauthorizedInitializer.selector, attacker)
        );
        vm.prank(address(poolManager));
        guard.beforeInitialize(attacker, poolKey, sqrtPriceX96);
    }

    function test_beforeInitialize_RevertsWhenNotPoolManager() public {
        vm.prank(owner);
        guard.addInitializer(tokenContract);

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        vm.expectRevert(ILiquidSwapGuard.NotPoolManager.selector);
        vm.prank(randomAddr);
        guard.beforeInitialize(tokenContract, poolKey, sqrtPriceX96);
    }

    // ============ beforeSwap (unrestricted) ============

    function test_beforeSwap_AllowsAnySwap() public {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            guard.beforeSwap(randomAddr, poolKey, swapParams, "");

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }

    // ============ Admin: setFactory ============

    function test_SetFactory_ByOwner() public {
        vm.prank(owner);
        guard.setFactory(factoryAddr);
        assertEq(guard.factory(), factoryAddr);
    }

    function test_SetFactory_RevertsForNonOwner() public {
        vm.prank(randomAddr);
        vm.expectRevert();
        guard.setFactory(factoryAddr);
    }

    function test_SetFactory_RevertsForZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ILiquidSwapGuard.InvalidFactoryAddress.selector);
        guard.setFactory(address(0));
    }

    // ============ Admin: addInitializer / removeInitializer ============

    function test_FactoryCanAddInitializer() public {
        vm.prank(owner);
        guard.setFactory(factoryAddr);

        vm.prank(factoryAddr);
        guard.addInitializer(tokenContract);
        assertTrue(guard.allowedInitializers(tokenContract));
    }

    function test_OwnerCanAddInitializer() public {
        vm.prank(owner);
        guard.addInitializer(tokenContract);
        assertTrue(guard.allowedInitializers(tokenContract));
    }

    function test_NonOwnerNonFactory_CannotAddInitializer() public {
        vm.prank(owner);
        guard.setFactory(factoryAddr);

        vm.prank(randomAddr);
        vm.expectRevert(ILiquidSwapGuard.NotOwnerOrFactory.selector);
        guard.addInitializer(tokenContract);
    }

    function test_OwnerCanRemoveInitializer() public {
        vm.prank(owner);
        guard.addInitializer(tokenContract);
        assertTrue(guard.allowedInitializers(tokenContract));

        vm.prank(owner);
        guard.removeInitializer(tokenContract);
        assertFalse(guard.allowedInitializers(tokenContract));
    }

    function test_NonOwner_CannotRemoveInitializer() public {
        vm.prank(owner);
        guard.addInitializer(tokenContract);

        vm.prank(randomAddr);
        vm.expectRevert();
        guard.removeInitializer(tokenContract);
    }

    // ============ Attack scenario ============

    function test_AttackScenario_PreInitializeFails() public {
        uint160 hostilePrice = TickMath.getSqrtPriceAtTick(10000);
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidSwapGuard.UnauthorizedInitializer.selector, attacker)
        );
        vm.prank(address(poolManager));
        guard.beforeInitialize(attacker, poolKey, hostilePrice);

        vm.prank(owner);
        guard.addInitializer(tokenContract);

        uint160 legitimatePrice = TickMath.getSqrtPriceAtTick(0);
        vm.prank(address(poolManager));
        bytes4 selector = guard.beforeInitialize(tokenContract, poolKey, legitimatePrice);
        assertEq(selector, IHooks.beforeInitialize.selector);
    }
}
