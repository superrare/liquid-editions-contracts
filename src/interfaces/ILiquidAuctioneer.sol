// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title ILiquidAuctioneer
/// @notice Interface for the LiquidAuctioneer contract that handles CCA auction interactions
interface ILiquidAuctioneer {
    enum RouteKind {
        NONE,
        V4_SINGLE,
        V3_PATH,
        V2_PATH
    }

    // ============================================
    // ERRORS
    // ============================================

    // Shared errors from ILiquidRouter (AddressZero)
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
    /// @notice Thrown when configured preset route is invalid or missing
    error InvalidPresetRoute();

    /// @notice Thrown when liquidToken is not registered in LiquidRegistry
    error UnregisteredToken(address token);

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
    /// @notice Emitted when preset token->RARE route configuration changes
    event TokenRouteUpdated(address indexed tokenIn, RouteKind indexed kind);

    /// @notice Emitted when the Universal Router is updated
    /// @param oldUniversalRouter Previous Universal Router
    /// @param newUniversalRouter New Universal Router
    event UniversalRouterUpdated(
        address indexed oldUniversalRouter,
        address indexed newUniversalRouter
    );

    /// @notice Emitted when the fee distributor pointer is updated
    event FeeDistributorUpdated(
        address indexed oldFeeDistributor,
        address indexed newFeeDistributor
    );

    /// @notice Emitted when the liquid registry pointer is updated
    event LiquidRegistryUpdated(
        address indexed oldLiquidRegistry,
        address indexed newLiquidRegistry
    );

    // ============================================
    // FUNCTIONS
    // ============================================

    /// @notice Bid on a CCA auction using a configured preset route
    /// @param tokenIn Input token address (address(0) for native ETH)
    /// @param amountIn Input amount for ERC20 bids (ignored for native ETH bids)
    /// @param liquidToken The Liquid token address
    /// @param maxPrice Maximum price willing to pay
    /// @param bidOwner Owner of the bid (receives tokens/refunds)
    /// @param prevTickPrice Previous tick price for bid ordering
    /// @param minRareOut Minimum RARE amount to bid (slippage protection)
    /// @param deadline Transaction deadline timestamp
    /// @return bidId The bid ID from the auction
    function bid(
        address tokenIn,
        uint256 amountIn,
        address liquidToken,
        uint256 maxPrice,
        address bidOwner,
        uint256 prevTickPrice,
        uint256 minRareOut,
        uint256 deadline
    ) external payable returns (uint256 bidId);

    /// @notice Set preset token->RARE route to V4 single-hop config (owner only)
    function setTokenRouteV4(
        address tokenIn,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) external;

    /// @notice Set preset token->RARE route to V3 path config (owner only)
    function setTokenRouteV3(address tokenIn, bytes calldata path) external;

    /// @notice Set preset token->RARE route to V2 path config (owner only)
    function setTokenRouteV2(address tokenIn, address[] calldata path) external;

    /// @notice Clear preset token->RARE route configuration (owner only)
    function removeTokenRoute(address tokenIn) external;

    /// @notice Set the Uniswap Universal Router address used for swaps
    /// @param _universalRouter New Universal Router address
    function setUniversalRouter(address _universalRouter) external;

    /// @notice Update the fee distributor module
    /// @param _feeDistributor New fee distributor contract
    function setFeeDistributor(address _feeDistributor) external;

    /// @notice Update the liquid registry module
    /// @param _liquidRegistry New liquid registry contract
    function setLiquidRegistry(address _liquidRegistry) external;

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

    /// @notice Get active fee distributor
    function feeDistributor() external view returns (address);

    /// @notice Get active liquid registry
    function liquidRegistry() external view returns (address);

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
