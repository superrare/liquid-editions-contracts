// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title Liquid interface
interface ILiquid {
    /// @notice Thrown when an operation is attempted with a zero address
    error AddressZero();

    /// @notice Thrown when there are insufficient funds for an operation
    error InsufficientFunds();

    /// @notice Thrown when the user has insufficient token balance for a sell operation
    error InsufficientBalance();

    /// @notice Thrown when the slippage bounds are exceeded during a transaction
    error SlippageBoundsExceeded();

    /// @notice Thrown when slippage exceeds the configured limit during RARE burn
    error SlippageExceeded();

    /// @notice Thrown when an invalid slippage value is provided
    error InvalidSlippage();

    /// @notice Thrown when an invalid price is provided
    error InvalidPrice();

    /// @notice Thrown when the initial order size is too large
    error InitialOrderSizeTooLarge();

    /// @notice Thrown when the ETH amount is too small for a transaction
    error EthAmountTooSmall();

    /// @notice Thrown when an ETH transfer fails
    error EthTransferFailed();

    /// @notice Thrown when an operation is attempted by an entity other than the pool
    error OnlyPool();

    /// @notice Thrown when an operation is attempted by an entity other than the V4 PoolManager
    error OnlyPoolManager();

    /// @notice Thrown when an unexpected unlock callback is received (security guard)
    error UnexpectedUnlock();

    /// @notice Thrown when an operation is attempted by an entity other than the NonfungiblePositionManager
    error OnlyPositionManager();

    /// @notice Thrown when an operation is attempted outside of the mint period
    error OnlyDuringMint();

    /// @notice Thrown when an operation is attempted by an entity other than WETH
    error OnlyWETH();

    /// @notice Thrown when the tick lower is not less than the maximum tick or not a multiple of 200
    error InvalidTickLower();

    /// @notice Thrown when the tick range is invalid (lower >= upper)
    error InvalidTickRange();

    /// @notice Thrown when the fee distribution is invalid (must sum to exactly 10000 BPS / 100%)
    error InvalidFeeDistribution();

    /// @notice Thrown when an invalid token URI is provided
    error InvalidTokenURI();

    /// @notice Thrown when caller is not the factory
    error NotFactory();

    /// @notice Thrown when the quoter is unavailable
    error QuoterUnavailable();

    /// @notice Thrown when the pool has not been initialized yet
    error PoolNotInitialized();

    /// @notice Thrown when liquidity amount is zero
    error ZeroLiquidity();

    /// @notice Thrown when liquidity amount exceeds maximum allowed value
    error LiquidityTooLarge(uint256 liquidity);

    /// @notice Thrown when swap delta0 has invalid sign (expected negative for buys, positive for sells)
    error InvalidSwapDelta0(int128 delta0);

    /// @notice Thrown when swap delta1 has invalid sign (expected positive for buys, negative for sells)
    error InvalidSwapDelta1(int128 delta1);

    /// @notice Thrown when a value exceeds uint128 maximum
    error AmountExceedsUint128(uint256 value);

    /// @notice Thrown when a value is negative but should be non-negative
    error NegativeValue(int128 value);

    /// @notice Thrown when a value is positive but should be non-positive
    error PositiveValue(int128 value);

    /// @notice Thrown when a buy swap partially fills due to price limit
    /// @param requested The amount of ETH requested to swap
    /// @param consumed The amount of ETH actually consumed by the pool
    error PartialFillBuy(uint256 requested, uint256 consumed);

    /// @notice Thrown when quote simulation completes without reverting (unexpected behavior)
    /// @dev Quote simulations use a revert-as-return pattern and should always revert
    error QuoteSimulationDidNotRevert();

    /// @notice Revert-as-return pattern for quote simulations
    /// @dev Not a real error - used to return quote results from simulation callbacks
    /// @param amountOut The simulated output amount from the swap
    /// @param sqrtPriceX96After The sqrt price after the simulated swap
    error QuoteResult(uint256 amountOut, uint160 sqrtPriceX96After);

    /// @notice The rewards accrued from the market's liquidity position
    struct MarketRewards {
        uint256 totalAmountCurrency;
        uint256 creatorPayoutAmountCurrency;
        uint256 protocolAmountCurrency;
    }

