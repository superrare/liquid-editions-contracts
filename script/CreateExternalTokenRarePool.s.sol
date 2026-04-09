// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {ILiquidGuard} from "liquid-editions/interfaces/ILiquidGuard.sol";
import {ExternalV4PoolBootstrapHelper} from "./ExternalV4PoolBootstrapHelper.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

interface IOwnableLike {
    function owner() external view returns (address);
}

interface IUniswapV2PairLike {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IUniswapV3PoolLike {
    function token0() external view returns (address);

    function token1() external view returns (address);

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

/**
 * @title CreateExternalTokenRarePool
 * @notice Creates a TOKEN/RARE Uniswap V4 pool for an already-existing ERC20 using LiquidGuard.
 *
 * Required env:
 * - DEPLOYER_PRIVATE_KEY
 * - TOKEN_ADDRESS
 * - TOKEN_AMOUNT_MAX
 * - RARE_AMOUNT_MAX
 *
 * Price source:
 * - Option A: TARGET_RARE_PER_TOKEN_WAD
 * - Option B: REFERENCE_POOL_KIND + REFERENCE_POOL
 *   - REFERENCE_POOL_KIND=V2 or V3
 * - Option C: REFERENCE_POOL_KIND=V4
 *   - REFERENCE_QUOTE_TOKEN
 *   - REFERENCE_POOL_FEE
 *   - REFERENCE_TICK_SPACING
 *   - REFERENCE_POOL_HOOKS (optional, default 0)
 *
 * Optional range controls:
 * - TARGET_TICK_LOWER / TARGET_TICK_UPPER
 * - LOWER_PRICE_BPS / UPPER_PRICE_BPS
 * - AUTO_SCARCE_SIDE_RANGE_BPS (default 2500 = 25%)
 *
 * Optional overrides:
 * - CHAIN_ID
 * - RARE_TOKEN
 * - POOL_MANAGER
 * - LIQUID_GUARD
 * - POOL_FEE (default 0)
 * - TICK_SPACING (default 60)
 * - EXISTING_PRICE_TOLERANCE_BPS (default 50 = 0.5%)
 * - RARE_PER_QUOTE_WAD / RARE_PER_ETH_WAD
 * - RARE_ETH_POOL_ID / RARE_ETH_POOL_MANAGER
 */
contract CreateExternalTokenRarePool is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant Q32 = 1 << 32;
    uint256 internal constant Q128 = 1 << 128;

    struct PriceQuote {
        address quoteToken;
        uint256 quotePerTokenWad;
        string source;
    }

    struct RangePlan {
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceLowerX96;
        uint160 sqrtPriceUpperX96;
        uint128 liquidity;
        uint256 amount0UsedEstimate;
        uint256 amount1UsedEstimate;
        bool currency0Scarce;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        uint256 chainId = _readUintEnvOr("CHAIN_ID", block.chainid);
        NetworkConfig.Config memory config = NetworkConfig.getConfig(chainId);

        address token = vm.envAddress("TOKEN_ADDRESS");
        uint256 tokenAmountMax = vm.envUint("TOKEN_AMOUNT_MAX");
        uint256 rareAmountMax = vm.envUint("RARE_AMOUNT_MAX");

        address rareToken = _readAddressEnvOr("RARE_TOKEN", config.rareToken);
        address poolManagerAddress = _readAddressEnvOr(
            "POOL_MANAGER",
            config.uniswapV4PoolManager
        );
        address liquidGuardAddress = _readAddressEnvOr(
            "LIQUID_GUARD",
            config.liquid.liquidGuard
        );
        uint24 poolFee = _readUint24EnvOr("POOL_FEE", 0);
        int24 tickSpacing = _readInt24EnvOr("TICK_SPACING", 60);

        require(token != address(0), "TOKEN_ADDRESS not set");
        require(rareToken != address(0), "RARE token not configured");
        require(token != rareToken, "TOKEN_ADDRESS == RARE");
        require(
            poolManagerAddress != address(0),
            "POOL_MANAGER not configured"
        );
        require(
            liquidGuardAddress != address(0),
            "LIQUID_GUARD not configured"
        );
        require(tickSpacing > 0, "invalid tick spacing");

        IPoolManager poolManager = IPoolManager(poolManagerAddress);

        uint8 tokenDecimals = _readTokenDecimals(token, "TOKEN_DECIMALS");
        uint8 rareDecimals = _readTokenDecimals(rareToken, "RARE_DECIMALS");

        PriceQuote memory referenceQuote = _discoverReferencePrice(
            rareToken,
            config,
            token,
            tokenDecimals
        );

