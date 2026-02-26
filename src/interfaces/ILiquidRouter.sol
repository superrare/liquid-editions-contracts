// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title ILiquidRouter
/// @notice Interface for the LiquidRouter contract that enables Liquid-style trading for existing ERC20s
/// @dev Fee configuration is provided by an external FeeDistributor module
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

    /// @notice Thrown when both leg1 and leg2 are empty in swap()
    error BothLegsEmpty();

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
    /// @param ethFee Fee deducted from ETH
    /// @param ethSwapped ETH sent to swap (after fee)
    /// @param tokensReceived Tokens received by recipient
    /// @param protocolFee Protocol fee amount
    /// @param beneficiaryFee Beneficiary fee amount
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
    /// @param grossEthReceived ETH received from swap (before fee)
    /// @param ethFee Fee deducted from ETH
    /// @param netEthReceived ETH sent to recipient (after fee)
    /// @param protocolFee Protocol fee amount
    /// @param beneficiaryFee Beneficiary fee amount
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

    /// @notice Emitted when a fee transfer to a recipient fails
    /// @param recipient The intended recipient
    /// @param amount The amount that failed to transfer
    /// @param reason The reason for failure
    event FeeTransferFailed(
        address indexed recipient,
        uint256 amount,
        string reason
    );

    /// @notice Emitted when a token is registered
    /// @param token The token address
    /// @param beneficiary The beneficiary address
    event TokenRegistered(address indexed token, address indexed beneficiary);

    /// @notice Emitted when a token is removed from the registry
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

    /// @notice Emitted when the Universal Router address is updated
    /// @param oldUniversalRouter Previous Universal Router address
    /// @param newUniversalRouter New Universal Router address
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

    /// @notice Emitted when tokens are swapped via the router (two-leg swap)
    /// @param tokenIn The input token (address(0) for ETH)
    /// @param tokenOut The output token (address(0) for ETH)
    /// @param sender The address initiating the swap
    /// @param recipient The address receiving the output
    /// @param amountIn The input amount (ETH or tokens)
    /// @param ethAtMidpoint The gross ETH at the midpoint (before fee)
    /// @param fee The total ETH fee collected
    /// @param amountOut The output amount (ETH or tokens)
    /// @param protocolFee Protocol fee amount
    /// @param beneficiaryFeeA Beneficiary fee amount for tokenIn
    /// @param beneficiaryFeeB Beneficiary fee amount for tokenOut
    event RouterSwap(
        address indexed tokenIn,
        address indexed tokenOut,
        address indexed sender,
        address recipient,
        uint256 amountIn,
        uint256 ethAtMidpoint,
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
    /// @dev Fee is deducted from ETH input before swap
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
    /// @dev Fee is deducted from ETH output after swap
    /// @param token The ERC20 token to sell
    /// @param tokenAmount The amount of tokens to sell
    /// @param recipient The address to receive the ETH
    /// @param minEthOut Minimum GROSS ETH expected from swap (before fees) - contract adjusts internally
    /// @param commands Encoded Universal Router command bytes
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @return ethReceived The amount of ETH received (after fees)
    function sell(
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external returns (uint256 ethReceived);

    /// @notice Swap between any two assets, always collecting fees in ETH
    /// @dev Executes two route legs with ETH fee harvest at the midpoint.
    ///      Supports: ERC20->ERC20, ERC20->ETH, ETH->ERC20.
    ///      For ETH-only trades, use buy() or sell() for lower gas.
    /// @param tokenIn Input token (address(0) for ETH)
    /// @param amountIn Input amount (ignored if ETH — uses msg.value)
    /// @param tokenOut Output token (address(0) for ETH)
    /// @param recipient Address to receive output
    /// @param minAmountOut Minimum final output after fees
    /// @param leg1Commands Route commands for tokenIn -> ETH (empty if input is ETH)
    /// @param leg1Inputs Route inputs for tokenIn -> ETH
    /// @param leg2Commands Route commands for ETH -> tokenOut (empty if output is ETH)
    /// @param leg2Inputs Route inputs for ETH -> tokenOut
    /// @param deadline Transaction deadline timestamp
    /// @return amountOut The amount of output received
    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        address recipient,
        uint256 minAmountOut,
        bytes calldata leg1Commands,
        bytes[] calldata leg1Inputs,
        bytes calldata leg2Commands,
        bytes[] calldata leg2Inputs,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    // ============================================
    // QUOTE FUNCTIONS
    // ============================================

    /// @notice Quote the fee breakdown for a given total fee
    /// @dev Fee percentages are read from the active distributor
    /// @param totalFee The total fee amount
    /// @return beneficiaryFee Fee to beneficiary
    /// @return protocolFee Fee to protocol
    function quoteFeeBreakdown(
        uint256 totalFee
    )
        external
        view
        returns (
            uint256 beneficiaryFee,
            uint256 protocolFee
        );

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @notice Register a token with its beneficiary (admin only)
    /// @param token The token address
    /// @param beneficiary The beneficiary address (receives "creator" fees)
    function registerToken(address token, address beneficiary) external;

    /// @notice Update Universal Router address
    /// @param _universalRouter New Universal Router address
    function setUniversalRouter(address _universalRouter) external;

    /// @notice Update the fee distributor module
    /// @param _feeDistributor New fee distributor contract
    function setFeeDistributor(address _feeDistributor) external;

    /// @notice Update the liquid registry module
    /// @param _liquidRegistry New liquid registry contract
    function setLiquidRegistry(address _liquidRegistry) external;

    /// @notice Remove a token from the registry
    /// @dev Clears the beneficiary mapping, blocking all trading
    /// @param token The token address
    function removeToken(address token) external;

    /// @notice Update a token's beneficiary
    /// @param token The token address
    /// @param newBeneficiary The new beneficiary address
    function updateBeneficiary(address token, address newBeneficiary) external;

    /// @notice Pause the contract (emergency stop)
    /// @dev Only callable by owner. Prevents buy(), sell(), and swap() operations.
    function pause() external;

    /// @notice Unpause the contract
    /// @dev Only callable by owner. Re-enables buy(), sell(), and swap() operations.
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

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Get the beneficiary for a token
    /// @param token The token address
    /// @return The beneficiary address
    function tokenBeneficiaries(address token) external view returns (address);

    /// @notice Get the Universal Router address
    /// @return The Universal Router address
    function universalRouter() external view returns (address);

    /// @notice Get the active fee distributor
    /// @return Distributor contract used for fee calculations and payout
    function feeDistributor() external view returns (address);

    /// @notice Get the active liquid registry
    /// @return Registry contract used for token registration and beneficiaries
    function liquidRegistry() external view returns (address);

    // Note: paused() is inherited from OpenZeppelin's Pausable contract
}
