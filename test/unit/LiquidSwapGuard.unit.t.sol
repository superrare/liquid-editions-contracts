// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidSwapGuard} from "liquid-editions/LiquidSwapGuard.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {IMsgSender} from "v4-periphery/interfaces/IMsgSender.sol";

/// @title Mock router that implements IMsgSender for testing
contract MockRouterWithMsgSender is IMsgSender {
    address public lastCaller;

    function execute() external {
        lastCaller = msg.sender;
    }

    function msgSender() external view returns (address) {
        return lastCaller;
    }

    function setMsgSender(address _caller) external {
        lastCaller = _caller;
    }
}

/// @title Mock that does NOT implement msgSender (for negative tests)
contract MockRouterWithoutMsgSender {
    function execute() external {}
}

/// @title Mock PoolManager that forwards swap to hook
contract MockPoolManagerForGuard {
    LiquidSwapGuard public guard;

    constructor(LiquidSwapGuard _guard) {
        guard = _guard;
    }

    function setGuard(LiquidSwapGuard _guard) external {
        guard = _guard;
    }

    function swapWithHook(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external view returns (bytes4, BeforeSwapDelta, uint24) {
        return guard.beforeSwap(sender, key, params, "");
    }
}

contract LiquidSwapGuardUnitTest is Test {
    LiquidSwapGuard public guard;
    MockPoolManagerForGuard public mockPoolManager;
    MockRouterWithMsgSender public mockRouter;
    MockRouterWithoutMsgSender public mockRouterNoMsgSender;

    address owner = makeAddr("owner");
    address liquidRouter = makeAddr("liquidRouter");
    address randomCaller = makeAddr("randomCaller");

    PoolKey poolKey;
    IPoolManager.SwapParams swapParams;

    function setUp() public {
        mockPoolManager = new MockPoolManagerForGuard(LiquidSwapGuard(address(0)));
        guard = new LiquidSwapGuard(
            IPoolManager(address(mockPoolManager)),
            owner,
            true // skipValidation for unit tests
        );
        mockPoolManager.setGuard(guard);
        mockRouter = new MockRouterWithMsgSender();
        mockRouterNoMsgSender = new MockRouterWithoutMsgSender();

        // Set up a minimal pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(guard))
        });
        swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        vm.prank(owner);
        guard.addRouter(address(mockRouter));
        vm.prank(owner);
        guard.addCaller(liquidRouter);
    }

    function _callBeforeSwap(address sender, address msgSenderReturn)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        mockRouter.setMsgSender(msgSenderReturn);
        vm.prank(address(mockPoolManager));
        return guard.beforeSwap(sender, poolKey, swapParams, "");
    }

    function _callBeforeSwapWithRouter(address router, address msgSenderReturn)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        MockRouterWithMsgSender(router).setMsgSender(msgSenderReturn);
        vm.prank(address(mockPoolManager));
        return guard.beforeSwap(router, poolKey, swapParams, "");
    }

    function test_addRouter_addCaller_allowsSwap() public {
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            _callBeforeSwap(address(mockRouter), liquidRouter);

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }

    function test_revert_whenRouterNotVerified() public {
        address unverifiedRouter = makeAddr("unverifiedRouter");
        vm.prank(owner);
        guard.addCaller(liquidRouter);

        vm.prank(address(mockPoolManager));
        vm.expectRevert(
            abi.encodeWithSelector(LiquidSwapGuard.UnverifiedRouter.selector, unverifiedRouter)
        );
        guard.beforeSwap(unverifiedRouter, poolKey, swapParams, "");
    }

    function test_revert_whenCallerNotAllowed() public {
        mockRouter.setMsgSender(randomCaller);
        vm.prank(address(mockPoolManager));
        vm.expectRevert(
            abi.encodeWithSelector(LiquidSwapGuard.UnauthorizedCaller.selector, randomCaller)
        );
        guard.beforeSwap(address(mockRouter), poolKey, swapParams, "");
    }

    function test_revert_whenRouterDoesNotImplementMsgSender() public {
        vm.prank(owner);
        guard.addRouter(address(mockRouterNoMsgSender));

        vm.prank(address(mockPoolManager));
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidSwapGuard.RouterDoesNotImplementMsgSender.selector,
                address(mockRouterNoMsgSender)
            )
        );
        guard.beforeSwap(address(mockRouterNoMsgSender), poolKey, swapParams, "");
    }

    function test_removeRouter_blocksSwap() public {
        vm.prank(owner);
        guard.removeRouter(address(mockRouter));

        vm.prank(address(mockPoolManager));
        vm.expectRevert(
            abi.encodeWithSelector(LiquidSwapGuard.UnverifiedRouter.selector, address(mockRouter))
        );
        guard.beforeSwap(address(mockRouter), poolKey, swapParams, "");
    }

    function test_removeCaller_blocksSwap() public {
        vm.prank(owner);
        guard.removeCaller(liquidRouter);

        mockRouter.setMsgSender(liquidRouter);
        vm.prank(address(mockPoolManager));
        vm.expectRevert(
            abi.encodeWithSelector(LiquidSwapGuard.UnauthorizedCaller.selector, liquidRouter)
        );
        guard.beforeSwap(address(mockRouter), poolKey, swapParams, "");
    }

    function test_onlyOwner_canAddRouter() public {
        vm.prank(randomCaller);
        vm.expectRevert();
        guard.addRouter(address(0x123));
    }

    function test_onlyOwner_canAddCaller() public {
        vm.prank(randomCaller);
        vm.expectRevert();
        guard.addCaller(address(0x123));
    }

    function test_onlyOwner_canRemoveRouter() public {
        vm.prank(randomCaller);
        vm.expectRevert();
        guard.removeRouter(address(mockRouter));
    }

    function test_onlyOwner_canRemoveCaller() public {
        vm.prank(randomCaller);
        vm.expectRevert();
        guard.removeCaller(liquidRouter);
    }

    function test_revert_whenNotPoolManager() public {
        mockRouter.setMsgSender(liquidRouter);
        vm.prank(randomCaller);
        vm.expectRevert(LiquidSwapGuard.NotPoolManager.selector);
        guard.beforeSwap(address(mockRouter), poolKey, swapParams, "");
    }
}