        uint256 rarePerTokenWad = _resolveRarePerTokenWad(
            config,
            poolManagerAddress,
            rareToken,
            rareDecimals,
            referenceQuote
        );

        bool tokenIsCurrency0 = token < rareToken;
        address currency0Address = tokenIsCurrency0 ? token : rareToken;
        address currency1Address = tokenIsCurrency0 ? rareToken : token;
        uint8 currency0Decimals = tokenIsCurrency0
            ? tokenDecimals
            : rareDecimals;
        uint8 currency1Decimals = tokenIsCurrency0
            ? rareDecimals
            : tokenDecimals;

        uint256 priceCurrency1PerCurrency0Wad = tokenIsCurrency0
            ? rarePerTokenWad
            : _invertPriceWad(rarePerTokenWad);

        uint160 targetSqrtPriceX96 = _priceWadToSqrtPriceX96(
            priceCurrency1PerCurrency0Wad,
            currency0Decimals,
            currency1Decimals
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0Address),
            currency1: Currency.wrap(currency1Address),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(liquidGuardAddress)
        });

        PoolId poolId = key.toId();
        uint128 existingLiquidity = poolManager.getLiquidity(poolId);
        (
            uint160 existingSqrtPriceX96,
            int24 existingTick,
            uint24 existingProtocolFee,
            uint24 existingLpFee
        ) = poolManager.getSlot0(poolId);

        bool initializePool = existingSqrtPriceX96 == 0;
        uint160 activeSqrtPriceX96 = initializePool
            ? targetSqrtPriceX96
            : existingSqrtPriceX96;
        uint256 toleranceBps = _readUintEnvOr(
            "EXISTING_PRICE_TOLERANCE_BPS",
            50
        );
        uint256 currentPriceWad = 0;
        uint256 deviationBps = 0;

        if (!initializePool) {
            currentPriceWad = _sqrtPriceX96ToPriceWad(
                existingSqrtPriceX96,
                currency0Decimals,
                currency1Decimals
            );
            deviationBps = _differenceBps(
                currentPriceWad,
                priceCurrency1PerCurrency0Wad
            );
            require(
                deviationBps <= toleranceBps,
                "existing pool price differs from target"
            );
        }

        uint256 amount0Max = tokenIsCurrency0 ? tokenAmountMax : rareAmountMax;
        uint256 amount1Max = tokenIsCurrency0 ? rareAmountMax : tokenAmountMax;

        RangePlan memory plan = _buildRangePlan(
            activeSqrtPriceX96,
            amount0Max,
            amount1Max,
            priceCurrency1PerCurrency0Wad,
            currency0Decimals,
            currency1Decimals,
            tickSpacing
        );

        uint256 tokenBalance = IERC20(token).balanceOf(deployer);
        uint256 rareBalance = IERC20(rareToken).balanceOf(deployer);

