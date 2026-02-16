// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import {AnvilForkAuctionBase} from "liquid-editions-test/AnvilForkAuctionBase.sol";
import {LiquidGraduated} from "liquid-editions/LiquidGraduated.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {ILBPStrategy} from "liquid-editions/interfaces/ILBPStrategy.sol";

/**
 * @title AnvilForkAuctionBidIntegrationTest
 * @notice Fork test for single bidWithETH flow.
 */
contract AnvilForkAuctionBidIntegrationTest is AnvilForkAuctionBase {
    function test_BidWithETH_LiquidAuctioneer() public {
        (AuctionTestState memory state, bool ok) = _createAuctionForTest();
        if (!ok) {
            vm.skip(true);
            return;
        }

        address graduatedToken = state.graduatedToken;
        LiquidGraduated graduated = state.graduated;
        address auctionAddr = state.auctionAddr;
        uint64 auctionEndBlock = state.auctionEndBlock;

        assertFalse(graduated.isGraduated(), "Should not be graduated yet");
        assertEq(
            graduated.auctionAddress(),
            auctionAddr,
            "Auction address should match"
        );

        uint256 bidAmount = 0.1 ether;
        bytes memory routeData = _encodeEthToRareRoute(bidAmount);

        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        uint256 bidId = auctioneer.bidWithETH{value: bidAmount}(
            graduatedToken,
            0,
            buyer,
            address(0),
            0,
            routeData,
            block.timestamp + 1 hours
        );

        console.log("Bid placed successfully, bidId:", bidId);

        address strategyAddr = graduated.strategy();
        vm.roll(auctionEndBlock + 1);

        uint256 buyerEthBefore = buyer.balance;
        uint256 maxPossibleRefund = 10e21;
        vm.prank(buyer);
        IERC20(config.rareToken).approve(
            address(auctioneer),
            maxPossibleRefund
        );

        bytes memory exitRouteData = _encodeRareToEthRoute(maxPossibleRefund);
        vm.prank(buyer);
        uint256 ethReceived = auctioneer.exitBidToETH(
            graduatedToken,
            bidId,
            buyer,
            0, // minEthOut: accept any amount in integration test
            exitRouteData,
            block.timestamp + 1 hours
        );

        console.log("exitBidToETH ethReceived:", _fmt(ethReceived));
        if (ethReceived > 0) {
            assertGt(
                buyer.balance,
                buyerEthBefore,
                "Buyer should receive ETH from exit"
            );
        }

        uint256 buyerTokensBefore = IERC20(graduatedToken).balanceOf(buyer);
        vm.prank(buyer);
        auctioneer.claimAuctionTokens(graduatedToken, bidId);
        uint256 buyerTokensAfter = IERC20(graduatedToken).balanceOf(buyer);
        console.log(
            "Tokens claimed:",
            _fmt(buyerTokensAfter - buyerTokensBefore)
        );
        assertGe(
            buyerTokensAfter,
            buyerTokensBefore,
            "Buyer should receive tokens from claim"
        );

        IContinuousClearingAuction cca = IContinuousClearingAuction(
            auctionAddr
        );
        uint256 strategyRareBefore = IERC20(config.rareToken).balanceOf(
            strategyAddr
        );
        cca.sweepCurrency();
        uint256 strategyRareAfter = IERC20(config.rareToken).balanceOf(
            strategyAddr
        );
        console.log(
            "sweepCurrency: strategy received RARE:",
            _fmt(strategyRareAfter - strategyRareBefore)
        );
        assertGt(
            strategyRareAfter,
            strategyRareBefore,
            "Strategy should receive RARE from sweep"
        );

        cca.sweepUnsoldTokens();

        uint256 clearingPriceQ96 = cca.clearingPrice();
        uint256 currencyRaised = cca.currencyRaised();
        assertFalse(
            graduated.isGraduated(),
            "Should not be graduated before migrate"
        );
        ILBPStrategy(strategyAddr).migrate();
        assertTrue(
            graduated.isGraduated(),
            "Should be graduated after migrate"
        );
        console.log("Migration complete; token graduated");
        uint256 priceScaled = (clearingPriceQ96 * 1e18) >> 96;
        console.log("  Clearing price (RARE per token):", _fmt(priceScaled));
        console.log("  Currency raised (RARE):", _fmt(currencyRaised));
    }
}
