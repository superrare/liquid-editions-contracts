// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LiquidPoolSwapHelper
/// @notice Helper to execute RARE<->LIQUID swaps on Liquid token pools for testing
/// @dev Uses unlock callback pattern. Caller must approve this contract for token transfers.
contract LiquidPoolSwapHelper is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable POOL_MANAGER;

    struct SwapParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        address baseToken;
        address liquidToken;
        bool zeroForOne;
        int256 amountSpecified;
        address payer;
        address recipient;
    }

    constructor(IPoolManager _poolManager) {
        POOL_MANAGER = _poolManager;
    }

    /// @notice Buy LIQUID with RARE (exact RARE in)
    function buy(
        address token,
        uint256 rareAmount,
        address recipient
    ) external returns (uint256 liquidOut) {
        (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) =
            _getPoolKey(token);
        (, address baseToken) = _getBaseToken(token);
        address liquidToken = token;
        bool baseIs0Actual = baseToken < liquidToken;
        (BalanceDelta delta, ) = _swap(
            Currency.wrap(currency0),
            Currency.wrap(currency1),
            fee,
            tickSpacing,
            hooks,
            baseToken,
            liquidToken,
            baseIs0Actual,
            -int256(rareAmount),
            msg.sender,
            recipient
        );
        int128 out = baseIs0Actual ? delta.amount1() : delta.amount0();
        return uint128(out);
    }

    function _getPoolKey(address token) internal view returns (
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("poolKey()")
        );
        require(success && data.length >= 32);
        return abi.decode(data, (address, address, uint24, int24, address));
    }

    function _getBaseToken(address token) internal view returns (bool baseIs0, address baseAddr) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("baseToken()")
        );
        require(success && data.length >= 32);
        baseAddr = abi.decode(data, (address));
        baseIs0 = baseAddr < token;
    }

    /// @notice Sell LIQUID for RARE (exact LIQUID in)
    function sell(
        address token,
        uint256 liquidAmount,
        address recipient
    ) external returns (uint256 rareOut) {
        (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) =
            _getPoolKey(token);
        (, address baseToken) = _getBaseToken(token);
        address liquidToken = token;
        bool baseIs0 = baseToken < liquidToken;
        (BalanceDelta delta, ) = _swap(
            Currency.wrap(currency0),
            Currency.wrap(currency1),
            fee,
            tickSpacing,
            hooks,
            baseToken,
            liquidToken,
            !baseIs0,
            -int256(liquidAmount),
            msg.sender,
            recipient
        );
        int128 out = baseIs0 ? delta.amount0() : delta.amount1();
        return uint128(out);
    }

    function _swap(
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooksAddr,
        address baseToken,
        address liquidToken,
        bool zeroForOne,
        int256 amountSpecified,
        address payer,
        address recipient
    ) internal returns (BalanceDelta, bytes memory) {
        SwapParams memory params = SwapParams({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooksAddr,
            baseToken: baseToken,
            liquidToken: liquidToken,
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            payer: payer,
            recipient: recipient
        });
        return (
            abi.decode(
                POOL_MANAGER.unlock(abi.encode(params)),
                (BalanceDelta)
            ),
            ""
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER));
        SwapParams memory params = abi.decode(data, (SwapParams));

        PoolKey memory poolKey = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(params.hooks)
        });

        BalanceDelta delta = POOL_MANAGER.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 < 0) {
            uint256 owed = uint256(uint128(-delta0));
            address token0 = Currency.unwrap(params.currency0);
            POOL_MANAGER.sync(params.currency0);
            if (params.payer != address(this)) {
                IERC20(token0).safeTransferFrom(params.payer, address(POOL_MANAGER), owed);
            } else {
                IERC20(token0).safeTransfer(address(POOL_MANAGER), owed);
            }
            POOL_MANAGER.settle();
        }
        if (delta1 < 0) {
            uint256 owed = uint256(uint128(-delta1));
            address token1 = Currency.unwrap(params.currency1);
            POOL_MANAGER.sync(params.currency1);
            if (params.payer != address(this)) {
                IERC20(token1).safeTransferFrom(params.payer, address(POOL_MANAGER), owed);
            } else {
                IERC20(token1).safeTransfer(address(POOL_MANAGER), owed);
            }
            POOL_MANAGER.settle();
        }
        if (delta0 > 0) {
            uint256 amount = uint256(uint128(delta0));
            POOL_MANAGER.take(params.currency0, params.recipient, amount);
        }
        if (delta1 > 0) {
            uint256 amount = uint256(uint128(delta1));
            POOL_MANAGER.take(params.currency1, params.recipient, amount);
        }

        return abi.encode(delta);
    }
}
