// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {SepoliaBehaviorBase} from "liquid-editions-test/helpers/bases/SepoliaBehaviorBase.sol";
import {PoolCalibrator} from "liquid-editions-test/helpers/PoolCalibrator.sol";

/**
 * @title Liquid Sepolia Instant User Behavior Simulation
 * @notice Fork test against the deployed Eth Sepolia system.
 *         Creates a fresh LiquidInstant token (650K RARE liquidity) then simulates
 *         a realistic sequence of ETH buys and sells, logging per-trade:
 *           - ETH in / tokens out
 *           - RARE routed into the pool
 *           - Token price in both RARE and ETH
 *           - Fees paid to beneficiary and protocol (from FeeDistributor events)
 *
 * @dev Requires ETH_SEPOLIA and MAINNET_RPC_URL in .env.
 *      Run with: make test-sepolia-behavior
 *      Or:  forge test test/scenarios/Liquid.sepolia.userBehavior.instant.t.sol -vv
 */
contract LiquidSepoliaInstantBehaviorTest is SepoliaBehaviorBase {
    uint256 internal initialRareLiquidity = 250 ether;

    function setUp() public {
        _setupSepoliaBehavior();

        // Deepen the RARE/ETH pool so the ETH→RARE leg has realistic slippage
        PoolCalibrator calibrator = new PoolCalibrator();
        vm.deal(address(calibrator), 1000 ether);
        deal(config.rareToken, address(calibrator), 500_000 ether);
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
        vm.deal(tokenCreator, 10 ether);
        deal(config.rareToken, tokenCreator, initialRareLiquidity);

        for (uint256 i = 0; i < 5; i++) {
            buyers[i] = makeAddr(string.concat("buyer", vm.toString(i)));
            vm.deal(buyers[i], 1 ether);
        }

        vm.startPrank(tokenCreator);
        IERC20(config.rareToken).approve(
            address(factory),
            initialRareLiquidity
        );
        address tokenAddr = factory.createLiquidTokenInstant(
            tokenCreator,
            "ipfs://sepolia-user-behavior-test",
            "Behavior Token",
            "BHV",
            initialRareLiquidity
        );
        vm.stopPrank();

        token = ILiquid(tokenAddr);

        (Currency currency0, , , , ) = token.poolKey();
        _rareIsCurrency0 = Currency.unwrap(currency0) == config.rareToken;
    }

    function testUserBehaviorModel() public {
        console.log("");
        console.log("========================================");
        console.log("  LIQUID SEPOLIA INSTANT BEHAVIOR MODEL");
        console.log("========================================");
        console.log("Token:", address(token));
        console.log("Factory:", address(factory));
        console.log("Router:", address(router));
        console.log("FeeDistributor:", config.liquid.feeDistributor);
        console.log("Initial RARE liquidity: 250 RARE");
        console.log("");

        _printRareEthPrice();
        _printMarketState("INITIAL STATE");

        ScenarioTotals memory totals;
        int24 initialTick;
        {
            (, , , int24 tick, , ) = token.getMarketState();
            initialTick = tick;
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
        // Mainnet-realistic ETH amounts (post-calibration: 1 ETH ≈ 127,812 RARE).
        console.log("--- BUY SEQUENCE ---");

        _doTrackedBuy(totals, buyers[0], 5e17, "buyer0");
        _doTrackedBuy(totals, buyers[1], 5e17, "buyer1");
        _doTrackedBuy(totals, buyers[2], 5e17, "buyer2");
        _doTrackedBuy(totals, buyers[3], 5e17, "buyer3");
        _doTrackedBuy(totals, buyers[4], 5e17, "buyer4");
        _doTrackedBuy(totals, buyers[0], 5e17, "buyer0");
        _doTrackedBuy(totals, buyers[1], 5e17, "buyer1");
        _doTrackedBuy(totals, buyers[2], 5e17, "buyer2");
        _doTrackedBuy(totals, buyers[0], 5e17, "buyer0");
        _doTrackedBuy(totals, buyers[1], 5e17, "buyer1");
        _doTrackedBuy(totals, buyers[2], 5e17, "buyer2");
        _doTrackedBuy(totals, buyers[3], 5e17, "buyer3");
        _doTrackedBuy(totals, buyers[4], 5e17, "buyer4");
        _doTrackedBuy(totals, buyers[0], 5e17, "buyer0");
        _doTrackedBuy(totals, buyers[1], 5e17, "buyer1");
        _doTrackedBuy(totals, buyers[2], 5e17, "buyer2");

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
        console.log("========================================");
    }
}
