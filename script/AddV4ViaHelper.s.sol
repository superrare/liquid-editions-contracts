// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {V4LiquidityHelper, IPermit2} from "./V4LiquidityHelper.sol";

contract AddV4ViaHelper is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _cid) {
            chainId = _cid;
        } catch {
            chainId = block.chainid;
        }

        // Load amounts and params
        uint256 ethAmount = vm.envUint("ETH_AMOUNT");
        uint256 tokenAmount = vm.envUint("TOKEN_AMOUNT");

        uint24 fee = 3000;
        try vm.envUint("POOL_FEE") returns (uint256 _fee) {
            require(_fee <= type(uint24).max, "fee");
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: require validates bounds
            fee = uint24(_fee);
        } catch {}
        int24 tickSpacing = 60;
        try vm.envInt("TICK_SPACING") returns (int256 _ts) {
            require(_ts >= type(int24).min && _ts <= type(int24).max, "ts");
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: require validates bounds
            tickSpacing = int24(_ts);
        } catch {}

        // Use network config
        NetworkConfig.Config memory cfg = NetworkConfig.getConfig(chainId);
        address token = cfg.rareToken;
        address hooks = _readAddressEnvOr("POOL_HOOKS", address(0));
        bytes32 positionSalt = _readBytes32EnvOr("POSITION_SALT", bytes32(0));

        // Build PoolKey (native ETH currency0)
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        IPoolManager poolManager = IPoolManager(cfg.uniswapV4PoolManager);
        PoolId poolId = key.toId();
        (uint160 liveSqrtPriceX96, int24 liveTick, , ) = poolManager.getSlot0(poolId);
        require(liveSqrtPriceX96 != 0, "pool not initialized");

        (int24 tickLower, int24 tickUpper, bool concentrateAbove) = _resolveTicks(
            liveTick,
            tickSpacing
        );

        // Use live pool price by default; allow optional override.
        uint160 sqrtPriceX96 = liveSqrtPriceX96;
        try vm.envUint("SQRT_PRICE_X96") returns (uint256 sp) {
            require(sp <= type(uint160).max, "sqrtPriceX96 too big");
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: require validates bounds
            sqrtPriceX96 = uint160(sp);
        } catch {}
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity = _calculateLiquidity(
            sqrtPriceX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            ethAmount,
            tokenAmount
        );

        console.log("=== Add via Helper ===");
        console.log("PoolManager:");
        console.logAddress(cfg.uniswapV4PoolManager);
        console.log("PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("Token:");
        console.logAddress(token);
        console.log("Hooks:");
        console.logAddress(hooks);
        console.log("Fee:");
        console.logUint(fee);
        console.log("live tick:");
        console.logInt(liveTick);
        console.log("live sqrtPriceX96:");
        console.logUint(liveSqrtPriceX96);
        console.log("using sqrtPriceX96:");
        console.logUint(sqrtPriceX96);
        console.log("concentrateAbove:");
        console.log(concentrateAbove ? "true" : "false");
        console.log("tickLower:");
        console.logInt(tickLower);
        console.log("tickUpper:");
        console.logInt(tickUpper);
        console.log("liq:");
        console.logUint(liquidity);

        address helperAddress = _executeAdd(
            pk,
            token,
            poolManager,
            key,
            tickLower,
            tickUpper,
            liquidity,
            ethAmount,
            tokenAmount,
            positionSalt
        );

        console.log("Helper:");
        console.logAddress(helperAddress);
        console.log("Position salt:");
        console.logBytes32(positionSalt);
    }

    function _resolveTicks(
        int24 liveTick,
        int24 tickSpacing
    ) internal view returns (int24 tickLower, int24 tickUpper, bool concentrateAbove) {
        bool hasExplicitTicks;
        try vm.envInt("TICK_LOWER") returns (int256 lower) {
            try vm.envInt("TICK_UPPER") returns (int256 upper) {
                require(
                    lower >= type(int24).min &&
                        lower <= type(int24).max &&
                        upper >= type(int24).min &&
                        upper <= type(int24).max,
                    "tick env overflow"
                );
                tickLower = int24(lower);
                tickUpper = int24(upper);
                hasExplicitTicks = true;
            } catch {}
        } catch {}

        concentrateAbove = _readBoolEnvOr("CONCENTRATE_ABOVE", false);
        if (!hasExplicitTicks && concentrateAbove) {
            int24 lowerOffset = _readInt24EnvOr(
                "ABOVE_LOWER_OFFSET_TICKS",
                tickSpacing
            );
            int24 widthTicks = _readInt24EnvOr(
                "ABOVE_WIDTH_TICKS",
                tickSpacing * 200
            );
            require(lowerOffset > 0, "ABOVE_LOWER_OFFSET_TICKS <= 0");
            require(widthTicks > 0, "ABOVE_WIDTH_TICKS <= 0");

            int256 lowerCandidate = int256(liveTick) + int256(lowerOffset);
            require(
                lowerCandidate >= type(int24).min &&
                    lowerCandidate <= type(int24).max,
                "lower overflow"
            );
            tickLower = _ceilToSpacing(int24(lowerCandidate), tickSpacing);

            widthTicks = _ceilPositiveToSpacing(widthTicks, tickSpacing);
            int256 upperCandidate = int256(tickLower) + int256(widthTicks);
            require(
                upperCandidate >= type(int24).min &&
                    upperCandidate <= type(int24).max,
                "upper overflow"
            );
            tickUpper = int24(upperCandidate);
        } else if (!hasExplicitTicks) {
            // Wide symmetric fallback range
            tickLower = -120000;
            tickUpper = 120000;
        }

        tickLower = _floorToSpacing(tickLower, tickSpacing);
        tickUpper = _ceilToSpacing(tickUpper, tickSpacing);
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        if (tickLower < minTick) tickLower = minTick;
        if (tickUpper > maxTick) tickUpper = maxTick;
        require(tickLower < tickUpper, "range");
    }

    function _executeAdd(
        uint256 pk,
        address token,
        IPoolManager poolManager,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 ethAmount,
        uint256 tokenAmount,
        bytes32 positionSalt
    ) internal returns (address helperAddress) {
        vm.startBroadcast(pk);

        V4LiquidityHelper helper;
        helperAddress = _readAddressEnvOr("V4_LIQUIDITY_HELPER", address(0));
        if (helperAddress == address(0)) {
            // Deploy once, then reuse this helper for future add/remove operations.
            helper = new V4LiquidityHelper(
                poolManager,
                IPermit2(PERMIT2_ADDR),
                vm.addr(pk)
            );
            helperAddress = address(helper);
        } else {
            helper = V4LiquidityHelper(payable(helperAddress));
            try helper.OWNER() returns (address owner) {
                require(owner == vm.addr(pk), "deployer is not helper owner");
            } catch {
                revert("helper is legacy; deploy new helper for removable positions");
            }
        }

        // Permit2 allowance for helper (from EOA)
        IERC20(token).approve(PERMIT2_ADDR, type(uint256).max);
        IPermit2(PERMIT2_ADDR).approve(
            token,
            address(helper),
            type(uint160).max,
            type(uint48).max
        );

        V4LiquidityHelper.ModifyParams memory p = V4LiquidityHelper.ModifyParams({
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: liquidity from calc fits int128
            liquidityDelta: int128(int256(uint256(liquidity))),
            amount0Max: ethAmount,
            amount1Max: tokenAmount,
            salt: positionSalt
        });

        helper.modifyLiquidity{value: ethAmount}(p);
        vm.stopBroadcast();
    }

    function _getLiquidityForAmount0(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0
    ) internal pure returns (uint128) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        uint256 intermediate = FullMath.mulDiv(
            sqrtPriceAX96,
            sqrtPriceBX96,
            FixedPoint96.Q96
        );
        uint256 liquidity = FullMath.mulDiv(
            amount0,
            intermediate,
            sqrtPriceBX96 - sqrtPriceAX96
        );
        require(liquidity <= type(uint128).max, "liq0 max");
        // forge-lint: disable-next-line(unsafe-typecast) -- safe: liquidity calc result fits uint128
        return uint128(liquidity);
    }

    function _getLiquidityForAmount1(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount1
    ) internal pure returns (uint128) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        uint256 liquidity = FullMath.mulDiv(
            amount1,
            FixedPoint96.Q96,
            sqrtPriceBX96 - sqrtPriceAX96
        );
        require(liquidity <= type(uint128).max, "liq1 max");
        // forge-lint: disable-next-line(unsafe-typecast) -- safe: liquidity calc result fits uint128
        return uint128(liquidity);
    }

    function _calculateLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            return
                _getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 l0 = _getLiquidityForAmount0(
                sqrtPriceX96,
                sqrtPriceBX96,
                amount0
            );
            uint128 l1 = _getLiquidityForAmount1(
                sqrtPriceAX96,
                sqrtPriceX96,
                amount1
            );
            return l0 < l1 ? l0 : l1;
        } else {
            return
                _getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    function _readAddressEnvOr(
        string memory envKey,
        address defaultValue
    ) internal view returns (address) {
        try vm.envAddress(envKey) returns (address value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function _readInt24EnvOr(
        string memory envKey,
        int24 defaultValue
    ) internal view returns (int24) {
        try vm.envInt(envKey) returns (int256 value) {
            require(
                value >= type(int24).min && value <= type(int24).max,
                "int24 env overflow"
            );
            return int24(value);
        } catch {
            return defaultValue;
        }
    }

    function _readBoolEnvOr(
        string memory envKey,
        bool defaultValue
    ) internal view returns (bool) {
        try vm.envBool(envKey) returns (bool value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function _floorToSpacing(
        int24 tick,
        int24 tickSpacing
    ) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function _ceilToSpacing(
        int24 tick,
        int24 tickSpacing
    ) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick > 0 && tick % tickSpacing != 0) compressed++;
        return compressed * tickSpacing;
    }

    function _ceilPositiveToSpacing(
        int24 value,
        int24 tickSpacing
    ) internal pure returns (int24) {
        require(value > 0, "value <= 0");
        int24 compressed = value / tickSpacing;
        if (value % tickSpacing != 0) compressed++;
        return compressed * tickSpacing;
    }

    function _readBytes32EnvOr(
        string memory envKey,
        bytes32 defaultValue
    ) internal view returns (bytes32) {
        try vm.envBytes32(envKey) returns (bytes32 value) {
            return value;
        } catch {
            return defaultValue;
        }
    }
}