        console.log("=== External TOKEN/RARE Bootstrap ===");
        console.log("Chain ID:");
        console.logUint(chainId);
        console.log("Deployer:");
        console.logAddress(deployer);
        console.log("Token:");
        console.logAddress(token);
        console.log("RARE:");
        console.logAddress(rareToken);
        console.log("PoolManager:");
        console.logAddress(poolManagerAddress);
        console.log("LiquidGuard:");
        console.logAddress(liquidGuardAddress);
        console.log("PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("currency0:");
        console.logAddress(currency0Address);
        console.log("currency1:");
        console.logAddress(currency1Address);
        console.log("currency0 decimals:");
        console.logUint(currency0Decimals);
        console.log("currency1 decimals:");
        console.logUint(currency1Decimals);
        console.log("Pool fee:");
        console.logUint(poolFee);
        console.log("Tick spacing:");
        console.logInt(tickSpacing);
        console.log("");

        console.log("Reference price source:");
        console.log(referenceQuote.source);
        console.log("Reference quote token:");
        console.logAddress(referenceQuote.quoteToken);
        console.log("Reference quote/token (wad):");
        console.logUint(referenceQuote.quotePerTokenWad);
        console.log("Target RARE/token (wad):");
        console.logUint(rarePerTokenWad);
        console.log("Target currency1/currency0 (wad):");
        console.logUint(priceCurrency1PerCurrency0Wad);
        console.log("Target currency0/currency1 (wad):");
        console.logUint(_invertPriceWad(priceCurrency1PerCurrency0Wad));
        console.log("Target sqrtPriceX96:");
        console.logUint(targetSqrtPriceX96);
        console.log("Existing liquidity:");
        console.logUint(existingLiquidity);
        console.log("Pool needs initialize:");
        console.log(initializePool ? "true" : "false");
        if (!initializePool) {
            console.log("Existing pool detected; current tick:");
            console.logInt(existingTick);
            console.log("Existing protocol fee:");
            console.logUint(existingProtocolFee);
            console.log("Existing LP fee:");
            console.logUint(existingLpFee);
            console.log("Existing currency1/currency0 (wad):");
            console.logUint(currentPriceWad);
            console.log("Existing currency0/currency1 (wad):");
            console.logUint(_invertPriceWad(currentPriceWad));
            console.log("Price deviation (bps):");
            console.logUint(deviationBps);
            console.log("Allowed deviation (bps):");
            console.logUint(toleranceBps);
        }
        console.log("");

        console.log("Range plan:");
        console.log("  tickLower:");
        console.logInt(plan.tickLower);
        console.log("  tickUpper:");
        console.logInt(plan.tickUpper);
        console.log("  sqrtLowerX96:");
        console.logUint(plan.sqrtPriceLowerX96);
        console.log("  sqrtUpperX96:");
        console.logUint(plan.sqrtPriceUpperX96);
        console.log("  lower currency1/currency0 (wad):");
        console.logUint(
            _sqrtPriceX96ToPriceWad(
                plan.sqrtPriceLowerX96,
                currency0Decimals,
                currency1Decimals
            )
        );
        console.log("  upper currency1/currency0 (wad):");
        console.logUint(
            _sqrtPriceX96ToPriceWad(
                plan.sqrtPriceUpperX96,
                currency0Decimals,
                currency1Decimals
            )
        );
        console.log("  auto scarce side is currency0:");
        console.log(plan.currency0Scarce ? "true" : "false");
        console.log("  liquidity:");
        console.logUint(plan.liquidity);
        console.log("  amount0 used estimate:");
        console.logUint(plan.amount0UsedEstimate);
        console.log("  amount1 used estimate:");
        console.logUint(plan.amount1UsedEstimate);
        console.log("  token used estimate:");
        console.logUint(
            tokenIsCurrency0
                ? plan.amount0UsedEstimate
                : plan.amount1UsedEstimate
        );
        console.log("  rare used estimate:");
        console.logUint(
            tokenIsCurrency0
                ? plan.amount1UsedEstimate
                : plan.amount0UsedEstimate
        );
        console.log("");

        console.log("Budget / balances:");
        console.log("  token max:");
        console.logUint(tokenAmountMax);
        console.log("  token balance:");
        console.logUint(tokenBalance);
        console.log("  rare max:");
        console.logUint(rareAmountMax);
        console.log("  rare balance:");
        console.logUint(rareBalance);
        console.log("");

        require(tokenBalance >= tokenAmountMax, "insufficient token balance");
        require(rareBalance >= rareAmountMax, "insufficient RARE balance");
        require(plan.liquidity > 0, "planned liquidity is zero");
        require(
            plan.liquidity <= uint128(type(int128).max),
            "liquidity exceeds int128"
        );

        address guardOwner = IOwnableLike(liquidGuardAddress).owner();
        address guardFactory = ILiquidGuard(liquidGuardAddress).factory();
        console.log("LiquidGuard owner:");
        console.logAddress(guardOwner);
        console.log("LiquidGuard factory:");
        console.logAddress(guardFactory);
        console.log("Deployer can whitelist initializer:");
        console.log(
            (deployer == guardOwner || deployer == guardFactory)
                ? "true"
                : "false"
        );
        console.log("");
        if (initializePool) {
            require(
                deployer == guardOwner || deployer == guardFactory,
                "deployer must be LiquidGuard owner or factory"
            );
        }

        vm.startBroadcast(deployerPrivateKey);

        ExternalV4PoolBootstrapHelper helper = new ExternalV4PoolBootstrapHelper(
                poolManager,
                deployer
            );

        if (initializePool) {
            ILiquidGuard(liquidGuardAddress).addInitializer(address(helper));
        }

        IERC20(token).approve(address(helper), tokenAmountMax);
        IERC20(rareToken).approve(address(helper), rareAmountMax);

        ExternalV4PoolBootstrapHelper.BootstrapParams
            memory params = ExternalV4PoolBootstrapHelper.BootstrapParams({
                key: key,
                sqrtPriceX96: activeSqrtPriceX96,
                initializePool: initializePool,
                tickLower: plan.tickLower,
                tickUpper: plan.tickUpper,
                liquidityDelta: int128(uint128(plan.liquidity)),
                amount0Max: amount0Max,
                amount1Max: amount1Max
            });

        (uint256 amount0Used, uint256 amount1Used) = helper.bootstrap(params);

        if (initializePool) {
            try
                ILiquidGuard(liquidGuardAddress).removeInitializer(
                    address(helper)
                )
            {
                console.log("Helper removed from LiquidGuard allowlist.");
            } catch {
                console.log(
                    "Warning: helper removal failed; helper is still one-shot and owner-bound."
                );
            }
        }

        vm.stopBroadcast();

        uint256 tokenUsed = tokenIsCurrency0 ? amount0Used : amount1Used;
        uint256 rareUsed = tokenIsCurrency0 ? amount1Used : amount0Used;
        (
            uint160 finalSqrtPriceX96,
            int24 finalTick,
            uint24 finalProtocolFee,
            uint24 finalLpFee
        ) = poolManager.getSlot0(poolId);
        uint128 finalLiquidity = poolManager.getLiquidity(poolId);

        console.log("");
        console.log("=== Bootstrap Complete ===");
        console.log("Helper:");
        console.logAddress(address(helper));
        console.log("Initialized pool:");
        console.log(initializePool ? "true" : "false");
        console.log("Token used:");
        console.logUint(tokenUsed);
        console.log("RARE used:");
        console.logUint(rareUsed);
        console.log("Token leftover:");
        console.logUint(tokenAmountMax - tokenUsed);
        console.log("RARE leftover:");
        console.logUint(rareAmountMax - rareUsed);
        console.log("Final sqrtPriceX96:");
        console.logUint(finalSqrtPriceX96);
        console.log("Final tick:");
        console.logInt(finalTick);
        console.log("Final protocol fee:");
        console.logUint(finalProtocolFee);
        console.log("Final LP fee:");
        console.logUint(finalLpFee);
        console.log("Final liquidity:");
        console.logUint(finalLiquidity);
        console.log("Final currency1/currency0 (wad):");
        console.logUint(
            _sqrtPriceX96ToPriceWad(
                finalSqrtPriceX96,
                currency0Decimals,
                currency1Decimals
            )
        );
        console.log("Final currency0/currency1 (wad):");
        console.logUint(
            _invertPriceWad(
                _sqrtPriceX96ToPriceWad(
                    finalSqrtPriceX96,
                    currency0Decimals,
                    currency1Decimals
                )
            )
        );
    }

