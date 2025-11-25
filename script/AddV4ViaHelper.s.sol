// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {NetworkConfig} from "./NetworkConfig.sol";
import {V4LiquidityHelper, IPermit2} from "./V4LiquidityHelper.sol";

contract AddV4ViaHelper is Script {
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
            fee = uint24(_fee);
        } catch {}
        int24 tickSpacing = 60;
        try vm.envInt("TICK_SPACING") returns (int256 _ts) {
            require(_ts >= type(int24).min && _ts <= type(int24).max, "ts");
            tickSpacing = int24(_ts);
        } catch {}

        // Use network config
        NetworkConfig.Config memory cfg = NetworkConfig.getConfig(chainId);
        address token = cfg.rareToken;

        // Wide symmetric range
        int24 tickLower = -120000;
        int24 tickUpper = 120000;
        // Round ticks to tick spacing boundaries (divide-then-multiply is intentional for rounding)
        // forge-lint: disable-next-line(divide-before-multiply)
        tickLower = int24((tickLower / tickSpacing) * tickSpacing);
        // forge-lint: disable-next-line(divide-before-multiply)
        tickUpper = int24((tickUpper / tickSpacing) * tickSpacing);
        require(tickLower < tickUpper, "range");

        // Build PoolKey (native ETH currency0)
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        // Liquidity calc using provided pool price when available; fallback 1:1
        uint160 sqrtPriceX96 = 79228162514264337593543950336;
        try vm.envUint("SQRT_PRICE_X96") returns (uint256 sp) {
            require(sp <= type(uint160).max, "sqrtPriceX96 too big");
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
        console.log("Token:");
        console.logAddress(token);
        console.log("Fee:");
        console.logUint(fee);
        console.log("tickLower:");
        console.logInt(tickLower);
        console.log("tickUpper:");
        console.logInt(tickUpper);
        console.log("liq:");
        console.logUint(liquidity);

        vm.startBroadcast(pk);

        // Deploy helper
        V4LiquidityHelper helper = new V4LiquidityHelper(
            IPoolManager(cfg.uniswapV4PoolManager),
            IPermit2(PERMIT2_ADDR)
        );

        // Permit2 allowance for helper (from EOA)
        IERC20(token).approve(PERMIT2_ADDR, type(uint256).max);
        IPermit2(PERMIT2_ADDR).approve(
            token,
            address(helper),
            type(uint160).max,
            type(uint48).max
        );

        // Build params
        V4LiquidityHelper.AddParams memory p = V4LiquidityHelper.AddParams({
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int128(int256(uint256(liquidity))),
            owner: vm.addr(pk),
            token: token,
            amount0Max: ethAmount,
            amount1Max: tokenAmount
        });

        // Call helper (send ETH)
        helper.addLiquidity{value: ethAmount}(p);

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
}
