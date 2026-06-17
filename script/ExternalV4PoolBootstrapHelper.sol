// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

/// @title ExternalV4PoolBootstrapHelper
/// @notice One-shot helper for initializing and seeding an ERC20/ERC20 Uniswap V4 pool.
/// @dev The helper is meant to be allowlisted temporarily in LiquidGuard, then used once by its owner.
contract ExternalV4PoolBootstrapHelper is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    error NotOwner();
    error OnlyPoolManager();
    error NativeCurrencyNotSupported();
    error HelperAlreadyUsed();
    error Amount0ExceedsMax(uint256 actual, uint256 max);
    error Amount1ExceedsMax(uint256 actual, uint256 max);
    error AddressZero();

    struct BootstrapParams {
        PoolKey key;
        uint160 sqrtPriceX96;
        bool initializePool;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
        uint256 amount0Max;
        uint256 amount1Max;
    }

    IPoolManager public immutable POOL_MANAGER;
    address public immutable OWNER;

    /// @notice Set to true after a successful bootstrap so an allowlisted helper cannot be reused.
    bool public used;

    constructor(IPoolManager poolManager, address owner_) {
        if (address(poolManager) == address(0) || owner_ == address(0)) {
            revert AddressZero();
        }
        POOL_MANAGER = poolManager;
        OWNER = owner_;
    }

    function bootstrap(
        BootstrapParams calldata params
    ) external returns (uint256 amount0Used, uint256 amount1Used) {
        if (msg.sender != OWNER) revert NotOwner();
        if (used) revert HelperAlreadyUsed();

        // Set eagerly so a successful bootstrap permanently burns the helper.
        // If unlock reverts, the whole transaction reverts and `used` rolls back.
        used = true;

        bytes memory result = POOL_MANAGER.unlock(abi.encode(params));
        return abi.decode(result, (uint256, uint256));
    }

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert OnlyPoolManager();

        BootstrapParams memory params = abi.decode(data, (BootstrapParams));

        address token0 = Currency.unwrap(params.key.currency0);
        address token1 = Currency.unwrap(params.key.currency1);
        if (token0 == address(0) || token1 == address(0)) {
            revert NativeCurrencyNotSupported();
        }

        if (params.initializePool) {
            POOL_MANAGER.initialize(params.key, params.sqrtPriceX96);
        }

        (BalanceDelta delta, ) = POOL_MANAGER.modifyLiquidity(
            params.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        uint256 amount0Used = _settleCurrency(
            params.key.currency0,
            delta.amount0(),
            params.amount0Max,
            true
        );
        uint256 amount1Used = _settleCurrency(
            params.key.currency1,
            delta.amount1(),
            params.amount1Max,
            false
        );

        return abi.encode(amount0Used, amount1Used);
    }

    function _settleCurrency(
        Currency currency,
        int128 deltaAmount,
        uint256 maxAmount,
        bool isCurrency0
    ) internal returns (uint256 amountUsed) {
        if (deltaAmount < 0) {
            amountUsed = _toUint128Neg(deltaAmount);
            if (amountUsed > maxAmount) {
                if (isCurrency0) revert Amount0ExceedsMax(amountUsed, maxAmount);
                revert Amount1ExceedsMax(amountUsed, maxAmount);
            }

            POOL_MANAGER.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(
                OWNER,
                address(POOL_MANAGER),
                amountUsed
            );
            POOL_MANAGER.settle();
            return amountUsed;
        }

        if (deltaAmount > 0) {
            uint128 amountOwedBack = _toUint128Pos(deltaAmount);
            POOL_MANAGER.take(currency, OWNER, amountOwedBack);
        }

        return 0;
    }

    function _toUint128Pos(int128 value) internal pure returns (uint128) {
        return uint128(uint256(int256(value)));
    }

    function _toUint128Neg(int128 value) internal pure returns (uint128) {
        int256 absoluteValue = -int256(value);
        return uint128(uint256(absoluteValue));
    }
}
