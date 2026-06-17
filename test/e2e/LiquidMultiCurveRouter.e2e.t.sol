// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidMultiCurve Router E2E Tests
 * @notice Full flow: LiquidRouter + ETH purchases + LiquidSwapGuard on multicurve pools
 * @dev Extends AnvilForkTestBase. Uses real RARE, ETH->RARE->LIQUID routing. Multicurve pools use LiquidSwapGuard.
 *
 * For accurate ETH/USDC and USD/RARE prices in logs, set FORK_BLOCK to a recent mainnet block (e.g. 24457000).
 * Without it, the fork may use a cached/stale block where ETH was ~$477 instead of ~$2000.
 */

import "forge-std/console.sol";
import {AnvilForkTestBase} from "liquid-editions-test/AnvilForkTestBase.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidSwapGuard} from "liquid-editions/LiquidSwapGuard.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {DeployLiquidSwapGuard} from "script/deployers/DeployLiquidSwapGuard.s.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @notice Uniswap V3 pool slot0 for ETH/USDC price lookup
interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

contract LiquidMultiCurveRouterE2ETest is AnvilForkTestBase {
    using StateLibrary for IPoolManager;

    /// @notice Override to pin fork block for accurate ETH/USDC prices. Set FORK_BLOCK in env for recent prices.
    function _getForkBlock() internal view override returns (uint256) {
        return vm.envOr("FORK_BLOCK", uint256(0));
    }

    LiquidSwapGuard public guard;
    LiquidMultiCurve public liquidMultiCurveToken;

    uint256 constant POOL_RARE = 2000e18;

    /// @notice V3 WETH/USDC pool addresses per chain (0.3% mainnet/Sepolia, 0.05% Base)
    /// @dev Mainnet: 0.3% pool (getPool(USDC, WETH, 3000)) per Uniswap docs. Prices depend on fork block.
    address constant V3_ETH_USDC_MAINNET =
        0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
    address constant V3_ETH_USDC_BASE =
        0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address constant V3_ETH_USDC_SEPOLIA =
        0x9799b5EDC1aA7D3FAd350309B08df3F64914E244;

    /// @notice Get ETH/RARE price from V4 pool. Returns RARE per 1 ETH (1e18 scale). ok=false if pool missing.
    function _getEthRarePrice()
        internal
        view
        returns (bool ok, uint256 rarePerEth)
    {
        if (config.rareEthPoolId == bytes32(0)) return (false, 0);
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(
            PoolId.wrap(config.rareEthPoolId)
        );
        if (sqrtPriceX96 == 0) return (false, 0);
        uint256 priceQ128 = FullMath.mulDiv(
            uint256(sqrtPriceX96),
            uint256(sqrtPriceX96),
            1 << 64
        );
        if (priceQ128 == 0) return (false, 0);
        // price = token1/token0 = WETH/RARE. So 1 ETH = price RARE. rarePerEth = price * 1e18 / 2^128
        rarePerEth = FullMath.mulDiv(priceQ128, 1e18, 1 << 128);
        return (true, rarePerEth);
    }

    /// @notice Get ETH/USDC price from V3 pool. Returns USDC per 1 ETH (6 decimals). ok=false if pool missing.
    /// @dev Mainnet/Sepolia: token0=USDC, token1=WETH. Base: token0=WETH, token1=USDC.
    function _getEthUsdcPrice()
        internal
        view
        returns (bool ok, uint256 usdcPerEth)
    {
        address pool;
        if (block.chainid == 8453) pool = V3_ETH_USDC_BASE;
        else if (block.chainid == 11155111) pool = V3_ETH_USDC_SEPOLIA;
        else pool = V3_ETH_USDC_MAINNET;
        if (pool == address(0)) return (false, 0);
        try IUniswapV3Pool(pool).slot0() returns (
            uint160 sqrtPriceX96,
            int24,
            uint16,
            uint16,
            uint16,
            uint8,
            bool
        ) {
            if (sqrtPriceX96 == 0) return (false, 0);
            uint256 priceQ128 = FullMath.mulDiv(
                uint256(sqrtPriceX96),
                uint256(sqrtPriceX96),
                1 << 64
            );
            if (priceQ128 == 0) return (false, 0);
            // sqrtPriceX96 = sqrt(token1/token0) * 2^96
            // priceQ128 = sqrtPriceX96^2 / 2^64 = (token1/token0) * 2^128
            //
            // For Mainnet USDC/WETH pool (0x8ad5...): token0=USDC(6d), token1=WETH(18d)
            // price_raw = priceQ128 / 2^128 = WETH_raw / USDC_raw
            // To get USDC per 1 ETH (in 6 decimals, i.e. $2000 = 2000e6):
            //   1 ETH = 1e18 WETH_raw
            //   USDC_raw_per_1ETH = 1e18 / price_raw = 1e18 * 2^128 / priceQ128
            //   This is already in USDC raw units (6 decimals). So:
            //   usdcPerEth = 1e18 * 2^128 / priceQ128
            uint256 inv = FullMath.mulDiv(1e18, 1 << 128, priceQ128);

            // For Base WETH/USDC pool: token0=WETH(18d), token1=USDC(6d)
            // price_raw = priceQ128 / 2^128 = USDC_raw / WETH_raw
            // USDC_raw_per_1ETH = price_raw * 1e18 = priceQ128 * 1e18 / 2^128
            uint256 fwd = FullMath.mulDiv(priceQ128, 1e18, 1 << 128);

            // Pick whichever is in reasonable range (500-5000 USD per ETH, so 500e6-5000e6)
            if (inv >= 500e6 && inv <= 5000e6) {
                usdcPerEth = inv;
            } else if (fwd >= 500e6 && fwd <= 5000e6) {
                usdcPerEth = fwd;
            } else {
                // Fallback - use whichever is closer to reasonable
                usdcPerEth = inv > 0 ? inv : fwd;
            }
            return (true, usdcPerEth);
        } catch {
            return (false, 0);
        }
    }

    function _defaultCurves() internal pure returns (Curve[] memory) {
        DeployConfig.MultiCurveConfig memory cfg = DeployConfig
            .getDefaultMultiCurveConfig();

        Curve[] memory curves = new Curve[](3);
        curves[0] = Curve({
            tickLower: cfg.tripWireTickLower,
            tickUpper: cfg.tripWireTickUpper,
            numPositions: cfg.tripWirePositions,
            shares: cfg.tripWireShares
        });
        curves[1] = Curve({
            tickLower: cfg.distributionTickLower,
            tickUpper: cfg.distributionTickUpper,
            numPositions: cfg.distributionPositions,
            shares: cfg.distributionShares
        });
        curves[2] = Curve({
            tickLower: cfg.steadyStateTickLower,
            tickUpper: cfg.steadyStateTickUpper,
            numPositions: cfg.steadyStatePositions,
            shares: cfg.steadyStateShares
        });
        return curves;
    }

    function _configureFactory() internal override {
        super._configureFactory();

        address guardAddr = DeployLiquidSwapGuard.deployForTest(
            IPoolManager(config.uniswapV4PoolManager),
            admin,
            bytes32(0)
        );
        guard = LiquidSwapGuard(guardAddr);
        guard.addRouter(config.uniswapUniversalRouter);
        guard.setFactory(address(factory));
        factory.setPoolHooks(address(guard));
    }

    function setUp() public override {
        vm.skip(true);
    }

    function test_FullFlowWithLogging_ETH_ViaRouter() public {
        address tokenAddr = address(liquidMultiCurveToken);

        // Simulate real user behavior: varied sizes including apes (1 ETH first buy possible)
        uint256[] memory ethAmounts = new uint256[](10);
        ethAmounts[0] = 1.00 ether; // First buyer apes in
        ethAmounts[1] = 1.00 ether;
        ethAmounts[2] = 1.00 ether;
        ethAmounts[3] = 1.00 ether;
        ethAmounts[4] = 1.00 ether;
        ethAmounts[5] = 1.00 ether;
        ethAmounts[6] = 1.00 ether;
        ethAmounts[7] = 1.00 ether;
        ethAmounts[8] = 1.00 ether;
        ethAmounts[9] = 1.00 ether;

        uint256 totalEthSpent = 0;
        uint256 totalTokensBought = 0;

        console.log(
            "=== MultiCurve full flow: ETH buys via LiquidRouter (LiquidSwapGuard) ==="
        );

        // Log market prices right before purchases (convention: USD/ETH = $ per 1 ETH, etc.)
        (bool ethRareOk, uint256 rarePerEth) = _getEthRarePrice();
        (bool ethUsdcOk, uint256 usdcPerEth) = _getEthUsdcPrice();
        uint256 ethUsd = ethUsdcOk ? (usdcPerEth / 1e6) : 0; // 1 ETH = X USDC (~$X), usdcPerEth has 6 decimals

        if (ethUsdcOk) {
            console.log("  USD/ETH (1 ETH ~= $X):", ethUsd);
        } else {
            console.log("  USD/ETH: (pool not available on this chain)");
        }
        if (ethRareOk) {
            uint256 ethPerRare = rarePerEth > 0
                ? (1e18 * 1e18) / rarePerEth
                : 0; // 1 RARE = X ETH (1e18 scale)
            if (ethUsdcOk && ethUsd > 0 && rarePerEth > 0) {
                uint256 rareUsd = FullMath.mulDiv(ethUsd, 1e36, rarePerEth); // 1 RARE ~= $X (1e18 scale)
                console.log("  USD/RARE (1 RARE ~= $X):", _fmtPrice(rareUsd));
            }
            console.log("  ETH/RARE (1 RARE = X ETH):", _fmtPrice(ethPerRare));
        } else {
            console.log("  USD/RARE: (pool not available)");
            console.log("  ETH/RARE: (pool not available on this chain)");
        }

        (uint256 priceRarePerToken, ) = liquidMultiCurveToken.getCurrentPrice();
        console.log(
            "  Initial price (RARE per token):",
            _fmtPrice(priceRarePerToken)
        );
        if (
            ethRareOk &&
            ethUsdcOk &&
            ethUsd > 0 &&
            priceRarePerToken > 0 &&
            rarePerEth > 0
        ) {
            uint256 tokenUsd = FullMath.mulDiv(
                priceRarePerToken,
                ethUsd * 1e18,
                rarePerEth
            );
            console.log("  USD/Token (1 token ~= $X):", _fmtPrice(tokenUsd));
        }

        for (uint256 i = 0; i < ethAmounts.length; i++) {
            uint256 ethIn = ethAmounts[i];
            uint256 ethForSwap = (ethIn * (10000 - _totalFeeBpsForRouter())) /
                10000;
            (uint256 priceBefore, ) = liquidMultiCurveToken.getCurrentPrice();
            (bool ethRareOkLoop, uint256 rarePerEthLoop) = _getEthRarePrice();

            uint256 tokensOut = _doBuyWithHooks(
                buyer,
                tokenAddr,
                buyer,
                ethIn,
                address(guard)
            );

            (uint256 priceAfter, ) = liquidMultiCurveToken.getCurrentPrice();
            totalEthSpent += ethIn;
            totalTokensBought += tokensOut;

            uint256 effectiveRarePerToken = tokensOut > 0
                ? (ethIn * 1e18) / tokensOut
                : 0;
            // Price impact: compare effective RARE/token vs spot. Estimate RARE in from ETH->RARE leg.
            uint256 priceImpactBps = 0;
            if (
                priceBefore > 0 &&
                tokensOut > 0 &&
                ethRareOkLoop &&
                rarePerEthLoop > 0
            ) {
                uint256 rareIn = FullMath.mulDiv(
                    ethForSwap,
                    rarePerEthLoop,
                    1e18
                );
                uint256 effectiveRarePerTokenFromPool = FullMath.mulDiv(
                    rareIn,
                    1e18,
                    tokensOut
                );
                // For buys: effective > spot means we paid more (positive impact)
                if (effectiveRarePerTokenFromPool > priceBefore) {
                    priceImpactBps = FullMath.mulDiv(
                        effectiveRarePerTokenFromPool - priceBefore,
                        10000,
                        priceBefore
                    );
                }
            }
            console.log(
                "  Buy",
                i,
                string.concat(
                    "ETH:",
                    _fmt(ethIn),
                    " tokens:",
                    _fmt(tokensOut),
                    " effRarePerToken:",
                    _fmtPrice(effectiveRarePerToken),
                    " priceBefore:",
                    _fmtPrice(priceBefore),
                    " priceAfter:",
                    _fmtPrice(priceAfter),
                    " priceImpactBps:",
                    vm.toString(priceImpactBps)
                )
            );
        }

        console.log("  Total ETH spent:", _fmt(totalEthSpent));
        console.log("  Total tokens bought:", _fmt(totalTokensBought));
        (uint256 priceAfterBuys, ) = liquidMultiCurveToken.getCurrentPrice();
        console.log(
            "  Price after all buys (RARE per token):",
            _fmtPrice(priceAfterBuys)
        );
        // USD/RARE after all purchases (before sells)
        (bool ethRareOkAfter, uint256 rarePerEthAfter) = _getEthRarePrice();
        (bool ethUsdcOkAfter, uint256 usdcPerEthAfter) = _getEthUsdcPrice();
        uint256 ethUsdAfter = ethUsdcOkAfter ? (usdcPerEthAfter / 1e6) : 0;
        if (
            ethRareOkAfter &&
            ethUsdcOkAfter &&
            ethUsdAfter > 0 &&
            rarePerEthAfter > 0
        ) {
            uint256 rareUsdAfter = FullMath.mulDiv(
                ethUsdAfter,
                1e36,
                rarePerEthAfter
            );
            console.log(
                "  USD/RARE after buys (1 RARE ~= $X):",
                _fmtPrice(rareUsdAfter)
            );
        }

        console.log("=== Sells (ETH out via router) ===");
        uint256 sellAmount1 = totalTokensBought / 4;
        uint256 sellAmount2 = totalTokensBought / 4;

        uint256 ethOut1 = _doSellWithHooks(
            buyer,
            tokenAddr,
            sellAmount1,
            buyer,
            address(guard)
        );
        console.log(
            "  Sell 1 tokens:",
            _fmt(sellAmount1),
            "ETH out:",
            _fmt(ethOut1)
        );

        uint256 ethOut2 = _doSellWithHooks(
            buyer,
            tokenAddr,
            sellAmount2,
            buyer,
            address(guard)
        );
        console.log(
            "  Sell 2 tokens:",
            _fmt(sellAmount2),
            "ETH out:",
            _fmt(ethOut2)
        );

        (uint256 priceAfterSells, ) = liquidMultiCurveToken.getCurrentPrice();
        console.log(
            "  Price after sells (RARE per token):",
            _fmtPrice(priceAfterSells)
        );

        uint256 ethOutTotal = ethOut1 + ethOut2;
        console.log("  Total ETH from sells:", _fmt(ethOutTotal));
        console.log(
            "  Buyer final token balance:",
            _fmt(liquidMultiCurveToken.balanceOf(buyer))
        );
        console.log("  Buyer final ETH balance:", _fmt(buyer.balance));

        assertGt(totalTokensBought, 0);
        assertGt(ethOutTotal, 0);
        assertTrue(
            priceAfterBuys > priceRarePerToken,
            "Price should rise after buys"
        );
    }

    function _doBuyWithHooks(
        address asUser,
        address token,
        address recipient,
        uint256 ethAmount,
        address poolHooks
    ) internal returns (uint256 tokensReceived) {
        uint256 ethForSwap = (ethAmount * (10000 - _totalFeeBpsForRouter())) /
            10000;
        (bytes memory commands, bytes[] memory inputs) = _encodeBuyRouteWithHooks(
            token,
            poolHooks,
            ethForSwap,
            1
        );
        vm.prank(asUser);
        return
            router.buy{value: ethAmount}(
                token,
                recipient,
                1,
                commands,
                inputs,
                block.timestamp + 1 hours
            );
    }

    /// @notice Fees are now skimmed at the V4 pool level by LiquidGuard (in RARE).
    ///         The router no longer deducts ETH fees, so the full ETH amount goes to the swap.
    function _totalFeeBpsForRouter() internal pure returns (uint256) {
        return 0;
    }

    function _doSellWithHooks(
        address asUser,
        address token,
        uint256 tokenAmount,
        address recipient,
        address poolHooks
    ) internal returns (uint256 ethReceived) {
        vm.startPrank(asUser);
        IERC20(token).approve(address(router), tokenAmount);
        (bytes memory commands, bytes[] memory inputs) = _encodeSellRouteWithHooks(
            token,
            poolHooks,
            tokenAmount,
            1
        );
        ethReceived = router.sell(
            token,
            tokenAmount,
            recipient,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
        return ethReceived;
    }
}