    function _discoverReferencePrice(
        address rareToken,
        NetworkConfig.Config memory config,
        address token,
        uint8 tokenDecimals
    ) internal view returns (PriceQuote memory quote) {
        try vm.envUint("TARGET_RARE_PER_TOKEN_WAD") returns (
            uint256 directRarePerTokenWad
        ) {
            require(directRarePerTokenWad > 0, "TARGET_RARE_PER_TOKEN_WAD=0");
            return
                PriceQuote({
                    quoteToken: rareToken,
                    quotePerTokenWad: directRarePerTokenWad,
                    source: "DIRECT TARGET_RARE_PER_TOKEN_WAD"
                });
        } catch {}

        string memory kind = _readStringEnvOr("REFERENCE_POOL_KIND", "");

        if (_equals(kind, "V2") || _equals(kind, "v2")) {
            address pair = vm.envAddress("REFERENCE_POOL");
            return _quoteFromV2Pool(pair, token, tokenDecimals);
        }

        if (_equals(kind, "V3") || _equals(kind, "v3")) {
            address pool = vm.envAddress("REFERENCE_POOL");
            return _quoteFromV3Pool(pool, token, tokenDecimals);
        }

        if (_equals(kind, "V4") || _equals(kind, "v4")) {
            address quoteToken = vm.envAddress("REFERENCE_QUOTE_TOKEN");
            uint24 fee = _readUint24EnvOr("REFERENCE_POOL_FEE", 0);
            int24 tickSpacing = _readInt24EnvOr("REFERENCE_TICK_SPACING", 60);
            address hooks = _readAddressEnvOr(
                "REFERENCE_POOL_HOOKS",
                address(0)
            );
            address poolManagerAddress = _readAddressEnvOr(
                "REFERENCE_POOL_MANAGER",
                config.uniswapV4PoolManager
            );
            return
                _quoteFromV4Pool(
                    poolManagerAddress,
                    token,
                    tokenDecimals,
                    quoteToken,
                    fee,
                    tickSpacing,
                    hooks
                );
        }

        revert(
            "set TARGET_RARE_PER_TOKEN_WAD or REFERENCE_POOL_KIND (V2/V3/V4)"
        );
    }

