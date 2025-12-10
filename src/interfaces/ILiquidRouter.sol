// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title ILiquidRouter
/// @notice Interface for the LiquidRouter contract that enables Liquid-style trading for existing ERC20s
/// @dev Fee configuration is pulled from LiquidFactory to stay in sync with Liquid tokens
interface ILiquidRouter {
    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when an operation is attempted with a zero address
    error AddressZero();

    /// @notice Thrown when an ETH transfer fails
    error EthTransferFailed();

    /// @notice Thrown when slippage exceeds the specified limit
    error SlippageExceeded();

    /// @notice Thrown when the Universal Router swap fails
    error SwapFailed();

    /// @notice Thrown when an invalid amount is provided
    error InvalidAmount();

    /// @notice Thrown when a token is not in the allowlist
    error TokenNotAllowed(address token);

    /// @notice Thrown when the transaction deadline has expired
    error DeadlineExpired();

    /// @notice Thrown when routeData is empty or invalid
    error InvalidRouteData();

    /// @notice Thrown when ETH is unexpectedly returned during a buy (forces EXACT_INPUT routes)
    error UnexpectedEthRefund();

    /// @notice Thrown when contract has insufficient balance for rescue operation
    error InsufficientBalance();

    /// @notice Thrown when a fee-on-transfer/deflationary token is used for sell()
    /// @param expected Amount the router attempted to pull
    /// @param received Amount actually received after the token's fee/deflation
    error FeeOnTransferDetected(uint256 expected, uint256 received);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when tokens are bought via the router
    /// @param token The ERC20 token being bought
    /// @param buyer The address initiating the buy
    /// @param recipient The address receiving the tokens
    /// @param orderReferrer The address of the order referrer
    /// @param totalEth Total ETH sent by the buyer
    /// @param ethFee Fee deducted from ETH
    /// @param ethSwapped ETH sent to swap (after fee)
    /// @param tokensReceived Tokens received by recipient
    /// @param protocolFee Protocol fee amount
    /// @param referrerFee Referrer fee amount
    /// @param beneficiaryFee Beneficiary fee amount
    /// @param burnFee RARE burn fee amount
    event RouterBuy(
        address indexed token,
        address indexed buyer,
        address indexed recipient,
        address orderReferrer,
        uint256 totalEth,
        uint256 ethFee,
        uint256 ethSwapped,
        uint256 tokensReceived,
        uint256 protocolFee,
        uint256 referrerFee,
        uint256 beneficiaryFee,
        uint256 burnFee
    );

    /// @notice Emitted when tokens are sold via the router
    /// @param token The ERC20 token being sold
    /// @param seller The address initiating the sell
    /// @param recipient The address receiving the ETH
    /// @param orderReferrer The address of the order referrer
    /// @param tokensSold Tokens sold by the seller
    /// @param grossEthReceived ETH received from swap (before fee)
    /// @param ethFee Fee deducted from ETH
    /// @param netEthReceived ETH sent to recipient (after fee)
    /// @param protocolFee Protocol fee amount
    /// @param referrerFee Referrer fee amount
    /// @param beneficiaryFee Beneficiary fee amount
    /// @param burnFee RARE burn fee amount
    event RouterSell(
        address indexed token,
        address indexed seller,
        address indexed recipient,
        address orderReferrer,
        uint256 tokensSold,
        uint256 grossEthReceived,
        uint256 ethFee,
        uint256 netEthReceived,
        uint256 protocolFee,
        uint256 referrerFee,
        uint256 beneficiaryFee,
        uint256 burnFee
    );

