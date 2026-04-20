// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import {AnvilForkTestBase} from "liquid-editions-test/AnvilForkTestBase.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IV4Router} from "v4-periphery/interfaces/IV4Router.sol";
import {ActionConstants} from "v4-periphery/libraries/ActionConstants.sol";

/**
 * @title AnvilForkIntegrationTest
 * @notice Comprehensive fork test: deploy full Liquid system on mainnet fork and test all hot paths
 * @dev Uses NetworkConfig for all addresses. Run with: forge test --match-contract AnvilForkIntegrationTest -vvv --fork-url $ETH_MAINNET
 */
contract AnvilForkIntegrationTest is AnvilForkTestBase {
    using StateLibrary for IPoolManager;

    function _assertNoNativeEthRetention(
        uint256 routerEthBefore,
        uint256 universalRouterEthBefore
    ) internal view {
        assertEq(
            address(router).balance,
            routerEthBefore,
            "LiquidRouter should not retain native ETH"
        );
        assertEq(
            router.universalRouter().balance,
            universalRouterEthBefore,
            "Universal Router should not retain additional native ETH"
        );
    }

    function _assertNoWethRetention(
        uint256 routerWethBefore,
        uint256 universalRouterWethBefore
    ) internal view {
        assertEq(
            IERC20(config.weth).balanceOf(address(router)),
            routerWethBefore,
            "LiquidRouter should not retain WETH"
        );
        assertEq(
            IERC20(config.weth).balanceOf(router.universalRouter()),
            universalRouterWethBefore,
            "Universal Router should not retain additional WETH"
        );
    }

    function _createWethBaseLiquidToken() internal returns (LiquidMultiCurve wethBaseToken) {
        vm.prank(admin);
        factory.setBaseToken(config.weth);

        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({
            tickLower: factory.lpTickLower(),
            tickUpper: factory.lpTickUpper(),
            numPositions: 1,
            shares: 1e18
        });

        vm.prank(tokenCreator);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://anvil-fork-weth-base",
            "Anvil Fork WETH Base Token",
            "AFWETH",
            0,
            curves
        );

        wethBaseToken = LiquidMultiCurve(payable(tokenAddr));
    }

    function _encodeBuyRouteWethBase(
        address liquidTokenAddress,
        uint256 ethForSwap,
        uint256 minTokensOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        Currency wethCurrency = Currency.wrap(config.weth);
        Currency liquidCurrency = Currency.wrap(liquidTokenAddress);
        bool wethIsCurrency0 = config.weth < liquidTokenAddress;

        PoolKey memory poolKey = PoolKey({
            currency0: wethIsCurrency0 ? wethCurrency : liquidCurrency,
            currency1: wethIsCurrency0 ? liquidCurrency : wethCurrency,
            fee: 0,
            tickSpacing: factory.poolTickSpacing(),
            hooks: IHooks(factory.poolHooks())
        });

        IV4Router.ExactInputSingleParams memory swapParams = IV4Router
            .ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: wethIsCurrency0,
                amountIn: ActionConstants.OPEN_DELTA,
                amountOutMinimum: uint128(minTokensOut),
                hookData: bytes("")
            });

        bytes memory actions = abi.encodePacked(uint8(0x0b), uint8(0x06), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(config.weth, ActionConstants.CONTRACT_BALANCE, false);
        params[1] = abi.encode(swapParams);
        params[2] = abi.encode(liquidTokenAddress, uint128(minTokensOut));

        commands = abi.encodePacked(WRAP_ETH, V4_SWAP);
        inputs = new bytes[](2);
        inputs[0] = abi.encode(ROUTER_ADDRESS, ethForSwap);
        inputs[1] = abi.encode(actions, params);
    }

    function _encodeSellRouteWethBaseViaEthRare(
        address liquidTokenAddress,
        uint256 tokenAmount,
        uint256 minRareOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        Currency wethCurrency = Currency.wrap(config.weth);
        Currency liquidCurrency = Currency.wrap(liquidTokenAddress);
        bool liquidIsCurrency0 = liquidTokenAddress < config.weth;

        PoolKey memory liquidPoolKey = PoolKey({
            currency0: liquidIsCurrency0 ? liquidCurrency : wethCurrency,
            currency1: liquidIsCurrency0 ? wethCurrency : liquidCurrency,
            fee: 0,
            tickSpacing: factory.poolTickSpacing(),
            hooks: IHooks(factory.poolHooks())
        });

        IV4Router.ExactInputSingleParams memory sellParams = IV4Router
            .ExactInputSingleParams({
                poolKey: liquidPoolKey,
                zeroForOne: liquidIsCurrency0,
                amountIn: uint128(tokenAmount),
                amountOutMinimum: 1,
                hookData: bytes("")
            });

        bytes memory actions0 = abi.encodePacked(
            uint8(0x06),
            uint8(0x0c),
            uint8(0x0e)
        );
        bytes[] memory params0 = new bytes[](3);
        params0[0] = abi.encode(sellParams);
        params0[1] = abi.encode(liquidTokenAddress, type(uint128).max);
        params0[2] = abi.encode(config.weth, ROUTER_ADDRESS, uint256(0));

        PoolKey memory rarePoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(config.rareToken),
            fee: ETH_RARE_POOL_FEE,
            tickSpacing: ETH_RARE_POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });

        IV4Router.ExactInputSingleParams memory rareBuyParams = IV4Router
            .ExactInputSingleParams({
                poolKey: rarePoolKey,
                zeroForOne: true,
                amountIn: ActionConstants.OPEN_DELTA,
                amountOutMinimum: uint128(minRareOut),
                hookData: bytes("")
            });

        bytes memory actions2 = abi.encodePacked(
            uint8(0x0b),
            uint8(0x06),
            uint8(0x0f)
        );
        bytes[] memory params2 = new bytes[](3);
        params2[0] = abi.encode(
            address(0),
            ActionConstants.CONTRACT_BALANCE,
            false
        );
        params2[1] = abi.encode(rareBuyParams);
        params2[2] = abi.encode(config.rareToken, uint128(minRareOut));

        commands = abi.encodePacked(V4_SWAP, UNWRAP_WETH, V4_SWAP);
        inputs = new bytes[](3);
        inputs[0] = abi.encode(actions0, params0);
        inputs[1] = abi.encode(ROUTER_ADDRESS, uint256(1));
        inputs[2] = abi.encode(actions2, params2);
    }

    // ============================================
    // TESTS
    // ============================================

    // ---------- Deployment / smoke ----------
    function test_Deployment() public view {
        assertTrue(address(factory) != address(0), "Factory deployed");
        assertTrue(address(router) != address(0), "Router deployed");
        assertTrue(address(liquidToken) != address(0), "Liquid token created");
        assertTrue(
            PoolId.unwrap(liquidToken.poolId()) != bytes32(0),
            "Pool created"
        );
        assertTrue(liquidToken.storedPositionsLength() > 0, "Pool has liquidity positions");
        assertEq(factory.baseToken(), config.rareToken, "Base token set");
    }

    /// @notice Buy RARE (base token) via V3 routing: WRAP_ETH + V3_SWAP_EXACT_IN
    /// @dev Validates that V3 WETH/RARE routing works through LiquidRouter on mainnet fork.
    ///      Requires a V3 WETH/RARE pool at 0.3% fee tier on Ethereum mainnet.
    function test_Buy_RARE_ViaRouter_V3Routing() public {
        vm.prank(admin);
        router.addCurrency(config.rareToken);

        uint256 ethAmount = 0.01 ether;
        uint256 ethForSwap = _ethForSwap(ethAmount);
        uint256 rareBefore = IERC20(config.rareToken).balanceOf(buyer);

        (bytes memory commands, bytes[] memory inputs) = _encodeBuyRouteV3Only(
            config.rareToken,
            ethForSwap,
            1
        );

        vm.prank(buyer);
        uint256 tokensReceived = router.buy{value: ethAmount}(
            config.rareToken,
            buyer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        uint256 rareAfter = IERC20(config.rareToken).balanceOf(buyer);

        assertGt(tokensReceived, 0, "Should receive RARE");
        assertEq(
            rareAfter - rareBefore,
            tokensReceived,
            "Balance should match"
        );

        console.log("V3 routing buy successful:");
        console.log("  ETH spent:", _fmt(ethAmount));
        console.log("  RARE received:", _fmt(tokensReceived));
    }

    function test_Buy_RARE_ViaRouter_V3Routing_DoesNotRetainNativeETH() public {
        vm.prank(admin);
        router.addCurrency(config.rareToken);

        uint256 ethAmount = 0.01 ether;
        uint256 ethForSwap = _ethForSwap(ethAmount);
        uint256 rareBefore = IERC20(config.rareToken).balanceOf(buyer);
        uint256 routerEthBefore = address(router).balance;
        uint256 universalRouterEthBefore = router.universalRouter().balance;

        (bytes memory commands, bytes[] memory inputs) = _encodeBuyRouteV3Only(
            config.rareToken,
            ethForSwap,
            1
        );

        vm.prank(buyer);
        uint256 tokensReceived = router.buy{value: ethAmount}(
            config.rareToken,
            buyer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        uint256 rareAfter = IERC20(config.rareToken).balanceOf(buyer);

        assertGt(tokensReceived, 0, "Should receive RARE");
        assertEq(
            rareAfter - rareBefore,
            tokensReceived,
            "Balance should match"
        );
        _assertNoNativeEthRetention(routerEthBefore, universalRouterEthBefore);
    }

    function test_Buy_LiquidToken_ViaRouter() public {
        uint256 ethAmount = 0.01 ether;
        uint256 balanceBefore = liquidToken.balanceOf(buyer);

        uint256 tokensReceived = _doBuy(
            buyer,
            address(liquidToken),
            buyer,
            ethAmount
        );

        uint256 balanceAfter = liquidToken.balanceOf(buyer);

        assertGt(tokensReceived, 0, "Should receive tokens");
        assertEq(
            balanceAfter - balanceBefore,
            tokensReceived,
            "Balance should match"
        );

        console.log("Buy successful:");
        console.log("  ETH spent:", _fmt(ethAmount));
        console.log("  Tokens received:", _fmt(tokensReceived));
    }

    function test_Buy_LiquidToken_ViaRouter_DoesNotRetainNativeETH() public {
        uint256 ethAmount = 0.01 ether;
        uint256 balanceBefore = liquidToken.balanceOf(buyer);
        uint256 routerEthBefore = address(router).balance;
        uint256 universalRouterEthBefore = router.universalRouter().balance;

        uint256 tokensReceived = _doBuy(
            buyer,
            address(liquidToken),
            buyer,
            ethAmount
        );

        uint256 balanceAfter = liquidToken.balanceOf(buyer);

        assertGt(tokensReceived, 0, "Should receive tokens");
        assertEq(
            balanceAfter - balanceBefore,
            tokensReceived,
            "Balance should match"
        );
        _assertNoNativeEthRetention(routerEthBefore, universalRouterEthBefore);
    }

    function test_Buy_WethBaseLiquidToken_ViaRouter_DoesNotRetainEthOrWeth() public {
        LiquidMultiCurve wethBaseToken = _createWethBaseLiquidToken();

        uint256 ethAmount = 0.01 ether;
        uint256 tokenBalanceBefore = wethBaseToken.balanceOf(buyer);
        uint256 routerEthBefore = address(router).balance;
        uint256 universalRouterEthBefore = router.universalRouter().balance;
        uint256 routerWethBefore = IERC20(config.weth).balanceOf(address(router));
        uint256 universalRouterWethBefore = IERC20(config.weth).balanceOf(router.universalRouter());

        (bytes memory commands, bytes[] memory inputs) = _encodeBuyRouteWethBase(
            address(wethBaseToken),
            ethAmount,
            1
        );

        vm.prank(buyer);
        uint256 tokensReceived = router.buy{value: ethAmount}(
            address(wethBaseToken),
            buyer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        uint256 tokenBalanceAfter = wethBaseToken.balanceOf(buyer);

        assertEq(wethBaseToken.baseToken(), config.weth, "Base token should be WETH");
        assertGt(tokensReceived, 0, "Should receive WETH-base LIQUID");
        assertEq(
            tokenBalanceAfter - tokenBalanceBefore,
            tokensReceived,
            "Balance should match"
        );
        _assertNoNativeEthRetention(routerEthBefore, universalRouterEthBefore);
        _assertNoWethRetention(routerWethBefore, universalRouterWethBefore);
    }

    function test_Swap_WethBaseLiquidToken_ViaUnwrapToRouterIntoRare_DoesNotRetainEthOrWeth()
        public
    {
        vm.prank(admin);
        router.addCurrency(config.rareToken);

        LiquidMultiCurve wethBaseToken = _createWethBaseLiquidToken();

        (bytes memory buyCommands, bytes[] memory buyInputs) = _encodeBuyRouteWethBase(
            address(wethBaseToken),
            0.05 ether,
            1
        );

        vm.prank(buyer);
        uint256 tokensBought = router.buy{value: 0.05 ether}(
            address(wethBaseToken),
            buyer,
            1,
            buyCommands,
            buyInputs,
            block.timestamp + 1 hours
        );

        uint256 tokenAmount = tokensBought / 2;
        uint256 rareBefore = IERC20(config.rareToken).balanceOf(buyer);
        uint256 routerEthBefore = address(router).balance;
        uint256 universalRouterEthBefore = router.universalRouter().balance;
        uint256 routerWethBefore = IERC20(config.weth).balanceOf(address(router));
        uint256 universalRouterWethBefore = IERC20(config.weth).balanceOf(router.universalRouter());

        (bytes memory commands, bytes[] memory inputs) = _encodeSellRouteWethBaseViaEthRare(
            address(wethBaseToken),
            tokenAmount,
            1
        );

        vm.startPrank(buyer);
        IERC20(address(wethBaseToken)).approve(address(router), tokenAmount);
        uint256 rareReceived = router.swap(
            address(wethBaseToken),
            tokenAmount,
            config.rareToken,
            buyer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        uint256 rareAfter = IERC20(config.rareToken).balanceOf(buyer);

        assertGt(rareReceived, 0, "Should receive RARE");
        assertEq(rareAfter - rareBefore, rareReceived, "RARE balance should match");
        _assertNoNativeEthRetention(routerEthBefore, universalRouterEthBefore);
        _assertNoWethRetention(routerWethBefore, universalRouterWethBefore);
    }

    // ---------- Router: buy, sell, swap ----------
    function test_Sell_LiquidToken_ViaRouter() public {
        // First buy tokens
        _doBuy(buyer, address(liquidToken), buyer, 0.01 ether);

        uint256 tokensToSell = liquidToken.balanceOf(buyer) / 2;
        require(tokensToSell > 0, "No tokens to sell");

        uint256 ethBefore = buyer.balance;
        uint256 ethReceived = _doSell(
            buyer,
            address(liquidToken),
            tokensToSell,
            buyer
        );
        uint256 ethAfter = buyer.balance;

        assertGt(ethReceived, 0, "Should receive ETH");
        assertEq(
            ethAfter - ethBefore,
            ethReceived,
            "ETH balance should increase"
        );

        console.log("Sell successful:");
        console.log("  Tokens sold:", _fmt(tokensToSell));
        console.log("  ETH received:", _fmt(ethReceived));
    }

    function test_BuySell_RoundTrip() public {
        uint256 tokensBought = _doBuy(
            buyer,
            address(liquidToken),
            buyer,
            0.005 ether
        );
        _doSell(buyer, address(liquidToken), tokensBought, buyer);

        assertEq(
            liquidToken.balanceOf(buyer),
            0,
            "Should have sold all tokens"
        );
        console.log("Round trip complete");
    }

    /// @notice Buy reverts when minTokensOut is unreasonably high (slippage protection)
    /// @dev Revert comes from Universal Router / V4 swap layer (amountOutMinimum), not LiquidRouter
    function test_Buy_RevertsOnSlippage() public {
        uint256 ethAmount = 0.01 ether;
        uint256 ethForSwap = _ethForSwap(ethAmount);
        uint256 unreasonableMinOut = 1_000_000 ether;
        (bytes memory commands, bytes[] memory inputs) = _encodeBuyRoute(
            address(liquidToken),
            ethForSwap,
            unreasonableMinOut
        );

        vm.prank(buyer);
        vm.expectRevert(); // Universal Router reverts on slippage before LiquidRouter check
        router.buy{value: ethAmount}(
            address(liquidToken),
            buyer,
            unreasonableMinOut,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    /// @notice Sell reverts when minEthOut is unreasonably high (slippage protection)
    /// @dev Revert comes from Universal Router / V4 swap layer (amountOutMinimum), not LiquidRouter
    function test_Sell_RevertsOnSlippage() public {
        _doBuy(buyer, address(liquidToken), buyer, 0.01 ether);
        uint256 tokensToSell = liquidToken.balanceOf(buyer) / 2;
        require(tokensToSell > 0, "No tokens to sell");

        uint256 unreasonableMinEthOut = 1000 ether;
        (bytes memory commands, bytes[] memory inputs) = _encodeSellRoute(
            address(liquidToken),
            tokensToSell,
            unreasonableMinEthOut
        );

        vm.prank(buyer);
        IERC20(liquidToken).approve(address(router), tokensToSell);
        vm.prank(buyer);
        vm.expectRevert(); // Universal Router reverts on slippage before LiquidRouter check
        router.sell(
            address(liquidToken),
            tokensToSell,
            buyer,
            unreasonableMinEthOut,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function test_Burn_LiquidToken() public {
        _doBuy(buyer, address(liquidToken), buyer, 0.01 ether);

        uint256 burnAmount = liquidToken.balanceOf(buyer) / 2;
        require(burnAmount > 0, "No tokens to burn");

        uint256 balanceBefore = liquidToken.balanceOf(buyer);
        uint256 supplyBefore = liquidToken.totalSupply();

        vm.prank(buyer);
        liquidToken.burn(burnAmount);

        assertEq(
            liquidToken.balanceOf(buyer),
            balanceBefore - burnAmount,
            "Balance should decrease"
        );
        assertEq(
            liquidToken.totalSupply(),
            supplyBefore - burnAmount,
            "Total supply should decrease"
        );
    }

    /// @notice ETH -> Token via router (same as buy; swap not in current LiquidRouter)
    function test_Swap_ETHToToken_ViaRouter() public {
        uint256 amountOut = _doBuy(
            buyer,
            address(liquidToken),
            buyer,
            0.01 ether
        );
        assertGt(amountOut, 0, "Should receive tokens");
    }

    /// @notice Token -> ETH via router (same as sell; swap not in current LiquidRouter)
    function test_Swap_TokenToETH_ViaRouter() public {
        _doBuy(buyer, address(liquidToken), buyer, 0.01 ether);
        uint256 tokensToSell = liquidToken.balanceOf(buyer) / 2;
        require(tokensToSell > 0, "No tokens to sell");
        uint256 ethBefore = buyer.balance;
        uint256 amountOut = _doSell(
            buyer,
            address(liquidToken),
            tokensToSell,
            buyer
        );
        assertGt(amountOut, 0, "Should receive ETH");
        assertGt(buyer.balance, ethBefore, "ETH balance should increase");
    }

    // ---------- Factory: createLiquidToken (standalone flow) ----------
    /// @notice Liquid -> Liquid via sell then buy (router has no swap; two-leg flow)
    function test_Swap_LiquidToLiquid_ViaRouter() public {
        // Create second Liquid token
        vm.startPrank(tokenCreator);
        uint256 minRare = factory.minRareLiquidityWei();
        IERC20(config.rareToken).approve(address(factory), minRare);
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({
            tickLower: factory.lpTickLower(),
            tickUpper: factory.lpTickUpper(),
            numPositions: 1,
            shares: 1e18
        });
        address token2Addr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://anvil-fork-test-2",
            "Anvil Fork Test Token 2",
            "AFT2",
            minRare,
            curves
        );
        liquidToken2 = LiquidMultiCurve(payable(token2Addr));
        vm.stopPrank();

        // Buy liquidToken with ETH
        _doBuy(buyer, address(liquidToken), buyer, 0.01 ether);

        uint256 tokensToSwap = liquidToken.balanceOf(buyer) / 2;
        require(tokensToSwap > 0, "No tokens to swap");

        // Sell token1 -> ETH, then buy token2 with ETH (replaces router.swap)
        uint256 ethReceived = _doSell(
            buyer,
            address(liquidToken),
            tokensToSwap,
            buyer
        );
        assertGt(ethReceived, 0, "Should receive ETH from sell");

        uint256 balanceBefore = liquidToken2.balanceOf(buyer);
        uint256 amountOut = _doBuy(
            buyer,
            address(liquidToken2),
            buyer,
            ethReceived
        );
        uint256 balanceAfter = liquidToken2.balanceOf(buyer);

        assertGt(amountOut, 0, "Should receive tokens");
        assertEq(
            balanceAfter - balanceBefore,
            amountOut,
            "Balance should match"
        );

        console.log("Swap (sell+buy) successful:");
        console.log("  Tokens sold:", _fmt(tokensToSwap));
        console.log("  Tokens received:", _fmt(amountOut));
    }
}
