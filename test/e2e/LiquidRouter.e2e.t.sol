// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import {AnvilForkTestBase} from "liquid-editions-test/AnvilForkTestBase.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {DeployRAREBurner} from "script/deployers/DeployRAREBurner.s.sol";
import {DeployLiquidRouter} from "script/deployers/DeployLiquidRouter.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/**
 * @title AnvilForkIntegrationTest
 * @notice Comprehensive fork test: deploy full Liquid system on mainnet fork and test all hot paths
 * @dev Uses NetworkConfig for all addresses. Run with: forge test --match-contract AnvilForkIntegrationTest -vvv --fork-url $ETH_MAINNET
 */
contract AnvilForkIntegrationTest is AnvilForkTestBase {
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
        assertTrue(liquidToken.lpLiquidity() > 0, "Pool has liquidity");
        assertEq(factory.baseToken(), config.rareToken, "Base token set");
    }

    /// @notice Buy RARE (base token) via V3 routing: WRAP_ETH + V3_SWAP_EXACT_IN
    /// @dev Validates that V3 WETH/RARE routing works through LiquidRouter on mainnet fork.
    ///      Requires a V3 WETH/RARE pool at 0.3% fee tier on Ethereum mainnet.
    function test_Buy_RARE_ViaRouter_V3Routing() public {
        vm.prank(admin);
        router.registerToken(config.rareToken, tokenCreator);

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
            address(0),
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
            ethAmount,
            address(0)
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
        _doBuy(buyer, address(liquidToken), buyer, 0.01 ether, address(0));

        uint256 tokensToSell = liquidToken.balanceOf(buyer) / 2;
        require(tokensToSell > 0, "No tokens to sell");

        uint256 ethBefore = buyer.balance;
        uint256 ethReceived = _doSell(
            buyer,
            address(liquidToken),
            tokensToSell,
            buyer,
            address(0)
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
            0.005 ether,
            address(0)
        );
        _doSell(buyer, address(liquidToken), tokensBought, buyer, address(0));

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
            address(0),
            unreasonableMinOut,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    /// @notice Sell reverts when minEthOut is unreasonably high (slippage protection)
    /// @dev Revert comes from Universal Router / V4 swap layer (amountOutMinimum), not LiquidRouter
    function test_Sell_RevertsOnSlippage() public {
        _doBuy(buyer, address(liquidToken), buyer, 0.01 ether, address(0));
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
            address(0),
            unreasonableMinEthOut,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function test_Buy_WithReferrer_ReceivesFee() public {
        // Deploy a second router with referrerFeeBPS > 0 (DeployConfig uses 0)
        DeployConfig.FeeConfig memory referrerRouterConfig = DeployConfig
            .FeeConfig({
                rareBurnFeeBPS: 0,
                protocolFeeBPS: 9500,
                referrerFeeBPS: 500
            });
        (address referrerRouterAddr, ) = DeployLiquidRouter.deploy(
            admin,
            protocolFeeRecipient,
            referrerRouterConfig,
            config,
            address(burner)
        );
        LiquidRouter referrerRouter = LiquidRouter(payable(referrerRouterAddr));
        // admin is already owner (passed to deploy)

        vm.prank(admin);
        referrerRouter.registerToken(address(liquidToken), tokenCreator);

        address referrer = makeAddr("referrer");
        uint256 ethAmount = 0.01 ether;
        uint256 ethForSwap = (ethAmount *
            (10000 - referrerRouter.TOTAL_FEE_BPS())) / 10000;
        (bytes memory commands, bytes[] memory inputs) = _encodeBuyRoute(
            address(liquidToken),
            ethForSwap,
            1
        );

        uint256 referrerEthBefore = referrer.balance;

        vm.prank(buyer);
        referrerRouter.buy{value: ethAmount}(
            address(liquidToken),
            buyer,
            referrer,
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        uint256 referrerEthAfter = referrer.balance;
        assertGt(
            referrerEthAfter,
            referrerEthBefore,
            "Referrer should receive fee"
        );
    }

    function test_Burn_LiquidToken() public {
        _doBuy(buyer, address(liquidToken), buyer, 0.01 ether, address(0));

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
            0.01 ether,
            address(0)
        );
        assertGt(amountOut, 0, "Should receive tokens");
    }

    /// @notice Token -> ETH via router (same as sell; swap not in current LiquidRouter)
    function test_Swap_TokenToETH_ViaRouter() public {
        _doBuy(buyer, address(liquidToken), buyer, 0.01 ether, address(0));
        uint256 tokensToSell = liquidToken.balanceOf(buyer) / 2;
        require(tokensToSell > 0, "No tokens to sell");
        uint256 ethBefore = buyer.balance;
        uint256 amountOut = _doSell(
            buyer,
            address(liquidToken),
            tokensToSell,
            buyer,
            address(0)
        );
        assertGt(amountOut, 0, "Should receive ETH");
        assertGt(buyer.balance, ethBefore, "ETH balance should increase");
    }

    function test_RAREBurner_ReceivesAndFlushes() public {
        // Deploy a burner with tryOnDeposit: false so ETH stays in pending (main burner may flush on deposit)
        DeployConfig.BurnerConfig memory burnerCfg = deployConfig.burner;
        burnerCfg.tryOnDeposit = false;
        RAREBurner testBurner = RAREBurner(
            payable(DeployRAREBurner.deploy(admin, burnerCfg, config))
        );

        // Deploy router with rareBurnFeeBPS > 0 (DeployConfig uses 0)
        DeployConfig.FeeConfig memory burnRouterConfig = DeployConfig
            .FeeConfig({
                rareBurnFeeBPS: 500,
                protocolFeeBPS: 9500,
                referrerFeeBPS: 0
            });
        (address burnRouterAddr, ) = DeployLiquidRouter.deploy(
            admin,
            protocolFeeRecipient,
            burnRouterConfig,
            config,
            address(testBurner)
        );
        LiquidRouter burnRouter = LiquidRouter(payable(burnRouterAddr));
        // admin is already owner (passed to deploy)

        vm.prank(admin);
        burnRouter.registerToken(address(liquidToken), tokenCreator);

        uint256 pendingBefore = testBurner.pendingEth();

        uint256 ethAmount = 0.01 ether;
        uint256 ethForSwap = (ethAmount *
            (10000 - burnRouter.TOTAL_FEE_BPS())) / 10000;
        (bytes memory commands, bytes[] memory inputs) = _encodeBuyRoute(
            address(liquidToken),
            ethForSwap,
            1
        );

        vm.prank(buyer);
        burnRouter.buy{value: ethAmount}(
            address(liquidToken),
            buyer,
            address(0),
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        uint256 pendingAfter = testBurner.pendingEth();
        assertGt(
            pendingAfter,
            pendingBefore,
            "RAREBurner should receive ETH from buy fee"
        );

        // Optionally flush - best-effort, may succeed or fail depending on pool state
        testBurner.flush();
    }

    // ---------- Factory: createLiquidToken (standalone flow) ----------
    /// @notice Liquid -> Liquid via sell then buy (router has no swap; two-leg flow)
    function test_Swap_LiquidToLiquid_ViaRouter() public {
        // Create second Liquid token
        vm.startPrank(tokenCreator);
        uint256 minRare = factory.minRareLiquidityWei();
        IERC20(config.rareToken).approve(address(factory), minRare);
        address token2Addr = factory.createLiquidToken(
            tokenCreator,
            "ipfs://anvil-fork-test-2",
            "Anvil Fork Test Token 2",
            "AFT2",
            minRare
        );
        liquidToken2 = LiquidInstant(payable(token2Addr));
        vm.stopPrank();

        vm.prank(admin);
        router.registerToken(token2Addr, tokenCreator);

        // Buy liquidToken with ETH
        _doBuy(buyer, address(liquidToken), buyer, 0.01 ether, address(0));

        uint256 tokensToSwap = liquidToken.balanceOf(buyer) / 2;
        require(tokensToSwap > 0, "No tokens to swap");

        // Sell token1 -> ETH, then buy token2 with ETH (replaces router.swap)
        uint256 ethReceived = _doSell(
            buyer,
            address(liquidToken),
            tokensToSwap,
            buyer,
            address(0)
        );
        assertGt(ethReceived, 0, "Should receive ETH from sell");

        uint256 balanceBefore = liquidToken2.balanceOf(buyer);
        uint256 amountOut = _doBuy(
            buyer,
            address(liquidToken2),
            buyer,
            ethReceived,
            address(0)
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