    /// @notice Emitted when fees are distributed
    /// @param beneficiary The token beneficiary
    /// @param orderReferrer The order referrer
    /// @param protocolFeeRecipient The protocol fee recipient
    /// @param rareBurnFee RARE burn fee deposited
    /// @param beneficiaryFee Beneficiary fee transferred
    /// @param referrerFee Referrer fee transferred
    /// @param protocolFee Protocol fee transferred
    event RouterFees(
        address indexed beneficiary,
        address indexed orderReferrer,
        address protocolFeeRecipient,
        uint256 rareBurnFee,
        uint256 beneficiaryFee,
        uint256 referrerFee,
        uint256 protocolFee
    );

    /// @notice Emitted when a fee transfer fails
    /// @param recipient The intended recipient
    /// @param amount The amount that failed to transfer
    /// @param reason The reason for failure
    event FeeTransferFailed(
        address indexed recipient,
        uint256 amount,
        string reason
    );

    /// @notice Emitted when ETH is deposited to the RARE burner
    /// @param router The router contract address
    /// @param burner The burner contract address
    /// @param amount The amount deposited
    /// @param success Whether the deposit succeeded
    event BurnerDeposit(
        address indexed router,
        address indexed burner,
        uint256 amount,
        bool success
    );

    /// @notice Emitted when a token is registered
    /// @param token The token address
    /// @param beneficiary The beneficiary address
    event TokenRegistered(address indexed token, address indexed beneficiary);

    /// @notice Emitted when a token is removed from the allowlist
    /// @param token The token address
    event TokenRemoved(address indexed token);

    /// @notice Emitted when a token's beneficiary is updated
    /// @param token The token address
    /// @param oldBeneficiary The old beneficiary address
    /// @param newBeneficiary The new beneficiary address
    event BeneficiaryUpdated(
        address indexed token,
        address oldBeneficiary,
        address newBeneficiary
    );

    /// @notice Emitted when the allowlist is enabled/disabled
    /// @param enabled Whether the allowlist is enabled
    event AllowlistEnabledUpdated(bool enabled);

    /// @notice Emitted when stuck ERC20 tokens are rescued
    /// @param token The token address
    /// @param to The recipient address
    /// @param amount The amount rescued
    event TokensRescued(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    /// @notice Emitted when stuck ETH is rescued
    /// @param to The recipient address
    /// @param amount The amount rescued
    event EthRescued(address indexed to, uint256 amount);

    /// @notice Emitted when the Universal Router address is updated
    /// @param oldRouter The previous router address
    /// @param newRouter The new router address
    event UniversalRouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );

    /// @notice Emitted when the LiquidFactory address is updated
    /// @param oldFactory The previous factory address
    /// @param newFactory The new factory address
    event FactoryUpdated(
        address indexed oldFactory,
        address indexed newFactory
    );

    // ============================================
    // TRADING FUNCTIONS
    // ============================================

    /// @notice Buy tokens with ETH
    /// @dev Fee is deducted from ETH input before swap
    /// @param token The ERC20 token to buy
    /// @param recipient The address to receive the tokens
    /// @param orderReferrer The address of the order referrer (receives referrer fee)
    /// @param minTokensOut Minimum tokens to receive (slippage protection)
    /// @param routeData Encoded Universal Router commands and inputs for the swap
    /// @param deadline Transaction deadline timestamp
    /// @return tokensReceived The amount of tokens received
    function buy(
        address token,
        address recipient,
        address orderReferrer,
        uint256 minTokensOut,
        bytes calldata routeData,
        uint256 deadline
    ) external payable returns (uint256 tokensReceived);

    /// @notice Sell tokens for ETH
    /// @dev Fee is deducted from ETH output after swap
    /// @param token The ERC20 token to sell
    /// @param tokenAmount The amount of tokens to sell
    /// @param recipient The address to receive the ETH
    /// @param orderReferrer The address of the order referrer (receives referrer fee)
    /// @param minEthOut Minimum GROSS ETH expected from swap (before fees) - contract adjusts internally
    /// @param routeData Encoded Universal Router commands and inputs for the swap
    /// @param deadline Transaction deadline timestamp
    /// @return ethReceived The amount of ETH received (after fees)
    function sell(
        address token,
        uint256 tokenAmount,
        address recipient,
        address orderReferrer,
        uint256 minEthOut,
        bytes calldata routeData,
        uint256 deadline
    ) external returns (uint256 ethReceived);

