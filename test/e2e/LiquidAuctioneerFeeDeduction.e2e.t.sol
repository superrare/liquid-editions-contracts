// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {AnvilForkAuctionBase} from "liquid-editions-test/AnvilForkAuctionBase.sol";

/// @title AnvilForkAuctioneerFeeDeductionTest
/// @notice Verifies bid fee allocation on forked mainnet auctioneer setup.
/// @dev Auctioneer sends 100% of ETH fee to protocolFeeRecipient (no beneficiary split).
contract AnvilForkAuctioneerFeeDeductionTest is AnvilForkAuctionBase {
    function test_BidWithETH_FeeDeduction() public {
        (AuctionTestState memory state, bool ok) = _createAuctionForTest();
        if (!ok) {
            vm.skip(true);
            return;
        }

        uint256 bidAmount = 1 ether;
        address protocolRecipient = auctioneer.protocolFeeRecipient();
        uint256 expectedFee = (bidAmount * auctioneer.ethFeeBps()) / 10_000;
        uint256 protocolBefore = protocolRecipient.balance;

        vm.prank(buyer);
        auctioneer.bid{value: bidAmount}(
            address(0),
            0,
            state.graduatedToken,
            0,
            buyer,
            0,
            1,
            block.timestamp + 1 hours
        );

        uint256 protocolAfter = protocolRecipient.balance;
        assertEq(
            protocolAfter - protocolBefore,
            expectedFee,
            "Protocol fee recipient should receive full ETH fee"
        );
    }
}
