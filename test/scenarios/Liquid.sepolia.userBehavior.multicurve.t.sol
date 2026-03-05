// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {SepoliaBehaviorBase} from "liquid-editions-test/helpers/bases/SepoliaBehaviorBase.sol";
import {PoolCalibrator} from "liquid-editions-test/helpers/PoolCalibrator.sol";

/**
 * @title Liquid Sepolia MultiCurve User Behavior Simulation
 * @notice Fork test against the deployed Eth Sepolia system.
 *         Creates a fresh LiquidMultiCurve token then simulates
 *         a realistic sequence of ETH buys and sells, logging per-trade:
 *           - ETH in / tokens out
 *           - RARE routed into the pool
 *           - Token price in RARE
 *           - Fees paid to beneficiary and protocol (from FeeDistributor events)
 *
 * @dev Requires ETH_SEPOLIA in .env.
 *      Run with: make test-sepolia-behavior-multicurve
 *      Or:  forge test test/scenarios/Liquid.sepolia.userBehavior.multicurve.t.sol -vv
 */
contract LiquidSepoliaMultiCurveBehaviorTest is SepoliaBehaviorBase {
    // ============================================
    // BUY SCENARIO CONFIG
    // ============================================
    uint256 internal constant BUY_AMOUNT_ETH = 0.1e18;
    uint256 internal constant NUM_BUYS = 100;

    // ============================================
    // MULTICURVE CONFIG (tick-based)
    // ============================================

    /// @dev Single-segment curve configuration:
    ///      - Wide range (0 to 65040 ticks) with 5 overlapping positions
    ///      - All 100% of supply distributed across positions
    function _buildCurves() internal pure returns (Curve[] memory curves) {
        curves = new Curve[](1);
        curves[0] = Curve({
            tickLower: 0,
            tickUpper: 65040,
            numPositions: 5,
            shares: 1e18
        });
    }

    // ============================================
    // FORMATTING HELPERS
    // ============================================

    /// @dev Format percentage with 3 decimal places for more precision (e.g., "12.345%").
    function _fmtPct3Dec(
        uint256 part,
        uint256 total
    ) internal pure returns (string memory) {
        if (total == 0) return "0%";
        uint256 pctBps = (part * 100000) / total; // 100000 = 100% (3 decimal places)
        uint256 whole = pctBps / 1000;
        uint256 frac = pctBps % 1000;
        string memory fracStr;
        if (frac < 10) {
            fracStr = string.concat("00", vm.toString(frac));
        } else if (frac < 100) {
            fracStr = string.concat("0", vm.toString(frac));
        } else {
            fracStr = vm.toString(frac);
        }
        return string.concat(vm.toString(whole), ".", fracStr, "%");
    }

    // ============================================
    // CURVE PROGRESS HELPER
    // ============================================

    /**
     * @dev Given the current tick and the curve array, returns a string like:
     *      "seg=1/3 pos=2/3 (67.45%)"
     *      - seg: which curve segment (1-indexed), or "done" if past all segments
     *      - pos: which position within the segment (1-indexed)
     *      - %: how far through the current position's tick range
     *
     *      When _rareIsCurrency0, Multicurve.adjustCurves flips ticks: the pool uses
     *      [-tickUpper, -tickLower] for each segment. We must convert our config bounds
     *      to pool coordinates before comparing.
     */
    function _fmtCurveProgress(
        int24 tick
    ) internal view returns (string memory) {
        Curve[] memory c = _buildCurves();
        uint256 totalSegs = c.length;

        for (uint256 s; s < totalSegs; s++) {
            int24 lo;
            int24 hi;
            if (_rareIsCurrency0) {
                // Pool ticks are negated: segment [tickLower, tickUpper] becomes [-tickUpper, -tickLower]
                lo = -c[s].tickUpper;
                hi = -c[s].tickLower;
            } else {
                lo = c[s].tickLower;
                hi = c[s].tickUpper;
            }
            uint16 n = c[s].numPositions;

            if (tick < lo || tick >= hi) continue;

            int24 segWidth = hi - lo;
            int24 posWidth = segWidth / int24(uint24(n));

            uint16 posIdx = 0;
            for (uint16 p; p < n; p++) {
                int24 posLo = lo + int24(uint24(p)) * posWidth;
                int24 posHi = lo + int24(uint24(p + 1)) * posWidth;
                if (p == n - 1) posHi = hi;
                if (tick >= posLo && tick < posHi) {
                    posIdx = p;
                    uint256 pct = (uint256(uint24(tick - posLo)) * 10000) /
                        uint256(uint24(posHi - posLo));
                    string memory pctWhole = vm.toString(pct / 100);
                    string memory pctFrac = pct % 100 < 10
                        ? string.concat("0", vm.toString(pct % 100))
                        : vm.toString(pct % 100);
                    return
                        string.concat(
                            "seg=",
                            vm.toString(s + 1),
                            "/",
                            vm.toString(totalSegs),
                            " pos=",
                            vm.toString(uint256(posIdx + 1)),
                            "/",
                            vm.toString(uint256(n)),
                            " (",
                            pctWhole,
                            ".",
                            pctFrac,
                            "%)"
                        );
                }
            }
        }

        int24 firstLo = _rareIsCurrency0 ? -c[0].tickUpper : c[0].tickLower;
        // int24 lastHi = _rareIsCurrency0
        //     ? -c[totalSegs - 1].tickLower
        //     : c[totalSegs - 1].tickUpper;

        if (tick < firstLo) return "seg=0 (below curve)";
        return "seg=done (above curve)";
    }

    /**
     * @dev Executes a buy, updates totals, and logs everything — including curve
     *      progress — on a single line. Replaces _doTrackedBuy for this scenario.
     */
    function _doTrackedBuyWithProgress(
        ScenarioTotals memory totals,
        address buyer,
        uint256 ethAmount,
        string memory label
    ) internal {
        (uint256 rarePriceBefore, , , , , ) = token.getMarketState();
        uint256 ethPxBefore = _toEthPrice(rarePriceBefore);
        uint256 rareBefore = IERC20(config.rareToken).balanceOf(address(token));

        vm.recordLogs();
        vm.prank(buyer);
        (bytes memory commands, bytes[] memory inputs) = _encodeBuyRoute(
            address(token),
            ethAmount,
            1
        );
        uint256 tokensReceived = router.buy{value: ethAmount}(
            address(token),
            buyer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 rareAfter = IERC20(config.rareToken).balanceOf(address(token));
        uint256 rareConsumed = rareAfter > rareBefore
            ? rareAfter - rareBefore
            : 0;

        (uint256 rarePriceAfter, , , int24 tickAfter, , ) = token
            .getMarketState();
        uint256 ethPxAfter = _toEthPrice(rarePriceAfter);

        (uint256 feeEthTotal, uint256 feeRareTotal) = _parseFees(logs);

        // Update totals
        totals.totalEthIn += ethAmount;
        totals.totalTokensBought += tokensReceived;
        totals.totalRareIn += rareConsumed;
        totals.totalFeesEth += feeEthTotal;
        totals.totalFeesRare += feeRareTotal;
        if (_rareIsCurrency0) {
            if (tickAfter < totals.minTickReached)
                totals.minTickReached = tickAfter;
        } else {
            if (tickAfter > totals.maxTickReached)
                totals.maxTickReached = tickAfter;
        }

        // Build log line
        string memory pctChange;
        if (rarePriceBefore > 0) {
            uint256 absDelta = rarePriceAfter > rarePriceBefore
                ? rarePriceAfter - rarePriceBefore
                : rarePriceBefore - rarePriceAfter;
            pctChange = string.concat(
                rarePriceAfter >= rarePriceBefore ? "+" : "-",
                _fmtPct3Dec(absDelta, rarePriceBefore)
            );
        } else {
            pctChange = "n/a";
        }

        uint256 ethPerToken = tokensReceived == 0
            ? 0
            : (ethAmount * 1e18) / tokensReceived;

        string memory feeSummary;
        if (feeEthTotal > 0) {
            feeSummary = string.concat(
                " | fee: ",
                _fmtPrice(feeEthTotal),
                "E (",
                _fmtPct(feeEthTotal, ethAmount),
                " of ETH in)"
            );
        } else if (feeRareTotal > 0) {
            uint256 feeEthEquiv = _toEthPrice(feeRareTotal);
            feeSummary = string.concat(
                " | fee: ",
                _fmt(feeRareTotal),
                "R (~",
                _fmtPrice(feeEthEquiv),
                "E, ",
                _fmtPct(feeEthEquiv, ethAmount),
                " of ETH in)"
            );
        } else {
            feeSummary = " | fee: none";
        }

        console.log(
            string.concat(
                label,
                " | in=",
                _fmtPrice(ethAmount),
                "E",
                " | out=",
                _fmtTokens(tokensReceived),
                " | pxE=",
                _fmtPrice(ethPxBefore),
                "->",
                _fmtPrice(ethPxAfter),
                " | dpx=",
                pctChange,
                " | effEth=",
                _fmtPrice(ethPerToken),
                "E/1T",
                feeSummary,
                " | ",
                _fmtCurveProgress(tickAfter)
            )
        );
    }

    // ============================================
    // SETUP
    // ============================================

    uint256 internal initialRareLiquidity = 0 ether;

    function setUp() public {
        _setupSepoliaBehavior();

        // Deepen the RARE/ETH pool so the ETH→RARE leg has realistic slippage
        PoolCalibrator calibrator = new PoolCalibrator();
        vm.deal(address(calibrator), 100000 ether);
        deal(config.rareToken, address(calibrator), 500_000_000 ether);
        calibrator.calibrate(
            IPoolManager(config.uniswapV4PoolManager),
            PoolKey({
                currency0: CurrencyLibrary.ADDRESS_ZERO,
                currency1: Currency.wrap(config.rareToken),
                fee: ETH_RARE_POOL_FEE,
                tickSpacing: ETH_RARE_POOL_TICK_SPACING,
                hooks: IHooks(address(0))
            }),
            config.rareToken
        );

        tokenCreator = makeAddr("tokenCreator");
        vm.deal(tokenCreator, 10000 ether);
        deal(config.rareToken, tokenCreator, initialRareLiquidity);

        for (uint256 i = 0; i < 5; i++) {
            buyers[i] = makeAddr(string.concat("buyer", vm.toString(i)));
            vm.deal(buyers[i], 10000 ether);
        }

        Curve[] memory curves = _buildCurves();

        vm.startPrank(tokenCreator);
        IERC20(config.rareToken).approve(
            address(factory),
            initialRareLiquidity
        );
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://bafybeiggczftngflqbnnmlrmcysg3lgdojrvamtjxrsnmie7mm5gypqnri/metadata.json",
            "sfds",
            "sds",
            initialRareLiquidity,
            curves
        );
        vm.stopPrank();

        token = ILiquid(tokenAddr);

        (Currency currency0, , , , ) = token.poolKey();
        _rareIsCurrency0 = Currency.unwrap(currency0) == config.rareToken;
    }

    // ============================================
    // MAIN SCENARIO
    // ============================================

    function testMultiCurveUserBehaviorModel() public {
        console.log("");
        console.log("========================================");
        console.log("  LIQUID SEPOLIA MULTICURVE BEHAVIOR");
        console.log("========================================");
        console.log("Token:", address(token));
        console.log("Factory:", address(factory));
        console.log("Router:", address(router));
        console.log("FeeDistributor:", config.liquid.feeDistributor);
        console.log(
            string.concat(
                "Initial RARE liquidity: ",
                _fmt(initialRareLiquidity),
                " RARE"
            )
        );
        console.log("");

        console.log("--- CURVE CONFIGURATION ---");
        {
            Curve[] memory c = _buildCurves();
            for (uint256 i; i < c.length; i++) {
                console.log(
                    string.concat(
                        "  Curve ",
                        vm.toString(i),
                        ": ticks [",
                        vm.toString(int256(c[i].tickLower)),
                        ", ",
                        vm.toString(int256(c[i].tickUpper)),
                        "], ",
                        vm.toString(uint256(c[i].numPositions)),
                        " position(s), ",
                        _fmtPct(c[i].shares, 1e18),
                        " shares"
                    )
                );
            }
        }
        console.log("");

        _printMarketState("INITIAL STATE");

        ScenarioTotals memory totals;
        int24 initialTick;
        uint256 initialEthPx;
        {
            (uint256 rarePrice, , , int24 tick, , ) = token.getMarketState();
            initialTick = tick;
            initialEthPx = _toEthPrice(rarePrice);
            totals.minTickReached = tick;
            totals.maxTickReached = tick;
        }
        console.log(
            string.concat(
                "RARE is currency0: ",
                _rareIsCurrency0 ? "yes" : "no",
                " (buys push tick ",
                _rareIsCurrency0 ? "DOWN" : "UP",
                ")"
            )
        );

        // ---- BUY SEQUENCE ----
        console.log("--- BUY SEQUENCE ---");
        for (uint256 i; i < NUM_BUYS; i++) {
            uint256 buyerIdx = i % 5;
            _doTrackedBuyWithProgress(
                totals,
                buyers[buyerIdx],
                BUY_AMOUNT_ETH,
                string.concat("buyer", vm.toString(buyerIdx))
            );
        }

        _printMarketState("AFTER ALL BUYS");

        // ---- SELL SEQUENCE ----
        console.log("--- SELL SEQUENCE ---");

        uint256 buyer3Bal = IERC20(address(token)).balanceOf(buyers[3]);
        uint256 buyer4Bal = IERC20(address(token)).balanceOf(buyers[4]);

        _doSell(
            buyers[3],
            buyer3Bal / 2,
            "buyer3  [50% holdings] partial exit"
        );
        _doSell(
            buyers[4],
            buyer4Bal / 4,
            "buyer4  [25% holdings] whale trim  "
        );

        _printMarketState("FINAL STATE");

        // ---- SUMMARY ----
        console.log("========================================");
        console.log("  SUMMARY");
        console.log("========================================");
        console.log(
            string.concat(
                "Total ETH spent on buys   : ",
                _fmtPrice(totals.totalEthIn),
                " ETH"
            )
        );
        console.log(
            string.concat(
                "Total RARE routed in      : ",
                _fmt(totals.totalRareIn),
                " RARE"
            )
        );
        console.log(
            string.concat(
                "  ETH->RARE efficiency    : ",
                _fmt((totals.totalRareIn * 1e18) / totals.totalEthIn),
                " RARE/ETH"
            )
        );
        console.log(
            string.concat(
                "Total tokens purchased    : ",
                _fmtTokens(totals.totalTokensBought)
            )
        );
        console.log(
            string.concat(
                "  % of pool supply        : ",
                _fmtPct(totals.totalTokensBought, 900_000e18)
            )
        );
        console.log(
            string.concat(
                "Total fees paid (ETH)     : ",
                _fmtPrice(totals.totalFeesEth),
                " ETH"
            )
        );
        console.log(
            string.concat(
                "Total fees paid (RARE)    : ",
                _fmt(totals.totalFeesRare),
                " RARE"
            )
        );
        console.log(
            string.concat(
                "  Fee % of ETH spend      : ",
                _fmtPct(totals.totalFeesEth, totals.totalEthIn)
            )
        );
        console.log(
            string.concat(
                "Initial tick              : ",
                vm.toString(int256(initialTick))
            )
        );
        if (_rareIsCurrency0) {
            int256 tickDelta = int256(initialTick) -
                int256(totals.minTickReached);
            console.log(
                string.concat(
                    "Lowest tick (peak buys)   : ",
                    vm.toString(int256(totals.minTickReached))
                )
            );
            console.log(
                string.concat(
                    "Tick delta (buy pressure) : -",
                    vm.toString(uint256(tickDelta)),
                    " ticks"
                )
            );
        } else {
            int256 tickDelta = int256(totals.maxTickReached) -
                int256(initialTick);
            console.log(
                string.concat(
                    "Highest tick (peak buys)  : ",
                    vm.toString(int256(totals.maxTickReached))
                )
            );
            console.log(
                string.concat(
                    "Tick delta (buy pressure) : +",
                    vm.toString(uint256(tickDelta)),
                    " ticks"
                )
            );
        }
        {
            (uint256 finalRarePrice, , , , , ) = token.getMarketState();
            uint256 finalEthPx = _toEthPrice(finalRarePrice);
            string memory totalPctChange;
            if (initialEthPx > 0 && finalEthPx > 0) {
                uint256 absDelta = finalEthPx > initialEthPx
                    ? finalEthPx - initialEthPx
                    : initialEthPx - finalEthPx;
                totalPctChange = string.concat(
                    finalEthPx >= initialEthPx ? "+" : "-",
                    _fmtPct(absDelta, initialEthPx)
                );
            } else {
                totalPctChange = "n/a";
            }
            console.log(
                string.concat(
                    "Price start               : ",
                    _fmtPrice(initialEthPx),
                    " ETH/token"
                )
            );
            console.log(
                string.concat(
                    "Price end                 : ",
                    _fmtPrice(finalEthPx),
                    " ETH/token"
                )
            );
            console.log(
                string.concat("Total price change        : ", totalPctChange)
            );
        }
        console.log("========================================");
    }
}
