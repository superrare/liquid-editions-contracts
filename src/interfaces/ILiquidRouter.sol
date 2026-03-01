// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title ILiquidRouter
/// @notice Interface for the LiquidRouter contract that enables Liquid-style trading for existing ERC20s
/// @dev Fees are no longer collected by the router. They are skimmed at the pool level by LiquidGuard.
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

    /// @notice Thrown when a module address is not a contract
    error InvalidModule();

    /// @notice Thrown when an invalid amount is provided
    error InvalidAmount();

    /// @notice Thrown when a token is not registered in LiquidRegistry
    error TokenNotAllowed(address token);

    /// @notice Thrown when the transaction deadline has expired
    error DeadlineExpired();

    /// @notice Thrown when route commands or inputs are invalid
    error InvalidRouteData();

    /// @notice Thrown when commands length doesn't match inputs length
    error CommandInputLengthMismatch();

    /// @notice Thrown when ETH is unexpectedly returned during a buy (forces EXACT_INPUT routes)
    error UnexpectedEthRefund();

    /// @notice Thrown when tokens pulled from the user are not fully consumed during a sell
    /// @param expected Amount of tokens the router attempted to swap
    /// @param leftover Tokens that were not consumed by the Universal Router
    error UnexpectedTokenRefund(uint256 expected, uint256 leftover);

    /// @notice Thrown when contract has insufficient balance for rescue operation
    error InsufficientBalance();

    /// @notice Thrown when a fee-on-transfer/deflationary token is used for sell()
    /// @param expected Amount the router attempted to pull
    /// @param received Amount actually received after the token's fee/deflation
    error FeeOnTransferDetected(uint256 expected, uint256 received);

    /// @notice Thrown when msg.value is sent but tokenIn is ERC20 (not ETH)
    error UnexpectedMsgValue();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when tokens are bought via the router
    /// @param token The ERC20 token being bought
    /// @param buyer The address initiating the buy
    /// @param recipient The address receiving the tokens
    /// @param totalEth Total ETH sent by the buyer
    /// @param ethFee Fee field (0 — fees now collected by LiquidGuard hook)
    /// @param ethSwapped ETH sent to swap
    /// @param tokensReceived Tokens received by recipient
    /// @param protocolFee Protocol fee field (0 — not collected here)
    /// @param beneficiaryFee Beneficiary fee field (0 — not collected here)
    event RouterBuy(
        address indexed token,
        address indexed buyer,
        address indexed recipient,
        uint256 totalEth,
        uint256 ethFee,
        uint256 ethSwapped,
        uint256 tokensReceived,
        uint256 protocolFee,
        uint256 beneficiaryFee
    );

    /// @notice Emitted when tokens are sold via the router
    /// @param token The ERC20 token being sold
    /// @param seller The address initiating the sell
    /// @param recipient The address receiving the ETH
    /// @param tokensSold Tokens sold by the seller
    /// @param grossEthReceived ETH received from swap
    /// @param ethFee Fee field (0 — fees now collected by LiquidGuard hook)
    /// @param netEthReceived ETH sent to recipient
    /// @param protocolFee Protocol fee field (0 — not collected here)
    /// @param beneficiaryFee Beneficiary fee field (0 — not collected here)
    event RouterSell(
        address indexed token,
        address indexed seller,
        address indexed recipient,
        uint256 tokensSold,
        uint256 grossEthReceived,
        uint256 ethFee,
        uint256 netEthReceived,
        uint256 protocolFee,
        uint256 beneficiaryFee
    );

    /// @notice Emitted when a currency is added to the whitelist
    event CurrencyAdded(address indexed currency);

    /// @notice Emitted when a currency is removed from the whitelist
    event CurrencyRemoved(address indexed currency);

    /// @notice Emitted when the Universal Router address is updated
    event UniversalRouterUpdated(
        address indexed oldUniversalRouter,
        address indexed newUniversalRouter
    );

    /// @notice Emitted when the liquid registry pointer is updated
    event LiquidRegistryUpdated(
        address indexed oldLiquidRegistry,
        address indexed newLiquidRegistry
    );

    /// @notice Emitted when stuck ERC20 tokens are rescued
    event TokensRescued(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    /// @notice Emitted when stuck ETH is rescued
    event EthRescued(address indexed to, uint256 amount);

    /// @notice Emitted when tokens are swapped via the router (single-route swap)
    /// @param tokenIn The input token (address(0) for ETH)
    /// @param tokenOut The output token (address(0) for ETH)
    /// @param sender The address initiating the swap
    /// @param recipient The address receiving the output
    /// @param amountIn The input amount (ETH or tokens)
    /// @param ethValue ETH value forwarded to Universal Router (msg.value for ETH input, else 0)
    /// @param fee Fee field (0 — fees now collected by LiquidGuard hook)
    /// @param amountOut The output amount (ETH or tokens)
    /// @param protocolFee Protocol fee field (0 — not collected here)
    /// @param beneficiaryFeeA Beneficiary fee field (0 — not collected here)
    /// @param beneficiaryFeeB Beneficiary fee field (0 — not collected here)
    event RouterSwap(
        address indexed tokenIn,
        address indexed tokenOut,
        address indexed sender,
        address recipient,
        uint256 amountIn,
        uint256 ethValue,
        uint256 fee,
        uint256 amountOut,
        uint256 protocolFee,
        uint256 beneficiaryFeeA,
        uint256 beneficiaryFeeB
    );

    // ============================================
    // TRADING FUNCTIONS
    // ============================================

    /// @notice Buy tokens with ETH
    /// @param token The ERC20 token to buy
    /// @param recipient The address to receive the tokens
    /// @param minTokensOut Minimum tokens to receive (slippage protection)
    /// @param commands Encoded Universal Router command bytes
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @return tokensReceived The amount of tokens received
    function buy(
        address token,
        address recipient,
        uint256 minTokensOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable returns (uint256 tokensReceived);

    /// @notice Sell tokens for ETH
    /// @param token The ERC20 token to sell
    /// @param tokenAmount The amount of tokens to sell
    /// @param recipient The address to receive the ETH
    /// @param minEthOut Minimum ETH expected from swap (slippage protection)
    /// @param commands Encoded Universal Router command bytes
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @return ethReceived The amount of ETH received
    function sell(
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external returns (uint256 ethReceived);

    /// @notice Swap between any two assets
    /// @param tokenIn Input token (address(0) for ETH)
    /// @param amountIn Input amount (ignored if ETH — uses msg.value)
    /// @param tokenOut Output token (address(0) for ETH)
    /// @param recipient Address to receive output
    /// @param minAmountOut Minimum final output
    /// @param commands Encoded Universal Router command bytes
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @return amountOut The amount of output received
    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        address recipient,
        uint256 minAmountOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @notice Add a currency to the whitelist
    function addCurrency(address currency) external;

    /// @notice Remove a currency from the whitelist
    function removeCurrency(address currency) external;

    /// @notice Update Universal Router address
    function setUniversalRouter(address _universalRouter) external;

    /// @notice Update the liquid registry module
    function setLiquidRegistry(address _liquidRegistry) external;

    /// @notice Pause the contract (emergency stop)
    function pause() external;

    /// @notice Unpause the contract
    function unpause() external;

    /// @notice Rescue stuck ERC20 tokens
    function rescueTokens(address token, address to, uint256 amount) external;

    /// @notice Rescue stuck ETH
    function rescueETH(address to, uint256 amount) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Check if a currency is whitelisted
    function isCurrencyWhitelisted(address currency) external view returns (bool);

    /// @notice Get the Universal Router address
    function universalRouter() external view returns (address);

    /// @notice Get the active liquid registry
    function liquidRegistry() external view returns (address);
}