    function _resolveRarePerTokenWad(
        NetworkConfig.Config memory config,
        address poolManagerAddress,
        address rareToken,
        uint8 rareDecimals,
        PriceQuote memory referenceQuote
    ) internal view returns (uint256) {
        if (referenceQuote.quoteToken == rareToken) {
            return referenceQuote.quotePerTokenWad;
        }

        if (_isEthEquivalent(referenceQuote.quoteToken, config.weth)) {
            uint256 rarePerEthWad = _readRarePerEthWad(
                config,
                poolManagerAddress,
                rareDecimals
            );
            return
                FullMath.mulDiv(
                    referenceQuote.quotePerTokenWad,
                    rarePerEthWad,
                    WAD
                );
        }

        try vm.envUint("RARE_PER_QUOTE_WAD") returns (uint256 rarePerQuoteWad) {
            require(rarePerQuoteWad > 0, "RARE_PER_QUOTE_WAD=0");
            return
                FullMath.mulDiv(
                    referenceQuote.quotePerTokenWad,
                    rarePerQuoteWad,
                    WAD
                );
        } catch {
            revert(
                "unsupported quote token; set RARE_PER_QUOTE_WAD for conversion"
            );
        }
    }

    function _buildRangePlan(
        uint160 sqrtPriceX96,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 priceCurrency1PerCurrency0Wad,
        uint8 currency0Decimals,
        uint8 currency1Decimals,
        int24 tickSpacing
    ) internal view returns (RangePlan memory plan) {
        bool hasExplicitTicks;
        int24 explicitTickLower;
        int24 explicitTickUpper;

        try vm.envInt("TARGET_TICK_LOWER") returns (int256 lower) {
            try vm.envInt("TARGET_TICK_UPPER") returns (int256 upper) {
                require(
                    lower >= type(int24).min &&
                        lower <= type(int24).max &&
                        upper >= type(int24).min &&
                        upper <= type(int24).max,
                    "explicit ticks overflow int24"
                );
                explicitTickLower = int24(lower);
                explicitTickUpper = int24(upper);
                hasExplicitTicks = true;
            } catch {}
        } catch {}

        if (hasExplicitTicks) {
            require(
                explicitTickLower % tickSpacing == 0 &&
                    explicitTickUpper % tickSpacing == 0,
                "explicit ticks must align with tick spacing"
            );
            plan.tickLower = explicitTickLower;
            plan.tickUpper = explicitTickUpper;
        } else {
            bool hasManualBands;
            uint256 lowerPriceBps;
            uint256 upperPriceBps;

            try vm.envUint("LOWER_PRICE_BPS") returns (uint256 lowerBps) {
                try vm.envUint("UPPER_PRICE_BPS") returns (uint256 upperBps) {
                    lowerPriceBps = lowerBps;
                    upperPriceBps = upperBps;
                    hasManualBands = true;
                } catch {}
            } catch {}

            if (hasManualBands) {
                require(
                    lowerPriceBps < BPS_DENOMINATOR,
                    "LOWER_PRICE_BPS >= 10000"
                );

                uint256 lowerPriceWad = FullMath.mulDiv(
                    priceCurrency1PerCurrency0Wad,
                    BPS_DENOMINATOR - lowerPriceBps,
                    BPS_DENOMINATOR
                );
                uint256 upperPriceWad = FullMath.mulDiv(
                    priceCurrency1PerCurrency0Wad,
                    BPS_DENOMINATOR + upperPriceBps,
                    BPS_DENOMINATOR
                );

                uint160 sqrtLower = _priceWadToSqrtPriceX96(
                    lowerPriceWad,
                    currency0Decimals,
                    currency1Decimals
                );
                uint160 sqrtUpper = _priceWadToSqrtPriceX96(
                    upperPriceWad,
                    currency0Decimals,
                    currency1Decimals
                );

                plan.tickLower = _floorToSpacing(
                    TickMath.getTickAtSqrtPrice(sqrtLower),
                    tickSpacing
                );
                plan.tickUpper = _ceilToSpacing(
                    TickMath.getTickAtSqrtPrice(sqrtUpper),
                    tickSpacing
                );
            } else {
                (
                    uint160 autoLower,
                    uint160 autoUpper,
                    bool currency0Scarce
                ) = _planAutoSqrtBounds(
                        sqrtPriceX96,
                        amount0Max,
                        amount1Max,
                        priceCurrency1PerCurrency0Wad,
                        currency0Decimals,
                        currency1Decimals,
                        tickSpacing
                    );

                plan.tickLower = _floorToSpacing(
                    TickMath.getTickAtSqrtPrice(autoLower),
                    tickSpacing
                );
                plan.tickUpper = _ceilToSpacing(
                    TickMath.getTickAtSqrtPrice(autoUpper),
                    tickSpacing
                );
                plan.currency0Scarce = currency0Scarce;
            }
        }

        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);

        if (plan.tickLower < minTick) plan.tickLower = minTick;
        if (plan.tickUpper > maxTick) plan.tickUpper = maxTick;

