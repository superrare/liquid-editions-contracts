// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LiquidFeeLib} from "liquid-editions/LiquidFeeLib.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";

/// @title FeeDistributor
/// @notice Fee distribution contract that splits trading fees between beneficiaries and protocol.
///         Supports three fee split scenarios:
///         - One beneficiary (or two identical): 50% beneficiary, 50% protocol
///         - Two distinct beneficiaries (swap operations): 33% beneficiaryA, 33% beneficiaryB, 34% protocol
///         - No beneficiary: 100% protocol
/// @dev Failed beneficiary transfers are absorbed (added to protocol fee) and emit FeeTransferFailed event.
///      Protocol fee transfer failure reverts entire transaction (ensures fees aren't lost).
contract FeeDistributor is IFeeDistributor, Ownable {
    /// @notice Gas limit for beneficiary ETH transfers (prevents griefing attacks)
    /// @dev Used when calling beneficiary addresses to prevent unbounded gas consumption.
    ///      If a beneficiary transfer fails (e.g., contract reverts), the fee is absorbed by protocol.
    uint16 public constant GAS_LIMIT_TRANSFER = 50_000;

    uint16 public totalFeeBPS;
    address public immutable PROTOCOL_FEE_RECIPIENT;

    constructor(
        address _owner,
        uint16 _totalFeeBPS,
        address _protocolFeeRecipient
    ) Ownable(_owner) {
        if (_totalFeeBPS == 0 || _totalFeeBPS > 10_000) {
            revert InvalidTotalFee();
        }
        if (_protocolFeeRecipient == address(0)) {
            revert InvalidAddress();
        }
        totalFeeBPS = _totalFeeBPS;
        PROTOCOL_FEE_RECIPIENT = _protocolFeeRecipient;
    }

    function protocolFeeRecipient() external view returns (address) {
        return PROTOCOL_FEE_RECIPIENT;
    }

    /// @notice Quotes fee breakdown for a single-beneficiary scenario (50/50 split)
    /// @dev This function only handles the single-beneficiary case (50/50 split).
    ///      For swap operations with two distinct beneficiaries (33/33/34 split),
    ///      use distributeFees() directly as quoteFeeBreakdown() does not support that scenario.
    /// @param grossFee Total fee amount
    /// @return beneficiaryFee Fee amount to beneficiary (50% of grossFee)
    /// @return protocolFee Fee amount to protocol (50% of grossFee)
    function quoteFeeBreakdown(
        uint256 grossFee
    )
        external
        pure
        returns (uint256 beneficiaryFee, uint256 protocolFee)
    {
        beneficiaryFee = grossFee / 2;
        protocolFee = grossFee - beneficiaryFee;
    }

    function setTotalFeeBPS(uint16 _totalFeeBPS) external override onlyOwner {
        if (_totalFeeBPS == 0 || _totalFeeBPS > 10_000) {
            revert InvalidTotalFee();
        }
        uint16 oldFee = totalFeeBPS;
        totalFeeBPS = _totalFeeBPS;
        emit TotalFeeUpdated(oldFee, _totalFeeBPS);
    }

    /// @notice Distributes fees to beneficiaries and protocol
    /// @dev Fee split logic:
    ///      - Two distinct beneficiaries: 33% A, 33% B, 34% protocol
    ///      - One beneficiary (or two identical): 50% beneficiary, 50% protocol
    ///      - No beneficiary: 100% protocol
    ///      Failed beneficiary transfers are absorbed (added to protocol fee) and emit FeeTransferFailed event.
    ///      Protocol fee transfer failure reverts entire transaction (ensures fees aren't lost).
    /// @param grossFee Total fee amount (must equal msg.value)
    /// @param beneficiaryA First beneficiary address (address(0) if none)
    /// @param beneficiaryB Second beneficiary address (address(0) if none)
    /// @return protocolFee Actual protocol fee transferred (includes failed beneficiary transfers)
    /// @return beneficiaryFeeA Actual beneficiary A fee transferred (0 if transfer failed)
    /// @return beneficiaryFeeB Actual beneficiary B fee transferred (0 if transfer failed)
    function distributeFees(
        uint256 grossFee,
        address beneficiaryA,
        address beneficiaryB
    )
        external
        payable
        returns (
            uint256 protocolFee,
            uint256 beneficiaryFeeA,
            uint256 beneficiaryFeeB
        )
    {
        if (grossFee == 0) {
            return (0, 0, 0);
        }
        if (msg.value != grossFee) {
            revert InvalidValue();
        }

        bool hasA = beneficiaryA != address(0);
        bool hasB = beneficiaryB != address(0);

        if (hasA && hasB && beneficiaryA != beneficiaryB) {
            // Two distinct beneficiaries: 33 / 33 / 34
            beneficiaryFeeA = grossFee / 3;
            beneficiaryFeeB = grossFee / 3;
            protocolFee = grossFee - beneficiaryFeeA - beneficiaryFeeB;
        } else if (hasA || hasB) {
            // One beneficiary (or both are the same address): 50 / 50
            beneficiaryFeeA = grossFee / 2;
            protocolFee = grossFee - beneficiaryFeeA;
            if (!hasA) {
                // beneficiaryB is the real one; move the amount
                beneficiaryFeeB = beneficiaryFeeA;
                beneficiaryFeeA = 0;
            }
        } else {
            // No beneficiary: 100% protocol
            protocolFee = grossFee;
        }

        // --- Transfers ---
        uint256 protocolTotal = protocolFee;

        if (beneficiaryFeeA > 0) {
            (bool ok, ) = payable(beneficiaryA).call{
                value: beneficiaryFeeA,
                gas: GAS_LIMIT_TRANSFER
            }("");
            if (!ok) {
                emit FeeTransferFailed(
                    beneficiaryA,
                    beneficiaryFeeA,
                    "beneficiary"
                );
                protocolTotal += beneficiaryFeeA;
                beneficiaryFeeA = 0;
            }
        }

        if (beneficiaryFeeB > 0) {
            (bool ok, ) = payable(beneficiaryB).call{
                value: beneficiaryFeeB,
                gas: GAS_LIMIT_TRANSFER
            }("");
            if (!ok) {
                emit FeeTransferFailed(
                    beneficiaryB,
                    beneficiaryFeeB,
                    "beneficiary"
                );
                protocolTotal += beneficiaryFeeB;
                beneficiaryFeeB = 0;
            }
        }

        (bool protocolOk, ) = payable(PROTOCOL_FEE_RECIPIENT).call{
            value: protocolTotal
        }("");
        if (!protocolOk) {
            revert LiquidFeeLib.EthTransferFailed();
        }
        protocolFee = protocolTotal;
    }
}
