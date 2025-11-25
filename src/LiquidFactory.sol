// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Liquid} from "./Liquid.sol";
import {ILiquidFactory} from "./interfaces/ILiquidFactory.sol";

/// @title LiquidFactory
/// @notice Factory contract for creating Liquid token instances with centralized configuration management
/// @dev Uses OpenZeppelin's Clones pattern (EIP-1167 minimal proxy) for gas-efficient deployment.
///      Maintains global configuration with individual settable values. Each Liquid token reads
///      configuration directly from the factory at call time (no caching).
///      Each Liquid token is deployed as a clone of a master implementation, reducing deployment costs by ~90%.
contract LiquidFactory is Ownable, ILiquidFactory {
    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The Liquid implementation contract address (master clone)
    /// @dev All new tokens are cloned from this implementation using EIP-1167
    address public liquidImplementation;

    /// @notice Total fee for new tokens (TIER 1)
    /// @dev Applied as percentage of trade amount (e.g., 100 BPS = 1%)
    uint256 public totalFeeBPS;

    /// @notice Creator fee for new tokens (TIER 2)
    /// @dev Applied as percentage of collected fees (e.g., 2500 BPS = 25%)
    uint256 public creatorFeeBPS;

    /// @notice RARE burn fee for new tokens (TIER 3)
    /// @dev Applied as percentage of collected fees (e.g., 2500 BPS = 25%)
    uint256 public rareBurnFeeBPS;

    /// @notice Protocol fee for new tokens (TIER 3)
    /// @dev Applied as percentage of collected fees (e.g., 2500 BPS = 25%)
    uint256 public protocolFeeBPS;

    /// @notice Referrer fee for new tokens (TIER 3)
    /// @dev Applied as percentage of collected fees (e.g., 2500 BPS = 25%)
    uint256 public referrerFeeBPS;

    // Protocol addresses
    address public protocolFeeRecipient;
    address public weth;
    address public rareBurner;
    address public poolManager;
    address public v4Quoter;
    address public poolHooks;

    // Trading knobs
    uint16 public internalMaxSlippageBps; // Slippage protection for secondary reward swaps
    uint128 public minOrderSizeWei; // Minimum ETH -> LIQUID purchase amount
    uint256 public minInitialLiquidityWei; // Minimum ETH for pool bootstrap

    // LP band (used at pool deploy only)
    int24 public lpTickLower;
    int24 public lpTickUpper;
    int24 public poolTickSpacing;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Constructor for LiquidFactory
    /// @dev Initializes the factory with global configuration and sets the owner.
    ///      Implementation must be set separately via setImplementation.
    /// @param _owner The owner of the factory (can update config and implementation)
    /// @param _protocolFeeRecipient The protocol fee recipient address
    /// @param _weth The WETH contract address (Wrapped ETH for Uniswap V4)
    /// @param _poolManager The Uniswap V4 PoolManager address
    /// @param _rareBurner The RARE burner accumulator contract address
    /// @param _rareBurnFeeBPS TIER 3: Burn's share of remainder after creator fee (0-10000 BPS)
    /// @param _protocolFeeBPS TIER 3: Protocol's share of remainder after creator fee (0-10000 BPS)
    /// @param _referrerFeeBPS TIER 3: Referrer's share of remainder after creator fee (0-10000 BPS)
    /// @param _totalFeeBPS Default total fee for new tokens (TIER 1, e.g., 100 for 1%)
    /// @param _creatorFeeBPS Default creator fee for new tokens (TIER 2, e.g., 2500 for 25%)
    /// @param _lpTickLower The lower tick for LP positions (defines price range)
    /// @param _lpTickUpper The upper tick for LP positions (defines price range)
    /// @param _v4Quoter The Uniswap V4 Quoter contract address (used by quote helpers)
    /// @param _poolHooks The Uniswap V4 hooks contract for the pool (address(0) if none)
    /// @param _poolTickSpacing Tick spacing to use when initializing the V4 pool
    /// @param _internalMaxSlippageBps Maximum slippage for internal protocol swaps (0-5000 BPS)
    /// @param _minOrderSizeWei Minimum order size in wei
    /// @param _minInitialLiquidityWei Minimum ETH for pool bootstrap (default: 1e15 = 0.001 ETH)
    constructor(
        address _owner,
        address _protocolFeeRecipient,
        address _weth,
        address _poolManager,
        address _rareBurner,
        uint256 _rareBurnFeeBPS,
        uint256 _protocolFeeBPS,
        uint256 _referrerFeeBPS,
        uint256 _totalFeeBPS,
        uint256 _creatorFeeBPS,
        int24 _lpTickLower,
        int24 _lpTickUpper,
        address _v4Quoter,
        address _poolHooks,
        int24 _poolTickSpacing,
        uint16 _internalMaxSlippageBps,
        uint128 _minOrderSizeWei,
        uint256 _minInitialLiquidityWei
    ) Ownable(_owner) {
        // Validate all addresses are non-zero
        if (
            _protocolFeeRecipient == address(0) ||
            _weth == address(0) ||
            _poolManager == address(0) ||
            _rareBurner == address(0) ||
            _v4Quoter == address(0)
        ) {
            revert AddressZero();
        }

        // Validate TIER 3 fees sum to exactly 100%
        uint256 tier3Total = _rareBurnFeeBPS +
            _protocolFeeBPS +
            _referrerFeeBPS;
        if (tier3Total != 10000) {
            revert InvalidFeeDistribution(); // Must be exactly 100%
        }

        // Validate default fee parameters
        if (_totalFeeBPS > 9000) revert FeeTooHigh(_totalFeeBPS, 9000); // Max 90%
        if (_creatorFeeBPS > 9000) revert FeeTooHigh(_creatorFeeBPS, 9000); // Max 90%

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
        totalFeeBPS = _totalFeeBPS;
        creatorFeeBPS = _creatorFeeBPS;
        protocolFeeRecipient = _protocolFeeRecipient;
        weth = _weth;
        rareBurner = _rareBurner;
        poolManager = _poolManager;
        v4Quoter = _v4Quoter;
        poolHooks = _poolHooks;
        rareBurnFeeBPS = _rareBurnFeeBPS;
        protocolFeeBPS = _protocolFeeBPS;
        referrerFeeBPS = _referrerFeeBPS;
        lpTickLower = _lpTickLower;
        lpTickUpper = _lpTickUpper;
        poolTickSpacing = _poolTickSpacing;
        internalMaxSlippageBps = _internalMaxSlippageBps;
        minOrderSizeWei = _minOrderSizeWei;
        minInitialLiquidityWei = _minInitialLiquidityWei;
    }

    // ============================================
    // TOKEN CREATION
    // ============================================

    /// @notice Creates a new Liquid token instance
    /// @dev Deploys a minimal proxy (clone) of the implementation, initializes it, and stores metadata.
    ///      Requires implementation to be set. Forwards msg.value to initialize function for pool bootstrapping.
    /// @param _creator The address of the token creator (receives fees and launch reward)
    /// @param _tokenUri The ERC20z token URI (metadata link)
    /// @param _name The token name
    /// @param _symbol The token symbol
    /// @return token The address of the created token
    function createLiquidToken(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol
    ) external payable returns (address token) {
        // Ensure implementation is set before creating tokens
        if (liquidImplementation == address(0)) {
            revert ImplementationNotSet();
        }

        // Validate creator address
        if (_creator == address(0)) {
            revert AddressZero();
        }

        // Deploy clone using EIP-1167 minimal proxy pattern
        // This creates a lightweight proxy that delegates all calls to liquidImplementation
        address clone = Clones.clone(liquidImplementation);

        // Get Liquid instance through clone address
        Liquid liquid = Liquid(payable(clone));

        // Initialize the Liquid token (msg.value is forwarded for pool bootstrapping)
        // The clone will call initialize() which sets up ERC20, creates Uniswap V4 pool, etc.
        liquid.initialize{value: msg.value}(
            _creator,
            _tokenUri,
            _name,
            _symbol,
            totalFeeBPS,
            creatorFeeBPS,
            minInitialLiquidityWei
        );

        // Emit event for indexing
        emit LiquidTokenCreated(clone, _creator, _tokenUri);

        return clone;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @notice Sets the initial Liquid implementation address
    /// @dev Should be called once after factory deployment, before creating any tokens
    /// @param _implementation The implementation address (master clone)
    function setImplementation(address _implementation) external onlyOwner {
        // Validate implementation address
        if (_implementation == address(0)) {
            revert AddressZero();
        }

        // Set implementation for cloning
        liquidImplementation = _implementation;

        // Emit event (with address(0) as old implementation to indicate initial setup)
        emit ImplementationUpdated(address(0), _implementation);
    }

    /// @notice Updates the Liquid implementation address
    /// @dev Warning: Only affects newly created tokens. Existing tokens continue using old implementation.
    ///      Use with caution. Ensure new implementation is compatible.
    /// @param _newImplementation The new implementation address
    function updateImplementation(
        address _newImplementation
    ) external onlyOwner {
        // Validate new implementation address
        if (_newImplementation == address(0)) {
            revert AddressZero();
        }

        // Store old implementation for event
        address oldImplementation = liquidImplementation;

        // Update implementation
        liquidImplementation = _newImplementation;

        // Emit event for tracking
        emit ImplementationUpdated(oldImplementation, _newImplementation);
    }

    /// @notice Sets the protocol fee recipient address
    function setProtocolFeeRecipient(
        address _protocolFeeRecipient
    ) external onlyOwner {
        if (_protocolFeeRecipient == address(0)) revert AddressZero();
        protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdated(_protocolFeeRecipient);
    }

    /// @notice Sets the WETH address
    function setWeth(address _weth) external onlyOwner {
        if (_weth == address(0)) revert AddressZero();
        weth = _weth;
        emit WethUpdated(_weth);
    }

    /// @notice Sets the RARE burner address
    function setRareBurner(address _rareBurner) external onlyOwner {
        if (_rareBurner == address(0)) revert AddressZero();
        rareBurner = _rareBurner;
        emit RareBurnerUpdated(_rareBurner);
    }

    /// @notice Sets the Uniswap V4 PoolManager address
    function setPoolManager(address _poolManager) external onlyOwner {
        if (_poolManager == address(0)) revert AddressZero();
        poolManager = _poolManager;
        emit PoolManagerUpdated(_poolManager);
    }

    /// @notice Sets the Uniswap V4 Quoter address
    function setV4Quoter(address _v4Quoter) external onlyOwner {
        if (_v4Quoter == address(0)) revert AddressZero();
        v4Quoter = _v4Quoter;
        emit V4QuoterUpdated(_v4Quoter);
    }

    /// @notice Sets the Uniswap V4 hooks address (optional)
    function setPoolHooks(address _poolHooks) external onlyOwner {
        poolHooks = _poolHooks;
        emit PoolHooksUpdated(_poolHooks);
    }

    /// @notice Sets the Uniswap V4 tick spacing
    /// @dev Validates that current lpTickLower and lpTickUpper are multiples of the new spacing
    function setPoolTickSpacing(int24 _poolTickSpacing) external onlyOwner {
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
    function setInternalMaxSlippageBps(uint16 _slippageBps) external onlyOwner {
        if (_slippageBps > 5000) revert SlippageTooHigh(_slippageBps, 5000);
        internalMaxSlippageBps = _slippageBps;
        emit InternalMaxSlippageBpsUpdated(_slippageBps);
    }

    /// @notice Sets the minimum order size in wei
    /// @param _minOrderSizeWei Minimum order size in wei (absolute floor, can be 0 to disable)
    function setMinOrderSizeWei(uint128 _minOrderSizeWei) external onlyOwner {
        minOrderSizeWei = _minOrderSizeWei;
        emit MinOrderSizeWeiUpdated(_minOrderSizeWei);
    }

    /// @notice Sets the minimum initial liquidity in wei
    /// @param _minInitialLiquidityWei Minimum ETH for pool bootstrap
    function setMinInitialLiquidityWei(
        uint256 _minInitialLiquidityWei
    ) external onlyOwner {
        minInitialLiquidityWei = _minInitialLiquidityWei;
        emit MinInitialLiquidityWeiUpdated(_minInitialLiquidityWei);
    }

    /// @notice Sets all TIER 3 fee splits atomically
    /// @dev Validates that fee splits sum to exactly 10000 BPS (100%)
    /// @param _rareBurnFeeBPS RARE burn fee in basis points
    /// @param _protocolFeeBPS Protocol fee in basis points
    /// @param _referrerFeeBPS Referrer fee in basis points
    function setTier3FeeSplits(
        uint256 _rareBurnFeeBPS,
        uint256 _protocolFeeBPS,
        uint256 _referrerFeeBPS
    ) external onlyOwner {
        uint256 tier3Total = _rareBurnFeeBPS +
            _protocolFeeBPS +
            _referrerFeeBPS;
        if (tier3Total != 10000) revert InvalidFeeDistribution();

        rareBurnFeeBPS = _rareBurnFeeBPS;
        protocolFeeBPS = _protocolFeeBPS;
        referrerFeeBPS = _referrerFeeBPS;

        emit RareBurnFeeBPSUpdated(_rareBurnFeeBPS);
        emit ProtocolFeeBPSUpdated(_protocolFeeBPS);
        emit ReferrerFeeBPSUpdated(_referrerFeeBPS);
    }

    /// @notice Sets the LP tick lower bound
    /// @dev Validates that lower < upper and that tick is a multiple of poolTickSpacing
    /// @param _lower Lower tick for LP positions
    function setLpTickLower(int24 _lower) external onlyOwner {
        if (_lower >= lpTickUpper) revert InvalidTickRange();
        if (_lower % poolTickSpacing != 0) revert InvalidTickSpacing();
        lpTickLower = _lower;
        emit LpTickLowerUpdated(_lower);
    }

    /// @notice Sets the LP tick upper bound
    /// @dev Validates that lower < upper and that tick is a multiple of poolTickSpacing
    /// @param _upper Upper tick for LP positions
    function setLpTickUpper(int24 _upper) external onlyOwner {
        if (lpTickLower >= _upper) revert InvalidTickRange();
        if (_upper % poolTickSpacing != 0) revert InvalidTickSpacing();
        lpTickUpper = _upper;
        emit LpTickUpperUpdated(_upper);
    }
}