        if (plan.tickLower >= plan.tickUpper) {
            int24 spotTick = _floorToSpacing(
                TickMath.getTickAtSqrtPrice(sqrtPriceX96),
                tickSpacing
            );
            plan.tickLower = spotTick - tickSpacing;
            plan.tickUpper = spotTick + tickSpacing;
            if (plan.tickLower < minTick) plan.tickLower = minTick;
            if (plan.tickUpper > maxTick) plan.tickUpper = maxTick;
            require(plan.tickLower < plan.tickUpper, "invalid tick range");
        }

        plan.sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(plan.tickLower);
        plan.sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(plan.tickUpper);

        plan.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            plan.sqrtPriceLowerX96,
            plan.sqrtPriceUpperX96,
            amount0Max,
            amount1Max
        );

        require(plan.liquidity > 0, "zero liquidity after planning");

        if (sqrtPriceX96 <= plan.sqrtPriceLowerX96) {
            plan.amount0UsedEstimate = SqrtPriceMath.getAmount0Delta(
                plan.sqrtPriceLowerX96,
                plan.sqrtPriceUpperX96,
                plan.liquidity,
                true
            );
        } else if (sqrtPriceX96 < plan.sqrtPriceUpperX96) {
            plan.amount0UsedEstimate = SqrtPriceMath.getAmount0Delta(
                sqrtPriceX96,
                plan.sqrtPriceUpperX96,
                plan.liquidity,
                true
            );
            plan.amount1UsedEstimate = SqrtPriceMath.getAmount1Delta(
                plan.sqrtPriceLowerX96,
                sqrtPriceX96,
                plan.liquidity,
                true
            );
        } else {
            plan.amount1UsedEstimate = SqrtPriceMath.getAmount1Delta(
                plan.sqrtPriceLowerX96,
                plan.sqrtPriceUpperX96,
                plan.liquidity,
                true
            );
        }
    }

    function _planAutoSqrtBounds(
        uint160 sqrtPriceX96,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 priceCurrency1PerCurrency0Wad,
        uint8 currency0Decimals,
        uint8 currency1Decimals,
        int24 tickSpacing
    )
        internal
        view
        returns (uint160 sqrtLower, uint160 sqrtUpper, bool currency0Scarce)
    {
        require(
            amount0Max > 0 && amount1Max > 0,
            "need both assets for auto range"
        );

        uint256 amount0WholeWad = FullMath.mulDiv(
            amount0Max,
            WAD,
            _pow10(currency0Decimals)
        );
        uint256 amount1WholeWad = FullMath.mulDiv(
            amount1Max,
            WAD,
            _pow10(currency1Decimals)
        );
        uint256 amount0ValueInCurrency1Wad = FullMath.mulDiv(
            amount0WholeWad,
            priceCurrency1PerCurrency0Wad,
            WAD
        );
        currency0Scarce = amount0ValueInCurrency1Wad <= amount1WholeWad;

        uint256 nearRangeBps = _readUintEnvOr(
            "AUTO_SCARCE_SIDE_RANGE_BPS",
            2500
        );
        uint160 sqrtMultiplierX96 = _priceWadToSqrtPriceX96(
            WAD + nearRangeBps * 1e14,
            18,
            18
        );

        uint160 minSqrt = TickMath.getSqrtPriceAtTick(
            TickMath.minUsableTick(tickSpacing)
        );
        uint160 maxSqrt = TickMath.getSqrtPriceAtTick(
            TickMath.maxUsableTick(tickSpacing)
        );

        if (currency0Scarce) {
            sqrtUpper = uint160(
                FullMath.mulDiv(
                    uint256(sqrtPriceX96),
                    uint256(sqrtMultiplierX96),
                    FixedPoint96.Q96
                )
            );
            if (sqrtUpper >= maxSqrt) sqrtUpper = maxSqrt;

            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
                sqrtPriceX96,
                sqrtUpper,
                amount0Max
            );
            uint256 distance = FullMath.mulDiv(
                amount1Max,
                FixedPoint96.Q96,
                liquidity
            );

            if (distance >= sqrtPriceX96) {
                sqrtLower = minSqrt;
            } else {
                sqrtLower = uint160(uint256(sqrtPriceX96) - distance);
                if (sqrtLower <= minSqrt) sqrtLower = minSqrt;
            }
        } else {
            sqrtLower = uint160(
                FullMath.mulDiv(
                    uint256(sqrtPriceX96),
                    FixedPoint96.Q96,
                    uint256(sqrtMultiplierX96)
                )
            );
            if (sqrtLower <= minSqrt) sqrtLower = minSqrt;

            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
                sqrtLower,
                sqrtPriceX96,
                amount1Max
            );

            uint256 liquidityQ96 = uint256(liquidity) * FixedPoint96.Q96;
            uint256 amount0TimesSqrt = amount0Max * uint256(sqrtPriceX96);

            if (liquidityQ96 <= amount0TimesSqrt) {
                sqrtUpper = maxSqrt;
            } else {
                sqrtUpper = uint160(
                    FullMath.mulDiv(
                        liquidityQ96,
                        uint256(sqrtPriceX96),
                        liquidityQ96 - amount0TimesSqrt
                    )
                );
                if (sqrtUpper >= maxSqrt) sqrtUpper = maxSqrt;
            }
        }

        require(
            sqrtLower < sqrtPriceX96 && sqrtPriceX96 < sqrtUpper,
            "auto range failed"
        );
    }

    function _quoteFromV2Pool(
        address pairAddress,
        address token,
        uint8 tokenDecimals
    ) internal view returns (PriceQuote memory quote) {
        IUniswapV2PairLike pair = IUniswapV2PairLike(pairAddress);
        address token0 = pair.token0();
        address token1 = pair.token1();

        require(
            token0 == token || token1 == token,
            "token missing from V2 pair"
        );

        address quoteToken = token0 == token ? token1 : token0;
        uint8 quoteDecimals = _readTokenDecimals(
            quoteToken,
            "REFERENCE_QUOTE_DECIMALS"
        );
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();

        uint256 quotePerTokenWad;
        if (token0 == token) {
            quotePerTokenWad = _reservePriceToWad(
                reserve0,
                tokenDecimals,
                reserve1,
                quoteDecimals
            );
        } else {
            quotePerTokenWad = _reservePriceToWad(
                reserve1,
                tokenDecimals,
                reserve0,
                quoteDecimals
            );
        }

        return
            PriceQuote({
                quoteToken: quoteToken,
                quotePerTokenWad: quotePerTokenWad,
                source: "REFERENCE_POOL_KIND=V2"
            });
    }

    function _quoteFromV3Pool(
        address poolAddress,
        address token,
        uint8 tokenDecimals
    ) internal view returns (PriceQuote memory quote) {
        IUniswapV3PoolLike pool = IUniswapV3PoolLike(poolAddress);
        address token0 = pool.token0();
        address token1 = pool.token1();

        require(
            token0 == token || token1 == token,
            "token missing from V3 pool"
        );

        address quoteToken = token0 == token ? token1 : token0;
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint8 quoteDecimals = _readTokenDecimals(
            quoteToken,
            "REFERENCE_QUOTE_DECIMALS"
        );

        uint256 priceToken1PerToken0Wad = _sqrtPriceX96ToPriceWad(
            sqrtPriceX96,
            token0 == token ? tokenDecimals : quoteDecimals,
            token1 == token ? tokenDecimals : quoteDecimals
        );

        uint256 quotePerTokenWad = token0 == token
            ? priceToken1PerToken0Wad
            : _invertPriceWad(priceToken1PerToken0Wad);

        return
            PriceQuote({
                quoteToken: quoteToken,
                quotePerTokenWad: quotePerTokenWad,
                source: "REFERENCE_POOL_KIND=V3"
            });
    }

    function _quoteFromV4Pool(
        address poolManagerAddress,
        address token,
        uint8 tokenDecimals,
        address quoteToken,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) internal view returns (PriceQuote memory quote) {
        bool tokenIsCurrency0 = token < quoteToken;
        address currency0Address = tokenIsCurrency0 ? token : quoteToken;
        address currency1Address = tokenIsCurrency0 ? quoteToken : token;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0Address),
            currency1: Currency.wrap(currency1Address),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        (uint160 sqrtPriceX96, , , ) = IPoolManager(poolManagerAddress)
            .getSlot0(key.toId());
        require(sqrtPriceX96 != 0, "reference V4 pool not initialized");

        uint8 quoteDecimals = _readTokenDecimals(
            quoteToken,
            "REFERENCE_QUOTE_DECIMALS"
        );
        uint8 currency0Decimals = tokenIsCurrency0
            ? tokenDecimals
            : quoteDecimals;
        uint8 currency1Decimals = tokenIsCurrency0
            ? quoteDecimals
            : tokenDecimals;

        uint256 priceToken1PerToken0Wad = _sqrtPriceX96ToPriceWad(
            sqrtPriceX96,
            currency0Decimals,
            currency1Decimals
        );

        return
            PriceQuote({
                quoteToken: quoteToken,
                quotePerTokenWad: tokenIsCurrency0
                    ? priceToken1PerToken0Wad
                    : _invertPriceWad(priceToken1PerToken0Wad),
                source: "REFERENCE_POOL_KIND=V4"
            });
    }

    function _readRarePerEthWad(
        NetworkConfig.Config memory config,
        address poolManagerAddress,
        uint8 rareDecimals
    ) internal view returns (uint256) {
        try vm.envUint("RARE_PER_ETH_WAD") returns (uint256 direct) {
            require(direct > 0, "RARE_PER_ETH_WAD=0");
            return direct;
        } catch {}

        bytes32 rareEthPoolId;
        try vm.envBytes32("RARE_ETH_POOL_ID") returns (bytes32 envPoolId) {
            rareEthPoolId = envPoolId;
        } catch {
            rareEthPoolId = config.rareEthPoolId;
        }
        require(rareEthPoolId != bytes32(0), "RARE_ETH_POOL_ID not configured");

        address rareEthPoolManager = _readAddressEnvOr(
            "RARE_ETH_POOL_MANAGER",
            poolManagerAddress
        );

        (uint160 sqrtPriceX96, , , ) = IPoolManager(rareEthPoolManager)
            .getSlot0(PoolId.wrap(rareEthPoolId));
        require(sqrtPriceX96 != 0, "RARE/ETH pool not initialized");

        return _sqrtPriceX96ToPriceWad(sqrtPriceX96, 18, rareDecimals);
    }

    function _reservePriceToWad(
        uint256 baseReserve,
        uint8 baseDecimals,
        uint256 quoteReserve,
        uint8 quoteDecimals
    ) internal pure returns (uint256) {
        require(baseReserve > 0 && quoteReserve > 0, "empty reserves");
        return
            FullMath.mulDiv(
                quoteReserve,
                WAD * _pow10(baseDecimals),
                baseReserve * _pow10(quoteDecimals)
            );
    }

    function _sqrtPriceX96ToPriceWad(
        uint160 sqrtPriceX96,
        uint8 decimals0,
        uint8 decimals1
    ) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(
            uint256(sqrtPriceX96),
            uint256(sqrtPriceX96),
            FixedPoint96.Q96
        );

        return
            FullMath.mulDiv(
                priceX96,
                WAD * _pow10(decimals0),
                FixedPoint96.Q96 * _pow10(decimals1)
            );
    }

    function _priceWadToSqrtPriceX96(
        uint256 priceWad,
        uint8 decimals0,
        uint8 decimals1
    ) internal pure returns (uint160) {
        require(priceWad > 0, "price=0");

        uint256 rawPriceX128 = FullMath.mulDiv(
            priceWad,
            Q128 * _pow10(decimals1),
            WAD * _pow10(decimals0)
        );

        uint256 sqrtPriceX64 = Math.sqrt(rawPriceX128);
        uint256 sqrtPriceX96 = sqrtPriceX64 * Q32;

        require(sqrtPriceX96 > 0, "sqrtPrice=0");
        require(sqrtPriceX96 <= type(uint160).max, "sqrtPrice overflow");
        return uint160(sqrtPriceX96);
    }

    function _invertPriceWad(uint256 priceWad) internal pure returns (uint256) {
        require(priceWad > 0, "cannot invert zero price");
        return FullMath.mulDiv(WAD, WAD, priceWad);
    }

    function _differenceBps(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        if (a == b) return 0;
        uint256 larger = a > b ? a : b;
        uint256 smaller = a > b ? b : a;
        return FullMath.mulDiv(larger - smaller, BPS_DENOMINATOR, larger);
    }

    function _isEthEquivalent(
        address quoteToken,
        address weth
    ) internal pure returns (bool) {
        return quoteToken == address(0) || quoteToken == weth;
    }

    function _readTokenDecimals(
        address token,
        string memory envKey
    ) internal view returns (uint8) {
        if (token == address(0)) return 18;

        try IERC20Metadata(token).decimals() returns (uint8 decimalsValue) {
            return decimalsValue;
        } catch {
            try vm.envUint(envKey) returns (uint256 overrideValue) {
                require(
                    overrideValue <= type(uint8).max,
                    "decimals override too big"
                );
                return uint8(overrideValue);
            } catch {
                revert("could not read token decimals");
            }
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

    function _readUintEnvOr(
        string memory envKey,
        uint256 defaultValue
    ) internal view returns (uint256) {
        try vm.envUint(envKey) returns (uint256 value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function _readUint24EnvOr(
        string memory envKey,
        uint24 defaultValue
    ) internal view returns (uint24) {
        try vm.envUint(envKey) returns (uint256 value) {
            require(value <= type(uint24).max, "uint24 env overflow");
            return uint24(value);
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

    function _readStringEnvOr(
        string memory envKey,
        string memory defaultValue
    ) internal view returns (string memory) {
        try vm.envString(envKey) returns (string memory value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function _pow10(uint8 exponent) internal pure returns (uint256) {
        return 10 ** uint256(exponent);
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

    function _equals(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
