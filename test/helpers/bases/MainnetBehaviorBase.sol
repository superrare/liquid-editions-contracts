// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

/**
 * @title MainnetBehaviorBase
 * @notice Shared base for Ethereum Mainnet user-behavior scenario tests.
 *         Forks Ethereum mainnet and reads the live RARE/ETH V4 pool price.
 *         Handles price caching, route encoding, fee parsing, trade execution,
 *         and console formatting.
 *
 * @dev Subclasses must:
 *   1. Call _setupMainnetBehavior() in setUp().
 *   2. Set `token` to the deployed ILiquid instance.
 *   3. Set `_rareIsCurrency0` from token.poolKey().
 */
abstract contract MainnetBehaviorBase is Test {
    using StateLibrary for IPoolManager;

    // ============================================
    // UNIVERSAL ROUTER COMMAND / ACTION CODES
    // ============================================
    bytes1 internal constant V4_SWAP = 0x10;

    uint8 internal constant SWAP_EXACT_IN = 0x07;
    uint8 internal constant SETTLE_ALL    = 0x0c;
    uint8 internal constant TAKE_ALL      = 0x0f;

    // ETH/RARE V4 pool parameters
    uint24  internal constant ETH_RARE_POOL_FEE          = 3000;
    int24   internal constant ETH_RARE_POOL_TICK_SPACING = 60;

    // FeeDistributor event topic hashes
    // FeeConvertedAndDistributed(address indexed, address indexed, uint256, uint256, uint256, uint256)
    bytes32 internal constant FEE_CONVERTED_TOPIC =
        keccak256("FeeConvertedAndDistributed(address,address,uint256,uint256,uint256,uint256)");
    // FeeDistributedInRare(address indexed, address indexed, uint256, uint256, uint256, bytes32)
    bytes32 internal constant FEE_IN_RARE_TOPIC =
        keccak256("FeeDistributedInRare(address,address,uint256,uint256,uint256,bytes32)");

    // ============================================
    // STATE
    // ============================================
    NetworkConfig.Config internal config;
    LiquidFactory internal factory;
    LiquidRouter  internal router;
    ILiquid       internal token;

    address    internal tokenCreator;
    address[5] internal buyers;

    // Whether RARE is currency0 in the LIQUID/RARE pool (Uniswap sorts by address).
    bool internal _rareIsCurrency0;

    // PathKey must match v4-periphery's PathKey exactly for ABI encoding
    struct PathKey {
        address intermediateCurrency;
        uint24  fee;
        int24   tickSpacing;
        address hooks;
        bytes   hookData;
    }

    struct ScenarioTotals {
        uint256 totalEthIn;
        uint256 totalTokensBought;
        uint256 totalRareIn;
        uint256 totalFeesEth;
        uint256 totalFeesRare;
        int24   minTickReached;
        int24   maxTickReached;
    }

    // ============================================
    // SETUP HELPER
    // ============================================

    /**
     * @notice Core setup shared by all Mainnet behavior tests.
     *         Selects the mainnet fork and binds deployed contracts.
     */
    function _setupMainnetBehavior() internal {
        vm.createSelectFork("mainnet");

        config  = NetworkConfig.getConfig(block.chainid); // 1
        factory = LiquidFactory(config.liquid.factory);
        router  = LiquidRouter(payable(config.liquid.router));
    }

    // ============================================
    // PRICE HELPERS
    // ============================================

    /**
     * @dev Reads the current live RARE/ETH V4 pool price.
     *      ETH = address(0) is always numerically smallest, so for any ETH/RARE pool:
     *        currency0 = ETH, currency1 = RARE
     *        sqrtPriceX96 = sqrt(RARE/ETH) * 2^96
     */
    function _getRareEthPrice()
        internal
        view
        returns (uint256 rarePerEth, uint256 ethPerRare)
    {
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(PoolId.wrap(config.rareEthPoolId));
        if (sqrtPriceX96 == 0) return (0, 0);

        uint256 sqrtQ48  = uint256(sqrtPriceX96) >> 48;
        uint256 priceQ96 = (sqrtQ48 * sqrtQ48 * 1e18) >> 96; // currency1 per currency0

        bool rareIsCurrency1 = address(0) < config.rareToken; // ETH=0x0 is always smaller

        if (rareIsCurrency1) {
            rarePerEth = priceQ96;
            ethPerRare = rarePerEth > 0 ? 1e36 / rarePerEth : 0;
        } else {
            ethPerRare = priceQ96;
            rarePerEth = ethPerRare > 0 ? 1e36 / ethPerRare : 0;
        }
    }

    /// @dev Converts a RARE-denominated token price to its ETH equivalent.
    function _toEthPrice(uint256 rarePerToken) internal view returns (uint256) {
        (, uint256 ethPerRare) = _getRareEthPrice();
        if (ethPerRare == 0) return 0;
        return (rarePerToken * ethPerRare) / 1e18;
    }

    function _printRareEthPrice() internal view {
        (uint256 rarePerEth, uint256 ethPerRare) = _getRareEthPrice();
        if (rarePerEth == 0) {
            console.log("--- RARE/ETH PRICE: pool not initialized ---");
            return;
        }
        console.log("--- RARE/ETH PRICE (Mainnet V4 pool) ---");
        console.log(string.concat("  1 ETH  = ", _fmt(rarePerEth), " RARE"));
        console.log(string.concat("  1 RARE = ", _fmtPrice(ethPerRare), " ETH"));
        console.log("");
    }

    function _printMarketState(string memory label) internal view {
        (
            uint256 rarePerToken,
            uint256 tokenPerRare,
            uint160 sqrtPriceX96,
            int24   currentTick,
            uint128 liquidity,
        ) = token.getMarketState();

        uint256 ethPerToken = _toEthPrice(rarePerToken);

        console.log(string.concat("--- ", label, " ---"));
        console.log(string.concat("  Price (RARE/token) : ", _fmtPrice(rarePerToken)));
        console.log(string.concat("  Price (ETH/token)  : ", _fmtPrice(ethPerToken)));
        console.log(string.concat("  Tokens per RARE    : ", _fmtTokens(tokenPerRare)));
        console.log(string.concat("  sqrtPriceX96       : ", vm.toString(uint256(sqrtPriceX96))));
        console.log(string.concat("  Current tick       : ", vm.toString(int256(currentTick))));
        console.log(string.concat("  Pool liquidity     : ", vm.toString(uint256(liquidity))));
        console.log("");
    }

    // ============================================
    // TRADE HELPERS
    // ============================================

    /// @dev Executes a buy and updates aggregate scenario totals.
    function _doTrackedBuy(
        ScenarioTotals memory totals,
        address buyer,
        uint256 ethAmount,
        string memory label
    ) internal {
        (
            uint256 tokensReceived,
            uint256 rareConsumed,
            uint256 feeEthTotal,
            uint256 feeRareTotal,
            int24   tickAfter
        ) = _doBuy(buyer, ethAmount, label);

        totals.totalEthIn        += ethAmount;
        totals.totalTokensBought += tokensReceived;
        totals.totalRareIn       += rareConsumed;
        totals.totalFeesEth      += feeEthTotal;
        totals.totalFeesRare     += feeRareTotal;

        if (_rareIsCurrency0) {
            if (tickAfter < totals.minTickReached) totals.minTickReached = tickAfter;
        } else {
            if (tickAfter > totals.maxTickReached) totals.maxTickReached = tickAfter;
        }
    }

    /// @dev Executes a buy and logs: ETH in, tokens out, price delta, effective price, fees.
    function _doBuy(
        address buyer,
        uint256 ethAmount,
        string memory label
    )
        internal
        returns (
            uint256 tokensReceived,
            uint256 rareConsumed,
            uint256 feeEthTotal,
            uint256 feeRareTotal,
            int24   tickAfter
        )
    {
        (uint256 rarePriceBefore, , , , , ) = token.getMarketState();
        uint256 ethPxBefore = _toEthPrice(rarePriceBefore);

        uint256 rareBefore = IERC20(config.rareToken).balanceOf(address(token));

        vm.recordLogs();

        vm.prank(buyer);
        (bytes memory commands, bytes[] memory inputs) = _encodeBuyRoute(address(token), ethAmount, 1);
        tokensReceived = router.buy{value: ethAmount}(
            address(token), buyer, 1, commands, inputs, block.timestamp + 1 hours
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 rareAfter = IERC20(config.rareToken).balanceOf(address(token));
        rareConsumed = rareAfter > rareBefore ? rareAfter - rareBefore : 0;

        (uint256 rarePriceAfter, , , int24 tickAfterRead, , ) = token.getMarketState();
        tickAfter      = tickAfterRead;
        uint256 ethPxAfter = _toEthPrice(rarePriceAfter);

        (feeEthTotal, feeRareTotal) = _parseFees(logs);

        string memory pctChange;
        if (rarePriceBefore > 0) {
            uint256 absDelta = rarePriceAfter > rarePriceBefore
                ? rarePriceAfter - rarePriceBefore
                : rarePriceBefore - rarePriceAfter;
            pctChange = string.concat(
                rarePriceAfter >= rarePriceBefore ? "+" : "-",
                _fmtPct(absDelta, rarePriceBefore)
            );
        } else {
            pctChange = "n/a";
        }

        uint256 ethPerToken = tokensReceived == 0 ? 0 : (ethAmount * 1e18) / tokensReceived;

        string memory feeSummary;
        if (feeEthTotal > 0) {
            feeSummary = string.concat(
                " | fee: ", _fmtPrice(feeEthTotal), "E (",
                _fmtPct(feeEthTotal, ethAmount), " of ETH in)"
            );
        } else if (feeRareTotal > 0) {
            uint256 feeEthEquiv = _toEthPrice(feeRareTotal);
            feeSummary = string.concat(
                " | fee: ", _fmt(feeRareTotal), "R (~",
                _fmtPrice(feeEthEquiv), "E, ",
                _fmtPct(feeEthEquiv, ethAmount), " of ETH in)"
            );
        } else {
            feeSummary = " | fee: none";
        }

        console.log(string.concat(
            label,
            " | in=",     _fmtPrice(ethAmount),     "E",
            " | out=",    _fmtTokens(tokensReceived),
            " | pxE=",    _fmtPrice(ethPxBefore),   "->", _fmtPrice(ethPxAfter),
            " | dpx=",    pctChange,
            " | effEth=", _fmtPrice(ethPerToken),   "E/1T",
            feeSummary
        ));
    }

    /// @dev Executes a sell and logs: tokens in, ETH out, price delta, fees.
    function _doSell(
        address seller,
        uint256 tokenAmount,
        string memory label
    ) internal returns (uint256 ethReceived) {
        (uint256 rarePriceBefore, , , int24 tickBefore, , ) = token.getMarketState();
        uint256 ethPxBefore = _toEthPrice(rarePriceBefore);

        vm.recordLogs();

        vm.startPrank(seller);
        IERC20(address(token)).approve(address(router), tokenAmount);
        (bytes memory commands, bytes[] memory inputs) = _encodeSellRoute(address(token), tokenAmount, 1);
        ethReceived = router.sell(
            address(token), tokenAmount, seller, 1, commands, inputs, block.timestamp + 1 hours
        );
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 rarePriceAfter, , , int24 tickAfter, , ) = token.getMarketState();
        uint256 ethPxAfter = _toEthPrice(rarePriceAfter);

        (uint256 feeEthTotal, uint256 feeRareTotal) = _parseFees(logs);

        string memory pctChange;
        if (rarePriceBefore > 0) {
            uint256 absDelta = rarePriceAfter > rarePriceBefore
                ? rarePriceAfter - rarePriceBefore
                : rarePriceBefore - rarePriceAfter;
            pctChange = string.concat(
                rarePriceAfter >= rarePriceBefore ? "+" : "-",
                _fmtPct(absDelta, rarePriceBefore)
            );
        } else {
            pctChange = "n/a";
        }

        console.log(string.concat(
            label,
            " | in=",   _fmtTokens(tokenAmount),
            " | out=",  _fmtPrice(ethReceived),    "E",
            " | pxE=",  _fmtPrice(ethPxBefore),    "->", _fmtPrice(ethPxAfter),
            " | pxR=",  _fmtPrice(rarePriceBefore), "->", _fmtPrice(rarePriceAfter),
            " | dpx=",  pctChange,
            " | tick=", vm.toString(int256(tickBefore)), "->", vm.toString(int256(tickAfter))
        ));

        if (feeEthTotal > 0) {
            console.log(string.concat(
                "         fee: ", _fmtPrice(feeEthTotal), "E  (",
                _fmtPct(feeEthTotal, ethReceived), " of ETH out)"
            ));
        } else if (feeRareTotal > 0) {
            uint256 feeEthEquiv = _toEthPrice(feeRareTotal);
            console.log(string.concat(
                "         fee: ", _fmt(feeRareTotal), "R  (~",
                _fmtPrice(feeEthEquiv), "E, ",
                _fmtPct(feeEthEquiv, ethReceived), " of ETH out)"
            ));
        } else {
            console.log("         fee: none detected in this tx");
        }
    }

    // ============================================
    // FEE EVENT PARSING
    // ============================================

    /// @dev Scans recorded logs for FeeDistributor events and returns total fee amounts.
    function _parseFees(
        Vm.Log[] memory logs
    ) internal pure returns (uint256 feeEthTotal, uint256 feeRareTotal) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;

            if (logs[i].topics[0] == FEE_CONVERTED_TOPIC) {
                (, , uint256 ethBeneficiary, uint256 ethProtocol) = abi.decode(
                    logs[i].data, (uint256, uint256, uint256, uint256)
                );
                feeEthTotal += ethBeneficiary + ethProtocol;
            } else if (logs[i].topics[0] == FEE_IN_RARE_TOPIC) {
                (uint256 rareTotal, , , ) = abi.decode(
                    logs[i].data, (uint256, uint256, uint256, bytes32)
                );
                feeRareTotal += rareTotal;
            }
        }
    }

    // ============================================
    // ROUTE ENCODING
    // ============================================

    function _encodeBuyRoute(
        address liquidTokenAddress,
        uint256 ethForSwap,
        uint256 minTokensOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        address currencyIn = address(0);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: config.rareToken,
            fee:         ETH_RARE_POOL_FEE,
            tickSpacing: ETH_RARE_POOL_TICK_SPACING,
            hooks:       address(0),
            hookData:    bytes("")
        });
        path[1] = PathKey({
            intermediateCurrency: liquidTokenAddress,
            fee:         0,
            tickSpacing: 60,
            hooks:       factory.poolHooks(),
            hookData:    bytes("")
        });

        bytes memory actions = abi.encodePacked(
            uint8(SWAP_EXACT_IN), uint8(SETTLE_ALL), uint8(TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(currencyIn, path, uint128(ethForSwap), uint128(minTokensOut));
        params[1] = abi.encode(currencyIn, type(uint128).max);
        params[2] = abi.encode(liquidTokenAddress, uint128(minTokensOut));

        commands  = abi.encodePacked(V4_SWAP);
        inputs    = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _encodeSellRoute(
        address liquidTokenAddress,
        uint256 tokenAmount,
        uint256 minEthOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        address outputCurrency = address(0);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: config.rareToken,
            fee:         0,
            tickSpacing: 60,
            hooks:       factory.poolHooks(),
            hookData:    bytes("")
        });
        path[1] = PathKey({
            intermediateCurrency: outputCurrency,
            fee:         ETH_RARE_POOL_FEE,
            tickSpacing: ETH_RARE_POOL_TICK_SPACING,
            hooks:       address(0),
            hookData:    bytes("")
        });

        bytes memory actions = abi.encodePacked(
            uint8(SWAP_EXACT_IN), uint8(SETTLE_ALL), uint8(TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        bytes memory structData = abi.encode(liquidTokenAddress, path, uint128(tokenAmount), uint128(minEthOut));
        params[0] = abi.encodePacked(uint256(0x20), structData);
        params[1] = abi.encode(liquidTokenAddress, type(uint128).max);
        params[2] = abi.encode(outputCurrency, uint128(minEthOut));

        commands  = abi.encodePacked(V4_SWAP);
        inputs    = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    // ============================================
    // FORMATTING HELPERS
    // ============================================

    function _fmt(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e18;
        uint256 frac  = (amount % 1e18) / 1e15;

        if (frac == 0) return vm.toString(whole);

        string memory fracStr = vm.toString(frac);
        if (frac < 10)       fracStr = string.concat("00", fracStr);
        else if (frac < 100) fracStr = string.concat("0",  fracStr);

        return string.concat(vm.toString(whole), ".", fracStr);
    }

    function _fmtTokens(uint256 amount) internal pure returns (string memory) {
        return string.concat(_fmt(amount), "T");
    }

    function _fmtPct(uint256 part, uint256 total) internal pure returns (string memory) {
        if (total == 0) return "0%";
        uint256 pctBps = (part * 10000) / total;
        uint256 whole  = pctBps / 100;
        uint256 frac   = pctBps % 100;
        string memory fracStr = frac < 10
            ? string.concat("0", vm.toString(frac))
            : vm.toString(frac);
        return string.concat(vm.toString(whole), ".", fracStr, "%");
    }

    function _fmtPrice(uint256 priceWei) internal pure returns (string memory) {
        if (priceWei == 0) return "0";

        uint256 whole = priceWei / 1e18;
        if (whole > 0) return _fmt(priceWei);

        uint256 frac9 = (priceWei % 1e18) / 1e9;
        if (frac9 == 0) return "0";

        string memory fracStr = vm.toString(frac9);
        if      (frac9 < 10)        fracStr = string.concat("00000000", fracStr);
        else if (frac9 < 100)       fracStr = string.concat("0000000",  fracStr);
        else if (frac9 < 1000)      fracStr = string.concat("000000",   fracStr);
        else if (frac9 < 10000)     fracStr = string.concat("00000",    fracStr);
        else if (frac9 < 100000)    fracStr = string.concat("0000",     fracStr);
        else if (frac9 < 1000000)   fracStr = string.concat("000",      fracStr);
        else if (frac9 < 10000000)  fracStr = string.concat("00",       fracStr);
        else if (frac9 < 100000000) fracStr = string.concat("0",        fracStr);

        return string.concat("0.", fracStr);
    }
}
