// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {AnvilForkAuctionBase} from "liquid-editions-test/AnvilForkAuctionBase.sol";

/// @title AnvilForkAuctioneerFeeDeductionTest
/// @notice Verifies bid fee allocation on forked mainnet auctioneer setup.
contract AnvilForkAuctioneerFeeDeductionTest is AnvilForkAuctionBase {
    uint256 internal constant BENEFICIARY_FEE_BPS = 2500;

    struct FeeSplit {
        uint256 totalFee;
        uint256 beneficiaryFee;
        uint256 protocolFee;
        uint256 referrerFee;
        uint256 burnerFee;
    }

    struct BalanceSnapshot {
        uint256 protocolRecipient;
        uint256 referrer;
        uint256 tokenBeneficiary;
        uint256 rareBurner;
    }

    function test_BidWithETH_FeeDeduction() public {
        (AuctionTestState memory state, bool ok) = _createAuctionForTest();
        if (!ok) {
            vm.skip(true);
            return;
        }

        address referrer = makeAddr("auctioneerFeeDeductionReferrer");
        uint256 bidAmount = 1 ether;
        address protocolRecipient = auctioneer.PROTOCOL_FEE_RECIPIENT();
        address tokenBeneficiary = auctioneer.tokenBeneficiaries(state.graduatedToken);
        address rareBurner = auctioneer.RARE_BURNER();
        FeeSplit memory expected = _computeFeeSplit(
            bidAmount,
            tokenBeneficiary,
            protocolRecipient
        );
        BalanceSnapshot memory before = _snapshotBalances(
            protocolRecipient,
            referrer,
            tokenBeneficiary,
            rareBurner
        );

        vm.prank(buyer);
        auctioneer.bid{value: bidAmount}(
            address(0),
            0,
            state.graduatedToken,
            0,
            buyer,
            referrer,
            0,
            1,
            block.timestamp + 1 hours
        );
        BalanceSnapshot memory afterSnapshot = _snapshotBalances(
            protocolRecipient,
            referrer,
            tokenBeneficiary,
            rareBurner
        );
        uint256 observedProtocol = afterSnapshot.protocolRecipient - before.protocolRecipient;
        uint256 observedReferrer = afterSnapshot.referrer - before.referrer;
        uint256 observedTokenBeneficiary = afterSnapshot.tokenBeneficiary -
            before.tokenBeneficiary;
        uint256 observedBurner = afterSnapshot.rareBurner - before.rareBurner;

        _assertFeeSplit(
            tokenBeneficiary,
            protocolRecipient,
            rareBurner,
            expected,
            observedProtocol,
            observedReferrer,
            observedTokenBeneficiary,
            observedBurner
        );

        assertEq(
            observedProtocol + observedReferrer + observedTokenBeneficiary + observedBurner,
            expected.totalFee,
            "All fee components should sum to total fee"
        );
    }

    function _balanceOrZero(
        address account
    ) internal view returns (uint256 balance) {
        return account == address(0) ? 0 : account.balance;
    }

    function _snapshotBalances(
        address protocolRecipient,
        address referrer,
        address tokenBeneficiary,
        address rareBurner
    ) internal view returns (BalanceSnapshot memory balances) {
        balances.protocolRecipient = _balanceOrZero(protocolRecipient);
        balances.referrer = _balanceOrZero(referrer);
        balances.tokenBeneficiary = _balanceOrZero(tokenBeneficiary);
        balances.rareBurner = _balanceOrZero(rareBurner);
    }

    function _computeFeeSplit(
        uint256 bidAmount,
        address tokenBeneficiary,
        address protocolRecipient
    ) internal view returns (FeeSplit memory feeSplit) {
        feeSplit.totalFee = (bidAmount * auctioneer.TOTAL_FEE_BPS()) / 10_000;
        feeSplit.beneficiaryFee = (feeSplit.totalFee * BENEFICIARY_FEE_BPS) /
            10_000;
        uint256 remainingFee = feeSplit.totalFee - feeSplit.beneficiaryFee;
        feeSplit.protocolFee =
            (remainingFee * auctioneer.PROTOCOL_FEE_BPS()) / 10_000;
        feeSplit.referrerFee =
            (remainingFee * auctioneer.REFERRER_FEE_BPS()) / 10_000;
        feeSplit.burnerFee = (remainingFee * auctioneer.RARE_BURN_FEE_BPS()) / 10_000;
        feeSplit.protocolFee +=
            remainingFee -
            (feeSplit.protocolFee + feeSplit.referrerFee + feeSplit.burnerFee);
        if (tokenBeneficiary == protocolRecipient || tokenBeneficiary == address(0)) {
            feeSplit.protocolFee += feeSplit.beneficiaryFee;
        }
    }

    function _assertFeeSplit(
        address tokenBeneficiary,
        address protocolRecipient,
        address rareBurner,
        FeeSplit memory expected,
        uint256 observedProtocol,
        uint256 observedReferrer,
        uint256 observedTokenBeneficiary,
        uint256 observedBurner
    ) internal pure {
        if (tokenBeneficiary == address(0) || tokenBeneficiary == protocolRecipient) {
            assertEq(
                observedProtocol,
                expected.protocolFee,
                "Protocol should receive protocol plus beneficiary share"
            );
            assertEq(
                observedTokenBeneficiary,
                0,
                "No direct beneficiary transfer in edge case"
            );
        } else {
            assertEq(
                observedTokenBeneficiary,
                expected.beneficiaryFee,
                "Token beneficiary should receive configured share"
            );
            assertEq(
                observedProtocol,
                expected.protocolFee,
                "Protocol should receive configured share"
            );
        }

        assertEq(
            observedReferrer,
            expected.referrerFee,
            "Referrer should receive configured referrer fee"
        );

        if (rareBurner == address(0)) {
            assertEq(observedBurner, 0, "No burner should receive no transfer");
        } else if (rareBurner == protocolRecipient) {
            assertEq(
                observedProtocol,
                expected.protocolFee + observedBurner,
                "Protocol total includes burn transfer when burner is protocol"
            );
        } else {
            assertEq(
                observedBurner,
                expected.burnerFee,
                "Burner should receive configured burn fee"
            );
        }
    }
}
