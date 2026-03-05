// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {ILiquidBase} from "liquid-editions/interfaces/ILiquidBase.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {IRender} from "liquid-editions/interfaces/IRender.sol";

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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Position} from "doppler/types/Position.sol";
import {QuoterRevert} from "@uniswap/v4-periphery/libraries/QuoterRevert.sol";

/*                                    
  _       _____  ____   _    _  _____  _____  
 | |     |_   _|/ __ \ | |  | ||_   _||  __ \ 
 | |       | | | |  | || |  | |  | |  | |  | |
 | |       | | | |  | || |  | |  | |  | |  | |
 | |____  _| |_| |__| || |__| | _| |_ | |__| |
 |______||_____|\___\_\ \____/ |_____||_____/ 

*/

/// @title LiquidInstant
/// @notice A liquid edition token with immediate Uniswap V4 pool creation (instant launch).
/// @dev Implements a bonding curve with immediate Uniswap V4 pool creation (RARE/LE pair with 0% LP fee).
///      Trading is handled by LiquidRouter for multi-hop routes. This contract provides pool creation,
///      state management, and quote functions. Uses a clone pattern for gas-efficient deployment via LiquidFactory.
///      All tokens are minted at creation.
contract LiquidInstant is
    ILiquid,
    ILiquidBase,
    ERC20Upgradeable,
    ReentrancyGuardUpgradeable,
    IUnlockCallback
{
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using QuoterRevert for bytes;
    using SafeERC20 for IERC20;

    // ============================================
    // TOKEN SUPPLY STATE (set once at initialization)
    // ============================================

    /// @notice Maximum total supply of this token (set at launch from factory config)
    uint256 public maxTotalSupply;

    /// @notice Tokens allocated to the Uniswap V4 pool at launch (maxTotalSupply - creatorLaunchReward)
    uint256 public poolLaunchSupply;

    /// @notice Tokens sent to the creator at launch (may be zero)
    uint256 public creatorLaunchReward;

    // ============================================
    // TRADING CONSTANTS
    // ============================================

    /// @notice Uniswap V4 pool fee tier (0% = 0)
    /// @dev Set to 0% to eliminate secondary rewards complexity
    uint24 internal constant LP_FEE = 0;
    uint256 internal constant MAX_POSITIONS = 25;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Factory address set at initialization
    /// @dev Used to pull configuration values directly from factory at call time
    address public factory;

    /// @notice Base token address (RARE) set at initialization
    /// @dev Set once during initialization and never changes
    address public baseToken;

    /// @notice Address of the token creator
    address public tokenCreator;

    /// @notice Metadata URI for the token
    string public initialTokenUri;

    /// @notice Render contract address for dynamic metadata (ERC-1046 compatible)
    /// @dev If set, tokenURI() will query this contract for metadata
    address public renderContract;

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
        QUOTE_SWAP_BUY,
        QUOTE_SWAP_SELL,
        MIGRATE_LIQUIDITY
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
    /// @param _creator The address of the liquid token creator (receives launch reward)
    /// @param _tokenUri The location of initial token metadata
    /// @param _name The liquid token name
    /// @param _symbol The liquid token symbol
    /// @param _minRequiredRareLiquidity The minimum RARE tokens (in wei) required to bootstrap the pool (threshold check)
    /// @param _maxTotalSupply Total token supply to mint at launch
    /// @param _creatorLaunchReward Tokens transferred to creator at launch (may be zero)
    function initialize(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _minRequiredRareLiquidity,
        uint256 _maxTotalSupply,
        uint256 _creatorLaunchReward
    ) external initializer {
        // Store factory address (msg.sender is factory during initialization)
        factory = msg.sender;

        // Read config from factory
        ILiquidFactory factoryContract = ILiquidFactory(factory);
        baseToken = factoryContract.baseToken();
        poolManager = factoryContract.poolManager();
        if (baseToken == address(0) || poolManager == address(0))
            revert AddressZero();

        // Validate that token URI is not empty string
        if (bytes(_tokenUri).length == 0) {
            revert InvalidTokenURI();
        }

        // Note: Initial liquidity is provided as RARE tokens, not ETH
        // The factory transfers RARE tokens to this contract before calling initialize()
        // We validate that we have received sufficient RARE tokens
        uint256 rareBalance = IERC20(baseToken).balanceOf(address(this));
        if (rareBalance < _minRequiredRareLiquidity) {
            revert RARELiquidityTooSmall();
        }

        // Validate the creation parameters
        if (_creator == address(0)) {
            revert AddressZero();
        }

        // Initialize base contracts (ERC20 and reentrancy guard)
        __ERC20_init(_name, _symbol);
        __ReentrancyGuard_init();

        // Store supply split (set-once; used by _deployPool and externally visible)
        maxTotalSupply = _maxTotalSupply;
        creatorLaunchReward = _creatorLaunchReward;
        poolLaunchSupply = _maxTotalSupply - _creatorLaunchReward;

        // Initialize liquid token state
        tokenCreator = _creator;
        initialTokenUri = _tokenUri;

        // Mint the entire total supply to this contract
        _mint(address(this), _maxTotalSupply);

        // Distribute launch rewards to creator (zero reward is valid — skip the transfer)
        if (_creatorLaunchReward > 0) {
            _transfer(address(this), _creator, _creatorLaunchReward);
        }

        // Deploy Uniswap V4 pool with two-sided liquidity (LIQUID + RARE)
        // Optimal starting price is calculated to use all provided RARE and LIQUID tokens
        _deployPool(rareBalance);
    }

    // ============================================
    // ERC20 FUNCTIONS
    // ============================================

    /// @notice Enables a user to burn their tokens
    /// @dev Standard ERC20 burn function, reduces total supply permanently
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external nonReentrant {
        _burn(msg.sender, amount);
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
    // METADATA FUNCTIONS (ERC-1046 COMPATIBLE)
    // ============================================

    /// @notice ERC-1046 compatible tokenURI function
    /// @dev Returns metadata URI, checking render contract first if set.
    ///      If render contract is set, attempts to call tokenURI() or tokenURI(0) on it.
    ///      Falls back to stored initialTokenUri if render contract is not set or call fails.
    /// @return The token URI string
    function tokenURI() external view returns (string memory) {
        // If render contract is set, try to get URI from it
        if (renderContract != address(0)) {
            // Try calling tokenURI() first (no parameters) using try/catch to handle decode failures
            try IRender(renderContract).tokenURI() returns (string memory uri) {
                // Validate that URI is not empty
                if (bytes(uri).length > 0) {
                    return uri;
                }
            } catch {
                // Decode failure or call reverted - continue to next attempt
            }

            // If tokenURI() failed, try tokenURI(0) for ERC721-style contracts
            try IRender(renderContract).tokenURI(uint256(0)) returns (
                string memory uri
            ) {
                // Validate that URI is not empty
                if (bytes(uri).length > 0) {
                    return uri;
                }
            } catch {
                // Decode failure or call reverted - fall back to stored initialTokenUri
            }
        }

        // Fall back to stored initialTokenUri
        return initialTokenUri;
    }

    /// @notice Sets the render contract address (only callable by token creator)
    /// @dev Allows token creator to set or update the render contract for dynamic metadata.
    ///      Can be set to address(0) to clear and use stored initialTokenUri instead.
    /// @param _renderContract The address of the render contract (can be address(0) to clear)
    function setRenderContract(address _renderContract) external {
        if (msg.sender != tokenCreator) {
            revert NotTokenCreator();
        }
        renderContract = _renderContract;
        emit RenderContractSet(_renderContract);
    }

    // ============================================
    // LIQUIDITY MANAGEMENT
    // ============================================

    /// @notice Atomically migrates all LP liquidity to a new pool with a different hook configuration
    /// @dev Only callable by the migration executor configured in the token's factory.
    ///      Removes liquidity from the old pool, initializes the new pool, and adds liquidity
    ///      to the new pool within a single PoolManager unlock callback. Tokens never leave the PoolManager.
    /// @param newPoolKey The target pool configuration (different hooks, same currencies)
    /// @param newSqrtPriceX96 The starting price for the new pool
    /// @param newPositions The liquidity positions to create in the new pool (must be exactly 1 for Instant)
    /// @param dustRecipient Address to receive any dust from rounding differences
    /// @param maxDust0 Maximum allowed positive net delta for currency0 during migration settlement
    /// @param maxDust1 Maximum allowed positive net delta for currency1 during migration settlement
    function migrateLiquidity(
        PoolKey calldata newPoolKey,
        uint160 newSqrtPriceX96,
        Position[] calldata newPositions,
        address dustRecipient,
        uint256 maxDust0,
        uint256 maxDust1
    ) external {
        address me = ILiquidFactory(factory).migrationExecutor();
        if (msg.sender != me) revert OnlyMigrationExecutor();
        if (lpLiquidity == 0) revert ZeroLiquidity();
        if (newPositions.length != 1) revert InvalidPositionCount();
        if (dustRecipient == address(0)) revert AddressZero();
        if (newPositions[0].salt != bytes32(0)) revert NonZeroSalt();

        // Defense-in-depth: verify currencies match even though executor validates this
        if (
            Currency.unwrap(newPoolKey.currency0) !=
            Currency.unwrap(poolKey.currency0) ||
            Currency.unwrap(newPoolKey.currency1) !=
            Currency.unwrap(poolKey.currency1)
        ) revert CurrencyMismatch();

        _unlockExpected = true;
        IPoolManager(poolManager).unlock(
            abi.encode(
                UnlockContext({
                    action: UnlockAction.MIGRATE_LIQUIDITY,
                    data: abi.encode(
                        newPoolKey,
                        newSqrtPriceX96,
                        newPositions,
                        dustRecipient,
                        maxDust0,
                        maxDust1
                    )
                })
            )
        );
        _unlockExpected = false;
    }

    // ============================================
    // MARKET STATE & QUOTE HELPERS
    // ============================================

    /// @inheritdoc ILiquidBase
    function getLaunchState()
        external
        pure
        returns (
            ILiquidBase.LaunchType launchType,
            bool poolLive,
            address auction,
            address strategyAddr
        )
    {
        return (
            ILiquidBase.LaunchType.INSTANT,
            true, // pool always live for instant
            address(0),
            address(0)
        );
    }

    /// @inheritdoc ILiquid
    function totalLiquidity() external view returns (uint128) {
        if (PoolId.unwrap(poolId) == bytes32(0)) return 0;
        return StateLibrary.getLiquidity(IPoolManager(poolManager), poolId);
    }

    /// @inheritdoc ILiquid
    function getCurrentPrice()
        external
        view
        returns (uint256 rarePerToken, uint256 tokenPerRare)
    {
        // Check if pool exists
        if (PoolId.unwrap(poolId) == bytes32(0)) {
            revert PoolNotInitialized();
        }

        // Read current price from pool
        IPoolManager pm = IPoolManager(poolManager);
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(pm, poolId);

        // Convert sqrtPriceX96 to actual price
        // price = token1/token0 = (sqrtPriceX96 / 2^96)^2 = sqrtPriceX96^2 / 2^192
        // Use Q192.64 fixed point for intermediate calculations
        // Use FullMath.mulDiv to prevent overflow when squaring uint160 sqrtPriceX96
        uint256 priceQ128 = FullMath.mulDiv(
            uint256(sqrtPriceX96),
            uint256(sqrtPriceX96),
            1 << 64
        ); // sqrtPriceX96^2 / 2^64
        uint256 denominatorQ128 = 1 << 128; // 2^192 / 2^64 = 2^128

        // Safety: if price is 0, return 0 for both (uninitialized or extreme state)
        if (priceQ128 == 0) {
            return (0, 0);
        }

        // Determine currency ordering based on address comparison
        bool baseTokenIsCurrency0 = baseToken < address(this);

        if (baseTokenIsCurrency0) {
            // baseToken (RARE) is currency0, LIQUID is currency1
            // price = LIQUID/RARE
            rarePerToken = FullMath.mulDiv(denominatorQ128, 1e18, priceQ128);
            tokenPerRare = FullMath.mulDiv(priceQ128, 1e18, denominatorQ128);
        } else {
            // LIQUID is currency0, baseToken (RARE) is currency1
            // price = RARE/LIQUID, so invert
            rarePerToken = FullMath.mulDiv(priceQ128, 1e18, denominatorQ128);
            tokenPerRare = FullMath.mulDiv(denominatorQ128, 1e18, priceQ128);
        }
    }

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
        )
    {
        // Check if pool exists
        if (PoolId.unwrap(poolId) == bytes32(0)) {
            revert PoolNotInitialized();
        }

        // Read current price from pool
        IPoolManager pm = IPoolManager(poolManager);
        (sqrtPriceX96, currentTick, , ) = StateLibrary.getSlot0(pm, poolId);

        // Get total pool liquidity
        liquidity = StateLibrary.getLiquidity(pm, poolId);

        // Get current supply
        currentSupply = totalSupply();

        // Convert sqrtPriceX96 to actual price (reuse logic from getCurrentPrice)
        // Use FullMath.mulDiv to prevent overflow when squaring uint160 sqrtPriceX96
        uint256 priceQ128 = FullMath.mulDiv(
            uint256(sqrtPriceX96),
            uint256(sqrtPriceX96),
            1 << 64
        );
        uint256 denominatorQ128 = 1 << 128;

        // Safety: if price is 0, return 0 for price values (uninitialized or extreme state)
        if (priceQ128 == 0) {
            return (0, 0, sqrtPriceX96, currentTick, liquidity, currentSupply);
        }

        // Determine currency ordering based on address comparison
        bool baseTokenIsCurrency0 = baseToken < address(this);

        if (baseTokenIsCurrency0) {
            // baseToken (RARE) is currency0, LIQUID is currency1
            // price = LIQUID/RARE
            rarePerToken = FullMath.mulDiv(denominatorQ128, 1e18, priceQ128);
            tokenPerRare = FullMath.mulDiv(priceQ128, 1e18, denominatorQ128);
        } else {
            // LIQUID is currency0, baseToken (RARE) is currency1
            // price = RARE/LIQUID, so invert
            rarePerToken = FullMath.mulDiv(priceQ128, 1e18, denominatorQ128);
            tokenPerRare = FullMath.mulDiv(denominatorQ128, 1e18, priceQ128);
        }
    }

    /// @notice Simulates a RARE to LIQUID swap (buy direction)
    /// @dev Simulates the swap via unlock callback. Uses revert-as-return pattern for gas-free simulation.
    ///      Not marked `view` (simulation reverts-to-return); use via eth_call.
    ///      Note: This quotes a direct RARE→LIQUID swap. For ETH→RARE→LIQUID routes, use LiquidRouter or client-side quoter.
    ///      Fees are collected by LiquidGuard at the pool level during swaps (if attached).
    /// @param rareIn Amount of RARE to swap
    /// @return liquidOut LIQUID tokens that would be received from the swap
    /// @return sqrtPriceX96After Post-swap sqrt price (useful for price impact calculations)
    function quoteBuy(
        uint256 rareIn
    ) external returns (uint256 liquidOut, uint160 sqrtPriceX96After) {
        return _simulateQuoteBuy(rareIn);
    }

    /// @notice Simulates a LIQUID to RARE swap (sell direction)
    /// @dev Simulates the swap via unlock callback. Uses revert-as-return pattern for gas-free simulation.
    ///      Not marked `view` (simulation reverts-to-return); use via eth_call.
    ///      Note: This quotes a direct LIQUID→RARE swap. For LIQUID→RARE→ETH routes, use LiquidRouter or client-side quoter.
    ///      Fees are collected by LiquidGuard at the pool level during swaps (if attached).
    /// @param liquidIn Amount of LIQUID tokens to swap
    /// @return rareOut RARE that would be received from the swap
    /// @return sqrtPriceX96After Post-swap sqrt price (useful for price impact calculations)
    function quoteSell(
        uint256 liquidIn
    ) external returns (uint256 rareOut, uint160 sqrtPriceX96After) {
        return _simulateQuoteSell(liquidIn);
    }

    // ============================================
    // INTERNAL POOL & SWAP FUNCTIONS
    // ============================================

    /// @notice Deploys the Uniswap V4 pool with initial liquidity
    /// @dev Creates pool if it doesn't exist, initializes with calculated price, and mints LP position.
    ///      The pool starts with two-sided liquidity: 900K LIQUID tokens + liquidityAmount RARE.
    /// @param liquidityAmount The amount of RARE tokens to provide as initial liquidity
    function _deployPool(uint256 liquidityAmount) internal {
        // Pull config directly from factory
        ILiquidFactory factoryContract = ILiquidFactory(factory);
        int24 tickLower = factoryContract.lpTickLower();
        int24 tickUpper = factoryContract.lpTickUpper();
        int24 tickSpacing = factoryContract.poolTickSpacing();
        address hooks = factoryContract.poolHooks();

        // Build PoolKey: RARE and LIQUID tokens
        // Currencies must be sorted by address (lower address is currency0)
        Currency currency0;
        Currency currency1;
        bool baseTokenIsCurrency0;

        if (baseToken < address(this)) {
            currency0 = Currency.wrap(baseToken);
            currency1 = Currency.wrap(address(this));
            baseTokenIsCurrency0 = true;
        } else {
            currency0 = Currency.wrap(address(this));
            currency1 = Currency.wrap(baseToken);
            baseTokenIsCurrency0 = false;
        }

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        // Compute PoolId
        poolId = poolKey.toId();

        // Determine tick values based on currency ordering
        //
        // CRITICAL: Uniswap V4 liquidity positions always have tickLower < tickUpper.
        // At any price within the range:
        // - Price near tickLower → position holds mostly currency0, little currency1
        // - Price near tickUpper → position holds mostly currency1, little currency0
        //
        // For our bonding curve to work correctly, we need:
        // - At start (cheap LIQUID): position holds mostly LIQUID tokens, little RARE
        // - At end (expensive LIQUID): position holds mostly RARE tokens, little LIQUID
        //
        // Case 1: RARE is currency0, LIQUID is currency1
        //   - Start at high tick (near tickUpper) → holds mostly LIQUID (currency1) ✓
        //   - Use tick range as configured: [tickLower, tickUpper]
        //
        // Case 2: LIQUID is currency0, RARE is currency1
        //   - Start at low tick (near tickLower) → holds mostly LIQUID (currency0) ✓
        //   - BUT we need to NEGATE and SWAP the tick range to maintain equivalent economics
        //   - Original range [tickLower, tickUpper] becomes [-tickUpper, -tickLower]
        //   - This ensures the position holds LIQUID at the cheap end regardless of ordering
        //
        // WHY NEGATION WORKS:
        // Negating a tick inverts the price ratio. If tick T represents price P = 1.0001^T,
        // then tick -T represents price 1/P = 1.0001^(-T).
        // Combined with swapping currency0/currency1, this creates equivalent economics.

        int24 effectiveTickLower;
        int24 effectiveTickUpper;

        if (baseTokenIsCurrency0) {
            // RARE is currency0 - use ticks as configured
            effectiveTickLower = tickLower;
            effectiveTickUpper = tickUpper;
        } else {
            // LIQUID is currency0 - negate and swap to maintain equivalent economics
            effectiveTickLower = -tickUpper;
            effectiveTickUpper = -tickLower;
        }

        // Ticks are already aligned to tickSpacing by LiquidFactory validation
        // (constructor, setLpTickLower, setLpTickUpper all enforce tick % spacing == 0).
        // Negation preserves alignment, so no rounding is needed here.
        lpTickLower = effectiveTickLower;
        lpTickUpper = effectiveTickUpper;

        if (lpTickLower >= lpTickUpper) revert InvalidTickRange();

        // Calculate liquidity bounds for the position
        // We're providing: liquidityAmount RARE + poolLaunchSupply LIQUID tokens
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(lpTickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(lpTickUpper);

        // Calculate optimal starting price that uses ALL provided liquidity
        // This replaces the edge-tick approach which left excess RARE trapped
        uint256 amount0;
        uint256 amount1;
        if (baseTokenIsCurrency0) {
            amount0 = liquidityAmount; // RARE is currency0
            amount1 = poolLaunchSupply; // LIQUID is currency1
        } else {
            amount0 = poolLaunchSupply; // LIQUID is currency0
            amount1 = liquidityAmount; // RARE is currency1
        }

        uint160 sqrtPriceX96 = _calculateOptimalStartingPrice(
            amount0,
            amount1,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96
        );

        // Calculate liquidity based on currency ordering
        if (baseTokenIsCurrency0) {
            // baseToken (RARE) is currency0, LIQUID is currency1
            // liquidityAmount RARE (currency0) + poolLaunchSupply LIQUID (currency1)
            lpLiquidity = _calculateLiquidity(
                sqrtPriceX96,
                sqrtPriceLowerX96,
                sqrtPriceUpperX96,
                liquidityAmount,
                poolLaunchSupply
            );
        } else {
            // LIQUID is currency0, baseToken (RARE) is currency1
            // poolLaunchSupply LIQUID (currency0) + liquidityAmount RARE (currency1)
            lpLiquidity = _calculateLiquidity(
                sqrtPriceX96,
                sqrtPriceLowerX96,
                sqrtPriceUpperX96,
                poolLaunchSupply,
                liquidityAmount
            );
        }

        // Ensure we have liquidity to add
        if (lpLiquidity == 0) revert ZeroLiquidity();

        // Initialize pool and add liquidity via unlock
        // Only sqrtPriceX96 is needed - settlement amounts are determined by BalanceDelta from modifyLiquidity()
        _unlockExpected = true;
        IPoolManager(poolManager).unlock(
            abi.encode(
                UnlockContext({
                    action: UnlockAction.INITIALIZE_POOL,
                    data: abi.encode(sqrtPriceX96)
                })
            )
        );
        _unlockExpected = false;

        // Emit event for pool graduation (market is now live)
        emit LiquidMarketGraduated(
            address(this),
            address(poolManager),
            liquidityAmount, // RARE amount
            poolLaunchSupply, // LIQUID amount
            uint256(lpLiquidity)
        );
    }

    /// @notice Simulate buy swap to obtain amount out + post-swap price
    /// @dev Uses revert-as-return pattern: triggers unlock callback with QUOTE_SWAP_BUY action,
    ///      which simulates the swap and reverts with QuoteResult containing the output.
    ///      This pattern allows gas-free simulation via eth_call while still executing V4 swap logic.
    ///      If the callback completes without reverting (unexpected), throws QuoteSimulationDidNotRevert.
    /// @param rareAmount Amount of RARE to simulate swapping
    /// @return amountOut Expected LIQUID tokens output from the swap
    /// @return sqrtPriceAfter Post-swap sqrt price
    function _simulateQuoteBuy(
        uint256 rareAmount
    ) internal returns (uint256 amountOut, uint160 sqrtPriceAfter) {
        _unlockExpected = true;
        try
            IPoolManager(poolManager).unlock(
                abi.encode(
                    UnlockContext({
                        action: UnlockAction.QUOTE_SWAP_BUY,
                        data: abi.encode(rareAmount)
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
    /// @return amountOut Expected RARE output from the swap
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
    ) external nonReentrant returns (bytes memory) {
        // Security: only PoolManager can call this
        if (msg.sender != poolManager) revert OnlyPoolManager();

        // Security: only during expected unlock operations
        if (!_unlockExpected) revert UnexpectedUnlock();

        UnlockContext memory ctx = abi.decode(data, (UnlockContext));

        if (ctx.action == UnlockAction.INITIALIZE_POOL) {
            return _unlockInitializePool(ctx.data);
        } else if (ctx.action == UnlockAction.QUOTE_SWAP_BUY) {
            return _unlockQuoteSwapBuy(ctx.data);
        } else if (ctx.action == UnlockAction.QUOTE_SWAP_SELL) {
            return _unlockQuoteSwapSell(ctx.data);
        } else if (ctx.action == UnlockAction.MIGRATE_LIQUIDITY) {
            return _unlockMigrateLiquidity(ctx.data);
        }

        revert UnexpectedUnlock();
    }

    /// @notice Initialize pool and add initial liquidity
    /// @dev Called during unlock callback. Initializes pool at optimal starting price, adds liquidity
    ///      to the configured tick range, settles token debts, and returns excess RARE to creator if any.
    ///      Uses internal transfer for LIQUID tokens to avoid external self-call.
    /// @param data Encoded sqrtPriceX96 (uint160)
    /// @return Empty bytes on success
    function _unlockInitializePool(
        bytes memory data
    ) internal returns (bytes memory) {
        uint160 sqrtPriceX96 = abi.decode(data, (uint160));

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
        // Settle currency0 debt (negative delta = we owe tokens)
        if (delta0 < 0) {
            uint128 owed0 = _toUint128Neg(delta0);
            address token0 = Currency.unwrap(poolKey.currency0);
            pm.sync(poolKey.currency0);
            if (token0 == address(this)) {
                // LIQUID token - use internal transfer (avoids external self-call)
                _transfer(address(this), address(pm), owed0);
            } else {
                // RARE token - use ERC20 transfer
                IERC20(token0).safeTransfer(address(pm), owed0);
            }
            pm.settle();
        }

        // Settle currency1 debt
        if (delta1 < 0) {
            uint128 owed1 = _toUint128Neg(delta1);
            address token1 = Currency.unwrap(poolKey.currency1);
            pm.sync(poolKey.currency1);
            if (token1 == address(this)) {
                // LIQUID token - use internal transfer (avoids external self-call)
                _transfer(address(this), address(pm), owed1);
            } else {
                // RARE token - use ERC20 transfer
                IERC20(token1).safeTransfer(address(pm), owed1);
            }
            pm.settle();
        }

        // Verify we used (nearly) all tokens - rounding may leave dust
        // Allow 1 wei tolerance for rounding errors
        uint256 remainingRare = IERC20(baseToken).balanceOf(address(this));
        if (remainingRare > 1) {
            // This indicates a calculation error - should not happen with optimal price calculation
            // Return excess to creator as failsafe
            IERC20(baseToken).safeTransfer(tokenCreator, remainingRare);
        }

        return "";
    }

    /// @notice Atomically migrate LP liquidity to a new pool
    /// @dev Called during unlock callback when migrateLiquidity() is invoked.
    ///      Removes liquidity from old position, initializes new pool, adds new position,
    ///      and settles net deltas. Tokens never leave the PoolManager.
    /// @param data Encoded (PoolKey, uint160, Position[], address, uint256, uint256)
    /// @return Empty bytes on success
    function _unlockMigrateLiquidity(
        bytes memory data
    ) internal returns (bytes memory) {
        (
            PoolKey memory newKey,
            uint160 newSqrtPrice,
            Position[] memory newPositions,
            address dustRecipient,
            uint256 maxDust0,
            uint256 maxDust1
        ) = abi.decode(
                data,
                (PoolKey, uint160, Position[], address, uint256, uint256)
            );

        IPoolManager pm = IPoolManager(poolManager);

        // Track net deltas across removal and addition
        int256 netDelta0;
        int256 netDelta1;

        // Phase 1: Remove old position (deltas stay in PoolManager)
        {
            (BalanceDelta delta, ) = pm.modifyLiquidity(
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: lpTickLower,
                    tickUpper: lpTickUpper,
                    liquidityDelta: -int128(uint128(lpLiquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            netDelta0 += delta.amount0();
            netDelta1 += delta.amount1();
        }

        // Phase 2: Initialize new pool
        pm.initialize(newKey, newSqrtPrice);

        // Phase 3: Add new position to new pool (use first position from array)
        Position memory newPos = newPositions[0];
        if (newPos.liquidity > uint128(type(int128).max)) {
            revert LiquidityTooLarge(newPos.liquidity);
        }

        {
            (BalanceDelta delta, ) = pm.modifyLiquidity(
                newKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: newPos.tickLower,
                    tickUpper: newPos.tickUpper,
                    liquidityDelta: int128(uint128(newPos.liquidity)),
                    salt: newPos.salt
                }),
                ""
            );
            netDelta0 += delta.amount0();
            netDelta1 += delta.amount1();
        }

        // Phase 4: Settle net deltas
        if (netDelta0 > 0) {
            if (uint256(netDelta0) > maxDust0) {
                revert DustExceeded(
                    Currency.unwrap(newKey.currency0),
                    uint256(netDelta0),
                    maxDust0
                );
            }
            pm.take(newKey.currency0, dustRecipient, uint256(netDelta0));
        } else if (netDelta0 < 0) {
            uint128 owed0 = _toUint128Neg256(netDelta0);
            address token0 = Currency.unwrap(newKey.currency0);
            pm.sync(newKey.currency0);
            if (token0 == address(this)) {
                _transfer(address(this), address(pm), owed0);
            } else {
                IERC20(token0).safeTransfer(address(pm), owed0);
            }
            pm.settle();
        }

        if (netDelta1 > 0) {
            if (uint256(netDelta1) > maxDust1) {
                revert DustExceeded(
                    Currency.unwrap(newKey.currency1),
                    uint256(netDelta1),
                    maxDust1
                );
            }
            pm.take(newKey.currency1, dustRecipient, uint256(netDelta1));
        } else if (netDelta1 < 0) {
            uint128 owed1 = _toUint128Neg256(netDelta1);
            address token1 = Currency.unwrap(newKey.currency1);
            pm.sync(newKey.currency1);
            if (token1 == address(this)) {
                _transfer(address(this), address(pm), owed1);
            } else {
                IERC20(token1).safeTransfer(address(pm), owed1);
            }
            pm.settle();
        }

        // Phase 5: Update pool state
        address oldHooks = address(poolKey.hooks);
        poolKey = newKey;
        poolId = newKey.toId();
        lpTickLower = newPos.tickLower;
        lpTickUpper = newPos.tickUpper;
        lpLiquidity = newPos.liquidity;

        emit LiquidityMigrated(oldHooks, address(newKey.hooks));

        return "";
    }

    /// @notice Quote helper for RARE -> LIQUID swaps (always reverts with QuoteResult)
    /// @dev Called during unlock callback to simulate buy swap. Executes V4 swap, validates delta signs,
    ///      extracts LIQUID output, and reverts with QuoteResult containing output and post-swap price.
    ///      Handles currency ordering (baseToken can be currency0 or currency1).
    /// @param data Encoded rareAmount (uint256)
    /// @return Empty bytes (never reached - always reverts with QuoteResult)
    function _unlockQuoteSwapBuy(
        bytes memory data
    ) internal returns (bytes memory) {
        uint256 rareAmount = abi.decode(data, (uint256));

        IPoolManager pm = IPoolManager(poolManager);

        // Determine swap direction based on currency ordering
        bool baseTokenIsCurrency0 = baseToken < address(this);
        bool zeroForOne = baseTokenIsCurrency0; // RARE -> LIQUID

        BalanceDelta delta = pm.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -SafeCast.toInt256(rareAmount),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Validate swap direction
        if (zeroForOne) {
            // RARE (currency0) -> LIQUID (currency1)
            if (delta0 >= 0) revert InvalidSwapDelta0(delta0);
            if (delta1 <= 0) revert InvalidSwapDelta1(delta1);
        } else {
            // LIQUID (currency0) -> RARE (currency1) - shouldn't happen for buy, but handle
            if (delta0 <= 0) revert InvalidSwapDelta0(delta0);
            if (delta1 >= 0) revert InvalidSwapDelta1(delta1);
        }

        uint256 tokensReceived = baseTokenIsCurrency0
            ? _toUint128Pos(delta1) // LIQUID is currency1
            : _toUint128Pos(delta0); // LIQUID is currency0
        (uint160 sqrtPriceAfter, , , ) = StateLibrary.getSlot0(
            pm,
            poolKey.toId()
        );

        revert QuoteResult(tokensReceived, sqrtPriceAfter);
    }

    /// @notice Quote helper for LIQUID -> RARE swaps (always reverts with QuoteResult)
    /// @dev Called during unlock callback to simulate sell swap. Executes V4 swap, validates delta signs,
    ///      extracts RARE output, and reverts with QuoteResult containing output and post-swap price.
    ///      Handles currency ordering (baseToken can be currency0 or currency1).
    /// @param data Encoded tokenAmount (uint256)
    /// @return Empty bytes (never reached - always reverts with QuoteResult)
    function _unlockQuoteSwapSell(
        bytes memory data
    ) internal returns (bytes memory) {
        uint256 tokenAmount = abi.decode(data, (uint256));

        IPoolManager pm = IPoolManager(poolManager);

        // Determine swap direction based on currency ordering
        bool baseTokenIsCurrency0 = baseToken < address(this);
        bool zeroForOne = !baseTokenIsCurrency0; // LIQUID -> RARE

        BalanceDelta delta = pm.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -SafeCast.toInt256(tokenAmount),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Validate swap direction
        if (zeroForOne) {
            // LIQUID (currency0) -> RARE (currency1)
            if (delta0 >= 0) revert InvalidSwapDelta0(delta0);
            if (delta1 <= 0) revert InvalidSwapDelta1(delta1);
        } else {
            // RARE (currency0) -> LIQUID (currency1) - shouldn't happen for sell, but handle
            if (delta0 <= 0) revert InvalidSwapDelta0(delta0);
            if (delta1 >= 0) revert InvalidSwapDelta1(delta1);
        }

        uint256 rareReceived = baseTokenIsCurrency0
            ? _toUint128Pos(delta0) // RARE is currency0
            : _toUint128Pos(delta1); // RARE is currency1
        (uint160 sqrtPriceAfter, , , ) = StateLibrary.getSlot0(
            pm,
            poolKey.toId()
        );

        revert QuoteResult(rareReceived, sqrtPriceAfter);
    }

    // ============================================
    // UTILITY FUNCTIONS
    // ============================================

    /// @dev Safe cast from uint256 to uint128 with overflow check
    /// @param value The uint256 value to cast
    /// @return The value as uint128
    function _toUint128Safe(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert AmountExceedsUint128(value);
        // Casting to uint128 is safe because we checked bounds above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    /// @notice Converts positive BalanceDelta amount to uint128
    /// @dev Safe cast helper for BalanceDelta conversions. Validates x >= 0 before casting.
    ///      Used to extract output amounts from swap deltas.
    /// @param x Positive int128 delta value
    /// @return uint128 representation of x
    function _toUint128Pos(int128 x) internal pure returns (uint128) {
        if (x < 0) revert NegativeValue(x);
        // Casting to uint128 is safe because we verified x >= 0
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(uint256(int256(x)));
    }

    /// @notice Converts negative BalanceDelta amount to uint128 (absolute value)
    /// @dev Safe cast helper for BalanceDelta conversions. Validates x <= 0, negates in 256-bit space
    ///      to avoid int128.min overflow, then casts to uint128. Used to extract input amounts from swap deltas.
    /// @param x Negative int128 delta value
    /// @return uint128 absolute value of x
    function _toUint128Neg(int128 x) internal pure returns (uint128) {
        if (x > 0) revert PositiveValue(x);
        int256 y = -int256(x); // negate in 256-bit space to avoid int128.min overflow
        // Casting to uint256 is safe because y is non-negative after negation
        // forge-lint: disable-next-line(unsafe-typecast) -- y is non-negative after negation, fits uint256
        if (uint256(y) > type(uint128).max)
            // forge-lint: disable-next-line(unsafe-typecast) -- y fits uint256, used for error reporting
            revert AmountExceedsUint128(uint256(y));
        // Casting to uint128 is safe because we checked bounds above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(uint256(y));
    }

    /// @notice Converts negative int256 to uint128 (absolute value)
    /// @dev Wide variant for accumulated deltas that may exceed int128 range.
    ///      Callers must ensure x <= 0 (enforced by require, not PositiveValue error
    ///      since that error takes int128 which would itself truncate).
    /// @param x Negative int256 delta value
    /// @return uint128 absolute value of x
    function _toUint128Neg256(int256 x) internal pure returns (uint128) {
        require(x <= 0, "positive value");
        uint256 y = uint256(-x);
        if (y > type(uint128).max) revert AmountExceedsUint128(y);
        return uint128(y);
    }

    /// @notice Calculates the starting sqrtPriceX96 that uses all provided liquidity
    /// @dev Solves the quadratic equation from Uniswap V4 liquidity math to find the exact
    ///      price where adding liquidity consumes all of both token amounts.
    ///
    ///      Given: amount0, amount1, sqrtLower, sqrtUpper
    ///      Find: sqrtPrice such that there exists L where:
    ///        L = amount0 * sqrtPrice * sqrtUpper / (sqrtUpper - sqrtPrice)
    ///        L = amount1 / (sqrtPrice - sqrtLower)
    ///
    ///      This reduces to quadratic: a*x² + b*x + c = 0 where x = sqrtPrice
    ///        a = amount0 * sqrtUpper
    ///        b = amount1 - amount0 * sqrtUpper * sqrtLower
    ///        c = -amount1 * sqrtUpper
    ///
    ///      Solution: x = (-b + sqrt(b² - 4ac)) / 2a
    ///
    /// @param amount0 Amount of currency0 to deposit
    /// @param amount1 Amount of currency1 to deposit
    /// @param sqrtPriceLowerX96 Lower bound sqrt price (Q64.96)
    /// @param sqrtPriceUpperX96 Upper bound sqrt price (Q64.96)
    /// @return sqrtPriceX96 The optimal starting price (Q64.96)
    function _calculateOptimalStartingPrice(
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96
    ) internal pure returns (uint160) {
        uint256 sqrtLower = uint256(sqrtPriceLowerX96);
        uint256 sqrtUpper = uint256(sqrtPriceUpperX96);

        // Calculate coefficient 'a' = amount0 * sqrtUpper / Q96
        // We scale down by Q96 to keep intermediate values manageable
        uint256 a = FullMath.mulDiv(amount0, sqrtUpper, FixedPoint96.Q96);

        // Calculate the term for 'b': amount0 * sqrtUpper * sqrtLower / Q96²
        uint256 bTerm = FullMath.mulDiv(
            FullMath.mulDiv(amount0, sqrtUpper, FixedPoint96.Q96),
            sqrtLower,
            FixedPoint96.Q96
        );

        // b = amount1 - bTerm (can be negative)
        bool bIsNegative = bTerm > amount1;
        uint256 bAbs = bIsNegative ? bTerm - amount1 : amount1 - bTerm;

        // |c| = amount1 * sqrtUpper / Q96
        uint256 cAbs = FullMath.mulDiv(amount1, sqrtUpper, FixedPoint96.Q96);

        // Discriminant D = b² + 4*a*|c| (positive since c is negative in original equation)
        // D = bAbs² + 4 * a * cAbs
        //
        // For very wide tick ranges (e.g. full-range MIN_TICK to MAX_TICK), 4*a*cAbs can
        // overflow uint256 because sqrtUpper is near MAX_SQRT_PRICE.  In that regime
        // 4ac >> b², so the quadratic solution reduces to the constant-product formula:
        //   sqrtPrice = Q96 * sqrt(amount1 / amount0)
        // We detect the overflow and return this exact result directly.
        uint256 fourA = 4 * a;
        if (fourA != 0 && cAbs > type(uint256).max / fourA) {
            // Overflow: use full-range constant-product formula
            // sqrtPriceX96 = sqrt(amount1 * Q96² / amount0)
            uint256 Q192 = uint256(FixedPoint96.Q96) *
                uint256(FixedPoint96.Q96);
            uint256 ratioQ192 = FullMath.mulDiv(amount1, Q192, amount0);
            uint256 sqrtPriceFullRange = Math.sqrt(ratioQ192);
            if (sqrtPriceFullRange <= sqrtLower)
                sqrtPriceFullRange = sqrtLower + 1;
            if (sqrtPriceFullRange >= sqrtUpper)
                sqrtPriceFullRange = sqrtUpper - 1;
            return uint160(sqrtPriceFullRange);
        }

        uint256 sqrtD = Math.sqrt(bAbs * bAbs + fourA * cAbs);

        // sqrtPrice = (-b + sqrt(D)) / (2a)
        // If b < 0 (bIsNegative = true):  sqrtPrice = (|b| + sqrtD) / (2a)
        // If b >= 0 (bIsNegative = false): sqrtPrice = (sqrtD - |b|) / (2a)
        uint256 numerator;
        if (bIsNegative) {
            numerator = bAbs + sqrtD;
        } else {
            // sqrtD >= |b| always because discriminant includes the 4ac term
            numerator = sqrtD > bAbs ? sqrtD - bAbs : 0;
        }

        // sqrtPrice = numerator / (2 * a) * Q96
        // Rewritten to avoid precision loss: sqrtPrice = numerator * Q96 / (2 * a)
        uint256 sqrtPrice = FullMath.mulDiv(numerator, FixedPoint96.Q96, 2 * a);

        // Clamp to valid range (within bounds)
        if (sqrtPrice <= sqrtLower) sqrtPrice = sqrtLower + 1;
        if (sqrtPrice >= sqrtUpper) sqrtPrice = sqrtUpper - 1;

        // forge-lint: disable-next-line(unsafe-typecast) -- sqrtPrice is uint256, fits uint160 (sqrtPriceX96 format)
        return uint160(sqrtPrice);
    }

    /// @notice Calculates liquidity for a given price range and token amounts
    /// @dev Uses Uniswap V4 math to compute liquidity when price is within the LP range.
    ///      This function is called during pool initialization with the optimal starting price
    ///      calculated by _calculateOptimalStartingPrice().
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
    /// @param amount0 Amount of currency0 (either RARE or LIQUID, depending on address ordering)
    /// @param amount1 Amount of currency1 (either RARE or LIQUID, depending on address ordering)
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
