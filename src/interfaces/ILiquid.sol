// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title Liquid interface
interface ILiquid {
    /// @notice Thrown when an operation is attempted with a zero address
    error AddressZero();

    /// @notice Thrown when the user has insufficient token balance for a sell operation
    error InsufficientBalance();

    /// @notice Thrown when the RARE token amount provided for initial liquidity is too small
    error RARELiquidityTooSmall();

    /// @notice Thrown when an ETH transfer fails
    error EthTransferFailed();

    /// @notice Thrown when an operation is attempted by an entity other than the V4 PoolManager
    error OnlyPoolManager();

    /// @notice Thrown when an unexpected unlock callback is received (security guard)
    error UnexpectedUnlock();

    /// @notice Thrown when the tick range is invalid (lower >= upper)
    error InvalidTickRange();

    /// @notice Thrown when the fee distribution is invalid (must sum to exactly 10000 BPS / 100%)
    error InvalidFeeDistribution();

    /// @notice Thrown when an invalid token URI is provided
    error InvalidTokenURI();

    /// @notice Thrown when caller is not the token creator
    error NotTokenCreator();

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

    /// @notice Thrown when caller is not the protocol fee recipient
    error OnlyProtocolFeeRecipient();

    /// @notice Thrown when quote simulation completes without reverting (unexpected behavior)
    /// @dev Quote simulations use a revert-as-return pattern and should always revert
    error QuoteSimulationDidNotRevert();

    /// @notice Revert-as-return pattern for quote simulations
    /// @dev Not a real error - used to return quote results from simulation callbacks
    /// @param amountOut The simulated output amount from the swap
    /// @param sqrtPriceX96After The sqrt price after the simulated swap
    error QuoteResult(uint256 amountOut, uint160 sqrtPriceX96After);

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

    /// @notice Emitted when a market graduates
    /// @param tokenAddress The address of the token
    /// @param poolAddress The address of the pool
    /// @param totalRareLiquidity The total RARE liquidity in the pool
    /// @param totalTokenLiquidity The total token liquidity in the pool
    /// @param lpPositionId The ID of the liquidity position
    event LiquidMarketGraduated(
        address indexed tokenAddress,
        address indexed poolAddress,
        uint256 totalRareLiquidity,
        uint256 totalTokenLiquidity,
        uint256 lpPositionId
    );

    /// @notice Emitted when liquidity is removed from the pool
    /// @param recipient The address that received the withdrawn tokens
    /// @param amount0 Amount of currency0 withdrawn
    /// @param amount1 Amount of currency1 withdrawn
    event LiquidityRemoved(address indexed recipient, uint256 amount0, uint256 amount1);

    /// @notice Emitted when the render contract is set
    /// @param renderContract The address of the render contract
    event RenderContractSet(address indexed renderContract);

    /// @notice Enables a user to burn their tokens
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external;

    /// @notice Removes all LP liquidity and sends underlying tokens to recipient
    /// @dev Only callable by factory's protocolFeeRecipient
    /// @param recipient Address to receive the withdrawn tokens
    function removeLiquidity(address recipient) external;

    /// @notice Returns the initial URI of the token
    /// @return The initial token URI
    function initialTokenUri() external view returns (string memory);

    /// @notice ERC-1046 compatible tokenURI function
    /// @dev Returns metadata URI, checking render contract first if set
    /// @return The token URI (from render contract if set, otherwise stored initialTokenUri)
    function tokenURI() external view returns (string memory);

    /// @notice Sets the render contract address (only callable by token creator)
    /// @param _renderContract The address of the render contract (can be address(0) to clear)
    function setRenderContract(address _renderContract) external;

    /// @notice Returns the address of the token creator
    /// @return The token creator's address
    function tokenCreator() external view returns (address);

    /// @notice Returns the base token address (RARE)
    /// @return The base token address
    function baseToken() external view returns (address);

    /// @notice Returns the factory address
    /// @return The factory address
    function factory() external view returns (address);