    /// @notice Emitted when market rewards are distributed
    /// @param tokenCreator The address of the token creator
    /// @param orderReferrer The address of the order referrer (address(0) for secondary rewards)
    /// @param protocolFeeRecipient The address of the protocol fee recipient
    /// @param rareBurnFee The ACTUAL amount deposited to RARE burner (0 if failed/not configured)
    /// @param tokenCreatorFee The ACTUAL amount transferred to token creator (0 if transfer failed)
    /// @param orderReferrerFee The ACTUAL amount transferred to order referrer (0 if transfer failed)
    /// @param protocolFee The ACTUAL amount transferred to protocol (includes fallback from failed transfers)
    event LiquidMarketRewards(
        address indexed tokenCreator,
        address indexed orderReferrer,
        address protocolFeeRecipient,
        uint256 rareBurnFee,
        uint256 tokenCreatorFee,
        uint256 orderReferrerFee,
        uint256 protocolFee
    );

    /// @notice Emitted when deferred LIQUID rewards are successfully swapped to WETH
    /// @param amountIn The amount of LIQUID tokens swapped
    /// @param minOut The minimum WETH output expected (based on quote and slippage tolerance)
    /// @param amountOut The actual WETH amount received
    event SecondaryRewardsSwap(
        uint256 amountIn,
        uint256 minOut,
        uint256 amountOut
    );

    /// @notice Emitted when LIQUID rewards conversion is deferred due to slippage breach or swap failure
    /// @param totalPending The total amount of LIQUID deferred (including new collection)
    /// @param minOut The minimum WETH output that would have been required
    /// @param slippageBps The slippage tolerance that was breached
    event SecondaryRewardsDeferred(
        uint256 totalPending,
        uint256 minOut,
        uint16 slippageBps
    );

    /// @notice Emitted when a fee transfer fails and is forwarded to protocol
    /// @param recipient The intended recipient whose transfer failed
    /// @param amount The amount that failed to transfer
    /// @param reason The reason for the failure (creator, referrer, or secondary)
    event FeeTransferFailed(
        address indexed recipient,
        uint256 amount,
        string reason
    );

    /// @notice Emitted when a secondary reward transfer fails
    /// @param recipient The intended recipient whose transfer failed
    /// @param amount The amount that failed to transfer
    event SecondaryRewardTransferFailed(
        address indexed recipient,
        uint256 amount
    );

    /// @notice Emitted when a Liquid token is bought
    /// @param buyer The address of the buyer
    /// @param recipient The address of the recipient
    /// @param orderReferrer The address of the order referrer
    /// @param totalEth The total ETH involved in the transaction
    /// @param ethFee The ETH fee for the transaction
    /// @param ethSold The amount of ETH sold
    /// @param tokensBought The number of tokens bought
    /// @param buyerTokenBalance The token balance of the buyer after the transaction
    /// @param totalSupply The total supply of tokens after the buy
    /// @param startPrice The sqrt price (Q64.96) of the pool before the swap
    /// @param endPrice The sqrt price (Q64.96) of the pool after the swap
    /// @param protocolFee The ACTUAL protocol fee amount transferred (includes fallback from failed transfers)
    /// @param referrerFee The ACTUAL referrer fee amount transferred (0 if transfer failed)
    /// @param creatorFee The ACTUAL creator fee amount transferred (0 if transfer failed)
    /// @param burnFee The ACTUAL RARE burn fee amount deposited (0 if failed/not configured)
    event LiquidBuy(
        address indexed buyer,
        address indexed recipient,
        address indexed orderReferrer,
        uint256 totalEth,
        uint256 ethFee,
        uint256 ethSold,
        uint256 tokensBought,
        uint256 buyerTokenBalance,
        uint256 totalSupply,
        uint160 startPrice,
        uint160 endPrice,
        uint256 protocolFee,
        uint256 referrerFee,
        uint256 creatorFee,
        uint256 burnFee
    );

