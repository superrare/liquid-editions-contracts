// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

import {ILiquidBase} from "liquid-editions/interfaces/ILiquidBase.sol";
import {ILiquidGraduated} from "liquid-editions/interfaces/ILiquidGraduated.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {IRender} from "liquid-editions/interfaces/IRender.sol";
import {ILBPStrategy} from "liquid-editions/interfaces/ILBPStrategy.sol";

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

/// @title LiquidGraduated
/// @notice A liquid edition token launched via CCA auction; pool is created at graduation with auction-discovered price.
/// @dev Same data surface as LiquidInstant post-graduation. Pre-graduation: no pool; auction views available.
///      Uses a clone pattern for gas-efficient deployment via LiquidFactory.
contract LiquidGraduated is
    ILiquidGraduated,
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
    // TRADING CONSTANTS
    // ============================================

    /// @notice Uniswap V4 pool fee tier (0% = 0)
    /// @dev Set to 0% to eliminate secondary rewards complexity
    uint24 internal constant LP_FEE = 0;

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

    /// @notice LBP strategy contract (holds auction, deploys pool on migrate)
    address public strategy;

    /// @notice Snapshot of pool tick spacing at init (prevents admin drift)
    int24 public snapshotTickSpacing;

    /// @notice Snapshot of pool hooks at init (= strategy address)
    address public snapshotPoolHooks;

    /// @notice LP tick bounds and liquidity (0 for graduated - strategy owns LP position)
    int24 public lpTickLower;
    int24 public lpTickUpper;
    uint128 public lpLiquidity;

    // ============================================
    // UNLOCK CALLBACK STATE
    // ============================================

    enum UnlockAction {
        QUOTE_SWAP_BUY,
        QUOTE_SWAP_SELL
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

    /// @notice Initializes a new liquid token with LBP strategy (no pool yet)
    /// @dev Called once by factory after cloning. This is the first phase of graduated launch:
    ///
    ///      **Phase 1: Initialization (this function)**
    ///      - Mints all tokens (1M total supply)
    ///      - Sends creator reward (100K tokens)
    ///      - Sends LP supply (900K tokens) to strategy
    ///      - Strategy creates CCA auction
    ///      - Pool is NOT created yet (no Uniswap V4 pool exists)
    ///
    ///      **Phase 2: Auction (after initialization)**
    ///      - Users bid on auction using LiquidAuctioneer.bid()
    ///      - Auction discovers price through bidding mechanism
    ///      - Auction ends after specified duration
    ///
    ///      **Phase 3: Graduation (after auction ends)**
    ///      - Anyone can call strategy.migrate() to create pool
    ///      - Pool is created at auction-discovered price
    ///      - Token "graduates" from auction to live trading
    ///      - _isPoolLive() returns true after graduation
    ///
    ///      The relationship: strategy → auction → pool
    ///      - strategy holds tokens and creates auction
    ///      - auction runs price discovery
    ///      - strategy.migrate() creates pool at discovered price
    /// @param _creator The address of the liquid token creator (receives launch reward)
    /// @param _tokenUri The location of initial token metadata
    /// @param _name The liquid token name
    /// @param _symbol The liquid token symbol
    /// @param _strategy The LBP strategy contract (receives POOL_LAUNCH_SUPPLY, creates auction)
    /// @param _poolHooksOverride When non-zero, use as pool hooks (e.g. strategy for FullRangeLBPStrategy). When zero, use factory.poolHooks().
    function initialize(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        address _strategy,
        address _poolHooksOverride
    ) external initializer {
        factory = msg.sender;

        ILiquidFactory factoryContract = ILiquidFactory(factory);
        baseToken = factoryContract.baseToken();
        poolManager = factoryContract.poolManager();
        if (baseToken == address(0) || poolManager == address(0))
            revert AddressZero();
        if (bytes(_tokenUri).length == 0) revert InvalidTokenURI();
        if (_creator == address(0)) revert AddressZero();
        if (_strategy == address(0)) revert AddressZero();

        __ERC20_init(_name, _symbol);
        __ReentrancyGuard_init();

        tokenCreator = _creator;
        initialTokenUri = _tokenUri;
        strategy = _strategy;

        // Snapshot pool config at init (prevents admin drift)
        snapshotTickSpacing = factoryContract.poolTickSpacing();
        snapshotPoolHooks = _poolHooksOverride != address(0)
            ? _poolHooksOverride
            : factoryContract.poolHooks();

        // Pre-compute poolKey and poolId
        _computeAndSetPoolKey();

        _mint(address(this), MAX_TOTAL_SUPPLY);
        _transfer(address(this), _creator, CREATOR_LAUNCH_REWARD);
        _transfer(address(this), _strategy, POOL_LAUNCH_SUPPLY);
        // Factory calls strategy.onTokensReceived() after this
    }

    /// @notice Computes poolKey from snapshotted config and sets poolId
    /// @dev Uses snapshotTickSpacing and snapshotPoolHooks (set at init) - prevents admin drift
    function _computeAndSetPoolKey() internal {
        // Sort currencies by address (Uniswap requirement)
        Currency currency0;
        Currency currency1;
        if (baseToken < address(this)) {
            currency0 = Currency.wrap(baseToken);
            currency1 = Currency.wrap(address(this));
        } else {
            currency0 = Currency.wrap(address(this));
            currency1 = Currency.wrap(baseToken);
        }

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: snapshotTickSpacing,
            hooks: IHooks(snapshotPoolHooks)
        });

        poolId = poolKey.toId();
    }

    /// @notice Updates the pool ID after strategy migration (factory only)
    /// @dev Called by factory after strategy.migrate() creates the Uniswap V4 pool.
    ///      During initialization, poolId is computed from poolKey (pre-computed from snapshotted config).
    ///      However, after migration, the actual pool may have a different ID if pool parameters changed.
    ///      This function allows factory to update poolId to match the actual deployed pool.
    ///      Only callable by factory (prevents unauthorized pool ID changes).
    /// @param _newPoolId The new pool ID from the migrated pool
    function setPoolId(PoolId _newPoolId) external {
        if (msg.sender != factory) revert NotMigrator();
        if (PoolId.unwrap(_newPoolId) == bytes32(0)) {
            revert InvalidPoolId();
        }
        emit PoolIdUpdated(poolId, _newPoolId);
        poolId = _newPoolId;
    }

    /// @inheritdoc ILiquidGraduated
    function isGraduated() external view returns (bool) {
        return _isPoolLive();
    }

    /// @inheritdoc ILiquidGraduated
    function auctionAddress() external view returns (address) {
        return
            strategy == address(0)
                ? address(0)
                : ILBPStrategy(strategy).initializer();
    }

    /// @inheritdoc ILiquidGraduated
    function getAuctionState()
        external
        view
        returns (address auction, bool graduated, address strategyAddr)
    {
        return (
            strategy == address(0)
                ? address(0)
                : ILBPStrategy(strategy).initializer(),
            _isPoolLive(),
            strategy
        );
    }

    /// @inheritdoc ILiquidBase
    function getLaunchState()
        external
        view
        returns (
            ILiquidBase.LaunchType launchType,
            bool poolLive,
            address auction,
            address strategyAddr
        )
    {
        return (
            ILiquidBase.LaunchType.GRADUATED,
            _isPoolLive(),
            strategy == address(0)
                ? address(0)
                : ILBPStrategy(strategy).initializer(),
            strategy
        );
    }

    /// @notice Returns whether the pool has been initialized (graduation detection)
    /// @dev This function detects if the token has "graduated" from auction to live pool.
    ///      Graduation flow:
    ///      1. Token is created with strategy (auction is active, no pool yet)
    ///      2. Auction runs and discovers price through bidding
    ///      3. After auction ends, anyone can call strategy.migrate()
    ///      4. strategy.migrate() creates Uniswap V4 pool at auction-discovered price
    ///      5. Pool initialization sets sqrtPriceX96 to non-zero value
    ///      6. This function detects graduation by checking if sqrtPriceX96 != 0
    ///
    ///      Before graduation: sqrtPriceX96 = 0 (pool not initialized)
    ///      After graduation: sqrtPriceX96 != 0 (pool initialized with discovered price)
    /// @return True if pool has been initialized (graduated), false if still in auction phase
    function _isPoolLive() internal view returns (bool) {
        if (strategy == address(0)) return false;
        // Read pool slot0 - sqrtPriceX96 is 0 if pool hasn't been initialized
        (uint160 sqrtPriceX96, , , ) = IPoolManager(poolManager).getSlot0(
            poolId
        );
        // Non-zero sqrtPriceX96 means pool was initialized (graduated)
        return sqrtPriceX96 != 0;
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

    /// @notice Not applicable for graduated tokens (LP managed by strategy/PositionManager)
    function removeLiquidity(address) external pure {
        revert("Graduated: use strategy");
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
    // QUOTE HELPERS (STATIC CALL ONLY - NOT VIEW)
    // ============================================

    /**
     * @notice Returns the current raw pool price (no fees) in both directions
     * @dev Reads directly from Uniswap V4 pool slot0. Returns WEI values scaled to 1e18.
     *      sqrtPriceX96 represents sqrt(token1/token0) * 2^96.
     *      Converts to actual price ratios and returns both directions.
     *      Uses FullMath.mulDiv to prevent overflow on extreme prices.
     *      Price is in RARE (base token), not ETH. Use client-side quoter for ETH prices.
     * @return rarePerToken WEI of RARE per 1e18 tokens
     * @return tokenPerRare WEI of tokens per 1e18 RARE
     */
    function getCurrentPrice()
        external
        view
        returns (uint256 rarePerToken, uint256 tokenPerRare)
    {
        // Check if pool exists (strategy.migrate() must have been called)
        if (!_isPoolLive()) {
            revert PoolNotInitialized();
        }

        // Read current price from pool
        IPoolManager pm = IPoolManager(poolManager);
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(poolId);

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

    /**
     * @notice Returns all market state for rendering in a single call
     * @dev Useful for render contracts and frontends that need multiple data points.
     *      Combines price, pool state, and supply info to minimize RPC calls.
     * @return rarePerToken Current price (RARE per 1e18 LIQUID tokens)
     * @return tokenPerRare Inverse price (LIQUID tokens per 1e18 RARE)
     * @return sqrtPriceX96 Raw Uniswap pool price (Q64.96 format)
     * @return currentTick Current tick position in the pool
     * @return liquidity Current total pool liquidity
     * @return currentSupply Total tokens in circulation (totalSupply())
     */
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
        // Check if pool exists (strategy.migrate() must have been called)
        if (!_isPoolLive()) {
            revert PoolNotInitialized();
        }

        // Read current price from pool
        IPoolManager pm = IPoolManager(poolManager);
        (sqrtPriceX96, currentTick, , ) = pm.getSlot0(poolId);

        // Get total pool liquidity
        liquidity = pm.getLiquidity(poolId);

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

    /**
     * @notice Simulates a RARE to LIQUID swap (buy direction).
     * @dev Simulates the swap via unlock callback. Uses revert-as-return pattern for gas-free simulation.
     *      Not marked `view` (simulation reverts-to-return); use via eth_call.
     *      Note: This quotes a direct RARE→LIQUID swap. For ETH→RARE→LIQUID routes, use LiquidRouter or client-side quoter.
     *      Fees are handled by LiquidRouter during actual trades.
     * @param rareIn Amount of RARE to swap
     * @return liquidOut LIQUID tokens that would be received from the swap
     * @return sqrtPriceX96After Post-swap sqrt price (useful for price impact calculations)
     */
    function quoteBuy(
        uint256 rareIn
    ) external returns (uint256 liquidOut, uint160 sqrtPriceX96After) {
        return _simulateQuoteBuy(rareIn);
    }

    /**
     * @notice Simulates a LIQUID to RARE swap (sell direction).
     * @dev Simulates the swap via unlock callback. Uses revert-as-return pattern for gas-free simulation.
     *      Not marked `view` (simulation reverts-to-return); use via eth_call.
     *      Note: This quotes a direct LIQUID→RARE swap. For LIQUID→RARE→ETH routes, use LiquidRouter or client-side quoter.
     *      Fees are handled by LiquidRouter during actual trades.
     * @param liquidIn Amount of LIQUID tokens to swap
     * @return rareOut RARE that would be received from the swap
     * @return sqrtPriceX96After Post-swap sqrt price (useful for price impact calculations)
     */
    function quoteSell(
        uint256 liquidIn
    ) external returns (uint256 rareOut, uint160 sqrtPriceX96After) {
        return _simulateQuoteSell(liquidIn);
    }

    // ============================================
    // INTERNAL POOL & SWAP FUNCTIONS
    // ============================================

    /// @notice Simulate buy swap to obtain amount out + post-swap price
    /// @dev Uses revert-as-return pattern: triggers unlock callback with QUOTE_SWAP_BUY action,
    ///      which simulates the swap and reverts with QuoteResult containing the output.
    ///      This pattern allows gas-free simulation via eth_call while still executing V4 swap logic.
    ///      If the callback completes without reverting (unexpected), throws QuoteSimulationDidNotRevert.
    /// @param rareAmount Amount of RARE to simulate swapping (after fees)
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
    /// @return amountOut Expected RARE output from the swap (before fees)
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

        if (ctx.action == UnlockAction.QUOTE_SWAP_BUY) {
            return _unlockQuoteSwapBuy(ctx.data);
        } else if (ctx.action == UnlockAction.QUOTE_SWAP_SELL) {
            return _unlockQuoteSwapSell(ctx.data);
        }

        revert UnexpectedUnlock();
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
        (uint160 sqrtPriceAfter, , , ) = pm.getSlot0(poolKey.toId());

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
        (uint160 sqrtPriceAfter, , , ) = pm.getSlot0(poolKey.toId());

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
}
