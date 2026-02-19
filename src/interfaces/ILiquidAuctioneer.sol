// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title ILiquidAuctioneer
/// @notice Interface for the LiquidAuctioneer contract that handles CCA auction interactions
interface ILiquidAuctioneer {
    // ============================================
    // ERRORS
    // ============================================

    // Shared errors from ILiquidRouter (AddressZero, InvalidFeeDistribution)
    // Specific errors below:

    /// @notice Thrown when auction operation fails (e.g., auction not found, not graduated)
    error NotGraduated();

    /// @notice Thrown when an external call fails without returning error data
    error CallFailed();

    /// @notice Thrown when ETH received from swap is below the caller's minimum
    error SlippageExceeded();

    /// @notice Thrown when RARE tokens were not fully consumed by the swap (possible theft via crafted route)
    error UnexpectedTokenBalance();

    /// @notice Thrown when router returns unexpected ETH (breaks fee accounting)
    error UnexpectedEthRefund();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when stuck ETH is rescued
    event EthRescued(address indexed to, uint256 amount);

    /// @notice Emitted when stuck ERC20 tokens are rescued
    event TokensRescued(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    // ============================================
    // FUNCTIONS
    // ============================================

    /// @notice Bid on a CCA auction using ETH
    /// @param liquidToken The Liquid token address
    /// @param maxPrice Maximum price willing to pay
    /// @param bidOwner Owner of the bid (receives tokens/refunds)
    /// @param orderReferrer Address of the order referrer (receives referrer fee)
    /// @param prevTickPrice Previous tick price for bid ordering
    /// @param commands Encoded Universal Router command bytes for ETH -> RARE swap
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @return bidId The bid ID from the auction
    function bidWithETH(
        address liquidToken,
        uint256 maxPrice,
        address bidOwner,
        address orderReferrer,
        uint256 prevTickPrice,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable returns (uint256 bidId);

    /// @notice Exit a fully filled bid and swap refund to ETH
    /// @param liquidToken The Liquid token address
    /// @param bidId The bid ID to exit
    /// @param recipient Address to receive ETH
    /// @param minEthOut Minimum ETH output required (slippage protection)
    /// @param commands Encoded Universal Router command bytes for RARE -> ETH swap
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @return ethReceived Amount of ETH received
    function exitBidToETH(
        address liquidToken,
        uint256 bidId,
        address recipient,
        uint256 minEthOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external returns (uint256 ethReceived);

    /// @notice Exit a partially filled bid and swap refund to ETH
    /// @param liquidToken The Liquid token address
    /// @param bidId The bid ID to exit
    /// @param lastFullyFilledCheckpointBlock Last block where bid was fully filled
    /// @param outbidBlock Block where bid was outbid
    /// @param recipient Address to receive ETH
    /// @param minEthOut Minimum ETH output required (slippage protection)
    /// @param commands Encoded Universal Router command bytes for RARE -> ETH swap
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @return ethReceived Amount of ETH received
    function exitPartialBidToETH(
        address liquidToken,
        uint256 bidId,
        uint256 lastFullyFilledCheckpointBlock,
        uint256 outbidBlock,
        address recipient,
        uint256 minEthOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external returns (uint256 ethReceived);

    /// @notice Claim auction tokens after auction ends
    /// @param liquidToken The Liquid token address
    /// @param bidId The bid ID to claim tokens for
    function claimAuctionTokens(address liquidToken, uint256 bidId) external;

    /// @notice Set beneficiary for a token (owner only)
    /// @param token The token address
    /// @param beneficiary The beneficiary address
    function setBeneficiary(address token, address beneficiary) external;

    /// @notice Pause the contract (owner only)
    function pause() external;

    /// @notice Unpause the contract (owner only)
    function unpause() external;

    /// @notice Get beneficiary for a token
    /// @param token The token address
    /// @return The beneficiary address
    function tokenBeneficiaries(address token) external view returns (address);

    /// @notice Rescue stuck ETH to a recipient (owner only)
    /// @param to Recipient address
    /// @param amount Amount to rescue
    function rescueETH(address to, uint256 amount) external;

    /// @notice Rescue stuck ERC20 tokens to a recipient (owner only)
    /// @param token The token address
    /// @param to Recipient address
    /// @param amount Amount to rescue
    function rescueTokens(address token, address to, uint256 amount) external;
}