    /// @notice Emitted when a Liquid token is sold
    /// @param seller The address of the seller
    /// @param recipient The address of the recipient
    /// @param orderReferrer The address of the order referrer
    /// @param totalEth The total ETH involved in the transaction
    /// @param ethFee The ETH fee for the transaction
    /// @param ethBought The amount of ETH bought
    /// @param tokensSold The number of tokens sold
    /// @param sellerTokenBalance The token balance of the seller after the transaction
    /// @param totalSupply The total supply of tokens after the sell
    /// @param startPrice The sqrt price (Q64.96) of the pool before the swap
    /// @param endPrice The sqrt price (Q64.96) of the pool after the swap
    /// @param protocolFee The ACTUAL protocol fee amount transferred (includes fallback from failed transfers)
    /// @param referrerFee The ACTUAL referrer fee amount transferred (0 if transfer failed)
    /// @param creatorFee The ACTUAL creator fee amount transferred (0 if transfer failed)
    /// @param burnFee The ACTUAL RARE burn fee amount deposited (0 if failed/not configured)
    event LiquidSell(
        address indexed seller,
        address indexed recipient,
        address indexed orderReferrer,
        uint256 totalEth,
        uint256 ethFee,
        uint256 ethBought,
        uint256 tokensSold,
        uint256 sellerTokenBalance,
        uint256 totalSupply,
        uint160 startPrice,
        uint160 endPrice,
        uint256 protocolFee,
        uint256 referrerFee,
        uint256 creatorFee,
        uint256 burnFee
    );

    /// @notice Emitted when Liquid tokens are transferred
    /// @param from The address of the sender
    /// @param to The address of the recipient
    /// @param amount The amount of tokens transferred
    /// @param fromTokenBalance The token balance of the sender after the transfer
    /// @param toTokenBalance The token balance of the recipient after the transfer
    /// @param totalSupply The total supply of tokens after the transfer
    event LiquidTransfer(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fromTokenBalance,
        uint256 toTokenBalance,
        uint256 totalSupply
    );

    /// @notice Emitted when fees are distributed
    /// @param tokenCreator The address of the token creator
    /// @param orderReferrer The address of the order referrer
    /// @param protocolFeeRecipient The address of the protocol fee recipient
    /// @param rareBurnFee The ACTUAL amount deposited to RARE burner (0 if failed/not configured)
    /// @param tokenCreatorFee The ACTUAL amount transferred to token creator (0 if transfer failed)
    /// @param orderReferrerFee The ACTUAL amount transferred to order referrer (0 if transfer failed)
    /// @param protocolFee The ACTUAL amount transferred to protocol (includes fallback from failed transfers)
    event LiquidFees(
        address indexed tokenCreator,
        address indexed orderReferrer,
        address protocolFeeRecipient,
        uint256 rareBurnFee,
        uint256 tokenCreatorFee,
        uint256 orderReferrerFee,
        uint256 protocolFee
    );

    /// @notice Emitted when ETH is deposited to the burner accumulator
    /// @dev Provides transaction-level attribution for RARE burn deposits from this Liquid token
    /// @param liquidToken The address of this Liquid token (indexed for filtering)
    /// @param burnerAccumulator The address of the RAREBurner receiving the deposit
    /// @param ethAmount The exact amount of ETH deposited for burning
    /// @param depositSuccess Whether the deposit to the accumulator succeeded
    event BurnerDeposit(
        address indexed liquidToken,
        address indexed burnerAccumulator,
        uint256 ethAmount,
        bool depositSuccess
    );

    /// @notice Emitted when a market graduates
    /// @param tokenAddress The address of the token
    /// @param poolAddress The address of the pool
    /// @param totalEthLiquidity The total ETH liquidity in the pool
    /// @param totalTokenLiquidity The total token liquidity in the pool
    /// @param lpPositionId The ID of the liquidity position
    event LiquidMarketGraduated(
        address indexed tokenAddress,
        address indexed poolAddress,
        uint256 totalEthLiquidity,
        uint256 totalTokenLiquidity,
        uint256 lpPositionId
    );

    /// @notice Executes an order to buy liquid tokens with ETH
    /// @param recipient The recipient address of the liquid tokens
    /// @param orderReferrer The address of the order referrer
    /// @param minOrderSize The minimum liquid tokens to prevent slippage
    /// @param sqrtPriceLimitX96 The price limit for Uniswap V4 pool swap
    function buy(
        address recipient,
        address orderReferrer,
        uint256 minOrderSize,
        uint160 sqrtPriceLimitX96
    ) external payable returns (uint256);