    // ============================================
    // QUOTE FUNCTIONS
    // ============================================

    /// @notice Quote the fee breakdown for a given total fee
    /// @dev Fee percentages are read from LiquidFactory
    /// @param totalFee The total fee amount
    /// @return beneficiaryFee Fee to beneficiary
    /// @return protocolFee Fee to protocol
    /// @return referrerFee Fee to referrer
    /// @return burnFee Fee for RARE burn
    function quoteFeeBreakdown(
        uint256 totalFee
    )
        external
        view
        returns (
            uint256 beneficiaryFee,
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 burnFee
        );

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @notice Register a token with its beneficiary
    /// @param token The token address
    /// @param beneficiary The beneficiary address (receives "creator" fees)
    function registerToken(address token, address beneficiary) external;

    /// @notice Remove a token from the allowlist
    /// @dev Also clears the beneficiary mapping
    /// @param token The token address
    function removeToken(address token) external;

    /// @notice Update a token's beneficiary
    /// @param token The token address
    /// @param newBeneficiary The new beneficiary address
    function updateBeneficiary(address token, address newBeneficiary) external;

    /// @notice Enable or disable the allowlist
    /// @param enabled Whether to enable the allowlist
    function setAllowlistEnabled(bool enabled) external;

    /// @notice Pause the contract (emergency stop)
    /// @dev Only callable by owner. Prevents buy() and sell() operations.
    function pause() external;

    /// @notice Unpause the contract
    /// @dev Only callable by owner. Re-enables buy() and sell() operations.
    function unpause() external;

    /// @notice Rescue stuck ERC20 tokens (emergency recovery)
    /// @dev Only callable by owner. Intended for accidentally sent tokens.
    /// @param token The ERC20 token to rescue
    /// @param to The recipient address
    /// @param amount The amount to rescue
    function rescueTokens(address token, address to, uint256 amount) external;

    /// @notice Rescue stuck ETH (emergency recovery)
    /// @dev Only callable by owner. Intended for accidentally sent ETH.
    /// @param to The recipient address
    /// @param amount The amount to rescue
    function rescueETH(address to, uint256 amount) external;

    /// @notice Update the Universal Router address
    /// @dev Only callable by owner. Use for router upgrades.
    /// @param _universalRouter The new Universal Router address
    function setUniversalRouter(address _universalRouter) external;

    /// @notice Update the LiquidFactory address
    /// @dev Only callable by owner. Use for factory upgrades.
    /// @param _factory The new LiquidFactory address
    function setFactory(address _factory) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Get the beneficiary for a token
    /// @param token The token address
    /// @return The beneficiary address
    function tokenBeneficiaries(address token) external view returns (address);

    /// @notice Check if a token is allowed
    /// @param token The token address
    /// @return Whether the token is allowed
    function allowedTokens(address token) external view returns (bool);

    /// @notice Check if allowlist is enabled
    /// @return Whether the allowlist is enabled
    function allowlistEnabled() external view returns (bool);

    /// @notice Get the Universal Router address
    /// @return The Universal Router address
    function universalRouter() external view returns (address);

    /// @notice Get the LiquidFactory address
    /// @dev Fee configuration is read from factory at runtime
    /// @return The LiquidFactory address
    function factory() external view returns (address);

    /// @notice Get the total fee BPS
    /// @return The total fee in basis points
    function TOTAL_FEE_BPS() external view returns (uint256);

    /// @notice Get the beneficiary fee BPS
    /// @return The beneficiary fee in basis points
    function BENEFICIARY_FEE_BPS() external view returns (uint256);

    // Note: paused() is inherited from OpenZeppelin's Pausable contract
}
