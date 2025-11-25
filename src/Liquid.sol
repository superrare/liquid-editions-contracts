// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

import {ILiquid} from "./interfaces/ILiquid.sol";
import {ILiquidFactory} from "./interfaces/ILiquidFactory.sol";
import {IRAREBurner} from "./interfaces/IRAREBurner.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {QuoterRevert} from "@uniswap/v4-periphery/libraries/QuoterRevert.sol";

/*                                    
  _       _____  ____   _    _  _____  _____  
 | |     |_   _|/ __ \ | |  | ||_   _||  __ \ 
 | |       | | | |  | || |  | |  | |  | |  | |
 | |       | | | |  | || |  | |  | |  | |  | |
 | |____  _| |_| |__| || |__| | _| |_ | |__| |
 |______||_____|\___\_\ \____/ |_____||_____/ 

*/

/// @title Liquid
/// @notice A liquid edition token with automated market making on Uniswap V4
/// @dev Implements a bonding curve with immediate Uniswap V4 pool creation, fee distribution, and optional RARE token burn mechanism.
///      Uses a clone pattern for gas-efficient deployment via LiquidFactory.
///      All tokens are minted at creation.
contract Liquid is
    ILiquid,
    ERC20Upgradeable,
    ReentrancyGuardUpgradeable,
    IUnlockCallback
{
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using QuoterRevert for bytes;

    // ============================================
    // TOKEN SUPPLY CONSTANTS
    // ============================================

    /// @notice Maximum total supply of liquid tokens
    /// @dev All tokens are minted at initialization
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000e18;

    /// @notice Amount of tokens allocated to Uniswap V4 pool at launch
    /// @dev These tokens provide the initial liquidity for trading
    uint256 internal constant POOL_LAUNCH_SUPPLY = 900_000e18;

    /// @notice Amount of tokens rewarded to creator at launch
    /// @dev Immediately transferred to creator as launch reward
    uint256 internal constant CREATOR_LAUNCH_REWARD = 100_000e18;

    // ============================================
    // TRADING & FEE CONSTANTS
    // ============================================

    // ============================================
    // FEE STRUCTURE (THREE-TIER SYSTEM)
    // ============================================
    //
    // TIER 1: Total Fee Collection
    // The total trading fee collected from each buy/sell transaction.
    // This is a percentage of the trade amount (e.g., 1% = 100 BPS).
    // Set once at token deployment and cannot be changed.
    //
    // TIER 2: Creator Fee Allocation
    // The token creator's fixed share of collected fees (e.g., 25% = 2500 BPS).
    // Calculated as: creatorAmount = totalCollectedFee * TOKEN_CREATOR_FEE_BPS / 10000
    // Set once at token deployment and cannot be changed.
    //
    // TIER 3: Remainder Distribution
    // After creator fee is paid, remaining fees are split among:
    //   - RARE Burn (rareBurnFeeBPS)
    //   - Protocol (protocolFeeBPS)
    //   - Order Referrer (referrerFeeBPS)
    // These percentages MUST sum to exactly 10000 BPS (100%).
    // These are synced from factory config and can be updated via factory.pushConfig().
    //
    // Example with 100 ETH trade, 1% total fee, 25% creator, 50%/30%/20% split:
    //   - Total collected: 1 ETH (1% of 100 ETH)
    //   - Creator: 0.25 ETH (25% of 1 ETH)
    //   - Remaining: 0.75 ETH
    //   - Burn: 0.375 ETH (50% of 0.75 ETH)
    //   - Protocol: 0.225 ETH (30% of 0.75 ETH)
    //   - Referrer: 0.15 ETH (20% of 0.75 ETH)

    /// @notice Total trading fee in basis points (e.g., 1% = 100 BPS)
    /// @dev Applied to both buy and sell orders. Set once at initialization.
    uint256 public TOTAL_FEE_BPS;

    /// @notice Token creator's fixed share of total fees in basis points (e.g., 25% = 2500 BPS)
    /// @dev Applied to total collected fees (TIER 2). Set once at initialization.
    uint256 public TOKEN_CREATOR_FEE_BPS;

    /// @notice Uniswap V4 pool fee tier (1% = 10000)
    /// @dev This is the liquidity pool's swap fee, separate from TOTAL_FEE_BPS
    uint24 internal constant LP_FEE = 10000;

    /// @notice Gas limit for external fee transfers (creator/referrer) to prevent griefing
    /// @dev Prevents malicious receivers from consuming all gas and reverting the trade.
    ///      50,000 gas is sufficient for standard ETH transfers (21,000) plus basic receiver
    ///      logic (events/logging), but prevents griefing by limiting forwarded gas.
    uint256 internal constant GAS_LIMIT_TRANSFER = 50000;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Factory address set at initialization
    /// @dev Used to pull configuration values directly from factory at call time
    address public factory;

    /// @notice WETH address set at initialization
    /// @dev Set once during initialization and never changes
    address public weth;

    /// @notice Accumulator for deferred LIQUID rewards that failed to be converted
    /// @dev Only accumulates LIQUID tokens. ETH rewards are distributed immediately
    uint256 private _pendingRewardsLiquid;

    /// @notice Address of the token creator
    address public tokenCreator;

    /// @notice Metadata URI for the token
    string public tokenUri;

    /// @notice Uniswap V4 PoolKey for this token's pool
    PoolKey public poolKey;

    /// @notice Uniswap V4 PoolId (derived from PoolKey)
    PoolId public poolId;

    /// @notice PoolManager address cached from factory
    address public poolManager;

    /// @notice Tick lower bound for LP position
    int24 public lpTickLower;

    /// @notice Tick upper bound for LP position
    int24 public lpTickUpper;

    /// @notice Position liquidity amount
    uint128 public lpLiquidity;

    // ============================================
    // UNLOCK CALLBACK STATE
    // ============================================

    enum UnlockAction {
        INITIALIZE_POOL,
        ADD_LIQUIDITY,
        SWAP_BUY,
        SWAP_SELL,
        QUOTE_SWAP_BUY,
        QUOTE_SWAP_SELL,
        SWAP_REWARDS,
        COLLECT_FEES
    }

    struct UnlockContext {
        UnlockAction action;
        bytes data;
    }

    /// @notice Guard to ensure unlock callbacks are only called during expected operations
    bool private _unlockExpected;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Constructor disables initialization on the implementation contract
    /// @dev Clones (EIP-1167) have separate storage and can still call initialize().
    ///      This prevents accidental or confusing usage of the implementation instance.
    constructor() {
        // Disable initialization on the implementation contract to prevent misuse
        // Clones (EIP-1167) have separate storage and can still call initialize()
        _disableInitializers();
    }

    // ============================================
    // INITIALIZATION
    // ============================================

    /// @notice Initializes a new liquid token
    /// @dev Called once by factory after cloning. Creates Uniswap V4 pool, mints all tokens, and performs optional auto-buy.
    ///      Configuration is read directly from factory at call time (no caching).
    /// @param _creator The address of the liquid token creator (receives fees and launch reward)
    /// @param _tokenUri The location of token metadata
    /// @param _name The liquid token name
    /// @param _symbol The liquid token symbol
    /// @param _totalFeeBPS The total trading fee in basis points (TIER 1)
    /// @param _creatorFeeBPS The creator's share of fees in basis points (TIER 2)
    /// @param _minInitialLiquidityWei The minimum ETH required to bootstrap the pool
    function initialize(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _totalFeeBPS,
        uint256 _creatorFeeBPS,
        uint256 _minInitialLiquidityWei
    ) public payable initializer {
        // Store factory address (msg.sender is factory during initialization)
        factory = msg.sender;

        // Read config from factory
        ILiquidFactory factoryContract = ILiquidFactory(factory);
        weth = factoryContract.weth();
        poolManager = factoryContract.poolManager();
        if (weth == address(0) || poolManager == address(0))
            revert AddressZero();

        // Validate that token URI is not empty string
        if (bytes(_tokenUri).length == 0) {
            revert InvalidTokenURI();
        }

        // Set immutable fee parameters
        TOTAL_FEE_BPS = _totalFeeBPS;
        TOKEN_CREATOR_FEE_BPS = _creatorFeeBPS;

        // Validate fees don't exceed 100%
        if (
            factoryContract.rareBurnFeeBPS() +
                factoryContract.protocolFeeBPS() +
                factoryContract.referrerFeeBPS() !=
            10000
        ) {
            revert InvalidFeeDistribution();
        }

        // Require minimum ETH to bootstrap the pool with two-sided liquidity
        // _minInitialLiquidityWei provides initial ETH liquidity. Any excess is used for auto-buy
        if (msg.value < _minInitialLiquidityWei) {
            revert EthAmountTooSmall();
        }

        // Validate the creation parameters
        if (_creator == address(0)) {
            revert AddressZero();
        }

        // Initialize base contracts (ERC20 and reentrancy guard)
        __ERC20_init(_name, _symbol);
        __ReentrancyGuard_init();

        // Initialize liquid token state
        tokenCreator = _creator;
        tokenUri = _tokenUri;

        // Mint the entire total supply to this contract
        _mint(address(this), MAX_TOTAL_SUPPLY);

        // Distribute launch rewards to creator
        _transfer(address(this), _creator, CREATOR_LAUNCH_REWARD);

        // Deploy Uniswap V4 pool with two-sided liquidity (LIQUID + ETH)
        // All provided ETH is used for initial liquidity
        _deployPool(msg.value);
    }

    // ============================================
    // TRADING FUNCTIONS
    // ============================================

    /// @notice Executes an order to buy liquid tokens with ETH (does NOT harvest secondary rewards)
    /// @dev Deducts trading fee, swaps ETH for tokens on Uniswap V4, and distributes primary fees.
    ///      This function is gas-efficient as it skips secondary reward harvesting.
    ///      Use buyAndHarvest() if you want to collect LP fees in the same transaction.
    ///      NOTE: This function does NOT apply quoter-based slippage protection. Users may specify
    ///      their own minOrderSize to protect against slippage. This design is intentional for bonding
    ///      curve behavior, where early buyers may accept high slippage for cheap tokens (low initial liquidity).
    ///
    ///      ATOMICITY: This function enforces all-or-nothing execution. If the swap cannot consume all
    ///      ETH (after fees) due to price limits or liquidity constraints, the entire transaction reverts
    ///      with PartialFillBuy. Use quoteBuy() to determine appropriate sqrtPriceLimitX96 values that
    ///      allow full execution while protecting against excessive price movement.
    /// @param recipient The recipient address of the liquid tokens
    /// @param orderReferrer The address of the order referrer (receives referrer fee)
    /// @param minOrderSize The minimum liquid tokens to prevent slippage (user-specified, 0 = no protection)
    /// @param sqrtPriceLimitX96 The price limit for Uniswap V4 pool swap (0 = no limit)
    /// @return trueOrderSize The actual amount of liquid tokens received
    function buy(
        address recipient,
        address orderReferrer,
        uint256 minOrderSize,
        uint160 sqrtPriceLimitX96
    ) public payable nonReentrant returns (uint256) {
        return _buy(recipient, orderReferrer, minOrderSize, sqrtPriceLimitX96);
    }

    /// @notice Internal implementation of buy logic (swap + primary fees only, no secondary rewards)
    /// @dev Called by buy() and buyAndHarvest().
    /// @param recipient The recipient address of the liquid tokens
    /// @param orderReferrer The address of the order referrer (receives referrer fee)
    /// @param minOrderSize The minimum liquid tokens to prevent slippage (user-specified, 0 = no protection)
    /// @param sqrtPriceLimitX96 The price limit for Uniswap V4 pool swap (0 = no limit)
    /// @return trueOrderSize The actual amount of liquid tokens received
    function _buy(
        address recipient,
        address orderReferrer,
        uint256 minOrderSize,
        uint160 sqrtPriceLimitX96
    ) internal returns (uint256) {
        // Pull minimum order size directly from factory
        if (msg.value < ILiquidFactory(factory).minOrderSizeWei()) {
            revert EthAmountTooSmall();
        }

        // Ensure the recipient is not the zero address
        if (recipient == address(0)) {
            revert AddressZero();
        }

        // Calculate the trading fee
        uint256 fee = _calculateFee(msg.value, TOTAL_FEE_BPS);

        // Calculate the remaining ETH after fee for swap
        uint256 costAfterFee = msg.value - fee;

        // Capture start price before swap
        IPoolManager pm = IPoolManager(poolManager);
        (uint160 startPrice, , , ) = pm.getSlot0(poolId);

        // Distribute fees to creator, referrer, and protocol (and optionally RARE burn)
        (
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 creatorFee,
            uint256 burnFee
        ) = _disperseFees(fee, orderReferrer);

        // Execute swap (ETH -> LIQUID)
        uint256 trueOrderSize = _swapExactInputETHForTokens(
            costAfterFee,
            minOrderSize,
            sqrtPriceLimitX96,
            recipient
        );

        // Capture end price after swap
        (uint160 endPrice, , , ) = pm.getSlot0(poolId);

        // Emit detailed event for indexing and tracking
        emit LiquidBuy(
            msg.sender,
            recipient,
            orderReferrer,
            msg.value,
            fee,
            costAfterFee,
            trueOrderSize,
            balanceOf(recipient),
            totalSupply(),
            startPrice,
            endPrice,
            protocolFee,
            referrerFee,
            creatorFee,
            burnFee
        );

        return trueOrderSize;
    }

    /// @notice Executes an order to sell liquid tokens for ETH
    /// @dev Swaps tokens for ETH on Uniswap V4, deducts fee, and sends to recipient.
    ///      NOTE: This function does NOT apply quoter-based slippage protection. Users must specify
    ///      their own minPayoutSize to protect against slippage. This design is intentional for bonding
    ///      curve behavior, where sells may experience high slippage due to low initial liquidity.
    ///
    ///      IMPORTANT: Callers do NOT need to approve tokens before calling this function. The contract
    ///      handles token transfers internally via ERC20's internal _transfer() mechanism, which differs
    ///      from the typical "approve + transferFrom" pattern used by most DEX routers. This is safe
    ///      because this contract is the token itself, not an external router.
    /// @param amount The number of liquid tokens to sell
    /// @param recipient The address to receive the ETH
    /// @param orderReferrer The address of the order referrer (receives referrer fee)
    /// @param minPayoutSize The minimum ETH payout to prevent slippage (user-specified, 0 = no protection)
    /// @param sqrtPriceLimitX96 The price limit for Uniswap V4 pool swap (0 = no limit)
    /// @return payoutAfterFee The actual ETH amount received by recipient (after fees)
    function sell(
        uint256 amount,
        address recipient,
        address orderReferrer,
        uint256 minPayoutSize,
        uint160 sqrtPriceLimitX96
    ) external nonReentrant returns (uint256) {
        // Ensure the sender has enough tokens to sell
        if (amount > balanceOf(msg.sender)) {
            revert InsufficientBalance();
        }

        // Ensure the recipient is not the zero address
        if (recipient == address(0)) {
            revert AddressZero();
        }

        // Capture start price before swap
        IPoolManager pm = IPoolManager(poolManager);
        (uint160 startPrice, , , ) = pm.getSlot0(poolId);

        // Execute Uniswap V4 swap: LIQUID -> ETH
        // Note: Pass 0 for minOut to validate slippage after fee deduction
        uint256 truePayoutSize = _swapExactInputTokensForETH(
            amount,
            0,
            sqrtPriceLimitX96,
            msg.sender
        );

        // Capture end price after swap
        (uint160 endPrice, , , ) = pm.getSlot0(poolId);

        // Calculate the trading fee (1% of payout)
        uint256 fee = _calculateFee(truePayoutSize, TOTAL_FEE_BPS);

        // Calculate the payout after fee deduction
        uint256 payoutAfterFee = truePayoutSize - fee;

        // Validate slippage protection AFTER fee deduction
        // This ensures users receive at least their specified minimum after all fees
        if (payoutAfterFee < minPayoutSize) revert SlippageExceeded();

        // Distribute fees to creator, referrer, and protocol (and optionally RARE burn)
        (
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 creatorFee,
            uint256 burnFee
        ) = _disperseFees(fee, orderReferrer);

        // Send the ETH payout to the recipient
        (bool success, ) = recipient.call{value: payoutAfterFee}("");
        if (!success) revert EthTransferFailed();

        // Emit detailed event for indexing and tracking
        emit LiquidSell(
            msg.sender,
            recipient,
            orderReferrer,
            truePayoutSize,
            fee,
            payoutAfterFee,
            amount,
            balanceOf(msg.sender),
            totalSupply(),
            startPrice,
            endPrice,
            protocolFee,
            referrerFee,
            creatorFee,
            burnFee
        );

        return payoutAfterFee;
    }

    /// @notice Enables a user to burn their tokens
    /// @dev Standard ERC20 burn function, reduces total supply permanently
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Returns the amount of pending LIQUID rewards awaiting conversion
    /// @dev These rewards accumulate when secondary reward swaps are deferred due to slippage.
    ///      Callers can use this value with quoteSell() off-chain to determine appropriate price limits.
    /// @return The amount of pending LIQUID tokens
    function pendingRewardsLiquid() external view returns (uint256) {
        return _pendingRewardsLiquid;
    }

    /// @notice Harvests accrued LP fees and distributes them to fee recipients
    /// @dev Collects ETH and LIQUID fees from the V4 LP position, converts LIQUID to ETH (with
    ///      slippage protection), then distributes the combined ETH to fee recipients in
    ///      a single distribution call. This function can be called by anyone.
    ///
    ///      IMPORTANT: The caller must provide the current sqrt price and slippage tolerance
    ///      to protect against sandwich attacks. Query getCurrentPrice() or slot0 off-chain
    ///      BEFORE constructing the transaction, then pass that price as the baseline.
    ///      The contract calculates a sqrt price limit based on the slippage tolerance.
    ///
    ///      For LIQUID->ETH swaps (zeroForOne=false), the price increases as you sell LIQUID.
    ///      The limit ensures the swap stops if price movement exceeds the slippage tolerance.
    /// @param currentSqrtPriceX96 The current sqrt price from pool (queried off-chain before tx submission)
    /// @param slippageBps Maximum acceptable slippage in basis points (e.g., 100 = 1%, 500 = 5%)
    function harvestSecondaryRewards(
        uint160 currentSqrtPriceX96,
        uint16 slippageBps
    ) external nonReentrant {
        if (currentSqrtPriceX96 == 0) revert InvalidPrice();
        if (slippageBps == 0 || slippageBps > 10000) revert InvalidSlippage();

        uint160 sqrtPriceLimitX96 = _calculateSqrtPriceLimitForSell(
            currentSqrtPriceX96,
            slippageBps
        );

        _handleSecondaryRewards(sqrtPriceLimitX96, slippageBps);
    }

    /// @notice Executes a buy order and harvests secondary rewards in a single transaction
    /// @dev Combines buy() and harvestSecondaryRewards() atomically.
    ///      Use this function when you want to collect accumulated LP fees during your buy.
    ///      Uses more gas than plain buy(), but provides convenience of automatic fee collection.
    ///
    ///      NOTE: For harvest slippage, pass the sqrt price BEFORE the buy executes (query off-chain).
    ///      The buy will push price down (favorable for harvest), so using pre-buy price is conservative.
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
    ) external payable nonReentrant returns (uint256) {
        // Buy the tokens
        uint256 trueOrderSize = _buy(
            recipient,
            orderReferrer,
            minOrderSize,
            sqrtPriceLimitX96Buy
        );

        // Only harvest if caller provided a baseline price (0 = skip)
        if (preBuySqrtPriceX96 > 0) {
            if (harvestSlippageBps == 0 || harvestSlippageBps > 10000)
                revert InvalidSlippage();

            // Calculate the sqrt price limit for the harvest swap
            uint160 sqrtPriceLimitX96 = _calculateSqrtPriceLimitForSell(
                preBuySqrtPriceX96,
                harvestSlippageBps
            );
            // Harvest the secondary rewards
            _handleSecondaryRewards(sqrtPriceLimitX96, harvestSlippageBps);
        }

        return trueOrderSize;
    }

    /// @notice Accepts ETH but does not execute any logic
    /// @dev The contract needs to receive ETH for:
    ///      - WETH unwrapping operations
    ///      - PoolManager settlement operations (settle() can send ETH back)
    ///      - Taking ETH from pool after swaps
    ///
    ///      Users who want to buy tokens must call buy() directly with explicit parameters.
    ///      This prevents unexpected auto-buy behavior and eliminates security concerns with
    ///      EOA code delegation (EIP-7702) where tx.origin == msg.sender even with contract code.
    receive() external payable {
        // Accept ETH but do nothing
        // Users must call buy() explicitly to purchase tokens
    }

    /// @notice Overrides ERC20's _update function to emit enhanced transfer events
    /// @dev Emits the superset `LiquidTransfer` event with additional context (balances, total supply)
    /// @param from The sender address
    /// @param to The recipient address
    /// @param value The amount transferred
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        // Execute standard ERC20 transfer logic
        super._update(from, to, value);

        // Emit enhanced event with post-transfer balances and supply
        emit LiquidTransfer(
            from,
            to,
            value,
            balanceOf(from),
            balanceOf(to),
            totalSupply()
        );
    }

    // ============================================
    // QUOTE HELPERS (STATIC CALL ONLY - NOT VIEW)
    // ============================================

    /**
     * @notice Returns the current raw pool price (no fees) in both directions
     * @dev Reads directly from Uniswap V4 pool slot0. Returns WEI values scaled to 1e18.
     *      sqrtPriceX96 represents sqrt(token1/token0) * 2^96.
     *      Converts to actual price ratios and returns both directions.
     *      Uses FullMath.mulDiv to prevent overflow on extreme prices.
     * @return ethPerToken WEI of ETH per 1e18 tokens
     * @return tokenPerEth WEI of tokens per 1e18 ETH
     */
    function getCurrentPrice()
        external
        view
        returns (uint256 ethPerToken, uint256 tokenPerEth)
    {
        // Check if pool exists
        if (PoolId.unwrap(poolId) == bytes32(0)) {
            revert PoolNotInitialized();
        }

        // Read current price from pool
        IPoolManager pm = IPoolManager(poolManager);
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(poolId);

        // Convert sqrtPriceX96 to actual price
        // price = token1/token0 = (sqrtPriceX96 / 2^96)^2 = sqrtPriceX96^2 / 2^192
        // Use Q192.64 fixed point for intermediate calculations
        uint256 priceQ128 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >>
            64; // sqrtPriceX96^2 / 2^64
        uint256 denominatorQ128 = 1 << 128; // 2^192 / 2^64 = 2^128

        // Safety: if price is 0, return 0 for both (uninitialized or extreme state)
        if (priceQ128 == 0) {
            return (0, 0);
        }

        // ETH is always currency0, LIQUID is always currency1 in V4
        // price = LIQUID/ETH
        // Use FullMath.mulDiv to prevent overflow on extreme prices
        ethPerToken = FullMath.mulDiv(denominatorQ128, 1e18, priceQ128);
        tokenPerEth = FullMath.mulDiv(priceQ128, 1e18, denominatorQ128);
    }

    /**
     * @notice Quote tokens out for a buy given the **gross** ETH the user intends to send.
     * @dev Computes primary fee internally, then simulates the swap via unlock callback.
     *      Uses revert-as-return pattern through _simulateQuoteBuy() for gas-free simulation.
     *      Not marked `view` (simulation reverts-to-return); use via eth_call.
     * @param ethAmount Gross ETH the user plans to send to buy()
     * @return feeBps        The primary fee BPS (TOTAL_FEE_BPS)
     * @return ethFee        The primary fee in ETH on ethAmount
     * @return ethIn         ETH that would be swapped after fee (ethAmount - ethFee)
     * @return tokenOut     Expected LIQUID tokens out from the swap
     * @return sqrtPriceX96After  Post-swap sqrt price (recommended sqrtPriceLimit for buy)
     */
    function quoteBuy(
        uint256 ethAmount
    )
        external
        returns (
            uint256 feeBps,
            uint256 ethFee,
            uint256 ethIn,
            uint256 tokenOut,
            uint160 sqrtPriceX96After
        )
    {
        feeBps = TOTAL_FEE_BPS;
        ethFee = _calculateFee(ethAmount, feeBps);
        ethIn = ethAmount - ethFee;

        (tokenOut, sqrtPriceX96After) = _simulateQuoteBuy(ethIn);
    }

    /**
     * @notice Quote ETH out for a sell given the **gross** LIQUID tokens to sell.
     * @dev Simulates the swap via unlock callback, then computes the primary fee on ETH out.
     *      Uses revert-as-return pattern through _simulateQuoteSell() for gas-free simulation.
     *      Returns ETH **after** the primary fee so callers get the true net payout.
     *      Not marked `view` (simulation reverts-to-return); use via eth_call.
     * @param tokenAmount Gross LIQUID tokens the user plans to pass to sell()
     * @return feeBps        The primary fee BPS (TOTAL_FEE_BPS)
     * @return ethFee        The primary fee in ETH on quoted payout
     * @return tokenIn       The token amount that would be swapped (== tokenAmount)
     * @return ethOut        Expected ETH to user **after** primary fee
     * @return sqrtPriceX96After  Post-swap sqrt price (recommended sqrtPriceLimit for sell)
     */
    function quoteSell(
        uint256 tokenAmount
    )
        external
        returns (
            uint256 feeBps,
            uint256 ethFee,
            uint256 tokenIn,
            uint256 ethOut,
            uint160 sqrtPriceX96After
        )
    {
        (uint256 ethOutBeforeFee, uint160 priceAfter) = _simulateQuoteSell(
            tokenAmount
        );

        feeBps = TOTAL_FEE_BPS;
        ethFee = _calculateFee(ethOutBeforeFee, feeBps);

        tokenIn = tokenAmount;
        ethOut = ethOutBeforeFee - ethFee;
        sqrtPriceX96After = priceAfter;
    }

    /**
     * @notice Returns the current sqrt price and recommended price limit for harvest slippage control
     * @dev Intended for off-chain callers via eth_call so they don't need to handle Q64.96 math.
     *      Reverts if the pool is uninitialized or if the provided slippage is invalid.
     * @param slippageBps Maximum acceptable slippage in basis points (e.g., 100 = 1%, 500 = 5%)
     * @return currentSqrtPriceX96 The current pool sqrt price (from slot0)
     * @return sqrtPriceLimitX96 The calculated sqrt price limit for LIQUID->ETH conversion
     */
    function quoteHarvestParams(
        uint16 slippageBps
    )
        external
        view
        returns (uint160 currentSqrtPriceX96, uint160 sqrtPriceLimitX96)
    {
        if (PoolId.unwrap(poolId) == bytes32(0)) revert PoolNotInitialized();
        if (slippageBps == 0 || slippageBps > 10000) revert InvalidSlippage();

        // Read the current sqrt price from the pool
        IPoolManager pm = IPoolManager(poolManager);
        (currentSqrtPriceX96, , , ) = pm.getSlot0(poolId);
        if (currentSqrtPriceX96 == 0) revert InvalidPrice();

        // The sqrt price limit is the maximum price at which the sell swap can be executed
        sqrtPriceLimitX96 = _calculateSqrtPriceLimitForSell(
            currentSqrtPriceX96,
            slippageBps
        );
    }

    // ============================================
    // INTERNAL POOL & SWAP FUNCTIONS
    // ============================================

    /// @notice Deploys the Uniswap V4 pool with initial liquidity
    /// @dev Creates pool if it doesn't exist, initializes with calculated price, and mints LP position.
    ///      The pool starts with two-sided liquidity: 900K LIQUID tokens + liquidityAmount ETH.
    /// @param liquidityAmount The amount of ETH to provide as initial liquidity
    function _deployPool(uint256 liquidityAmount) internal {
        // Pull config directly from factory
        ILiquidFactory factoryContract = ILiquidFactory(factory);
        int24 tickLower = factoryContract.lpTickLower();
        int24 tickUpper = factoryContract.lpTickUpper();
        int24 tickSpacing = factoryContract.poolTickSpacing();
        address hooks = factoryContract.poolHooks();

        // Build PoolKey: Native ETH (currency0) paired with LIQUID (currency1)
        // Native ETH is always address(0), which sorts before any ERC20
        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(this)),
            fee: LP_FEE,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        // Compute PoolId
        poolId = poolKey.toId();

        // Determine tick values (ETH is always currency0)
        // Round ticks to nearest multiple of tick spacing (required by V4)
        //
        // WHY THIS IS REQUIRED:
        // Uniswap V4 pools organize liquidity into discrete "ticks" separated by tickSpacing.
        // Ticks must be multiples of tickSpacing to ensure efficient storage and computation.
        // If ticks aren't properly rounded, V4's modifyLiquidity() will revert.
        //
        // ROUNDING LOGIC:
        // - For negative ticks: round DOWN (toward more negative) to nearest spacing multiple
        //   Example: tickLower=-123, spacing=60 → rounds to -120 (closer to zero)
        // - For positive ticks: round UP (toward more positive) to nearest spacing multiple
        //   Example: tickUpper=123, spacing=60 → rounds to 180 (further from zero)
        // This ensures the rounded range always contains or equals the original range.
        //
        // NOTE: Deliberately using divide-then-multiply to round tick to spacing multiple.
        // This is required by Uniswap V4, not a precision loss bug.
        if (tickLower < 0) {
            // Negative ticks: round down (divide truncates toward zero, then multiply back)
            // forge-lint: disable-next-line(divide-before-multiply)
            lpTickLower = (tickLower / tickSpacing) * tickSpacing;
        } else {
            // Positive ticks: round up (add spacing-1 before divide to round up)
            // forge-lint: disable-next-line(divide-before-multiply)
            lpTickLower =
                ((tickLower + tickSpacing - 1) / tickSpacing) *
                tickSpacing;
        }

        if (tickUpper < 0) {
            // Negative ticks: round up (subtract spacing-1 before divide to round up)
            // forge-lint: disable-next-line(divide-before-multiply)
            lpTickUpper =
                ((tickUpper - tickSpacing + 1) / tickSpacing) *
                tickSpacing;
        } else {
            // Positive ticks: round up (add spacing-1 before divide to round up)
            // forge-lint: disable-next-line(divide-before-multiply)
            lpTickUpper =
                ((tickUpper + tickSpacing - 1) / tickSpacing) *
                tickSpacing;
        }

        if (lpTickLower >= lpTickUpper) revert InvalidTickRange();

        // Calculate liquidity bounds for the position
        // We're providing: liquidityAmount ETH (currency0) + POOL_LAUNCH_SUPPLY tokens (currency1)
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(lpTickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(lpTickUpper);

        // Set starting price at the upper bound of the range (bonding curve starting point)
        // In our pool: currency0=ETH, currency1=LIQUID, price = LIQUID/ETH
        // High tick = low price (many LIQUID per ETH) = cheap tokens (bonding curve bottom)
        // As users buy, tick moves DOWN (fewer LIQUID per ETH) = expensive tokens
        // Start at tickUpper - 1 to ensure we're strictly within the range
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(lpTickUpper - 1);

        lpLiquidity = _calculateLiquidity(
            sqrtPriceX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            liquidityAmount,
            POOL_LAUNCH_SUPPLY
        );

        // Ensure we have liquidity to add
        if (lpLiquidity == 0) revert ZeroLiquidity();

        // Initialize pool and add liquidity via unlock
        _unlockExpected = true;
        IPoolManager(poolManager).unlock(
            abi.encode(
                UnlockContext({
                    action: UnlockAction.INITIALIZE_POOL,
                    data: abi.encode(sqrtPriceX96, liquidityAmount)
                })
            )
        );
        _unlockExpected = false;

        // Emit event for pool graduation (market is now live)
        emit LiquidMarketGraduated(
            address(this),
            address(poolManager),
            liquidityAmount,
            POOL_LAUNCH_SUPPLY,
            uint256(lpLiquidity)
        );
    }

    /// @notice Swaps exact ETH input for LIQUID tokens
    /// @param ethAmount Amount of ETH to swap
    /// @param minOut Minimum tokens out (slippage protection)
    /// @param sqrtPriceLimitX96 Price limit (0 = no limit)
    /// @param recipient Recipient of tokens
    /// @return amountOut Amount of tokens received
    function _swapExactInputETHForTokens(
        uint256 ethAmount,
        uint256 minOut,
        uint160 sqrtPriceLimitX96,
        address recipient
    ) internal returns (uint256) {
        _unlockExpected = true;
        bytes memory result = IPoolManager(poolManager).unlock(
            abi.encode(
                UnlockContext({
                    action: UnlockAction.SWAP_BUY,
                    data: abi.encode(
                        ethAmount,
                        minOut,
                        sqrtPriceLimitX96,
                        recipient
                    )
                })
            )
        );
        _unlockExpected = false;
        return abi.decode(result, (uint256));
    }

    /// @notice Swaps exact LIQUID tokens for ETH
    /// @param tokenAmount Amount of tokens to swap
    /// @param minOut Minimum ETH out (slippage protection)
    /// @param sqrtPriceLimitX96 Price limit (0 = no limit)
    /// @param seller Address selling the tokens
    /// @return amountOut Amount of ETH received
    function _swapExactInputTokensForETH(
        uint256 tokenAmount,
        uint256 minOut,
        uint160 sqrtPriceLimitX96,
        address seller
    ) internal returns (uint256) {
        // Transfer tokens from seller to this contract
        _transfer(seller, address(this), tokenAmount);

        _unlockExpected = true;
        bytes memory result = IPoolManager(poolManager).unlock(
            abi.encode(
                UnlockContext({
                    action: UnlockAction.SWAP_SELL,
                    data: abi.encode(tokenAmount, minOut, sqrtPriceLimitX96)
                })
            )
        );
        _unlockExpected = false;
        return abi.decode(result, (uint256));
    }

    /// @notice Simulate buy swap to obtain amount out + post-swap price
    /// @dev Uses revert-as-return pattern: triggers unlock callback with QUOTE_SWAP_BUY action,
    ///      which simulates the swap and reverts with QuoteResult containing the output.
    ///      This pattern allows gas-free simulation via eth_call while still executing V4 swap logic.
    ///      If the callback completes without reverting (unexpected), throws QuoteSimulationDidNotRevert.
    /// @param ethAmount Amount of ETH to simulate swapping (after fees)
    /// @return amountOut Expected LIQUID tokens output from the swap
    /// @return sqrtPriceAfter Post-swap sqrt price
    function _simulateQuoteBuy(
        uint256 ethAmount
    ) internal returns (uint256 amountOut, uint160 sqrtPriceAfter) {
        _unlockExpected = true;
        try
            IPoolManager(poolManager).unlock(
                abi.encode(
                    UnlockContext({
                        action: UnlockAction.QUOTE_SWAP_BUY,
                        data: abi.encode(ethAmount)
                    })
                )
            )
        returns (bytes memory) {
            _unlockExpected = false;
            revert QuoteSimulationDidNotRevert();
        } catch (bytes memory reason) {
            _unlockExpected = false;
            (amountOut, sqrtPriceAfter) = _decodeQuoteResult(reason);
        }
    }

    /// @notice Simulate sell swap to obtain amount out + post-swap price
    /// @dev Uses revert-as-return pattern: triggers unlock callback with QUOTE_SWAP_SELL action,
    ///      which simulates the swap and reverts with QuoteResult containing the output.
    ///      This pattern allows gas-free simulation via eth_call while still executing V4 swap logic.
    ///      If the callback completes without reverting (unexpected), throws QuoteSimulationDidNotRevert.
    /// @param tokenAmount Amount of LIQUID tokens to simulate swapping
    /// @return amountOut Expected ETH output from the swap (before fees)
    /// @return sqrtPriceAfter Post-swap sqrt price
    function _simulateQuoteSell(
        uint256 tokenAmount
    ) internal returns (uint256 amountOut, uint160 sqrtPriceAfter) {
        _unlockExpected = true;
        try
            IPoolManager(poolManager).unlock(
                abi.encode(
                    UnlockContext({
                        action: UnlockAction.QUOTE_SWAP_SELL,
                        data: abi.encode(tokenAmount)
                    })
                )
            )
        returns (bytes memory) {
            _unlockExpected = false;
            revert QuoteSimulationDidNotRevert();
        } catch (bytes memory reason) {
            _unlockExpected = false;
            (amountOut, sqrtPriceAfter) = _decodeQuoteResult(reason);
        }
    }

    /// @notice Decodes quote simulation results from revert reason
    /// @dev Parses the QuoteResult error from a revert reason byte array.
    ///      Expected format: bytes4(selector) + uint256(amountOut) + uint160(sqrtPriceAfter)
    ///      If the revert reason doesn't match QuoteResult selector, re-throws the original error
    ///      using QuoterRevert.bubbleReason() to propagate the actual revert.
    /// @param reason The revert reason bytes from the quote simulation
    /// @return amountOut The simulated output amount extracted from the QuoteResult
    /// @return sqrtPriceAfter The post-swap sqrt price extracted from the QuoteResult
    function _decodeQuoteResult(
        bytes memory reason
    ) internal pure returns (uint256 amountOut, uint160 sqrtPriceAfter) {
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }

        if (selector != QuoteResult.selector) {
            reason.bubbleReason();
        }

        assembly ("memory-safe") {
            amountOut := mload(add(reason, 0x24))
            sqrtPriceAfter := mload(add(reason, 0x44))
        }
    }

    // ============================================
    // UNLOCK CALLBACK
    // ============================================

    /// @notice Uniswap V4 unlock callback
    /// @dev Called by PoolManager during unlock. Executes the requested action.
    ///
    ///      BALANCEDELTA SIGN CONVENTIONS (Uniswap V4):
    ///      BalanceDelta represents the net change in pool balances after an operation.
    ///      - Negative delta (delta < 0): We OWE the pool tokens (must settle)
    ///      - Positive delta (delta > 0): We RECEIVE tokens from the pool (can take)
    ///
    ///      For liquidity adds:
    ///      - Negative deltas mean we must provide tokens to the pool
    ///      - Example: delta0 = -100 means we owe 100 ETH to the pool
    ///
    ///      For swaps:
    ///      - Input currency has negative delta (we owe what we're swapping in)
    ///      - Output currency has positive delta (we receive what we're swapping out)
    ///      - Example: ETH→LIQUID swap: delta0 = -100 (owe 100 ETH), delta1 = +50 (receive 50 LIQUID)
    ///
    /// @param data Encoded UnlockContext
    /// @return Encoded return data
    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        // Security: only PoolManager can call this
        if (msg.sender != poolManager) revert OnlyPoolManager();

        // Security: only during expected unlock operations
        if (!_unlockExpected) revert UnexpectedUnlock();

        UnlockContext memory ctx = abi.decode(data, (UnlockContext));

        if (ctx.action == UnlockAction.INITIALIZE_POOL) {
            return _unlockInitializePool(ctx.data);
        } else if (ctx.action == UnlockAction.SWAP_BUY) {
            return _unlockSwapBuy(ctx.data);
        } else if (ctx.action == UnlockAction.SWAP_SELL) {
            return _unlockSwapSell(ctx.data);
        } else if (ctx.action == UnlockAction.QUOTE_SWAP_BUY) {
            return _unlockQuoteSwapBuy(ctx.data);
        } else if (ctx.action == UnlockAction.QUOTE_SWAP_SELL) {
            return _unlockQuoteSwapSell(ctx.data);
        } else if (ctx.action == UnlockAction.SWAP_REWARDS) {
            return _unlockSwapRewards(ctx.data);
        } else if (ctx.action == UnlockAction.COLLECT_FEES) {
            return _unlockCollectFees(ctx.data);
        }

        revert UnexpectedUnlock();
    }

    /// @notice Initialize pool and add initial liquidity
    function _unlockInitializePool(
        bytes memory data
    ) internal returns (bytes memory) {
        (uint160 sqrtPriceX96, ) = abi.decode(data, (uint160, uint256));

        IPoolManager pm = IPoolManager(poolManager);

        // Initialize pool
        pm.initialize(poolKey, sqrtPriceX96);

        // Add liquidity
        // Ensure liquidity fits in int128 (max positive value is 2^127 - 1)
        if (lpLiquidity > uint128(type(int128).max)) {
            revert LiquidityTooLarge(lpLiquidity);
        }
        (BalanceDelta delta, ) = pm.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lpTickLower,
                tickUpper: lpTickUpper,
                // lpLiquidity is already uint128, casting to int128 for V4 interface
                // forge-lint: disable-next-line(unsafe-typecast)
                liquidityDelta: int128(uint128(lpLiquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        // Settle debts
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // For liquidity adds, negative delta means we owe the pool
        if (delta0 < 0) {
            uint128 owed0 = _toUint128Neg(delta0);
            // ETH is currency0, settle with native ETH
            pm.settle{value: owed0}();
        }

        if (delta1 < 0) {
            uint128 owed1 = _toUint128Neg(delta1);
            // LIQUID is currency1, transfer tokens and settle
            pm.sync(poolKey.currency1);
            _transfer(address(this), address(pm), owed1);
            pm.settle();
        }

        return "";
    }

    /// @notice Execute buy swap (ETH -> LIQUID)
    /// @dev Enforces atomic all-or-nothing execution. If the V4 swap consumes less ETH than requested
    ///      (due to price limits, liquidity exhaustion, or hook behavior), the function reverts with
    ///      PartialFillBuy. This prevents ETH from being stranded in the contract and ensures users
    ///      either complete their full trade or retain all their funds.
    function _unlockSwapBuy(bytes memory data) internal returns (bytes memory) {
        (
            uint256 ethAmount,
            uint256 minOut,
            uint160 sqrtPriceLimitX96,
            address recipient
        ) = abi.decode(data, (uint256, uint256, uint160, address));

        IPoolManager pm = IPoolManager(poolManager);

        // Swap: ETH (currency0) -> LIQUID (currency1)
        // Price limit handling:
        // - If user provides 0, we use directional bounds (MIN_SQRT_PRICE + 1 for zeroForOne=true)
        // - V4 rejects exact MIN_SQRT_PRICE/MAX_SQRT_PRICE values, requiring +1/-1 offset
        // - For zeroForOne=true (ETH→LIQUID), we use MIN_SQRT_PRICE + 1 (price can only decrease)
        // - This ensures swap completes fully without hitting invalid price bounds
        BalanceDelta delta = pm.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -SafeCast.toInt256(ethAmount), // Negative = exact input
                sqrtPriceLimitX96: sqrtPriceLimitX96 == 0
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : sqrtPriceLimitX96
            }),
            ""
        );

        // delta.amount0() is negative (ETH we owe), delta.amount1() is positive (LIQUID we receive)
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 >= 0) revert InvalidSwapDelta0(delta0);
        if (delta1 <= 0) revert InvalidSwapDelta1(delta1);

        uint128 ethOwed = _toUint128Neg(delta0);
        uint128 tokensReceived = _toUint128Pos(delta1);

        // Enforce all-or-nothing: revert if swap didn't consume all requested ETH
        if (ethOwed != ethAmount) revert PartialFillBuy(ethAmount, ethOwed);

        if (tokensReceived < minOut) revert SlippageExceeded();

        // Settle ETH debt
        pm.settle{value: ethOwed}();

        // Take tokens and send to recipient
        pm.take(poolKey.currency1, recipient, tokensReceived);

        return abi.encode(tokensReceived);
    }

    /// @notice Execute sell swap (LIQUID -> ETH)
    function _unlockSwapSell(
        bytes memory data
    ) internal returns (bytes memory) {
        (uint256 tokenAmount, uint256 minOut, uint160 sqrtPriceLimitX96) = abi
            .decode(data, (uint256, uint256, uint160));

        IPoolManager pm = IPoolManager(poolManager);

        // Swap: LIQUID (currency1) -> ETH (currency0)
        // Price limit handling:
        // - If user provides 0, we use directional bounds (MAX_SQRT_PRICE - 1 for zeroForOne=false)
        // - V4 rejects exact MIN_SQRT_PRICE/MAX_SQRT_PRICE values, requiring +1/-1 offset
        // - For zeroForOne=false (LIQUID→ETH), we use MAX_SQRT_PRICE - 1 (price can only increase)
        // - This ensures swap completes fully without hitting invalid price bounds
        BalanceDelta delta = pm.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -SafeCast.toInt256(tokenAmount), // Negative = exact input
                sqrtPriceLimitX96: sqrtPriceLimitX96 == 0
                    ? TickMath.MAX_SQRT_PRICE - 1
                    : sqrtPriceLimitX96
            }),
            ""
        );

        // delta.amount0() is positive (ETH we receive), delta.amount1() is negative (LIQUID we owe)
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 <= 0) revert InvalidSwapDelta0(delta0);
        if (delta1 >= 0) revert InvalidSwapDelta1(delta1);

        uint128 ethReceived = _toUint128Pos(delta0);
        uint128 tokensOwed = _toUint128Neg(delta1);

        // Only validate if minOut > 0 (allows caller to validate after fees)
        if (minOut > 0 && ethReceived < minOut) revert SlippageExceeded();

        // Settle LIQUID debt
        pm.sync(poolKey.currency1);
        _transfer(address(this), address(pm), tokensOwed);
        pm.settle();

        // Take ETH and send to this contract (will be distributed by caller)
        pm.take(poolKey.currency0, address(this), ethReceived);

        return abi.encode(ethReceived);
    }

    /// @notice Quote helper for ETH -> LIQUID swaps (always reverts with QuoteResult)
    function _unlockQuoteSwapBuy(
        bytes memory data
    ) internal returns (bytes memory) {
        uint256 ethAmount = abi.decode(data, (uint256));

        IPoolManager pm = IPoolManager(poolManager);
        BalanceDelta delta = pm.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -SafeCast.toInt256(ethAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        if (delta0 >= 0) revert InvalidSwapDelta0(delta0);
        if (delta1 <= 0) revert InvalidSwapDelta1(delta1);

        uint256 tokensReceived = _toUint128Pos(delta1);
        (uint160 sqrtPriceAfter, , , ) = pm.getSlot0(poolKey.toId());

        revert QuoteResult(tokensReceived, sqrtPriceAfter);
    }

    /// @notice Quote helper for LIQUID -> ETH swaps (always reverts with QuoteResult)
    function _unlockQuoteSwapSell(
        bytes memory data
    ) internal returns (bytes memory) {
        uint256 tokenAmount = abi.decode(data, (uint256));

        IPoolManager pm = IPoolManager(poolManager);
        BalanceDelta delta = pm.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -SafeCast.toInt256(tokenAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        if (delta0 <= 0) revert InvalidSwapDelta0(delta0);
        if (delta1 >= 0) revert InvalidSwapDelta1(delta1);

        uint256 ethReceived = _toUint128Pos(delta0);
        (uint160 sqrtPriceAfter, , , ) = pm.getSlot0(poolKey.toId());

        revert QuoteResult(ethReceived, sqrtPriceAfter);
    }

    /// @notice Execute reward swap (LIQUID -> ETH for secondary rewards)
    /// @dev Uses caller-provided price limit to prevent execution at manipulated prices.
    ///      If the swap would push price beyond the limit, V4 will partially fill or revert.
    ///      We treat any failure (including 0 output) as a signal to defer the swap.
    function _unlockSwapRewards(
        bytes memory data
    ) internal returns (bytes memory) {
        (uint256 tokenAmount, uint160 sqrtPriceLimitX96) = abi.decode(
            data,
            (uint256, uint160)
        );

        IPoolManager pm = IPoolManager(poolManager);

        // Swap: LIQUID (currency1) -> ETH (currency0)
        // Price limit: Use caller-provided limit to protect against sandwich attacks
        // For zeroForOne=false (LIQUID→ETH), price increases as we sell LIQUID
        // The swap will stop if it would push the price beyond sqrtPriceLimitX96
        BalanceDelta delta = pm.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -SafeCast.toInt256(tokenAmount),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 <= 0 || delta1 >= 0) {
            // Invalid swap, return 0
            return abi.encode(uint256(0));
        }

        uint128 ethReceived = _toUint128Pos(delta0);
        uint128 tokensOwed = _toUint128Neg(delta1);

        // If we received 0 ETH, the price limit was immediately hit (bad price)
        if (ethReceived == 0) {
            return abi.encode(uint256(0));
        }

        // Settle LIQUID debt
        pm.sync(poolKey.currency1);
        _transfer(address(this), address(pm), tokensOwed);
        pm.settle();

        // Take ETH to this contract
        pm.take(poolKey.currency0, address(this), ethReceived);

        return abi.encode(ethReceived);
    }

    /// @notice Collect fees from LP position
    function _unlockCollectFees(bytes memory) internal returns (bytes memory) {
        IPoolManager pm = IPoolManager(poolManager);

        // Skip fee collection if position has no liquidity (prevents CannotUpdateEmptyPosition)
        if (lpLiquidity == 0) {
            return abi.encode(uint256(0), uint256(0));
        }

        // Poke the position with zero liquidity delta to collect fees
        (BalanceDelta delta, ) = pm.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lpTickLower,
                tickUpper: lpTickUpper,
                liquidityDelta: 0,
                salt: bytes32(0)
            }),
            ""
        );

        // Positive deltas are fees we can claim
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        uint128 ethFees = 0;
        uint128 tokenFees = 0;

        if (delta0 > 0) {
            ethFees = _toUint128Pos(delta0);
            pm.take(poolKey.currency0, address(this), ethFees);
        }

        if (delta1 > 0) {
            tokenFees = _toUint128Pos(delta1);
            pm.take(poolKey.currency1, address(this), tokenFees);
        }

        return abi.encode(ethFees, tokenFees);
    }

    // ============================================
    // FEE DISTRIBUTION
    // ============================================

    /// @notice Distributes collected fees using three-tier system with direct ETH transfers
    /// @dev TIER 1: Collect total fee from trade
    ///      TIER 2: Pay creator their fixed percentage
    ///      TIER 3: Split remainder among burn/protocol/referrer
    ///
    ///      CRITICAL: This function NEVER reverts user trades due to RARE burn issues.
    ///      - Buffered burn pattern: ETH deposits to accumulator (sync), actual burns happen separately (async)
    ///      - If accumulator deposit fails (paused/broken), ETH forwards to protocol instead
    ///      - User trades always succeed regardless of V4 pool availability
    ///      - Actual RARE burns occur later via permissionless flush() calls
    ///
    ///      Fee distribution uses direct transfers with fallback:
    ///      - Failed creator transfer → accumulated to protocol
    ///      - Failed referrer transfer → accumulated to protocol
    ///      - Protocol receives its share + all failed transfers
    ///      - Only protocol transfer failure causes revert
    ///
    ///      EVENT EMISSION:
    ///      - Returns ACTUAL amounts transferred (not intended amounts)
    ///      - If creator/referrer transfer fails, their returned amount is 0
    ///      - Protocol amount includes any fallback funds from failed transfers
    ///      - This ensures emitted events accurately reflect on-chain transfers
    ///
    /// @param _fee The total fee amount collected from the trade
    /// @param _orderReferrer The address of the order referrer
    /// @return protocolFee The ACTUAL protocol fee amount transferred (includes fallback from failed transfers)
    /// @return referrerFee The ACTUAL referrer fee amount transferred (0 if transfer failed)
    /// @return creatorFee The ACTUAL creator fee amount transferred (0 if transfer failed)
    /// @return rareBurnFee The ACTUAL RARE burn fee amount deposited (0 if burn failed or not configured)
    function _disperseFees(
        uint256 _fee,
        address _orderReferrer
    )
        internal
        returns (
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 creatorFee,
            uint256 rareBurnFee
        )
    {
        // Pull fee config directly from factory
        ILiquidFactory factoryContract = ILiquidFactory(factory);
        address protocolFeeRecipient = factoryContract.protocolFeeRecipient();

        // Default referrer to protocol recipient if none provided
        if (_orderReferrer == address(0)) {
            _orderReferrer = protocolFeeRecipient;
        }

        // TIER 2: Calculate and extract creator's fixed share
        creatorFee = _calculateFee(_fee, TOKEN_CREATOR_FEE_BPS);
        uint256 remainingFee = _fee - creatorFee;

        // TIER 3: Split remainder among burn/protocol/referrer
        rareBurnFee = _calculateFee(
            remainingFee,
            factoryContract.rareBurnFeeBPS()
        );
        referrerFee = _calculateFee(
            remainingFee,
            factoryContract.referrerFeeBPS()
        );
        protocolFee = _calculateFee(
            remainingFee,
            factoryContract.protocolFeeBPS()
        );

        // Calculate dust and add to protocol (ensures exact sum)
        uint256 totalRemainder = rareBurnFee + referrerFee + protocolFee;
        uint256 dust = remainingFee - totalRemainder;
        protocolFee += dust;

        // Handle RARE burn deposit (non-reverting pattern)
        address rareBurnerAddr = factoryContract.rareBurner();
        if (rareBurnFee > 0 && rareBurnerAddr != address(0)) {
            (bool ok, ) = rareBurnerAddr.call{value: rareBurnFee}(
                abi.encodeWithSelector(IRAREBurner.depositForBurn.selector)
            );
            emit BurnerDeposit(address(this), rareBurnerAddr, rareBurnFee, ok);

            if (!ok) {
                // Fallback: forward to protocol if burner fails
                protocolFee += rareBurnFee;
                rareBurnFee = 0;
            }
        } else {
            // No burn configured, add to protocol
            protocolFee += rareBurnFee;
            rareBurnFee = 0;
        }

        // ============================================
        // FEE DISTRIBUTION WITH FALLBACK PATTERN
        // ============================================
        // CRITICAL BEHAVIOR:
        // - Creator transfer failure → NON-REVERTING (funds go to protocol)
        // - Referrer transfer failure → NON-REVERTING (funds go to protocol)
        // - Protocol transfer failure → REVERTS ENTIRE TRADE
        //
        // This ensures user trades never fail due to creator/referrer issues
        // but protocol is guaranteed to receive all fees or trade fails.
        // ============================================

        // Track protocol total (starts with base protocol fee)
        uint256 protocolTotal = protocolFee;

        // Track actual amounts paid (for accurate event emission)
        uint256 creatorPaid = creatorFee;
        uint256 referrerPaid = referrerFee;

        // Try creator transfer - FAILURE IS ABSORBED
        // Gas limit prevents malicious contracts from consuming all gas and reverting the trade
        (bool creatorOk, ) = tokenCreator.call{
            value: creatorFee,
            gas: GAS_LIMIT_TRANSFER
        }("");
        if (!creatorOk) {
            // Non-reverting: add creator fee to protocol total
            protocolTotal += creatorFee;
            creatorPaid = 0; // Creator received nothing
            emit FeeTransferFailed(tokenCreator, creatorFee, "creator");
        }

        // Try referrer transfer - FAILURE IS ABSORBED
        // Gas limit prevents malicious contracts from consuming all gas and reverting the trade
        (bool referrerOk, ) = _orderReferrer.call{
            value: referrerFee,
            gas: GAS_LIMIT_TRANSFER
        }("");
        if (!referrerOk) {
            // Non-reverting: add referrer fee to protocol total
            protocolTotal += referrerFee;
            referrerPaid = 0; // Referrer received nothing
            emit FeeTransferFailed(_orderReferrer, referrerFee, "referrer");
        }

        // Final protocol transfer - FAILURE REVERTS TRADE
        // Protocol receives: base fee + any failed creator/referrer transfers
        (bool protocolOk, ) = protocolFeeRecipient.call{value: protocolTotal}(
            ""
        );
        if (!protocolOk) revert EthTransferFailed(); // CRITICAL: Only protocol failure reverts

        // Emit consolidated fee event with ACTUAL amounts transferred
        emit LiquidFees(
            tokenCreator,
            _orderReferrer,
            protocolFeeRecipient,
            rareBurnFee,
            creatorPaid, // Actual amount (may be 0 if transfer failed)
            referrerPaid, // Actual amount (may be 0 if transfer failed)
            protocolTotal // Actual amount (includes fallback from failed transfers)
        );

        // Return actual fee breakdown for parent event emission
        return (protocolTotal, referrerPaid, creatorPaid, rareBurnFee);
    }

    // ============================================
    // SECONDARY REWARDS (LP FEES)
    // ============================================

    /// @notice Collects accrued trading fees from the Uniswap V4 LP position
    /// @dev Called by buyAndHarvest() or harvestSecondaryRewards(). NOT called by plain buy().
    ///      Collects ETH and LIQUID fees, converts LIQUID to ETH, then distributes the combined
    ///      ETH total to fee recipients in a single call.
    /// @param sqrtPriceLimitX96 Maximum acceptable sqrt price for LIQUID->ETH reward swap
    /// @param slippageBps Slippage tolerance in basis points (for event emission)
    function _handleSecondaryRewards(
        uint160 sqrtPriceLimitX96,
        uint16 slippageBps
    ) internal {
        // Collect fees via unlock
        _unlockExpected = true;
        bytes memory result = IPoolManager(poolManager).unlock(
            abi.encode(
                UnlockContext({action: UnlockAction.COLLECT_FEES, data: ""})
            )
        );
        _unlockExpected = false;

        (uint256 ethFees, uint256 tokenFees) = abi.decode(
            result,
            (uint256, uint256)
        );

        // Aggregate ETH from both sources before distribution
        uint256 totalEthToDistribute = ethFees;

        // Convert LIQUID token fees to ETH and add to total
        if (tokenFees > 0) {
            uint256 convertedEth = _processLiquidRewards(
                tokenFees,
                sqrtPriceLimitX96,
                slippageBps
            );
            totalEthToDistribute += convertedEth;
        }

        // Distribute combined ETH (LP fees + converted LIQUID) in a single call
        uint256 protocolFee;
        uint256 referrerFee;
        uint256 creatorFee;
        uint256 rareBurnFee;

        if (totalEthToDistribute > 0) {
            (protocolFee, referrerFee, creatorFee, rareBurnFee) = _disperseFees(
                totalEthToDistribute,
                address(0)
            );
        }

        // Emit event for secondary rewards tracking with broken out fees
        emit LiquidMarketRewards(
            tokenCreator,
            address(0), // No referrer for secondary rewards
            ILiquidFactory(factory).protocolFeeRecipient(),
            rareBurnFee,
            creatorFee,
            referrerFee,
            protocolFee
        );
    }

    /// @notice Processes LIQUID token rewards by attempting to convert to ETH
    /// @dev Uses caller-provided price limit instead of internal quote to prevent sandwich attacks.
    ///      If the swap reverts due to price limit breach, rewards are deferred for later harvest.
    /// @param tokenFees The amount of newly collected LIQUID fees to convert
    /// @param sqrtPriceLimitX96 Maximum acceptable sqrt price for LIQUID->ETH swap
    /// @param slippageBps Slippage tolerance in basis points (for event emission)
    /// @return ethConverted The amount of ETH obtained from converting LIQUID tokens (0 if deferred/failed)
    function _processLiquidRewards(
        uint256 tokenFees,
        uint160 sqrtPriceLimitX96,
        uint16 slippageBps
    ) internal returns (uint256 ethConverted) {
        // Aggregate with any previously deferred LIQUID rewards
        uint256 swapIn = _pendingRewardsLiquid + tokenFees;
        if (swapIn == 0) return 0;

        // Calculate approximate minOut for event emission
        // This represents the minimum ETH expected at the price limit with slippage
        uint256 minOut = _estimateMinOutForRewards(
            swapIn,
            sqrtPriceLimitX96,
            slippageBps
        );

        // Attempt swap with caller-provided price limit (wrapped in try/catch for graceful deferral)
        _unlockExpected = true;
        try
            IPoolManager(poolManager).unlock(
                abi.encode(
                    UnlockContext({
                        action: UnlockAction.SWAP_REWARDS,
                        data: abi.encode(swapIn, sqrtPriceLimitX96)
                    })
                )
            )
        returns (bytes memory result) {
            _unlockExpected = false;
            uint256 ethAmt = abi.decode(result, (uint256));

            if (ethAmt > 0) {
                // Swap succeeded - clear deferred accumulator and return ETH amount
                _pendingRewardsLiquid = 0;
                emit SecondaryRewardsSwap(swapIn, 0, ethAmt);
                return ethAmt;
            } else {
                // Swap failed (price limit hit), defer
                _pendingRewardsLiquid = swapIn;
                emit SecondaryRewardsDeferred(swapIn, minOut, slippageBps);
                return 0;
            }
        } catch {
            _unlockExpected = false;
            // Swap failed (reverted), defer
            _pendingRewardsLiquid = swapIn;
            emit SecondaryRewardsDeferred(swapIn, minOut, slippageBps);
            return 0;
        }
    }

    // ============================================
    // UTILITY FUNCTIONS
    // ============================================

    /// @dev Estimates minimum ETH output for a LIQUID->ETH swap based on price limit and slippage
    /// @param liquidAmount Amount of LIQUID tokens to swap
    /// @param sqrtPriceLimitX96 The price limit for the swap
    /// @param slippageBps Slippage tolerance in basis points
    /// @return minOut Approximate minimum ETH output expected
    function _estimateMinOutForRewards(
        uint256 liquidAmount,
        uint160 sqrtPriceLimitX96,
        uint16 slippageBps
    ) internal pure returns (uint256 minOut) {
        // Convert sqrtPriceX96 to price (ETH per LIQUID token)
        // price = (sqrtPriceX96^2) / (2^192)
        // ethPerToken = (2^192) / price = (2^192) / ((sqrtPriceX96^2) / (2^192)) = (2^384) / (sqrtPriceX96^2)

        // To avoid overflow, we use: ethPerToken = (2^128 * 1e18) / ((sqrtPriceX96^2) >> 64)
        uint256 priceQ128 = (uint256(sqrtPriceLimitX96) *
            uint256(sqrtPriceLimitX96)) >> 64;

        if (priceQ128 == 0) return 0;

        uint256 denominatorQ128 = 1 << 128;

        // Calculate ETH per LIQUID token at the price limit
        uint256 ethPerToken = FullMath.mulDiv(denominatorQ128, 1e18, priceQ128);

        // Calculate expected ETH output at price limit
        uint256 expectedEth = FullMath.mulDiv(liquidAmount, ethPerToken, 1e18);

        // Apply slippage tolerance: minOut = expectedEth * (10000 - slippageBps) / 10000
        minOut = FullMath.mulDiv(expectedEth, 10000 - slippageBps, 10000);
    }

    /// @dev Safe cast from uint256 to uint128 with overflow check
    /// @param value The uint256 value to cast
    /// @return The value as uint128
    function _toUint128Safe(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert AmountExceedsUint128(value);
        // Casting to uint128 is safe because we checked bounds above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    /// @dev Safe cast helpers for BalanceDelta conversions
    function _toUint128Pos(int128 x) internal pure returns (uint128) {
        if (x < 0) revert NegativeValue(x);
        // Casting to uint128 is safe because we verified x >= 0
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(uint256(int256(x)));
    }

    function _toUint128Neg(int128 x) internal pure returns (uint128) {
        if (x > 0) revert PositiveValue(x);
        int256 y = -int256(x); // negate in 256-bit space to avoid int128.min overflow
        // Casting to uint256 is safe because y is non-negative after negation
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint256(y) > type(uint128).max)
            revert AmountExceedsUint128(uint256(y));
        // Casting to uint128 is safe because we checked bounds above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(uint256(y));
    }

    /// @notice Calculates the fee for a given amount and basis points
    /// @dev Standard BPS calculation: (amount * bps) / 10_000
    /// @param amount The amount to calculate fee on
    /// @param bps The basis points (e.g., 100 = 1%)
    /// @return The calculated fee amount
    function _calculateFee(
        uint256 amount,
        uint256 bps
    ) internal pure returns (uint256) {
        return (amount * bps) / 10_000;
    }

    /// @notice Calculates sqrt price limit for LIQUID→ETH sells given current price and slippage tolerance
    /// @dev For zeroForOne=false (selling LIQUID for ETH), price increases as you sell.
    ///      The limit is: currentSqrtPrice * sqrt(1 + slippageBps/10000)
    ///
    ///      We use FullMath.mulDiv for safe arithmetic:
    ///      sqrtPriceLimit = currentSqrtPrice * sqrt((10000 + slippageBps) / 10000)
    ///
    ///      To avoid floating point, we compute:
    ///      sqrtPriceLimit = currentSqrtPrice * sqrt(10000 + slippageBps) / sqrt(10000)
    ///
    ///      sqrt(10000) = 100, so:
    ///      sqrtPriceLimit = currentSqrtPrice * sqrt(10000 + slippageBps) / 100
    ///
    /// @param currentSqrtPrice The current sqrt price from the pool
    /// @param slippageBps The slippage tolerance in basis points (e.g., 100 = 1%)
    /// @return sqrtPriceLimitX96 The calculated sqrt price limit
    function _calculateSqrtPriceLimitForSell(
        uint160 currentSqrtPrice,
        uint16 slippageBps
    ) internal pure returns (uint160 sqrtPriceLimitX96) {
        // Calculate sqrt(10000 + slippageBps) using Babylonian method
        uint256 sqrtMultiplier = _sqrt(uint256(10000) + uint256(slippageBps));

        // sqrtPriceLimit = currentSqrtPrice * sqrtMultiplier / 100
        uint256 limit = FullMath.mulDiv(
            uint256(currentSqrtPrice),
            sqrtMultiplier,
            100
        );

        // Ensure result fits in uint160
        if (limit > type(uint160).max) {
            // Cap at MAX_SQRT_PRICE - 1 (V4's upper bound)
            return TickMath.MAX_SQRT_PRICE - 1;
        }

        sqrtPriceLimitX96 = uint160(limit);

        // Ensure we don't exceed V4's valid range
        if (sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
            sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1;
        }
    }

    /// @notice Calculates integer square root using Babylonian method
    /// @dev Used for slippage calculations. Accurate enough for price limit purposes.
    /// @param x The number to find the square root of
    /// @return y The integer square root of x
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Calculates liquidity for a given price range and token amounts
    /// @dev Uses Uniswap V4 math to compute liquidity when price is within the LP range.
    ///      This function is only called during pool initialization where price is set to
    ///      tickUpper - 1, guaranteeing the price is always in-range.
    ///
    ///      Formula (price in range):
    ///      - Calculate liquidity0 from amount0: L0 = amount0 * (sqrtPrice * sqrtUpper / Q96) / (sqrtUpper - sqrtPrice)
    ///      - Calculate liquidity1 from amount1: L1 = amount1 * Q96 / (sqrtPrice - sqrtLower)
    ///      - Use min(L0, L1) because both amounts must be satisfied simultaneously
    ///      - Edge case: If one rounds to 0 due to precision, use the other (prevents zero liquidity)
    ///
    ///      The smaller liquidity value represents the binding constraint - providing more liquidity
    ///      than this would require more tokens than available.
    ///
    /// @param sqrtPriceX96 Current sqrt price (Q64.96 format) - must be within range
    /// @param sqrtPriceLowerX96 Lower bound sqrt price (Q64.96 format)
    /// @param sqrtPriceUpperX96 Upper bound sqrt price (Q64.96 format)
    /// @param amount0 Amount of currency0 (ETH)
    /// @param amount1 Amount of currency1 (LIQUID)
    /// @return liquidity The calculated liquidity amount (constrained to uint128 for V4)
    function _calculateLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        // Calculate liquidity0 from amount0: L0 = amount0 * (sqrtPrice * sqrtUpper / Q96) / (sqrtUpper - sqrtPrice)
        uint256 intermediate = FullMath.mulDiv(
            sqrtPriceX96,
            sqrtPriceUpperX96,
            FixedPoint96.Q96
        );
        uint256 liq0 = FullMath.mulDiv(
            amount0,
            intermediate,
            sqrtPriceUpperX96 - sqrtPriceX96
        );
        if (liq0 > type(uint128).max) revert AmountExceedsUint128(liq0);
        // Casting to uint128 is safe because we checked bounds above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 liquidity0 = uint128(liq0);

        // Calculate liquidity1 from amount1: L1 = amount1 * Q96 / (sqrtPrice - sqrtLower)
        uint256 liq1 = FullMath.mulDiv(
            amount1,
            FixedPoint96.Q96,
            sqrtPriceX96 - sqrtPriceLowerX96
        );
        if (liq1 > type(uint128).max) revert AmountExceedsUint128(liq1);
        // Casting to uint128 is safe because we checked bounds above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 liquidity1 = uint128(liq1);

        // Use the smaller liquidity (both amounts constrained)
        // The smaller value represents the binding constraint - both amounts must be satisfied
        // Edge case: If one rounds to 0 due to precision, use the other (prevents zero liquidity)
        if (liquidity0 == 0 && liquidity1 > 0) {
            liquidity = liquidity1;
        } else if (liquidity1 == 0 && liquidity0 > 0) {
            liquidity = liquidity0;
        } else {
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }
    }
}
