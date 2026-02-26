// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {AnvilForkAuctionBase} from "liquid-editions-test/AnvilForkAuctionBase.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";

/// @title AnvilForkAuctioneerFeeDeductionTest
/// @notice Verifies bid fee allocation on forked mainnet auctioneer setup.
contract AnvilForkAuctioneerFeeDeductionTest is AnvilForkAuctionBase {
    uint256 internal constant BENEFICIARY_FEE_BPS = 5000;

    struct FeeSplit {
        uint256 totalFee;
        uint256 beneficiaryFee;
        uint256 protocolFee;
    }

    struct BalanceSnapshot {
        uint256 protocolRecipient;
        uint256 tokenBeneficiary;
    }

    function test_BidWithETH_FeeDeduction() public {
        (AuctionTestState memory state, bool ok) = _createAuctionForTest();
        if (!ok) {
            vm.skip(true);
            return;
        }

        uint256 bidAmount = 1 ether;
        IFeeDistributor distributor = IFeeDistributor(auctioneer.feeDistributor());
        address protocolRecipient = distributor.protocolFeeRecipient();
        address tokenBeneficiary = auctioneer.tokenBeneficiaries(state.graduatedToken);
        FeeSplit memory expected = _computeFeeSplit(
            bidAmount,
            tokenBeneficiary,
            protocolRecipient
        );
        BalanceSnapshot memory before = _snapshotBalances(
            protocolRecipient,
            tokenBeneficiary
        );

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
        BalanceSnapshot memory afterSnapshot = _snapshotBalances(
            protocolRecipient,
            tokenBeneficiary
        );
        uint256 observedProtocol = afterSnapshot.protocolRecipient - before.protocolRecipient;
        uint256 observedTokenBeneficiary = afterSnapshot.tokenBeneficiary -
            before.tokenBeneficiary;

        _assertFeeSplit(
            tokenBeneficiary,
            protocolRecipient,
            expected,
            observedProtocol,
            observedTokenBeneficiary
        );

        assertEq(
            observedProtocol + observedTokenBeneficiary,
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
        address tokenBeneficiary
    ) internal view returns (BalanceSnapshot memory balances) {
        balances.protocolRecipient = _balanceOrZero(protocolRecipient);
        balances.tokenBeneficiary = _balanceOrZero(tokenBeneficiary);
    }

    function _computeFeeSplit(
        uint256 bidAmount,
        address tokenBeneficiary,
        address protocolRecipient
    ) internal view returns (FeeSplit memory feeSplit) {
        IFeeDistributor distributor = IFeeDistributor(auctioneer.feeDistributor());
        feeSplit.totalFee = (bidAmount * distributor.totalFeeBPS()) / 10_000;
        feeSplit.beneficiaryFee = (feeSplit.totalFee * BENEFICIARY_FEE_BPS) /
            10_000;
        feeSplit.protocolFee = feeSplit.totalFee - feeSplit.beneficiaryFee;
        if (tokenBeneficiary == protocolRecipient || tokenBeneficiary == address(0)) {
            feeSplit.protocolFee += feeSplit.beneficiaryFee;
        }
    }

    function _assertFeeSplit(
        address tokenBeneficiary,
        address protocolRecipient,
        FeeSplit memory expected,
        uint256 observedProtocol,
        uint256 observedTokenBeneficiary
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
    }
}