    /// @notice Executes an order to sell liquid tokens for ETH
    /// @param amount The number of liquid tokens to sell
    /// @param recipient The address to receive the ETH
    /// @param orderReferrer The address of the order referrer
    /// @param minPayoutSize The minimum ETH payout to prevent slippage
    /// @param sqrtPriceLimitX96 The price limit for Uniswap V4 pool swap
    function sell(
        uint256 amount,
        address recipient,
        address orderReferrer,
        uint256 minPayoutSize,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256);

    /// @notice Enables a user to burn their tokens
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external;

    /// @notice Returns the URI of the token
    /// @return The token URI
    function tokenUri() external view returns (string memory);

    /// @notice Returns the address of the token creator
    /// @return The token creator's address
    function tokenCreator() external view returns (address);

    /// @notice Returns the current raw pool price (no fees) in both directions
    /// @dev Reads directly from Uniswap V4 pool slot0. Returns WEI values scaled to 1e18.
    /// @return ethPerToken WEI of ETH per 1e18 tokens
    /// @return tokenPerEth WEI of tokens per 1e18 ETH
    function getCurrentPrice()
        external
        view
        returns (uint256 ethPerToken, uint256 tokenPerEth);

    /// @notice Returns the amount of pending LIQUID rewards awaiting conversion
    /// @dev These rewards accumulate when secondary reward swaps are deferred due to slippage
    /// @return The amount of pending LIQUID tokens
    function pendingRewardsLiquid() external view returns (uint256);

    /// @notice Harvests accrued LP fees and distributes them to fee recipients
    /// @dev Collects ETH and LIQUID fees from the V4 LP position, converts LIQUID to ETH (with
    ///      slippage protection), then distributes the combined ETH to fee recipients.
    ///      This function can be called by anyone. The caller must provide the current sqrt price
    ///      and slippage tolerance to protect against sandwich attacks.
    /// @param currentSqrtPriceX96 The current sqrt price from pool (queried off-chain before tx submission)
    /// @param slippageBps Maximum acceptable slippage in basis points (e.g., 100 = 1%, 500 = 5%)
    function harvestSecondaryRewards(
        uint160 currentSqrtPriceX96,
        uint16 slippageBps
    ) external;

    /// @notice Returns the current sqrt price and recommended price limit for harvest slippage control
    /// @param slippageBps Maximum acceptable slippage in basis points (e.g., 100 = 1%, 500 = 5%)
    /// @return currentSqrtPriceX96 The current pool sqrt price
    /// @return sqrtPriceLimitX96 The calculated sqrt price limit for LIQUID->ETH conversion
    function quoteHarvestParams(
        uint16 slippageBps
    )
        external
        view
        returns (uint160 currentSqrtPriceX96, uint160 sqrtPriceLimitX96);

    /// @notice Executes a buy order and harvests secondary rewards in a single transaction
    /// @dev Combines buy() and harvestSecondaryRewards() atomically.
    ///      Use this function when you want to collect accumulated LP fees during your buy.
    /// @param recipient The recipient address of the liquid tokens
    /// @param orderReferrer The address of the order referrer (receives referrer fee)
    /// @param minOrderSize The minimum liquid tokens to prevent slippage (user-specified, 0 = no protection)
    /// @param sqrtPriceLimitX96Buy The price limit for the buy swap (0 = no limit)
    /// @param preBuySqrtPriceX96 The sqrt price before buy (for harvest slippage calc, 0 = skip harvest)
    /// @param harvestSlippageBps The slippage tolerance for harvest swap in basis points (ignored if preBuySqrtPriceX96 = 0)
    /// @return trueOrderSize The actual amount of liquid tokens received
    function buyAndHarvest(
        address recipient,
        address orderReferrer,
        uint256 minOrderSize,
        uint160 sqrtPriceLimitX96Buy,
        uint160 preBuySqrtPriceX96,
        uint16 harvestSlippageBps
    ) external payable returns (uint256);
}
