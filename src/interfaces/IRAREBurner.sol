// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title IRAREBurner
/// @notice Interface for the RARE burn accumulator contract that buffers ETH and performs best-effort burns
/// @dev Implements non-reverting burn mechanism to prevent user transaction failures
interface IRAREBurner {
    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when an operation is attempted with a zero address
    error AddressZero();

    /// @notice Thrown when slippage value exceeds the maximum allowed
    error SlippageTooHigh(uint256 slippage, uint256 maxSlippage);

    /// @notice Thrown when trying to sweep more than available pending ETH
    error InsufficientPendingEth(uint256 requested, uint256 available);

    /// @notice Thrown when there is no excess ETH to sweep
    error NoExcessEth();

    /// @notice Thrown when a value exceeds uint128 maximum
    error AmountExceedsUint128(uint256 value);

    /// @notice Thrown when caller is not the contract itself
    error OnlySelf();

    /// @notice Thrown when an ETH transfer fails
    error EthTransferFailed();

    /// @notice Thrown when contract is paused
    error BurnerPaused();

    /// @notice Thrown when slippage protection fails
    error SlippageExceeded();

    /// @notice Thrown when trying to sweep more than actual balance
    error InsufficientBalance();

    // ============================================
    // EVENTS (Consolidated)
    // ============================================

    /// @notice Emitted when ETH is deposited for burning
    /// @param from The address depositing ETH
    /// @param amount The amount of ETH deposited
    /// @param pendingTotal New total pending ETH balance
    event Deposited(address indexed from, uint256 amount, uint256 pendingTotal);

    /// @notice Emitted when RARE tokens are successfully burned
    /// @param ethIn Amount of ETH used for swap
    /// @param rareOut Amount of RARE tokens burned
    event Burned(uint256 ethIn, uint256 rareOut);

    /// @notice Emitted when a burn attempt fails
    /// @param ethIn Amount of ETH that was attempted
    /// @param reason Failure reason code (0=swap failed, 1=quote failed, 2=config mismatch)
    event BurnFailed(uint256 ethIn, uint8 reason);

    /// @notice Emitted when mutable configuration is updated
    /// @param enabled Whether RARE burning is enabled
    /// @param maxSlippageBPS Maximum slippage in basis points
    event ConfigUpdated(bool enabled, uint16 maxSlippageBPS);

    /// @notice Emitted when pause status changes
    /// @param isPaused New pause status
    event Paused(bool isPaused);

    // ============================================
    // CONSTANTS (Failure reason codes for BurnFailed event)
    // ============================================

    // Note: These are documented here for reference but defined as constants in RAREBurner.sol
    // FAIL_SWAP = 0      - V4 swap execution failed
    // FAIL_QUOTE = 1     - Quoter returned zero or failed
    // FAIL_CONFIG = 2    - Pool configuration mismatch

    // ============================================
    // FUNCTIONS
    // ============================================

    /// @notice Deposits ETH for burning RARE tokens
    /// @dev Non-reverting: buffers ETH if swap fails, optionally tries burn on deposit
    function depositForBurn() external payable;

    /// @notice Permissionless flush to attempt burning accumulated ETH
    /// @dev Best-effort: does not revert if burn fails, keeps funds pending for next attempt
    function flush() external;

    /// @notice Returns the amount of ETH pending burn attempts
    /// @return Amount of ETH buffered for future burn attempts
    function pendingEth() external view returns (uint256);

    /// @notice Sweeps excess ETH (beyond pendingEth) to specified address (owner only)
    /// @dev Recovers ETH received via selfdestruct or forced sends
    /// @param to Recipient address
    function sweepExcess(address to) external;
}