    /// @notice Returns the render contract address
    /// @return The render contract address (address(0) if not set)
    function renderContract() external view returns (address);

    /// @notice Returns the pool manager address
    /// @return The Uniswap V4 PoolManager address
    function poolManager() external view returns (address);

    /// @notice Returns the maximum total supply of tokens
    /// @return The maximum total supply (1,000,000 tokens)
    function MAX_TOTAL_SUPPLY() external view returns (uint256);

    /// @notice Returns the lower tick bound for LP position
    /// @return The lower tick bound
    function lpTickLower() external view returns (int24);

    /// @notice Returns the upper tick bound for LP position
    /// @return The upper tick bound
    function lpTickUpper() external view returns (int24);

    /// @notice Returns the LP position liquidity amount
    /// @return The liquidity amount
    function lpLiquidity() external view returns (uint128);

    /// @notice Returns the current raw pool price (no fees) in both directions
    /// @dev Reads directly from Uniswap V4 pool slot0. Returns WEI values scaled to 1e18.
    ///      Price is in RARE (base token), not ETH. Use client-side quoter for ETH prices.
    /// @return rarePerToken WEI of RARE per 1e18 tokens
    /// @return tokenPerRare WEI of tokens per 1e18 RARE
    function getCurrentPrice()
        external
        view
        returns (uint256 rarePerToken, uint256 tokenPerRare);

    /// @notice Returns all market state for rendering in a single call
    /// @dev Useful for render contracts and frontends that need multiple data points.
    ///      Combines price, pool state, and supply info to minimize RPC calls.
    /// @return rarePerToken Current price (RARE per 1e18 LIQUID tokens)
    /// @return tokenPerRare Inverse price (LIQUID tokens per 1e18 RARE)
    /// @return sqrtPriceX96 Raw Uniswap pool price (Q64.96 format)
    /// @return currentTick Current tick position in the pool
    /// @return liquidity Current total pool liquidity
    /// @return currentSupply Total tokens in circulation (totalSupply())
    function getMarketState()
        external
        view
        returns (
            uint256 rarePerToken,
            uint256 tokenPerRare,
            uint160 sqrtPriceX96,
            int24 currentTick,
            uint128 liquidity,
            uint256 currentSupply
        );

    /// @notice Simulates a RARE to LIQUID swap (buy direction)
    /// @dev Simulates the swap via unlock callback. Uses revert-as-return pattern for gas-free simulation.
    ///      Not marked `view` (simulation reverts-to-return); use via eth_call.
    ///      Note: This quotes a direct RARE→LIQUID swap. For ETH→RARE→LIQUID routes, use LiquidRouter or client-side quoter.
    ///      Fees are handled by LiquidRouter during actual trades.
    /// @param rareIn Amount of RARE to swap
    /// @return liquidOut LIQUID tokens that would be received from the swap
    /// @return sqrtPriceX96After Post-swap sqrt price (useful for price impact calculations)
    function quoteBuy(
        uint256 rareIn
    ) external returns (uint256 liquidOut, uint160 sqrtPriceX96After);

    /// @notice Simulates a LIQUID to RARE swap (sell direction)
    /// @dev Simulates the swap via unlock callback. Uses revert-as-return pattern for gas-free simulation.
    ///      Not marked `view` (simulation reverts-to-return); use via eth_call.
    ///      Note: This quotes a direct LIQUID→RARE swap. For LIQUID→RARE→ETH routes, use LiquidRouter or client-side quoter.
    ///      Fees are handled by LiquidRouter during actual trades.
    /// @param liquidIn Amount of LIQUID tokens to swap
    /// @return rareOut RARE that would be received from the swap
    /// @return sqrtPriceX96After Post-swap sqrt price (useful for price impact calculations)
    function quoteSell(
        uint256 liquidIn
    ) external returns (uint256 rareOut, uint160 sqrtPriceX96After);
}
