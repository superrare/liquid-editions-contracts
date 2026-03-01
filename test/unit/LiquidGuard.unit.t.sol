// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {ILiquidGuard} from "liquid-editions/interfaces/ILiquidGuard.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @notice Mock FeeDistributor that records notifyFee() calls
contract MockFeeDistributor {
    uint16 public totalFee = 400;

    struct Notification {
        address liquidToken;
        uint256 rareAmount;
    }

    constructor(uint16 _feeBps) {
        totalFee = _feeBps;
    }

    Notification[] public notifications;

    function notifyFee(address liquidToken, uint256 rareAmount) external {
        notifications.push(Notification({liquidToken: liquidToken, rareAmount: rareAmount}));
    }

    function totalFeeBPS() external view returns (uint16) {
        return totalFee;
    }

    function notificationCount() external view returns (uint256) {
        return notifications.length;
    }
}

contract MockFeeDistributorRevert {
    uint16 public totalFee = 400;

    function notifyFee(address, uint256) external pure {
        revert("notifyFee failed");
    }

    function totalFeeBPS() external view returns (uint16) {
        return totalFee;
    }
}

/// @notice Mock PoolManager that records take() calls
contract MockPoolManager {
    struct TakeCall {
        Currency currency;
        address to;
        uint256 amount;
    }

    TakeCall[] public takeCalls;

    function take(Currency currency, address to, uint256 amount) external {
        takeCalls.push(TakeCall({currency: currency, to: to, amount: amount}));
    }

    function takeCallCount() external view returns (uint256) {
        return takeCalls.length;
    }
}

