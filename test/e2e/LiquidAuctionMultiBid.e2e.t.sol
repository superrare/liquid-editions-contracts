// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import {AnvilForkAuctionBase} from "liquid-editions-test/AnvilForkAuctionBase.sol";
import {LiquidGraduated} from "liquid-editions/LiquidGraduated.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {ILBPStrategy} from "liquid-editions/interfaces/ILBPStrategy.sol";

/**
 * @title AnvilForkAuctionMultiBidIntegrationTest
 * @notice Fork test for multi-bid auction scenarios.
 */
contract AnvilForkAuctionMultiBidIntegrationTest is AnvilForkAuctionBase {
    function test_AuctionBids_MultiBidScenarios() public {
        (AuctionTestState memory state, bool ok) = _createAuctionForTest();
        if (!ok) {
            vm.skip(true);
            return;
        }

        (
            uint256[] memory bidIds,
            address[] memory bidders,
            uint256 totalTokensClaimed
        ) = _runMultiBidFlow(state);

        _assertAndMigrateMultiBid(state, bidIds, bidders, totalTokensClaimed);
    }

    /// @dev Extracted to reduce stack depth in main test
    function _runMultiBidFlow(
        AuctionTestState memory state
    )
        internal
        returns (
            uint256[] memory bidIds,
            address[] memory bidders,
            uint256 totalTokensClaimed
        )
    {
        (
            uint64[] memory blockOffsets,
            uint256[] memory ethAmounts,
            address[] memory b
        ) = _getMultiBidSetup();
        bidders = b;

        bidIds = _placeMultiBids(
            state.graduatedToken,
            state.auctionAddr,
            state.auctionStartBlock,
            state.auctionEndBlock,
            blockOffsets,
            ethAmounts,
            bidders,
            _getMultiBidMaxPrices()
        );

        IContinuousClearingAuction cca = IContinuousClearingAuction(
            state.auctionAddr
        );
        cca.checkpoint();
        uint256 clearingPrice = cca.clearingPrice();

        uint256[] memory tokensClaimedPerBid;
        (totalTokensClaimed, tokensClaimedPerBid) = _exitAndClaimMultiBids(
            state.graduatedToken,
            state.auctionAddr,
            bidIds,
            bidders,
            clearingPrice
        );

        _logMultiBidSummary(
            ethAmounts,
            tokensClaimedPerBid,
            totalTokensClaimed,
            state.graduatedToken,
            state.auctionAddr
        );
    }

    /// @dev Logs per-bid summary and totals. Extracted to reduce stack depth.
    function _logMultiBidSummary(
        uint256[] memory ethAmounts,
        uint256[] memory tokensClaimedPerBid,
        uint256 totalTokensClaimed,
        address graduatedToken,
        address auctionAddr
    ) internal view {
        console.log("Auction bids summary:");
        for (uint256 i = 0; i < 10; i++) {
            uint256 pricePerToken = tokensClaimedPerBid[i] > 0
                ? (ethAmounts[i] * 1e18) / tokensClaimedPerBid[i]
                : 0;
            string memory pctStr = _fmtPct(
                tokensClaimedPerBid[i],
                totalTokensClaimed
            );
            string memory ethStr = _fmt(ethAmounts[i]);
            string memory tokStr = _fmt(tokensClaimedPerBid[i]);
            string memory priceStr = _fmtPrice(pricePerToken);
            console.log(
                "  Bid",
                i,
                string.concat(
                    "ETH:",
                    ethStr,
                    " tokens:",
                    tokStr,
                    " ",
                    pctStr,
                    " price:",
                    priceStr
                )
            );
        }
        uint256 auctionTokenBalance = IERC20(graduatedToken).balanceOf(
            auctionAddr
        );
        console.log("  Total liquid tokens claimed:", _fmt(totalTokensClaimed));
        console.log(
            "  Actual auction token balance:",
            _fmt(auctionTokenBalance)
        );
    }

    /// @dev Extracted to reduce stack depth
    function _getMultiBidSetup()
        internal
        returns (
            uint64[] memory blockOffsets,
            uint256[] memory ethAmounts,
            address[] memory bidders
        )
    {
        address b1 = makeAddr("multiBid1");
        address b2 = makeAddr("multiBid2");
        address b3 = makeAddr("multiBid3");
        address b4 = makeAddr("multiBid4");
        address b5 = makeAddr("multiBid5");
        address b6 = makeAddr("multiBid6");
        address b7 = makeAddr("multiBid7");
        address b8 = makeAddr("multiBid8");
        address b9 = makeAddr("multiBid9");
        vm.deal(b1, 1000 ether);
        vm.deal(b2, 1000 ether);
        vm.deal(b3, 1000 ether);
        vm.deal(b4, 1000 ether);
        vm.deal(b5, 1000 ether);
        vm.deal(b6, 1000 ether);
        vm.deal(b7, 1000 ether);
        vm.deal(b8, 1000 ether);
        vm.deal(b9, 1000 ether);

        blockOffsets = new uint64[](10);
        ethAmounts = new uint256[](10);
        bidders = new address[](10);
        blockOffsets[0] = 0;
        ethAmounts[0] = 0.55 ether;
        bidders[0] = b1;
        blockOffsets[1] = 0;
        ethAmounts[1] = 0.55 ether;
        bidders[1] = b2;
        blockOffsets[2] = 0;
        ethAmounts[2] = 1.40 ether;
        bidders[2] = b3;
        blockOffsets[3] = 5;
        ethAmounts[3] = 0.12 ether;
        bidders[3] = b4;
        blockOffsets[4] = 10;
        ethAmounts[4] = 2.20 ether;
        bidders[4] = b5;
        blockOffsets[5] = 20;
        ethAmounts[5] = 0.80 ether;
        bidders[5] = b6;
        blockOffsets[6] = 30;
        ethAmounts[6] = 0.35 ether;
        bidders[6] = b7;
        blockOffsets[7] = 50;
        ethAmounts[7] = 3.10 ether;
        bidders[7] = b1;
        blockOffsets[8] = 70;
        ethAmounts[8] = 6.5 ether;
        bidders[8] = b8;
        blockOffsets[9] = 99;
        ethAmounts[9] = 1.05 ether;
        bidders[9] = b9;
    }

    /// @dev maxPrice=0 means "accept any price" - auctioneer uses MAX_BID_PRICE so bid passes placement.
    ///      Using 0 for all avoids BidMustBeAboveClearingPrice as clearing price rises with each bid.
    function _getMultiBidMaxPrices() internal pure returns (uint256[] memory) {
        uint256[] memory maxPrices = new uint256[](10);
        return maxPrices;
    }

    /// @dev Extracted to reduce stack depth
    function _assertAndMigrateMultiBid(
        AuctionTestState memory state,
        uint256[] memory bidIds,
        address[] memory bidders,
        uint256 totalTokensClaimed
    ) internal {
        bidIds;
        bidders;
        uint256 auctionSupply = 900_000e18;
        assertLe(totalTokensClaimed, auctionSupply, "Tokens claimed <= supply");

        IContinuousClearingAuction cca = IContinuousClearingAuction(
            state.auctionAddr
        );
        uint256 strategyRareBefore = IERC20(config.rareToken).balanceOf(
            state.strategyAddr
        );
        cca.sweepCurrency();
        uint256 strategyRareAfter = IERC20(config.rareToken).balanceOf(
            state.strategyAddr
        );
        assertGt(
            strategyRareAfter,
            strategyRareBefore,
            "Strategy should receive RARE"
        );

        cca.sweepUnsoldTokens();

        uint256 clearingPriceQ96 = cca.clearingPrice();
        uint256 currencyRaised = cca.currencyRaised();
        assertFalse(
            state.graduated.isGraduated(),
            "Should not be graduated before migrate"
        );
        ILBPStrategy(state.strategyAddr).migrate();
        assertTrue(
            state.graduated.isGraduated(),
            "Should be graduated after migrate"
        );

        uint256 priceScaledMulti = (clearingPriceQ96 * 1e18) >> 96;
        console.log("Migration complete:");
        console.log(
            "  Clearing price (RARE per token):",
            _fmt(priceScaledMulti)
        );
        console.log("  Currency raised (RARE):", _fmt(currencyRaised));
        console.log("  Liquid tokens claimed:", _fmt(totalTokensClaimed));

        _postMigrationRouterTrading(state.graduatedToken, tokenCreator);
    }
}
