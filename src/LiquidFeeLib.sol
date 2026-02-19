// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IRAREBurner} from "liquid-editions/interfaces/IRAREBurner.sol";
import {RoutePolicy} from "liquid-editions/RoutePolicy.sol";

/// @title LiquidFeeLib
/// @notice Shared fee calculation, swap execution, and fee distribution for LiquidRouter and LiquidAuctioneer
/// @dev Library functions are internal; they run in the caller's context (balance, msg.sender, etc.)
library LiquidFeeLib {
    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Total trading fee in basis points (4% = 400 BPS)
    uint256 internal constant TOTAL_FEE_BPS = 400;

    /// @notice Beneficiary's share of total fees in basis points (25%)
    uint256 internal constant BENEFICIARY_FEE_BPS = 2500;

    /// @notice Gas limit for external fee transfers to prevent griefing
    uint256 internal constant GAS_LIMIT_TRANSFER = 50000;

    // ============================================
    // ERRORS (shared with callers for swap path)
    // ============================================

    error DeadlineExpired();
    error InvalidRouteData();
    error CommandInputLengthMismatch();
    error SwapFailed();
    error EthTransferFailed();

    // ============================================
    // EVENTS (emitted in caller's context)
    // ============================================

    event FeeTransferFailed(address indexed to, uint256 amount, string reason);
    event BurnerDeposit(
        address indexed from,
        address indexed to,
        uint256 amount,
        bool success
    );

    // ============================================
    // FEE CALCULATION
    // ============================================

    /// @notice Calculates fee amount based on basis points
    /// @param amount The amount to calculate fee from
    /// @param bps The fee in basis points (1 BPS = 0.01%, 100 BPS = 1%)
    /// @return The calculated fee amount (rounds down due to integer division)
    function calculateFee(
        uint256 amount,
        uint256 bps
    ) internal pure returns (uint256) {
        // BPS = basis points: 10000 BPS = 100%, 400 BPS = 4%
        return (amount * bps) / 10_000;
    }

    // ============================================
    // SWAP EXECUTION
    // ============================================

    /// @notice Executes a swap via Universal Router
    /// @param universalRouter Address of Uniswap Universal Router
    /// @param ethValue ETH to send with the call
    /// @param commands Encoded Universal Router command bytes
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @param expectsEthOutput True if this route must return native ETH to caller
    function executeSwap(
        address universalRouter,
        uint256 ethValue,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 deadline,
        bool expectsEthOutput
    ) internal {
        // Validate deadline and route structure
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (commands.length == 0) revert InvalidRouteData();
        if (commands.length != inputs.length)
            revert CommandInputLengthMismatch();

        // Enforce route policy before crossing the Universal Router boundary.
        RoutePolicy.validateRoute(commands, inputs, expectsEthOutput);

        bytes memory routeData = abi.encodeWithSignature(
            "execute(bytes,bytes[],uint256)",
            commands,
            inputs,
            deadline
        );

        // Execute swap via Universal Router (supports V2/V3/V4, multi-hop)
        (bool success, bytes memory result) = universalRouter.call{
            value: ethValue
        }(routeData);

        // Propagate revert reason if swap failed
        if (!success) {
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert SwapFailed();
        }
    }

    // ============================================
    // FEE DISTRIBUTION
    // ============================================

    /// @notice Distributes collected fees to beneficiaries, protocol, referrer, and RARE burn
    /// @param _fee The total fee amount to distribute
    /// @param _orderReferrer The address of the order referrer
    /// @param _beneficiaryA The first beneficiary address
    /// @param _beneficiaryB The second beneficiary address
    /// @param _protocolFeeRecipient Protocol fee recipient
    /// @param _rareBurner RARE burner contract address
    /// @param rareBurnFeeBPS RARE burn fee in basis points (TIER 3)
    /// @param protocolFeeBPS Protocol fee in basis points (TIER 3)
    /// @param referrerFeeBPS Referrer fee in basis points (TIER 3)
    /// @return protocolFee Actual protocol fee transferred
    /// @return referrerFee Actual referrer fee transferred
    /// @return beneficiaryFeeA Actual beneficiary fee transferred to A
    /// @return beneficiaryFeeB Actual beneficiary fee transferred to B
    /// @return rareBurnFee Actual RARE burn fee deposited
    function disperseFees(
        uint256 _fee,
        address _orderReferrer,
        address _beneficiaryA,
        address _beneficiaryB,
        address _protocolFeeRecipient,
        address _rareBurner,
        uint256 rareBurnFeeBPS,
        uint256 protocolFeeBPS,
        uint256 referrerFeeBPS
    )
        internal
        returns (
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 beneficiaryFeeA,
            uint256 beneficiaryFeeB,
            uint256 rareBurnFee
        )
    {
        // Skip referrer if not set or same as protocol (avoid self-transfer)
        bool skipReferrerTransfer = _orderReferrer == address(0) ||
            _orderReferrer == _protocolFeeRecipient;

        // TIER 2: Beneficiary gets fixed share first (25% of total fee)
        uint256 totalBeneficiaryFee = calculateFee(_fee, BENEFICIARY_FEE_BPS);
        uint256 remainingFee = _fee - totalBeneficiaryFee;

        // Split beneficiary fee between A and B (for swap: tokenIn vs tokenOut beneficiaries)
        if (_beneficiaryA == _beneficiaryB) {
            beneficiaryFeeA = totalBeneficiaryFee;
            beneficiaryFeeB = 0;
        } else if (_beneficiaryA == address(0)) {
            beneficiaryFeeA = 0;
            beneficiaryFeeB = totalBeneficiaryFee;
        } else if (_beneficiaryB == address(0)) {
            beneficiaryFeeA = totalBeneficiaryFee;
            beneficiaryFeeB = 0;
        } else {
            // Both set: split 50/50
            beneficiaryFeeA = totalBeneficiaryFee / 2;
            beneficiaryFeeB = totalBeneficiaryFee - beneficiaryFeeA;
        }

        // TIER 3: Split remainder among burn, referrer, protocol (per router config)
        rareBurnFee = calculateFee(remainingFee, rareBurnFeeBPS);
        referrerFee = calculateFee(remainingFee, referrerFeeBPS);
        protocolFee = calculateFee(remainingFee, protocolFeeBPS);

        // Rounding dust goes to protocol (ensures exact accounting)
        uint256 totalRemainder = rareBurnFee + referrerFee + protocolFee;
        uint256 dust = remainingFee - totalRemainder;
        protocolFee += dust;

        // RARE Burn: deposit to burner (non-reverting - failures go to protocol)
        if (rareBurnFee > 0 && _rareBurner != address(0)) {
            (bool ok, ) = _rareBurner.call{value: rareBurnFee}(
                abi.encodeWithSelector(IRAREBurner.depositForBurn.selector)
            );
            emit BurnerDeposit(address(this), _rareBurner, rareBurnFee, ok);
            if (!ok) {
                // Burn failed - redirect to protocol
                protocolFee += rareBurnFee;
                rareBurnFee = 0;
            }
        } else {
            // No burner or zero amount - send to protocol
            protocolFee += rareBurnFee;
            rareBurnFee = 0;
        }

        // Track actual amounts paid (transfers may fail and redirect to protocol)
        uint256 protocolTotal = protocolFee;
        uint256 beneficiaryAPaid = beneficiaryFeeA;
        uint256 beneficiaryBPaid = beneficiaryFeeB;
        uint256 referrerPaid = referrerFee;

        // Beneficiary A: gas-limited transfer (failure -> protocol gets it)
        if (_beneficiaryA != address(0) && beneficiaryFeeA > 0) {
            (bool beneficiaryAOk, ) = _beneficiaryA.call{
                value: beneficiaryFeeA,
                gas: GAS_LIMIT_TRANSFER
            }("");
            if (!beneficiaryAOk) {
                protocolTotal += beneficiaryFeeA;
                beneficiaryAPaid = 0;
                emit FeeTransferFailed(
                    _beneficiaryA,
                    beneficiaryFeeA,
                    "beneficiary"
                );
            }
        } else {
            // No beneficiary A - redirect to protocol
            protocolTotal += beneficiaryFeeA;
            beneficiaryAPaid = 0;
        }

        // Beneficiary B: gas-limited transfer (failure -> protocol gets it)
        if (_beneficiaryB != address(0) && beneficiaryFeeB > 0) {
            (bool beneficiaryBOk, ) = _beneficiaryB.call{
                value: beneficiaryFeeB,
                gas: GAS_LIMIT_TRANSFER
            }("");
            if (!beneficiaryBOk) {
                protocolTotal += beneficiaryFeeB;
                beneficiaryBPaid = 0;
                emit FeeTransferFailed(
                    _beneficiaryB,
                    beneficiaryFeeB,
                    "beneficiary"
                );
            }
        } else {
            // No beneficiary B - redirect to protocol
            protocolTotal += beneficiaryFeeB;
            beneficiaryBPaid = 0;
        }

        // Referrer: gas-limited transfer (failure -> protocol gets it)
        if (skipReferrerTransfer) {
            // No referrer or same as protocol - redirect to protocol
            protocolTotal += referrerFee;
            referrerPaid = 0;
        } else {
            (bool referrerOk, ) = _orderReferrer.call{
                value: referrerFee,
                gas: GAS_LIMIT_TRANSFER
            }("");
            if (!referrerOk) {
                protocolTotal += referrerFee;
                referrerPaid = 0;
                emit FeeTransferFailed(_orderReferrer, referrerFee, "referrer");
            }
        }

        // Protocol: final transfer must succeed (reverts if recipient rejects)
        (bool protocolOk, ) = _protocolFeeRecipient.call{value: protocolTotal}(
            ""
        );
        if (!protocolOk) revert EthTransferFailed();

        return (
            protocolTotal,
            referrerPaid,
            beneficiaryAPaid,
            beneficiaryBPaid,
            rareBurnFee
        );
    }
}
