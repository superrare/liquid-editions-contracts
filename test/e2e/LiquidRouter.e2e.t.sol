// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import {AnvilForkTestBase} from "liquid-editions-test/AnvilForkTestBase.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/**
 * @title AnvilForkIntegrationTest
 * @notice Comprehensive fork test: deploy full Liquid system on mainnet fork and test all hot paths
 * @dev Uses NetworkConfig for all addresses. Run with: forge test --match-contract AnvilForkIntegrationTest -vvv --fork-url $ETH_MAINNET
 */
contract AnvilForkIntegrationTest is AnvilForkTestBase {
    using StateLibrary for IPoolManager;

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