contract LiquidGuardUnitTest is Test {
    using CurrencyLibrary for Currency;

    LiquidGuard public guard;
    MockPoolManager public poolManager;
    MockFeeDistributor public feeDistributor;

    address owner = makeAddr("owner");
    address factoryAddr = makeAddr("factory");
    address attacker = makeAddr("attacker");
    address tokenContract = makeAddr("tokenContract");
    address randomAddr = makeAddr("random");

    address rareToken = makeAddr("rareToken");
    address liquidToken = makeAddr("liquidToken");

    uint16 constant FEE_BPS = 400; // 4%

    PoolKey rareIsToken0Key;  // currency0 = RARE, currency1 = liquidToken
    PoolKey rareIsToken1Key;  // currency0 = liquidToken, currency1 = RARE
    PoolKey nonRareKey;       // neither currency is RARE

    function setUp() public {
        poolManager = new MockPoolManager();
        feeDistributor = new MockFeeDistributor(FEE_BPS);

        vm.prank(owner);
        guard = new LiquidGuard(
            IPoolManager(address(poolManager)),
            owner,
            rareToken,
            true // skip validation (address won't have 0x20CC pattern in tests)
        );

        vm.prank(owner);
        guard.setFeeDistributor(address(feeDistributor));

        // Build pool keys: V4 requires currency0 < currency1 by address.
        // We build both orderings and name them by where RARE actually lands.
        address addrLow  = rareToken < liquidToken ? rareToken  : liquidToken;
        address addrHigh = rareToken < liquidToken ? liquidToken : rareToken;

        // rareIsToken0Key: RARE is currency0 iff rareToken < liquidToken.
        // If rareToken > liquidToken, we still put the lower address as currency0 (V4 invariant).
        // The key name reflects the actual RARE position.
        if (rareToken < liquidToken) {
            // RARE is the lower address → it IS currency0
            rareIsToken0Key = PoolKey({
                currency0: Currency.wrap(rareToken),
                currency1: Currency.wrap(liquidToken),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(guard))
            });
            rareIsToken1Key = PoolKey({
                currency0: Currency.wrap(liquidToken),
                currency1: Currency.wrap(rareToken),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(guard))
            });
        } else {
            // rareToken > liquidToken → RARE must be currency1 in the sorted pool
            // rareIsToken0Key: we force RARE to be currency0 by using a different fee (for testing only)
            // Actually for guard tests we just need one key where RARE is currency0 and one where it's currency1.
            // Since V4 sorts by address, use fee tier to distinguish and just put RARE as currency0 regardless.
            rareIsToken0Key = PoolKey({
                currency0: Currency.wrap(rareToken),   // higher address — test-only, guard doesn't validate ordering
                currency1: Currency.wrap(liquidToken),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(guard))
            });
            rareIsToken1Key = PoolKey({
                currency0: Currency.wrap(addrLow),    // liquidToken is lower
                currency1: Currency.wrap(addrHigh),   // rareToken is higher
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(guard))
            });
        }

        nonRareKey = PoolKey({
            currency0: Currency.wrap(makeAddr("tokenA")),
            currency1: Currency.wrap(makeAddr("tokenB")),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(guard))
        });
    }

    // ============================================
    // beforeInitialize
    // ============================================

    function test_beforeInitialize_AuthorizedSucceeds() public {
        vm.prank(owner);
        guard.addInitializer(tokenContract);

        uint160 price = TickMath.getSqrtPriceAtTick(0);
        vm.prank(address(poolManager));
        bytes4 selector = guard.beforeInitialize(tokenContract, rareIsToken0Key, price);
        assertEq(selector, IHooks.beforeInitialize.selector);
    }

    function test_beforeInitialize_UnauthorizedReverts() public {
        uint160 price = TickMath.getSqrtPriceAtTick(0);
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidGuard.UnauthorizedInitializer.selector, attacker)
        );
        vm.prank(address(poolManager));
        guard.beforeInitialize(attacker, rareIsToken0Key, price);
    }

    function test_beforeInitialize_NotPoolManagerReverts() public {
        vm.prank(owner);
        guard.addInitializer(tokenContract);

        uint160 price = TickMath.getSqrtPriceAtTick(0);
        vm.expectRevert(ILiquidGuard.NotPoolManager.selector);
        vm.prank(randomAddr);
        guard.beforeInitialize(tokenContract, rareIsToken0Key, price);
    }

    // ============================================
    // Non-RARE pool passthrough
    // ============================================

    function test_beforeSwap_NonRarePool_ZeroDelta() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            guard.beforeSwap(randomAddr, nonRareKey, params, "");

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
        assertEq(poolManager.takeCallCount(), 0);
        assertEq(feeDistributor.notificationCount(), 0);
    }

    function test_afterSwap_NonRarePool_ZeroDelta() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (bytes4 selector, int128 delta) =
            guard.afterSwap(randomAddr, nonRareKey, params, BalanceDeltaLibrary.ZERO_DELTA, "");

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(delta, 0);
        assertEq(poolManager.takeCallCount(), 0);
    }

    // ============================================
    // beforeSwap: RARE is specified currency
    // ============================================

    function test_beforeSwap_RareIsSpecified_ExactIn_ZeroForOne() public {
        // rareIsToken0, zeroForOne=true, exactInput → RARE is specified
        // amountSpecified < 0 = exact input
        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        if (!isRareToken0) {
            // use rareIsToken1Key instead and !zeroForOne
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: 0
            });
            vm.prank(address(poolManager));
            (bytes4 selector, BeforeSwapDelta delta, ) =
                guard.beforeSwap(randomAddr, rareIsToken1Key, params, "");

            assertEq(selector, IHooks.beforeSwap.selector);
            uint256 expectedFee = (1e18 * uint256(FEE_BPS)) / 10_000;
            // upper 128 bits of BeforeSwapDelta = specifiedDelta
            int128 specifiedDelta = int128(BeforeSwapDelta.unwrap(delta) >> 128);
            assertEq(uint128(specifiedDelta), uint128(expectedFee));
            assertEq(poolManager.takeCallCount(), 1);
            assertEq(feeDistributor.notificationCount(), 1);
        } else {
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: 0
            });
            vm.prank(address(poolManager));
            (bytes4 selector, BeforeSwapDelta delta, ) =
                guard.beforeSwap(randomAddr, rareIsToken0Key, params, "");

            assertEq(selector, IHooks.beforeSwap.selector);
            uint256 expectedFee = (1e18 * uint256(FEE_BPS)) / 10_000;
            int128 specifiedDelta = int128(BeforeSwapDelta.unwrap(delta) >> 128);
            assertEq(uint128(specifiedDelta), uint128(expectedFee));
            assertEq(poolManager.takeCallCount(), 1);
            assertEq(feeDistributor.notificationCount(), 1);
        }
    }

    function test_beforeSwap_NotifyFeeReverts_DoesNotRevertSwap() public {
        MockFeeDistributorRevert revertDist = new MockFeeDistributorRevert();
        vm.prank(owner);
        guard.setFeeDistributor(address(revertDist));

        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key = isRareToken0 ? rareIsToken0Key : rareIsToken1Key;
        uint256 amount = 1e18;
        uint256 expectedFee = (amount * 400) / 10_000;
        address expectedLiquidToken = isRareToken0
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: isRareToken0,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, true, false, true);
        emit LiquidGuard.FeeNotifyFailed(address(revertDist), expectedLiquidToken, expectedFee);

        vm.prank(address(poolManager));
        (bytes4 selector, BeforeSwapDelta delta, ) =
            guard.beforeSwap(randomAddr, key, params, "");

        assertEq(selector, IHooks.beforeSwap.selector);
        int128 specifiedDelta = int128(BeforeSwapDelta.unwrap(delta) >> 128);
        assertEq(uint128(specifiedDelta), expectedFee);
        assertEq(poolManager.takeCallCount(), 1);
    }

    function test_beforeSwap_FeeAmount_IsCorrect() public {
        // Use whichever key has RARE as currency0 / token0
        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key = isRareToken0 ? rareIsToken0Key : rareIsToken1Key;
        bool zeroForOne = isRareToken0 ? true : false;

        uint256 amount = 10_000e18;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (, BeforeSwapDelta delta, ) = guard.beforeSwap(randomAddr, key, params, "");

        uint256 expectedFee = (amount * FEE_BPS) / 10_000;
        int128 specifiedDelta = int128(BeforeSwapDelta.unwrap(delta) >> 128);
        assertEq(uint128(specifiedDelta), uint128(expectedFee));

        // Verify take was called with correct fee
        (Currency currency, address to, uint256 takeAmount) = poolManager.takeCalls(0);
        assertEq(Currency.unwrap(currency), rareToken);
        assertEq(to, address(feeDistributor));
        assertEq(takeAmount, expectedFee);

        // Verify notifyFee called
        (address notifyToken, uint256 notifyAmount) = feeDistributor.notifications(0);
        assertEq(notifyToken, isRareToken0
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0));
        assertEq(notifyAmount, expectedFee);
    }

    // ============================================
    // afterSwap: RARE is unspecified currency
    // ============================================

    function test_afterSwap_RareIsUnspecified_TakesFee() public {
        // RARE is unspecified: e.g., LIQUID is specified (exact input), zeroForOne = !isRareToken0
        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;

        // zeroForOne = true, exactInput: specified=currency0, unspecified=currency1
        // If rare is token1, it's unspecified when zeroForOne=true exactInput
        // If rare is token0, it's unspecified when !zeroForOne + exactInput

        PoolKey memory key;
        bool zeroForOne;
        if (isRareToken0) {
            key = rareIsToken0Key;
            zeroForOne = false; // !zeroForOne + exactInput → specified=currency1=liquid, unspecified=currency0=RARE
        } else {
            key = rareIsToken1Key;
            zeroForOne = true; // zeroForOne + exactInput → specified=currency0=liquid, unspecified=currency1=RARE
        }

        uint256 swapAmount = 1e18;
        uint256 rareOutput = 500e18; // RARE received by caller as unspecified output

        // delta: RARE is positive (caller receives RARE)
        // For rareIsToken0: amount0 = rareOutput, amount1 = -swapAmount
        // For rareIsToken1: amount0 = -swapAmount, amount1 = rareOutput
        BalanceDelta swapDelta;
        if (isRareToken0) {
            // amount0 = +rareOutput (RARE for caller), amount1 = -swapAmount
            swapDelta = toBalanceDelta(int128(uint128(rareOutput)), -int128(uint128(swapAmount)));
        } else {
            // amount0 = -swapAmount, amount1 = +rareOutput (RARE for caller)
            swapDelta = toBalanceDelta(-int128(uint128(swapAmount)), int128(uint128(rareOutput)));
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (bytes4 selector, int128 hookDelta) =
            guard.afterSwap(randomAddr, key, params, swapDelta, "");

        assertEq(selector, IHooks.afterSwap.selector);

        uint256 expectedFee = (rareOutput * FEE_BPS) / 10_000;
        assertEq(uint128(hookDelta), uint128(expectedFee));
        assertEq(poolManager.takeCallCount(), 1);

        (Currency currency, address to, uint256 takeAmt) = poolManager.takeCalls(0);
        assertEq(Currency.unwrap(currency), rareToken);
        assertEq(to, address(feeDistributor));
        assertEq(takeAmt, expectedFee);
    }

    function test_afterSwap_NotifyFeeReverts_DoesNotRevertSwap() public {
        MockFeeDistributorRevert revertDist = new MockFeeDistributorRevert();
        vm.prank(owner);
        guard.setFeeDistributor(address(revertDist));

        // Match RARE-unspecified path in afterSwap with RARE output.
        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key;
        bool zeroForOne;
        if (isRareToken0) {
            key = rareIsToken0Key;
            zeroForOne = false;
        } else {
            key = rareIsToken1Key;
            zeroForOne = true;
        }

        uint256 swapAmount = 1e18;
        uint256 rareOutput = 500e18;
        BalanceDelta swapDelta = isRareToken0
            ? toBalanceDelta(int128(uint128(rareOutput)), -int128(uint128(swapAmount)))
            : toBalanceDelta(-int128(uint128(swapAmount)), int128(uint128(rareOutput)));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: 0
        });

        uint256 expectedFee = (rareOutput * 400) / 10_000;
        address expectedLiquidToken = isRareToken0
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        vm.expectEmit(true, true, false, true);
        emit LiquidGuard.FeeNotifyFailed(address(revertDist), expectedLiquidToken, expectedFee);

        vm.prank(address(poolManager));
        (bytes4 selector, int128 hookDelta) =
            guard.afterSwap(randomAddr, key, params, swapDelta, "");

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(uint128(hookDelta), uint128(expectedFee));
        assertEq(poolManager.takeCallCount(), 1);

        (Currency currency, address to, uint256 takeAmt) = poolManager.takeCalls(0);
        assertEq(Currency.unwrap(currency), rareToken);
        assertEq(to, address(revertDist));
        assertEq(takeAmt, expectedFee);
    }

    function test_afterSwap_RareIsSpecified_SkipsFee() public {
        // RARE is specified → afterSwap should skip (beforeSwap handled it)
        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key = isRareToken0 ? rareIsToken0Key : rareIsToken1Key;
        bool zeroForOne = isRareToken0 ? true : false; // RARE specified: zeroForOne + exactInput for rareIsToken0

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1e18, // exact input
            sqrtPriceLimitX96: 0
        });

        BalanceDelta swapDelta = toBalanceDelta(-1e18, int128(uint128(500e18)));

        vm.prank(address(poolManager));
        (, int128 hookDelta) = guard.afterSwap(randomAddr, key, params, swapDelta, "");

        assertEq(hookDelta, 0);
        assertEq(poolManager.takeCallCount(), 0);
    }

    // ============================================
    // afterSwap: RARE is unspecified INPUT (exact-output, fee bypass fix)
    // ============================================

    /// @notice Regression test: exact-output swap where output is LIQUID and RARE is the
    ///         unspecified input must still charge fees. Before the fix, afterSwap early-returned
    ///         when rareRawDelta <= 0, allowing fee-free swaps via direct PoolManager access.
    function test_afterSwap_RareIsUnspecifiedInput_ChargesFee() public {
        // Scenario: exact-output swap, zeroForOne=true, output=LIQUID (specified), input=RARE (unspecified)
        // For rareIsToken0: zeroForOne=true + exactOutput → specified=currency1=LIQUID, unspecified=currency0=RARE
        // rareIsSpecified = (true == (true == false)) = (true == false) = false → afterSwap handles
        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;

        PoolKey memory key;
        bool zeroForOne;
        if (isRareToken0) {
            key = rareIsToken0Key;
            zeroForOne = true; // zeroForOne + exactOutput → specified=currency1=LIQUID, unspecified=currency0=RARE
        } else {
            key = rareIsToken1Key;
            zeroForOne = false; // !zeroForOne + exactOutput → specified=currency0=LIQUID, unspecified=currency1=RARE
        }

        uint256 liquidOutput = 500e18;  // exact output the caller wants
        uint256 rareInput = 1000e18;    // RARE the caller must pay (unspecified)

        // delta: RARE is negative (caller pays RARE), LIQUID is positive (caller receives LIQUID)
        BalanceDelta swapDelta;
        if (isRareToken0) {
            // amount0 = -rareInput (RARE owed by caller), amount1 = +liquidOutput
            swapDelta = toBalanceDelta(-int128(uint128(rareInput)), int128(uint128(liquidOutput)));
        } else {
            // amount0 = +liquidOutput, amount1 = -rareInput (RARE owed by caller)
            swapDelta = toBalanceDelta(int128(uint128(liquidOutput)), -int128(uint128(rareInput)));
        }

        // exactOutput: amountSpecified > 0
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(liquidOutput),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (bytes4 selector, int128 hookDelta) =
            guard.afterSwap(randomAddr, key, params, swapDelta, "");

        assertEq(selector, IHooks.afterSwap.selector);

        // Fee should be charged on the absolute RARE input amount
        uint256 expectedFee = (rareInput * FEE_BPS) / 10_000;
        assertGt(hookDelta, 0, "hookDelta should be positive (fee charged)");
        assertEq(uint128(hookDelta), uint128(expectedFee), "fee amount mismatch");

        // Verify take() was called
        assertEq(poolManager.takeCallCount(), 1, "take should have been called");
        (Currency currency, address to, uint256 takeAmt) = poolManager.takeCalls(0);
        assertEq(Currency.unwrap(currency), rareToken);
        assertEq(to, address(feeDistributor));
        assertEq(takeAmt, expectedFee);

        // Verify notifyFee() was called
        assertEq(feeDistributor.notificationCount(), 1, "notifyFee should have been called");
    }

    /// @notice Verify that beforeSwap also does NOT handle the exact-output-LIQUID case
    ///         (confirming afterSwap is the correct handler).
    function test_beforeSwap_ExactOutputLiquid_RareUnspecified_ZeroDelta() public {
        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;

        PoolKey memory key;
        bool zeroForOne;
        if (isRareToken0) {
            key = rareIsToken0Key;
            zeroForOne = true;
        } else {
            key = rareIsToken1Key;
            zeroForOne = false;
        }

        // exactOutput: amountSpecified > 0
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(500e18),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (, BeforeSwapDelta delta, ) = guard.beforeSwap(randomAddr, key, params, "");

        // beforeSwap should return zero delta because RARE is unspecified in this scenario
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "beforeSwap should not charge fee when RARE is unspecified");
        assertEq(poolManager.takeCallCount(), 0);
    }

    /// @notice Ensure fee clamping also works for the negative-delta (unspecified input) path
    function test_afterSwap_RareUnspecifiedInput_FeeClamp() public {
        // Set fee to 100% to trigger clamp — deploy new distributor with 10_000 BPS
        MockFeeDistributor maxFeeDist = new MockFeeDistributor(10_000);
        vm.prank(owner);
        guard.setFeeDistributor(address(maxFeeDist));

        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key;
        bool zeroForOne;
        if (isRareToken0) {
            key = rareIsToken0Key;
            zeroForOne = true;
        } else {
            key = rareIsToken1Key;
            zeroForOne = false;
        }

        uint256 rareInput = 1000;
        uint256 liquidOutput = 500;

        BalanceDelta swapDelta;
        if (isRareToken0) {
            swapDelta = toBalanceDelta(-int128(uint128(rareInput)), int128(uint128(liquidOutput)));
        } else {
            swapDelta = toBalanceDelta(int128(uint128(liquidOutput)), -int128(uint128(rareInput)));
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(liquidOutput),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (, int128 hookDelta) = guard.afterSwap(randomAddr, key, params, swapDelta, "");

        // fee should be clamped to rareInput - 1 = 999
        assertEq(uint128(hookDelta), 999, "fee should be clamped to rareAmount - 1");
    }

    // ============================================
    // Fee clamping: fee < absAmount
    // ============================================

    function test_beforeSwap_FeeClamp() public {
        // Set fee to 100% to trigger clamp — deploy new distributor with 10_000 BPS
        MockFeeDistributor maxFeeDist = new MockFeeDistributor(10_000);
        vm.prank(owner);
        guard.setFeeDistributor(address(maxFeeDist));

        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key = isRareToken0 ? rareIsToken0Key : rareIsToken1Key;
        bool zeroForOne = isRareToken0 ? true : false;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1000,
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (, BeforeSwapDelta delta, ) = guard.beforeSwap(randomAddr, key, params, "");

        // fee should be clamped to absAmount - 1 = 999
        int128 specifiedDelta = int128(BeforeSwapDelta.unwrap(delta) >> 128);
        assertLt(uint128(specifiedDelta), uint128(1000));
        assertEq(uint128(specifiedDelta), 999);
    }

    function test_afterSwap_FeeClamp() public {
        // Set fee to 100% to trigger clamp — deploy new distributor with 10_000 BPS
        MockFeeDistributor maxFeeDist = new MockFeeDistributor(10_000);
        vm.prank(owner);
        guard.setFeeDistributor(address(maxFeeDist));

        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key = isRareToken0 ? rareIsToken0Key : rareIsToken1Key;
        bool zeroForOne = !isRareToken0; // RARE is unspecified

        uint256 swapAmount = 1e18;
        uint256 rareOutput = 1000;
        BalanceDelta swapDelta;
        if (isRareToken0) {
            // amount0: +rareOutput (RARE to caller), amount1: -swapAmount
            swapDelta = toBalanceDelta(int128(uint128(rareOutput)), -int128(uint128(swapAmount)));
        } else {
            // amount0: -swapAmount, amount1: +rareOutput (RARE to caller)
            swapDelta = toBalanceDelta(-int128(uint128(swapAmount)), int128(uint128(rareOutput)));
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (bytes4 selector, int128 hookDelta) =
            guard.afterSwap(randomAddr, key, params, swapDelta, "");

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(uint128(hookDelta), 999);

        (Currency takeCurrency, , uint256 takeAmount) = poolManager.takeCalls(0);
        assertEq(takeAmount, 999);
        assertEq(Currency.unwrap(takeCurrency), rareToken);
    }

    // ============================================
    // afterSwap: zero RARE delta → no fee
    // ============================================

    function test_afterSwap_ZeroRareDelta_SkipsFee() public {
        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key = isRareToken0 ? rareIsToken0Key : rareIsToken1Key;
        bool zeroForOne = !isRareToken0; // RARE is unspecified

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        // RARE delta = 0 (no output)
        BalanceDelta swapDelta = BalanceDeltaLibrary.ZERO_DELTA;

        vm.prank(address(poolManager));
        (, int128 hookDelta) = guard.afterSwap(randomAddr, key, params, swapDelta, "");

        assertEq(hookDelta, 0);
        assertEq(poolManager.takeCallCount(), 0);
    }

    // ============================================
    // No feeDistributor → no take(), no notify
    // ============================================

    function test_beforeSwap_NoFeeDistributor_SkipsTake() public {
        // Clear feeDistributor
        vm.prank(owner);
        guard.setFeeDistributor(address(0));

        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key = isRareToken0 ? rareIsToken0Key : rareIsToken1Key;
        bool zeroForOne = isRareToken0 ? true : false;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (, BeforeSwapDelta delta, ) = guard.beforeSwap(randomAddr, key, params, "");

        // no distributor → no take/notify and zero delta (returning delta without take breaks PM accounting)
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(poolManager.takeCallCount(), 0);
    }

    // ============================================
    // Edge case: type(int256).min amountSpecified
    // ============================================

    function test_beforeSwap_MinInt256_ReturnsZeroDelta() public {
        // type(int256).min cannot be safely negated in signed arithmetic — Solidity 0.8 panics.
        // The guard must return zero delta rather than reverting.
        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key = isRareToken0 ? rareIsToken0Key : rareIsToken1Key;
        bool zeroForOne = isRareToken0 ? true : false;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: type(int256).min,
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (, BeforeSwapDelta delta, ) = guard.beforeSwap(randomAddr, key, params, "");

        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(poolManager.takeCallCount(), 0);
    }

    function test_beforeSwap_AmountSpecifiedZero_ReturnsZeroDelta() public {
        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key = isRareToken0 ? rareIsToken0Key : rareIsToken1Key;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: isRareToken0,
            amountSpecified: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (bytes4 selector, BeforeSwapDelta delta, ) = guard.beforeSwap(randomAddr, key, params, "");

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(poolManager.takeCallCount(), 0);
        assertEq(feeDistributor.notificationCount(), 0);
    }

    // ============================================
    // Admin functions
    // ============================================

    function test_setFactory_ByOwner() public {
        vm.prank(owner);
        guard.setFactory(factoryAddr);
        assertEq(guard.factory(), factoryAddr);
    }

    function test_setFactory_RevertsForZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ILiquidGuard.InvalidFactoryAddress.selector);
        guard.setFactory(address(0));
    }

    function test_setFactory_RevertsForNonOwner() public {
        vm.prank(randomAddr);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomAddr)
        );
        guard.setFactory(factoryAddr);
    }

    function test_setFactory_EmitsFactoryUpdated() public {
        address oldFactory = guard.factory();

        vm.expectEmit(true, true, false, false);
        emit ILiquidGuard.FactoryUpdated(oldFactory, factoryAddr);

        vm.prank(owner);
        guard.setFactory(factoryAddr);
    }

    function test_setFeeDistributor_ByOwner() public {
        // Must be a contract — deploy a minimal stub
        address newDist = address(new FeeDistributorStub());
        vm.prank(owner);
        guard.setFeeDistributor(newDist);
        assertEq(guard.feeDistributor(), newDist);
    }

    function test_setFeeDistributor_RevertsForEOA() public {
        address eoa = makeAddr("eoa");
        vm.prank(owner);
        vm.expectRevert(ILiquidGuard.InvalidFeeDistributor.selector);
        guard.setFeeDistributor(eoa);
    }


    function test_setFeeDistributor_SyncsFeeBPSFromDistributor() public {
        MockFeeDistributor customDistributor = new MockFeeDistributor(1234);
        vm.prank(owner);
        guard.setFeeDistributor(address(customDistributor));
        assertEq(guard.totalFeeBPS(), 1234);
    }

    function test_setFeeDistributor_ZeroAddressResetsFeeBPSToZero() public {
        vm.prank(owner);
        guard.setFeeDistributor(address(0));
        assertEq(guard.totalFeeBPS(), 0);
    }

    function test_setFeeDistributor_EmitsFeeDistributorUpdated() public {
        address newDist = address(new FeeDistributorStub());
        address oldDist = guard.feeDistributor();

        vm.expectEmit(true, true, false, false);
        emit ILiquidGuard.FeeDistributorUpdated(oldDist, newDist);

        vm.prank(owner);
        guard.setFeeDistributor(newDist);
    }

    function test_setFeeDistributor_SyncsTotalFeeBPS_AfterUpdate() public {
        // After setFeeDistributor, totalFeeBPS should reflect the new distributor's value.
        MockFeeDistributor customDistributor = new MockFeeDistributor(1234);

        vm.prank(owner);
        guard.setFeeDistributor(address(customDistributor));

        assertEq(guard.totalFeeBPS(), 1234, "totalFeeBPS should be synced from new distributor");
    }

    function test_setFeeDistributor_RevertsForNonOwner() public {
        address newDist = address(new FeeDistributorStub());
        vm.prank(randomAddr);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomAddr)
        );
        guard.setFeeDistributor(newDist);
    }

    function test_setFeeDistributor_RevertsWhen_FeeTooLarge() public {
        MockFeeDistributor overflowDist = new MockFeeDistributor(10_001);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidGuard.FeeTooLarge.selector, uint256(10_001), uint256(10_000))
        );
        guard.setFeeDistributor(address(overflowDist));
    }

    function test_removeInitializer_RevertsForNonOwner() public {
        vm.prank(owner);
        guard.addInitializer(tokenContract);

        vm.prank(randomAddr);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomAddr)
        );
        guard.removeInitializer(tokenContract);
    }

    function test_addInitializer_RevertsForNonOwner() public {
        vm.prank(randomAddr);
        vm.expectRevert(ILiquidGuard.NotOwnerOrFactory.selector);
        guard.addInitializer(tokenContract);
    }

    function test_addInitializer_ZeroAddress_Succeeds() public {
        vm.prank(owner);
        guard.addInitializer(address(0));
        assertTrue(guard.allowedInitializers(address(0)));
    }

    function test_FactoryCanAddInitializer() public {
        vm.prank(owner);
        guard.setFactory(factoryAddr);

        vm.prank(factoryAddr);
        guard.addInitializer(tokenContract);
        assertTrue(guard.allowedInitializers(tokenContract));
    }

    function test_NonOwnerNonFactory_CannotAddInitializer() public {
        vm.prank(owner);
        guard.setFactory(factoryAddr);

        vm.prank(randomAddr);
        vm.expectRevert(ILiquidGuard.NotOwnerOrFactory.selector);
        guard.addInitializer(tokenContract);
    }

    function test_OwnerCanRemoveInitializer() public {
        vm.prank(owner);
        guard.addInitializer(tokenContract);

        vm.prank(owner);
        guard.removeInitializer(tokenContract);
        assertFalse(guard.allowedInitializers(tokenContract));
    }

    // ============================================
    // Constructor: zero-address validation
    // ============================================

    function test_constructor_RevertsForZeroPoolManager() public {
        vm.expectRevert("LiquidGuard: zero pool manager");
        new LiquidGuard(
            IPoolManager(address(0)),
            owner,
            rareToken,
            true
        );
    }

    function test_constructor_RevertsForZeroRareToken() public {
        vm.expectRevert("LiquidGuard: zero RARE token");
        new LiquidGuard(
            IPoolManager(address(poolManager)),
            owner,
            address(0),
            true
        );
    }

    // ============================================
    // afterSwap: type(int128).min guard
    // ============================================

    function test_afterSwap_MinInt128_ReturnsZeroDelta() public {
        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key;
        bool zeroForOne;
        if (isRareToken0) {
            key = rareIsToken0Key;
            zeroForOne = false;
        } else {
            key = rareIsToken1Key;
            zeroForOne = true;
        }

        BalanceDelta swapDelta;
        if (isRareToken0) {
            swapDelta = toBalanceDelta(type(int128).min, int128(uint128(1e18)));
        } else {
            swapDelta = toBalanceDelta(int128(uint128(1e18)), type(int128).min);
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(1e18),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (bytes4 selector, int128 hookDelta) =
            guard.afterSwap(randomAddr, key, params, swapDelta, "");

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0, "should return zero delta for int128.min to avoid overflow revert");
        assertEq(poolManager.takeCallCount(), 0, "should not call take()");
    }

    // ============================================
    // setFeeDistributor: TotalFeeBpsUpdated event
    // ============================================

    function test_setFeeDistributor_EmitsTotalFeeBpsUpdated() public {
        uint16 oldBps = guard.totalFeeBPS();
        MockFeeDistributor newDist = new MockFeeDistributor(750);

        vm.expectEmit(false, false, false, true);
        emit ILiquidGuard.TotalFeeBpsUpdated(oldBps, 750);

        vm.prank(owner);
        guard.setFeeDistributor(address(newDist));
    }

    function test_setFeeDistributor_NoTotalFeeBpsEvent_WhenUnchanged() public {
        MockFeeDistributor sameBpsDist = new MockFeeDistributor(FEE_BPS);

        vm.recordLogs();
        vm.prank(owner);
        guard.setFeeDistributor(address(sameBpsDist));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeBpsEventSig = keccak256("TotalFeeBpsUpdated(uint16,uint16)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != feeBpsEventSig, "should not emit TotalFeeBpsUpdated when BPS unchanged");
        }
    }

    // ============================================
    // Fuzz tests for fee calculations
    // ============================================

    function testFuzz_BeforeSwap_FeeNeverExceedsSwapAmount(uint128 swapAmt) public {
        swapAmt = uint128(bound(uint256(swapAmt), 1e6, 1_000_000e18));

        bool isRareToken0 = Currency.unwrap(rareIsToken0Key.currency0) == rareToken;
        PoolKey memory key = isRareToken0 ? rareIsToken0Key : rareIsToken1Key;

        // exactInput (negative amountSpecified = RARE in)
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: isRareToken0,
            amountSpecified: -int256(uint256(swapAmt)),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (, BeforeSwapDelta delta, ) = guard.beforeSwap(randomAddr, key, params, "");

        // specifiedDelta upper 128 bits stores the fee as a positive uint128
        // (it represents RARE taken from the swap as fee)
        uint128 feeTaken = uint128(uint256(BeforeSwapDelta.unwrap(delta) >> 128));
        uint256 expectedFee = (uint256(swapAmt) * uint256(FEE_BPS)) / 10_000;

        assertEq(feeTaken, expectedFee, "fee should equal exactly swapAmt * FEE_BPS / 10000");
        assertLe(feeTaken, swapAmt, "fee must never exceed the swap amount");
    }

    function testFuzz_SetFeeDistributor_FeeBPS_ValidRange(uint16 feeBps) public {
        feeBps = uint16(bound(uint256(feeBps), 0, 10_000));

        MockFeeDistributor customDistributor = new MockFeeDistributor(feeBps);

        vm.prank(owner);
        guard.setFeeDistributor(address(customDistributor));

        assertEq(guard.totalFeeBPS(), feeBps, "totalFeeBPS should match distributor");
    }
}

/// @dev Minimal contract stub so setFeeDistributor code.length check passes
contract FeeDistributorStub {
    function totalFeeBPS() external pure returns (uint16) {
        return 400;
    }
}
