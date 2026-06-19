// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {ISovereignERC20Market} from "liquid-editions/interfaces/ISovereignERC20Market.sol";
import {SovereignERC20Core} from "liquid-editions/extensions/SovereignERC20Core.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {Curve, Multicurve} from "doppler/libraries/Multicurve.sol";
import {Position} from "doppler/types/Position.sol";

/// @title SovereignERC20MarketCore
/// @notice Shared Uniswap V4 multicurve bootstrap for Sovereign market variants.
abstract contract SovereignERC20MarketCore is SovereignERC20Core, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    uint24 internal constant LP_FEE = 0;
    uint256 internal constant MAX_POSITIONS = 25;

    address public factory;
    address public baseToken;
    address public poolManager;
    uint256 public marketSupply;

    PoolKey public poolKey;
    PoolId public poolId;

    Position[] internal _storedPositions;
    bool private _unlockExpected;

    enum UnlockAction {
        INITIALIZE_POOL
    }

    struct UnlockContext {
        UnlockAction action;
        bytes data;
    }

    function _initializeSovereignERC20MarketConfig(
        address initialOwner,
        string memory tokenURI_,
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        Curve[] calldata curves
    ) internal onlyInitializing {
        if (factory != address(0)) {
            revert ISovereignERC20Market.SovereignMarketAlreadyInitialized();
        }
        if (initialSupply == 0) revert ISovereignERC20Market.SovereignMarketZeroSupply();
        if (curves.length == 0) revert ISovereignERC20Market.SovereignMarketZeroCurves();

        factory = msg.sender;
        ILiquidFactory factoryContract = ILiquidFactory(factory);
        baseToken = factoryContract.baseToken();
        poolManager = factoryContract.poolManager();
        if (baseToken == address(0) || poolManager == address(0)) {
            revert ILiquidFactory.AddressZero();
        }

        marketSupply = initialSupply;
        _initializeSovereignERC20Core(initialOwner, name_, symbol_, tokenURI_, initialSupply);
    }

    function _initializeSovereignERC20MarketPool(Curve[] calldata curves) internal {
        _mint(address(this), marketSupply);
        _deployPool(curves);

        uint256 residual = balanceOf(address(this));
        if (residual > 0) {
            _burn(address(this), residual);
            marketSupply -= residual;
        }

        emit ISovereignERC20Market.SovereignMarketInitialized(address(this), poolManager, marketSupply);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager) revert ISovereignERC20Market.SovereignMarketOnlyPoolManager();
        if (!_unlockExpected) revert ISovereignERC20Market.SovereignMarketUnexpectedUnlock();

        UnlockContext memory ctx = abi.decode(data, (UnlockContext));
        if (ctx.action == UnlockAction.INITIALIZE_POOL) {
            return _unlockInitializePool(ctx.data);
        }

        revert ISovereignERC20Market.SovereignMarketUnexpectedUnlock();
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(SovereignERC20Core) returns (bool) {
        return interfaceId == type(ISovereignERC20Market).interfaceId || super.supportsInterface(interfaceId);
    }

    function _deployPool(Curve[] calldata curves) internal {
        ILiquidFactory factoryContract = ILiquidFactory(factory);
        int24 tickSpacing = factoryContract.poolTickSpacing();
        address hooks = factoryContract.poolHooks();
        if (hooks == address(0)) revert ILiquidFactory.PoolHooksNotSet();

        bool isToken0 = address(this) < baseToken;

        Currency currency0;
        Currency currency1;
        if (baseToken < address(this)) {
            currency0 = Currency.wrap(baseToken);
            currency1 = Currency.wrap(address(this));
        } else {
            currency0 = Currency.wrap(address(this));
            currency1 = Currency.wrap(baseToken);
        }

        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: LP_FEE, tickSpacing: tickSpacing, hooks: IHooks(hooks)
        });
        poolId = poolKey.toId();

        Curve[] memory curvesMem = new Curve[](curves.length);
        for (uint256 i; i < curves.length; i++) {
            curvesMem[i] = curves[i];
        }

        (Curve[] memory adjustedCurves, int24 lowerTickBoundary, int24 upperTickBoundary) =
            Multicurve.adjustCurves(curvesMem, 0, tickSpacing, isToken0);

        int24 launchTick = isToken0 ? lowerTickBoundary : upperTickBoundary;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(launchTick);

        Position[] memory positions =
            Multicurve.calculatePositions(adjustedCurves, tickSpacing, marketSupply, 0, isToken0);
        if (positions.length > MAX_POSITIONS) revert ISovereignERC20Market.SovereignMarketTooManyPositions();
        if (!_hasNonzeroLiquidity(positions)) revert ISovereignERC20Market.SovereignMarketNoLiquidity();

        _unlockExpected = true;
        IPoolManager(poolManager)
            .unlock(
                abi.encode(
                    UnlockContext({action: UnlockAction.INITIALIZE_POOL, data: abi.encode(sqrtPriceX96, positions)})
                )
            );
        _unlockExpected = false;
    }

    function _hasNonzeroLiquidity(Position[] memory positions) internal pure returns (bool) {
        for (uint256 i; i < positions.length; i++) {
            if (positions[i].liquidity != 0) return true;
        }
        return false;
    }

    function _unlockInitializePool(bytes memory data) internal returns (bytes memory) {
        (uint160 sqrtPriceX96, Position[] memory positions) = abi.decode(data, (uint160, Position[]));

        IPoolManager pm = IPoolManager(poolManager);
        pm.initialize(poolKey, sqrtPriceX96);

        for (uint256 i; i < positions.length; i++) {
            Position memory pos = positions[i];
            if (pos.liquidity == 0) continue;

            if (pos.liquidity > uint128(type(int128).max)) {
                revert ISovereignERC20Market.SovereignMarketLiquidityTooLarge(pos.liquidity);
            }

            _storedPositions.push(pos);

            (BalanceDelta delta,) = pm.modifyLiquidity(
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: pos.tickLower,
                    tickUpper: pos.tickUpper,
                    liquidityDelta: int128(uint128(pos.liquidity)),
                    salt: pos.salt
                }),
                ""
            );

            int128 delta0 = delta.amount0();
            int128 delta1 = delta.amount1();

            if (delta0 < 0) {
                uint128 owed0 = _toUint128Neg(delta0);
                address token0 = Currency.unwrap(poolKey.currency0);
                pm.sync(poolKey.currency0);
                if (token0 == address(this)) {
                    _transfer(address(this), address(pm), owed0);
                } else {
                    IERC20(token0).safeTransfer(address(pm), owed0);
                }
                pm.settle();
            }

            if (delta1 < 0) {
                uint128 owed1 = _toUint128Neg(delta1);
                address token1 = Currency.unwrap(poolKey.currency1);
                pm.sync(poolKey.currency1);
                if (token1 == address(this)) {
                    _transfer(address(this), address(pm), owed1);
                } else {
                    IERC20(token1).safeTransfer(address(pm), owed1);
                }
                pm.settle();
            }
        }

        return "";
    }

    function _toUint128Neg(int128 x) internal pure returns (uint128) {
        if (x > 0) revert ISovereignERC20Market.SovereignMarketPositiveValue(x);
        int256 y = -int256(x);
        if (uint256(y) > type(uint128).max) {
            revert ISovereignERC20Market.SovereignMarketAmountExceedsUint128(uint256(y));
        }
        return uint128(uint256(y));
    }
}
