// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {RoutePolicy} from "liquid-editions/RoutePolicy.sol";

/// @title LiquidFeeLib
/// @notice Shared fee calculation and swap execution helpers for LiquidRouter and LiquidAuctioneer.
/// @dev Library functions are internal; they run in the caller's context (balance, msg.sender, etc.)
library LiquidFeeLib {
    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Legacy total trading fee constant (4% = 400 BPS)
    /// @dev **DEPRECATED**: This constant is kept for backward compatibility only.
    ///      New code should NOT use this constant. Instead, read the fee from FeeDistributor:
    ///      `FeeDistributor.totalFeeBPS()` which can be updated by the protocol owner.
    ///      This constant represents a hardcoded 4% fee that cannot be changed without redeployment.
    ///      Migration path: Replace `TOTAL_FEE_BPS` with `IFeeDistributor(feeDistributor).totalFeeBPS()`.
    uint256 internal constant TOTAL_FEE_BPS = 400;

    /// @notice Legacy beneficiary fee share constant (25% of total fee = 2500 BPS)
    /// @dev **DEPRECATED**: This constant is kept for backward compatibility only.
    ///      New code should NOT use this constant. Fee distribution is now handled by FeeDistributor
    ///      which supports dynamic fee splits (50/50, 33/33/34, 100% protocol) based on beneficiary configuration.
    ///      This constant represented a hardcoded 25% beneficiary share that cannot be changed.
    ///      Migration path: Use `FeeDistributor.distributeFees()` which handles all fee split scenarios automatically.
    uint256 internal constant BENEFICIARY_FEE_BPS = 2500;

    // ============================================
    // ERRORS (shared with callers for swap path)
    // ============================================

    error DeadlineExpired();
    error InvalidRouteData();
    error CommandInputLengthMismatch();
    error SwapFailed();
    error EthTransferFailed();

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
        if (commands.length != inputs.length) revert CommandInputLengthMismatch();

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
}
