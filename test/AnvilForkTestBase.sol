// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {LiquidAuctioneer} from "liquid-editions/LiquidAuctioneer.sol";
import {LiquidRouterForkBase} from "liquid-editions-test/helpers/bases/LiquidRouterForkBase.sol";
import {DeployLiquidAuctioneer} from "script/deployers/DeployLiquidAuctioneer.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/// @notice Interface for FullRangeLBPStrategyFactory to compute addresses
interface IStrategyFactory {
    function getAddress(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt,
        address sender
    ) external view returns (address);
}

/**
 * @title AnvilForkTestBase
 * @notice Abstract base for fork integration tests. Extends LiquidRouterForkBase; adds auctioneer, liquidToken, route encoding.
 */
abstract contract AnvilForkTestBase is LiquidRouterForkBase {
    using StateLibrary for IPoolManager;

    LiquidAuctioneer public auctioneer;
    LiquidInstant public liquidToken;
    LiquidInstant public liquidToken2; // Second token for swap test
    string internal forkUrlForFFI;

    // Universal Router command codes
    bytes1 constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 constant PERMIT2_TRANSFER_FROM = 0x02;
    bytes1 constant WRAP_ETH = 0x0b;
    bytes1 constant UNWRAP_WETH = 0x0c;
    bytes1 constant V4_SWAP = 0x10;

    // Universal Router recipient placeholders
    address constant MSG_SENDER =
        address(0x0000000000000000000000000000000000000001);
    address constant ROUTER_ADDRESS =
        address(0x0000000000000000000000000000000000000002);

    // V4 action codes (from v4-periphery Actions.sol)
    uint8 constant SWAP_EXACT_IN = 0x07; // Multi-hop
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;

    // ETH/RARE V4 pool params (mainnet pool 0xc5e82ff...)
    uint24 constant ETH_RARE_POOL_FEE = 3000;
    int24 constant ETH_RARE_POOL_TICK_SPACING = 60;

    /// @notice PathKey struct for V4 multi-hop routing
    /// @dev Must match v4-periphery's PathKey exactly for proper ABI encoding
    struct PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    function _configureFactory() internal virtual override {
        if (
            config.ccaFactory != address(0) &&
            config.lbpStrategyFactory != address(0)
        ) {
            factory.setCcaFactory(config.ccaFactory);
            factory.setLbpStrategyFactory(config.lbpStrategyFactory);
            factory.setPositionManager(config.uniswapV4PositionManager);
            factory.setProtocolFeeRecipient(protocolFeeRecipient);
            auctioneer = LiquidAuctioneer(
                payable(
                    DeployLiquidAuctioneer.deploy(
                        admin,
                        protocolFeeRecipient,
                        deployConfig.fees,
                        config.uniswapUniversalRouter,
                        address(burner),
                        config.rareToken,
                        config.weth,
                        true
                    )
                )
            );
        }
    }

    function setUp() public virtual override {
        super.setUp();
        forkUrlForFFI = _getForkUrl();

        vm.startPrank(tokenCreator);
        uint256 minRare = factory.minRareLiquidityWei();
        IERC20(config.rareToken).approve(address(factory), minRare);
        address tokenAddr = factory.createLiquidToken(
            tokenCreator,
            "ipfs://anvil-fork-test",
            "Anvil Fork Test Token",
            "AFT",
            minRare
        );
        liquidToken = LiquidInstant(payable(tokenAddr));
        vm.stopPrank();

        vm.prank(admin);
        router.registerToken(tokenAddr, tokenCreator);

        vm.deal(buyer, 10 ether);
    }

    // ============================================
    // ROUTE ENCODING HELPERS
    // ============================================

    function _fmt(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e18;
        uint256 frac = (amount % 1e18) / 1e15;

        if (frac == 0) {
            return vm.toString(whole);
        }

        string memory fracStr = vm.toString(frac);
        if (frac < 10) {
            fracStr = string.concat("00", fracStr);
        } else if (frac < 100) {
            fracStr = string.concat("0", fracStr);
        }

        return string.concat(vm.toString(whole), ".", fracStr);
    }

    function _fmtPct(
        uint256 part,
        uint256 total
    ) internal pure returns (string memory) {
        if (total == 0) return "0%";
        uint256 pctBps = (part * 10000) / total;
        uint256 whole = pctBps / 100;
        uint256 frac = pctBps % 100;
        string memory fracStr = frac < 10
            ? string.concat("0", vm.toString(frac))
            : vm.toString(frac);
        return string.concat(vm.toString(whole), ".", fracStr, "%");
    }

    function _fmtPrice(uint256 priceWei) internal pure returns (string memory) {
        if (priceWei == 0) return "0";

        uint256 whole = priceWei / 1e18;
        if (whole > 0) {
            return _fmt(priceWei);
        }

        uint256 frac9 = (priceWei % 1e18) / 1e9;

        if (frac9 == 0) return "0";

        string memory fracStr = vm.toString(frac9);
        if (frac9 < 10) {
            fracStr = string.concat("00000000", fracStr);
        } else if (frac9 < 100) {
            fracStr = string.concat("0000000", fracStr);
        } else if (frac9 < 1000) {
            fracStr = string.concat("000000", fracStr);
        } else if (frac9 < 10000) {
            fracStr = string.concat("00000", fracStr);
        } else if (frac9 < 100000) {
            fracStr = string.concat("0000", fracStr);
        } else if (frac9 < 1000000) {
            fracStr = string.concat("000", fracStr);
        } else if (frac9 < 10000000) {
            fracStr = string.concat("00", fracStr);
        } else if (frac9 < 100000000) {
            fracStr = string.concat("0", fracStr);
        }

        return string.concat("0.", fracStr);
    }

    function _ethForSwap(uint256 ethAmount) internal view returns (uint256) {
        return (ethAmount * (10000 - router.TOTAL_FEE_BPS())) / 10000;
    }

    function _doBuy(
        address asUser,
        address token,
        address recipient,
        uint256 ethAmount,
        address referrer
    ) internal returns (uint256 tokensReceived) {
        uint256 ethForSwap = _ethForSwap(ethAmount);
        (bytes memory commands, bytes[] memory inputs) = _encodeBuyRoute(
            token,
            ethForSwap,
            1
        );
        vm.prank(asUser);
        return
            router.buy{value: ethAmount}(
                token,
                recipient,
                referrer,
                1,
                commands,
                inputs,
                block.timestamp + 1 hours
            );
    }

    function _doSell(
        address asUser,
        address token,
        uint256 tokenAmount,
        address recipient,
        address referrer
    ) internal returns (uint256 ethReceived) {
        vm.startPrank(asUser);
        IERC20(token).approve(address(router), tokenAmount);
        (bytes memory commands, bytes[] memory inputs) = _encodeSellRoute(
            token,
            tokenAmount,
            1
        );
        ethReceived = router.sell(
            token,
            tokenAmount,
            recipient,
            referrer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
        return ethReceived;
    }

    function _encodeBuyRouteWithHooks(
        address liquidTokenAddress,
        address poolHooks,
        uint256 ethForSwap,
        uint256 minTokensOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        address currencyIn = address(0);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: config.rareToken,
            fee: ETH_RARE_POOL_FEE,
            tickSpacing: ETH_RARE_POOL_TICK_SPACING,
            hooks: address(0),
            hookData: bytes("")
        });
        path[1] = PathKey({
            intermediateCurrency: liquidTokenAddress,
            fee: 0,
            tickSpacing: 60,
            hooks: poolHooks,
            hookData: bytes("")
        });

        bytes memory actions = abi.encodePacked(
            uint8(SWAP_EXACT_IN),
            uint8(SETTLE_ALL),
            uint8(TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            currencyIn,
            path,
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: ethForSwap from calc fits uint128
            uint128(ethForSwap),
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: minTokensOut fits uint128
            uint128(minTokensOut)
        );
        params[1] = abi.encode(currencyIn, type(uint128).max);
        // forge-lint: disable-next-line(unsafe-typecast) -- safe: minTokensOut fits uint128
        params[2] = abi.encode(liquidTokenAddress, uint128(minTokensOut));

        bytes memory v4SwapInput = abi.encode(actions, params);

        commands = abi.encodePacked(V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = v4SwapInput;
    }

    function _encodeBuyRoute(
        address liquidTokenAddress,
        uint256 ethForSwap,
        uint256 minTokensOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        return
            _encodeBuyRouteWithHooks(
                liquidTokenAddress,
                address(0),
                ethForSwap,
                minTokensOut
            );
    }

    function _encodeSellRouteWithHooks(
        address liquidTokenAddress,
        address poolHooks,
        uint256 tokenAmount,
        uint256 minEthOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        address outputCurrency = address(0);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: config.rareToken,
            fee: 0,
            tickSpacing: 60,
            hooks: poolHooks,
            hookData: bytes("")
        });
        path[1] = PathKey({
            intermediateCurrency: outputCurrency,
            fee: ETH_RARE_POOL_FEE,
            tickSpacing: ETH_RARE_POOL_TICK_SPACING,
            hooks: address(0),
            hookData: bytes("")
        });

        bytes memory actions = abi.encodePacked(
            uint8(SWAP_EXACT_IN),
            uint8(SETTLE_ALL),
            uint8(TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        bytes memory structData = abi.encode(
            liquidTokenAddress,
            path,
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: tokenAmount fits uint128
            uint128(tokenAmount),
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: minEthOut fits uint128
            uint128(minEthOut)
        );
        params[0] = abi.encodePacked(uint256(0x20), structData);
        params[1] = abi.encode(liquidTokenAddress, type(uint128).max);
        // forge-lint: disable-next-line(unsafe-typecast) -- safe: minEthOut fits uint128
        params[2] = abi.encode(outputCurrency, uint128(minEthOut));

        bytes memory v4SwapInput = abi.encode(actions, params);

        commands = abi.encodePacked(V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = v4SwapInput;
    }

    function _encodeSellRoute(
        address liquidTokenAddress,
        uint256 tokenAmount,
        uint256 minEthOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        return
            _encodeSellRouteWithHooks(
                liquidTokenAddress,
                address(0),
                tokenAmount,
                minEthOut
            );
    }

    /// @notice Encode V3-only buy route: WRAP_ETH + V3_SWAP_EXACT_IN
    /// @dev Used for buying RARE (base token) directly via V3 WETH/RARE pool.
    ///      Validates that V3 routing works through LiquidRouter.
    function _encodeBuyRouteV3Only(
        address outputToken,
        uint256 ethForSwap,
        uint256 minTokensOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        bytes memory wrapInput = abi.encode(
            ROUTER_ADDRESS,
            ethForSwap
        );

        // V3 path: WETH -> outputToken (0.3% fee = 3000)
        bytes memory v3Path = abi.encodePacked(
            config.weth,
            uint24(3000),
            outputToken
        );

        bytes memory v3SwapInput = abi.encode(
            MSG_SENDER, // Send to LiquidRouter (msg.sender of execute)
            ethForSwap,
            minTokensOut,
            v3Path,
            false // payerIsUser = false (Universal Router has WETH)
        );

        commands = abi.encodePacked(WRAP_ETH, V3_SWAP_EXACT_IN);
        inputs = new bytes[](2);
        inputs[0] = wrapInput;
        inputs[1] = v3SwapInput;
    }

    function _encodeBuyRouteForSwapLeg2(
        address liquidTokenAddress,
        uint256 minTokensOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        address currencyIn = address(0);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: config.rareToken,
            fee: ETH_RARE_POOL_FEE,
            tickSpacing: ETH_RARE_POOL_TICK_SPACING,
            hooks: address(0),
            hookData: bytes("")
        });
        path[1] = PathKey({
            intermediateCurrency: liquidTokenAddress,
            fee: 0,
            tickSpacing: 60,
            hooks: address(0),
            hookData: bytes("")
        });

        bytes memory actions = abi.encodePacked(
            uint8(SWAP_EXACT_IN),
            uint8(SETTLE_ALL),
            uint8(TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        uint128 amountIn = uint128(5e15);
        params[0] = abi.encode(
            currencyIn,
            path,
            amountIn,
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: minTokensOut fits uint128
            uint128(minTokensOut)
        );
        params[1] = abi.encode(currencyIn, type(uint128).max);
        // forge-lint: disable-next-line(unsafe-typecast) -- safe: minTokensOut fits uint128
        params[2] = abi.encode(liquidTokenAddress, uint128(minTokensOut));

        bytes memory v4SwapInput = abi.encode(actions, params);

        commands = abi.encodePacked(V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = v4SwapInput;
    }
}
