// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Liquid} from "./Liquid.sol";
import {ILiquidFactory} from "./interfaces/ILiquidFactory.sol";

/// @title LiquidFactory
/// @notice Factory contract for creating Liquid token instances with centralized configuration management
/// @dev Uses OpenZeppelin's Clones pattern (EIP-1167 minimal proxy) for gas-efficient deployment.
///      Maintains global configuration with individual settable values. Each Liquid token reads
///      configuration directly from the factory at call time (no caching).
///      Each Liquid token is deployed as a clone of a master implementation.
contract LiquidFactory is AccessControl, ILiquidFactory {
    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The Liquid implementation contract address (master clone)
    /// @dev All new tokens are cloned from this implementation using EIP-1167
    address public liquidImplementation;

    // Protocol addresses
    address public weth;
    address public poolManager;
    address public v4Quoter;
    address public poolHooks;
    address public baseToken; // RARE token address

    // Trading knobs
    uint16 public internalMaxSlippageBps; // Slippage protection for secondary reward swaps
    uint256 public minRareLiquidityWei; // Minimum RARE tokens (in wei) required for pool bootstrap

    // LP band (used at pool deploy only)
    /// @notice Lower tick bound for LP positions (defines price range)
    /// @dev IMPORTANT: Tick semantics depend on token ordering at deployment time.
    ///      Uniswap V4 pools sort tokens by address (lower address = currency0).
    ///      Since Liquid token addresses vary, the token ordering can flip:
    ///      - If baseToken < liquidToken: baseToken is currency0, liquidToken is currency1
    ///      - If liquidToken < baseToken: liquidToken is currency0, baseToken is currency1
    ///
    ///      The bonding curve goal is: LIQUID tokens start "cheap" and become "expensive" as bought.
    ///      - When baseToken is currency0: price = LIQUID/RARE, so HIGH tick = cheap LIQUID
    ///      - When liquidToken is currency0: price = RARE/LIQUID, so LOW tick = cheap LIQUID
    ///
    ///      Liquid.sol handles this correctly by selecting the starting tick based on ordering:
    ///      - If baseToken is currency0: starts at tickUpper - 1 (high tick = cheap)
    ///      - If liquidToken is currency0: starts at tickLower + 1 (low tick = cheap)
    ///
    ///      These tick values are global and applied to all Liquid tokens, but their semantic
    ///      meaning (which end represents "cheap" vs "expensive") flips based on each token's
    ///      deployed address relative to baseToken. This ensures consistent bonding curve behavior.
    int24 public lpTickLower;

    /// @notice Upper tick bound for LP positions (defines price range)
    /// @dev See lpTickLower documentation for important details about token ordering semantics.
    int24 public lpTickUpper;

    /// @notice Tick spacing for Uniswap V4 pools (e.g., 60)
    /// @dev All ticks must be multiples of this spacing. Used when initializing pools.
    int24 public poolTickSpacing;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Constructor for LiquidFactory
    /// @dev Initializes the factory with global configuration and sets the owner.
    ///      Implementation must be set separately via setImplementation before creating tokens.
    /// @param _owner The owner of the factory (can update config and implementation)
    /// @param _weth The WETH contract address (Wrapped ETH for Uniswap V4)
    /// @param _poolManager The Uniswap V4 PoolManager address
    /// @param _lpTickLower The lower tick for LP positions (defines price range).
    ///                      NOTE: Semantic meaning depends on token ordering - see lpTickLower documentation.
    /// @param _lpTickUpper The upper tick for LP positions (defines price range).
    ///                      NOTE: Semantic meaning depends on token ordering - see lpTickLower documentation.
    /// @param _v4Quoter The Uniswap V4 Quoter contract address (used by quote helpers)
    /// @param _poolHooks The Uniswap V4 hooks contract for the pool (address(0) if none)
    /// @param _poolTickSpacing Tick spacing to use when initializing the V4 pool
    /// @param _internalMaxSlippageBps Maximum slippage for internal protocol swaps (0-5000 BPS)
    /// @param _minRareLiquidityWei Minimum RARE tokens (in wei) required for pool bootstrap (default: 1e15 = 0.001 RARE)
    constructor(
        address _owner,
        address _weth,
        address _poolManager,
        int24 _lpTickLower,
        int24 _lpTickUpper,
        address _v4Quoter,
        address _poolHooks,
        int24 _poolTickSpacing,
        uint16 _internalMaxSlippageBps,
        uint256 _minRareLiquidityWei
    ) {
        // Validate owner address
        if (_owner == address(0)) {
            revert AddressZero();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);

        // Validate all addresses are non-zero
        if (
            _weth == address(0) ||
            _poolManager == address(0) ||
            _v4Quoter == address(0)
        ) {
            revert AddressZero();
        }

        // Validate tick range (lower must be less than upper)
        if (_lpTickLower >= _lpTickUpper) {
            revert InvalidTickRange();
        }

        // Validate pool tick spacing (must be positive)
        if (_poolTickSpacing <= 0) revert InvalidTickSpacing();

        // Validate that ticks are multiples of tick spacing
        // This ensures Liquid won't need to round during pool initialization
        if (
            _lpTickLower % _poolTickSpacing != 0 ||
            _lpTickUpper % _poolTickSpacing != 0
        ) {
            revert InvalidTickSpacing();
        }

        // Validate trading knobs
        if (_internalMaxSlippageBps > 5000)
            revert SlippageTooHigh(_internalMaxSlippageBps, 5000); // Max 50%

        // Store configuration parameters
        weth = _weth;
        poolManager = _poolManager;
        v4Quoter = _v4Quoter;
        poolHooks = _poolHooks;
        lpTickLower = _lpTickLower;
        lpTickUpper = _lpTickUpper;
        poolTickSpacing = _poolTickSpacing;
        internalMaxSlippageBps = _internalMaxSlippageBps;
        minRareLiquidityWei = _minRareLiquidityWei;
    }

    // ============================================
    // TOKEN CREATION
    // ============================================

    /// @notice Creates a new Liquid token instance
    /// @dev Deploys a minimal proxy (clone) of the implementation, initializes it, and stores metadata.
    ///      Requires implementation and baseToken to be set. Transfers RARE tokens from caller for pool bootstrapping.
    ///      This function is permissionless - anyone can create a Liquid token.
    ///      A concierge service can still call this on behalf of users by passing their address as _creator.
    /// @param _creator The address of the token creator (receives fees and launch reward)
    /// @param _tokenUri The ERC20z token URI (metadata link)
    /// @param _name The token name
    /// @param _symbol The token symbol
    /// @param _initialRareLiquidity The amount of RARE tokens to provide as initial liquidity
    /// @return token The address of the created token
    function createLiquidToken(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _initialRareLiquidity
    ) external returns (address token) {
        // Ensure implementation is set before creating tokens
        if (liquidImplementation == address(0)) {
            revert ImplementationNotSet();
        }

        // Ensure baseToken is set
        if (baseToken == address(0)) {
            revert AddressZero();
        }

        // Validate creator address
        if (_creator == address(0)) {
            revert AddressZero();
        }

        // Validate minimum liquidity requirement
        if (_initialRareLiquidity < minRareLiquidityWei) {
            revert InvalidAmount();
        }

        // Deploy clone using EIP-1167 minimal proxy pattern
        // This creates a lightweight proxy that delegates all calls to liquidImplementation
        address clone = Clones.clone(liquidImplementation);

        // Transfer RARE tokens from sender to the new Liquid contract
        IERC20(baseToken).transferFrom(
            msg.sender,
            clone,
            _initialRareLiquidity
        );

        // Get Liquid instance through clone address
        Liquid liquid = Liquid(payable(clone));

        // Initialize the Liquid token (RARE tokens already transferred to clone)
        // The clone will call initialize() which sets up ERC20, creates Uniswap V4 pool, etc.
        liquid.initialize(
            _creator,
            _tokenUri,
            _name,
            _symbol,
            minRareLiquidityWei
        );

        // Emit event for indexing
        emit LiquidTokenCreated(clone, _creator, _tokenUri);

        return clone;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @notice Sets or updates the Liquid implementation address
    /// @dev Can be called multiple times to update the implementation.
    ///      Warning: Only affects newly created tokens. Existing tokens continue using old implementation.
    ///      Use with caution. Ensure new implementation is compatible.
    /// @param _implementation The implementation address (master clone)
    function setImplementation(
        address _implementation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Validate implementation address
        if (_implementation == address(0)) {
            revert AddressZero();
        }

        // Store old implementation for event
        address oldImplementation = liquidImplementation;

        // Set/update implementation for cloning
        liquidImplementation = _implementation;

        // Emit event (oldImplementation will be address(0) on first call)
        emit ImplementationUpdated(oldImplementation, _implementation);
    }

    /// @notice Sets the WETH address
    function setWeth(address _weth) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_weth == address(0)) revert AddressZero();
        weth = _weth;
        emit WethUpdated(_weth);
    }

    /// @notice Sets the Uniswap V4 PoolManager address
    function setPoolManager(
        address _poolManager
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_poolManager == address(0)) revert AddressZero();
        poolManager = _poolManager;
        emit PoolManagerUpdated(_poolManager);
    }

    /// @notice Sets the Uniswap V4 Quoter address
    function setV4Quoter(
        address _v4Quoter
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_v4Quoter == address(0)) revert AddressZero();
        v4Quoter = _v4Quoter;
        emit V4QuoterUpdated(_v4Quoter);
    }

    /// @notice Sets the Uniswap V4 hooks address (optional)
    function setPoolHooks(
        address _poolHooks
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        poolHooks = _poolHooks;
        emit PoolHooksUpdated(_poolHooks);
    }

    /// @notice Sets the Uniswap V4 tick spacing
    /// @dev Validates that current lpTickLower and lpTickUpper are multiples of the new spacing
    function setPoolTickSpacing(
        int24 _poolTickSpacing
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_poolTickSpacing <= 0) revert InvalidTickSpacing();
        // Ensure existing tick bounds are compatible with new spacing
        if (
            lpTickLower % _poolTickSpacing != 0 ||
            lpTickUpper % _poolTickSpacing != 0
        ) {
            revert InvalidTickSpacing();
        }
        poolTickSpacing = _poolTickSpacing;
        emit PoolTickSpacingUpdated(_poolTickSpacing);
    }

    /// @notice Sets the internal max slippage BPS
    /// @param _slippageBps Maximum slippage for internal protocol swaps (must be <= 5000 BPS / 50%)
    function setInternalMaxSlippageBps(
        uint16 _slippageBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_slippageBps > 5000) revert SlippageTooHigh(_slippageBps, 5000);
        internalMaxSlippageBps = _slippageBps;
        emit InternalMaxSlippageBpsUpdated(_slippageBps);
    }

    /// @notice Sets the minimum RARE liquidity required for pool bootstrap
    /// @param _minRareLiquidityWei Minimum RARE tokens (in wei) required for pool bootstrap
    function setMinRareLiquidityWei(
        uint256 _minRareLiquidityWei
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minRareLiquidityWei = _minRareLiquidityWei;
        emit MinRareLiquidityWeiUpdated(_minRareLiquidityWei);
    }

    /// @notice Sets the LP tick lower bound
    /// @dev Validates that lower < upper and that tick is a multiple of poolTickSpacing.
    ///      NOTE: The semantic meaning of "lower" vs "upper" depends on token ordering.
    ///      See lpTickLower documentation for details on how Liquid.sol interprets these values
    ///      based on whether baseToken or liquidToken is currency0.
    /// @param _lower Lower tick for LP positions
    function setLpTickLower(
        int24 _lower
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_lower >= lpTickUpper) revert InvalidTickRange();
        if (_lower % poolTickSpacing != 0) revert InvalidTickSpacing();
        lpTickLower = _lower;
        emit LpTickLowerUpdated(_lower);
    }

    /// @notice Sets the LP tick upper bound
    /// @dev Validates that lower < upper and that tick is a multiple of poolTickSpacing.
    ///      NOTE: The semantic meaning of "lower" vs "upper" depends on token ordering.
    ///      See lpTickLower documentation for details on how Liquid.sol interprets these values
    ///      based on whether baseToken or liquidToken is currency0.
    /// @param _upper Upper tick for LP positions
    function setLpTickUpper(
        int24 _upper
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (lpTickLower >= _upper) revert InvalidTickRange();
        if (_upper % poolTickSpacing != 0) revert InvalidTickSpacing();
        lpTickUpper = _upper;
        emit LpTickUpperUpdated(_upper);
    }

    /// @notice Sets the base token address (RARE)
    /// @dev Must be set before creating Liquid tokens. Used for pool creation.
    /// @param _baseToken The base token address (RARE)
    function setBaseToken(
        address _baseToken
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_baseToken == address(0)) revert AddressZero();
        baseToken = _baseToken;
        emit BaseTokenUpdated(_baseToken);
    }
}
