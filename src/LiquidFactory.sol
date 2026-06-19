// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {SovereignERC20} from "liquid-editions/SovereignERC20.sol";
import {SovereignERC20Market} from "liquid-editions/SovereignERC20Market.sol";
import {SovereignERC20MarketRewards} from "liquid-editions/SovereignERC20MarketRewards.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {ILiquidGuard} from "liquid-editions/interfaces/ILiquidGuard.sol";

/// @title LiquidFactory
/// @notice Factory contract for creating Liquid token instances with centralized configuration management
/// @dev Uses OpenZeppelin's Clones pattern (EIP-1167 minimal proxy) for gas-efficient deployment.
///      Maintains global configuration with individual settable values. Each Liquid token reads
///      configuration directly from the factory at call time (no caching).
///      Each Liquid token is deployed as a clone of a master implementation.
contract LiquidFactory is Ownable, Pausable, ILiquidFactory {
    using SafeERC20 for IERC20;
    using Hooks for IHooks;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The LiquidMultiCurve implementation (for multicurve anti-sniping launches)
    address public liquidMultiCurveImplementation;

    address public constant SELF_REWARD_TOKEN = address(1);
    bytes32 public constant KIND_SOVEREIGN_ERC20 = keccak256("SOVEREIGN_ERC20");
    bytes32 public constant KIND_SOVEREIGN_ERC20_MARKET = keccak256("SOVEREIGN_ERC20_MARKET");
    bytes32 public constant KIND_SOVEREIGN_ERC20_MARKET_REWARDS = keccak256("SOVEREIGN_ERC20_MARKET_REWARDS");

    struct TokenImplementation {
        address implementation;
        bool enabled;
    }

    /// @notice Sovereign token implementations keyed by kind.
    mapping(bytes32 kind => TokenImplementation implementation) public tokenImplementations;

    /// @notice External ERC20 reward tokens allowed for future Sovereign reward deployments.
    mapping(address rewardToken => bool allowed) public sovereignRewardTokenAllowed;

    /// @notice Registry used for token registration and beneficiary mapping
    address public liquidRegistry;
    /// @notice Migration executor address - only this address can call migrateLiquidity() on tokens
    address public migrationExecutor;

    // Protocol addresses
    address public poolManager;
    address public poolHooks;
    address public baseToken; // RARE token address

    /// @notice Max total supply minted for each new token at launch (default 1M)
    uint256 public maxTotalSupply = 1_000_000e18;

    /// @notice Tokens transferred to creator at launch (default 100K; 0 = no carve-out)
    uint256 public creatorLaunchReward = 100_000e18;

    /// @notice Tick spacing for Uniswap V4 pools (e.g., 60)
    /// @dev All ticks must be multiples of this spacing. Used when initializing pools.
    int24 public poolTickSpacing;

    /// @notice Creator-approved operators that can launch Liquid tokens on a creator's behalf
    mapping(address creator => mapping(address operator => bool)) public isCreatorDelegate;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Constructor for LiquidFactory
    /// @dev Initializes the factory with global configuration and sets the owner.
    ///      Implementation must be set separately via setImplementation before creating tokens.
    /// @param _owner The owner of the factory (can update config and implementation)
    /// @param _poolManager The Uniswap V4 PoolManager address
    /// @param _poolHooks The Uniswap V4 hooks contract for the pool (address(0) if none)
    /// @param _poolTickSpacing Tick spacing to use when initializing the V4 pool
    constructor(address _owner, address _poolManager, address _poolHooks, int24 _poolTickSpacing) Ownable(_owner) {
        if (_owner == address(0)) {
            revert AddressZero();
        }

        if (_poolManager == address(0)) {
            revert AddressZero();
        }

        // Validate pool tick spacing (must be positive)
        if (_poolTickSpacing <= 0) revert InvalidTickSpacing();

        poolManager = _poolManager;
        poolHooks = _poolHooks;
        poolTickSpacing = _poolTickSpacing;
    }

    // ============================================
    // TOKEN CREATION
    // ============================================

    /// @notice Creates a new Liquid token with multicurve liquidity
    /// @dev Deploys a clone of liquidMultiCurveImplementation, distributes liquidity across
    ///      multiple concentrated positions per the provided curves. The bonding curve is funded
    ///      by LIQUID tokens derived from the factory's current supply settings, not by creator
    ///      RARE. Optional RARE creates a head position beyond the curve range for post-curve
    ///      liquidity (can be 0).
    /// @param _creator The address of the token creator (receives fees and launch reward)
    /// @param _tokenUri The ERC20z token URI (metadata link)
    /// @param _name The token name
    /// @param _symbol The token symbol
    /// @param _initialRareLiquidity Optional RARE for head position beyond curve range (can be 0)
    /// @param _curves Curve configuration (tick ranges, positions, shares) for multicurve deployment
    /// @return token The address of the created token
    function createLiquidTokenMultiCurve(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _initialRareLiquidity,
        Curve[] calldata _curves
    ) external whenNotPaused returns (address token) {
        if (_creator == address(0)) revert AddressZero();
        // Protects creators from malicious launches while allowing explicit delegation.
        if (!_isAuthorizedCreator(_creator, msg.sender)) revert Unauthorized();

        return _createLiquidTokenMultiCurve(
            _creator, _tokenUri, _name, _symbol, _initialRareLiquidity, _curves, maxTotalSupply
        );
    }

    /// @notice Creates a new Liquid token with multicurve liquidity and a custom max total supply
    /// @dev Deploys a clone of liquidMultiCurveImplementation using the provided max total supply
    ///      and the factory's current creatorLaunchReward. The bonding curve is funded by LIQUID
    ///      tokens derived from that supply split, not by creator RARE.
    /// @param _creator The address of the token creator (receives fees and launch reward)
    /// @param _tokenUri The ERC20z token URI (metadata link)
    /// @param _name The token name
    /// @param _symbol The token symbol
    /// @param _initialRareLiquidity Optional RARE for head position beyond curve range (can be 0)
    /// @param _curves Curve configuration (tick ranges, positions, shares) for multicurve deployment
    /// @param _customMaxTotalSupply Custom total token supply minted at launch
    /// @return token The address of the created token
    function createLiquidTokenMultiCurveWithSupply(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _initialRareLiquidity,
        Curve[] calldata _curves,
        uint256 _customMaxTotalSupply
    ) external whenNotPaused returns (address token) {
        if (_creator == address(0)) revert AddressZero();
        if (!_isAuthorizedCreator(_creator, msg.sender)) revert Unauthorized();

        return _createLiquidTokenMultiCurve(
            _creator, _tokenUri, _name, _symbol, _initialRareLiquidity, _curves, _customMaxTotalSupply
        );
    }

    /// @notice Creates a no-market owner-controlled Sovereign ERC20.
    function createSovereignERC20(
        address owner,
        string memory tokenUri,
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 maxSupply
    ) external whenNotPaused returns (address token) {
        if (owner == address(0)) revert AddressZero();
        if (!_isAuthorizedCreator(owner, msg.sender)) revert Unauthorized();

        address implementation = _requireSovereignImplementation(KIND_SOVEREIGN_ERC20);
        token = Clones.clone(implementation);
        SovereignERC20(token).initialize(owner, name, symbol, tokenUri, initialSupply, maxSupply);

        emit SovereignTokenCreated(KIND_SOVEREIGN_ERC20, token, owner, tokenUri);
        _registerToken(token, owner);
    }

    /// @notice Creates a Sovereign ERC20 with atomic one-sided RARE market liquidity.
    function createSovereignERC20Market(
        address owner,
        string memory tokenUri,
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        Curve[] calldata curves
    ) external whenNotPaused returns (address token) {
        if (owner == address(0)) revert AddressZero();
        if (!_isAuthorizedCreator(owner, msg.sender)) revert Unauthorized();
        _validateSovereignMarketInputs(initialSupply, curves);

        address implementation = _requireSovereignImplementation(KIND_SOVEREIGN_ERC20_MARKET);
        token = Clones.clone(implementation);
        ILiquidGuard(poolHooks).addInitializer(token);

        SovereignERC20Market(payable(token)).initialize(owner, tokenUri, name, symbol, initialSupply, curves);

        emit SovereignTokenCreated(KIND_SOVEREIGN_ERC20_MARKET, token, owner, tokenUri);
        _registerToken(token, owner);
    }

    /// @notice Creates a Sovereign ERC20 with atomic one-sided RARE market liquidity and holder rewards.
    function createSovereignERC20MarketRewards(
        address owner,
        string memory tokenUri,
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        Curve[] calldata curves,
        address rewardToken
    ) external whenNotPaused returns (address token) {
        if (owner == address(0)) revert AddressZero();
        if (!_isAuthorizedCreator(owner, msg.sender)) revert Unauthorized();
        if (!isSovereignRewardTokenAllowed(rewardToken)) revert SovereignRewardTokenNotAllowed(rewardToken);
        _validateSovereignMarketInputs(initialSupply, curves);

        address implementation = _requireSovereignImplementation(KIND_SOVEREIGN_ERC20_MARKET_REWARDS);
        token = Clones.clone(implementation);
        ILiquidGuard(poolHooks).addInitializer(token);

        SovereignERC20MarketRewards(payable(token))
            .initialize(owner, tokenUri, name, symbol, initialSupply, curves, rewardToken);

        emit SovereignTokenCreated(KIND_SOVEREIGN_ERC20_MARKET_REWARDS, token, owner, tokenUri);
        _registerToken(token, owner);
    }

    /// @notice Returns whether a caller can create Liquid tokens for a creator
    function _isAuthorizedCreator(address creator, address caller) internal view returns (bool) {
        return creator == caller || isCreatorDelegate[creator][caller];
    }

    // ============================================
    // CREATOR DELEGATION
    // ============================================

    /// @notice Allows an operator to create Liquid tokens on behalf of msg.sender.
    /// @dev Delegated operators still pay any `_initialRareLiquidity` pulled by the create call.
    function delegateTokenCreation(address operator) external {
        if (operator == address(0)) revert AddressZero();
        isCreatorDelegate[msg.sender][operator] = true;
        emit CreatorDelegateUpdated(msg.sender, operator, true);
    }

    /// @notice Revokes an operator's permission to create Liquid tokens on behalf of msg.sender.
    function revokeTokenCreationDelegate(address operator) external {
        if (operator == address(0)) revert AddressZero();
        isCreatorDelegate[msg.sender][operator] = false;
        emit CreatorDelegateUpdated(msg.sender, operator, false);
    }

    /// @notice Internal function that creates a LiquidMultiCurve token clone and initializes it
    /// @dev This function handles the complete deployment flow:
    ///      1. Validates all inputs (implementation, baseToken, creator, curves, supply split)
    ///      2. Creates EIP-1167 minimal proxy clone of liquidMultiCurveImplementation
    ///      3. Optionally transfers RARE tokens from caller to clone (for head position beyond curve range)
    ///      4. Validates pool hooks configuration (must have all LiquidGuard flags: 0x20CC)
    ///      5. Whitelists clone as allowed pool initializer in hooks contract (CRITICAL: must happen before initialize())
    ///      6. Calls clone.initialize() which creates the Uniswap V4 pool
    ///      7. Registers token in LiquidRegistry with creator as beneficiary
    ///
    ///      **Security Note**: Hook validation and whitelisting MUST happen before initialize()
    ///      to prevent pool pre-initialization DoS attacks. If an attacker front-runs token deployment
    ///      and initializes the pool with a hostile price, the token's initialize() would fail or
    ///      create a pool at the wrong price. By whitelisting the clone address first, we ensure only
    ///      the legitimate token contract can initialize its pool.
    /// @param _creator The address of the token creator (receives fees and launch reward)
    /// @param _tokenUri The ERC20z token URI (metadata link)
    /// @param _name The token name
    /// @param _symbol The token symbol
    /// @param _initialRareLiquidity Optional RARE for head position beyond curve range (can be 0)
    /// @param _curves Curve configuration array (tick ranges, positions, shares) for multicurve deployment
    /// @param _effectiveMaxTotalSupply Total token supply to mint at launch
    /// @return token The address of the created token clone
    function _createLiquidTokenMultiCurve(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _initialRareLiquidity,
        Curve[] memory _curves,
        uint256 _effectiveMaxTotalSupply
    ) internal returns (address token) {
        // Validate implementation is set
        if (liquidMultiCurveImplementation == address(0)) {
            revert ImplementationNotSet();
        }
        // Validate good metadata
        if (bytes(_tokenUri).length == 0) revert InvalidTokenURI();
        if (bytes(_name).length == 0) revert InvalidName();
        if (bytes(_symbol).length == 0) revert InvalidSymbol();

        // Validate base token is configured
        if (baseToken == address(0)) revert AddressZero();
        // Validate creator address
        if (_creator == address(0)) revert AddressZero();
        // Validate curves array is non-empty
        if (_curves.length == 0) revert InvalidAmount();
        // Validate supply split
        if (_effectiveMaxTotalSupply <= creatorLaunchReward) revert InvalidAmount();
        // Create EIP-1167 minimal proxy clone (gas-efficient deployment)
        address clone = Clones.clone(liquidMultiCurveImplementation);

        // Transfer RARE tokens from caller to clone (for optional head position beyond curve range)
        if (_initialRareLiquidity > 0) {
            IERC20(baseToken).safeTransferFrom(msg.sender, clone, _initialRareLiquidity);
        }

        // CRITICAL SECURITY STEP: Validate and whitelist clone BEFORE initialize() is called
        // This prevents pool pre-initialization DoS attacks where attackers front-run token deployment
        // by initializing the pool first with a hostile price. Only whitelisted addresses can initialize.
        if (poolHooks == address(0)) revert PoolHooksNotSet();
        // Validate hook has correct permissions (all LiquidGuard flags: 0x20CC)
        _validatePoolHook();
        // Whitelist clone as allowed initializer (must happen before clone.initialize() calls pm.initialize())
        // Use ILiquidGuard (LiquidGuard) interface for allowlisting
        ILiquidGuard(poolHooks).addInitializer(clone);

        // Initialize the clone (this creates the Uniswap V4 pool with multicurve liquidity)
        LiquidMultiCurve liquid = LiquidMultiCurve(payable(clone));
        liquid.initialize(_creator, _tokenUri, _name, _symbol, _curves, _effectiveMaxTotalSupply, creatorLaunchReward);

        // Emit event and register token in registry
        emit LiquidTokenCreated(clone, _creator, _tokenUri);
        _registerToken(clone, _creator);
        return clone;
    }

    /// @notice Registers a token with its beneficiary in the LiquidRegistry
    /// @dev Called after token creation to register the token-beneficiary mapping.
    ///      Silently skips registration if registry is not set or has no code (allows factory to work without registry).
    /// @param token The token address to register
    /// @param beneficiary The beneficiary address (receives creator fees)
    function _registerToken(address token, address beneficiary) internal {
        if (liquidRegistry == address(0)) return;
        if (liquidRegistry.code.length == 0) return;
        ILiquidRegistry(liquidRegistry).setBeneficiary(token, beneficiary);
    }

    /// @notice Returns true when a reward token may be used for future Sovereign reward deployments.
    function isSovereignRewardTokenAllowed(address rewardToken) public view returns (bool) {
        return rewardToken == SELF_REWARD_TOKEN || sovereignRewardTokenAllowed[rewardToken];
    }

    function _requireSovereignImplementation(bytes32 kind) internal view returns (address implementation) {
        if (!_isKnownSovereignKind(kind)) revert InvalidTokenKind(kind);

        TokenImplementation memory config = tokenImplementations[kind];
        implementation = config.implementation;
        if (implementation == address(0)) revert ImplementationNotSet();
        if (!config.enabled) revert TokenImplementationDisabled(kind);
    }

    function _validateSovereignMarketInputs(uint256 initialSupply, Curve[] calldata curves) internal view {
        if (initialSupply == 0) revert InvalidAmount();
        if (curves.length == 0) revert InvalidAmount();
        if (baseToken == address(0)) revert AddressZero();
        if (poolHooks == address(0)) revert PoolHooksNotSet();

        _validatePoolHook();
        _validatePoolHookRareToken();
    }

    function _validatePoolHookRareToken() internal view {
        address hookRareToken = ILiquidGuard(poolHooks).RARE_TOKEN();
        if (hookRareToken != baseToken) {
            revert PoolHookRareTokenMismatch(poolHooks, hookRareToken, baseToken);
        }
    }

    function _isKnownSovereignKind(bytes32 kind) internal pure returns (bool) {
        return kind == KIND_SOVEREIGN_ERC20 || kind == KIND_SOVEREIGN_ERC20_MARKET
            || kind == KIND_SOVEREIGN_ERC20_MARKET_REWARDS;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @notice Sets the LiquidMultiCurve implementation (for multicurve anti-sniping launches)
    /// @param _implementation The implementation address
    function setLiquidMultiCurveImplementation(address _implementation) external onlyOwner {
        if (_implementation == address(0)) revert AddressZero();
        liquidMultiCurveImplementation = _implementation;
    }

    /// @notice Configures a Sovereign token implementation by kind.
    function setSovereignTokenImplementation(bytes32 kind, address implementation, bool enabled) external onlyOwner {
        if (!_isKnownSovereignKind(kind)) revert InvalidTokenKind(kind);
        if (implementation == address(0)) revert AddressZero();

        address oldImplementation = tokenImplementations[kind].implementation;
        tokenImplementations[kind] = TokenImplementation({implementation: implementation, enabled: enabled});

        emit SovereignTokenImplementationUpdated(kind, oldImplementation, implementation, enabled);
    }

    /// @notice Updates the external ERC20 reward-token allowlist for future Sovereign deployments.
    function setSovereignRewardTokenAllowed(address rewardToken, bool allowed) external onlyOwner {
        if (rewardToken == address(0) || rewardToken == SELF_REWARD_TOKEN) revert AddressZero();
        sovereignRewardTokenAllowed[rewardToken] = allowed;
        emit SovereignRewardTokenAllowlistUpdated(rewardToken, allowed);
    }

    /// @notice Sets the migration executor address
    /// @dev Only the migration executor can call migrateLiquidity() on Liquid tokens.
    function setMigrationExecutor(address _migrationExecutor) external onlyOwner {
        if (_migrationExecutor == address(0)) revert AddressZero();
        migrationExecutor = _migrationExecutor;
        emit MigrationExecutorUpdated(_migrationExecutor);
    }

    /// @notice Sets the registry used for automatic token registration
    /// @dev Factory must be a writer on the registry to register tokens.
    function setLiquidRegistry(address _liquidRegistry) external onlyOwner {
        if (_liquidRegistry == address(0)) revert AddressZero();
        address oldLiquidRegistry = liquidRegistry;
        liquidRegistry = _liquidRegistry;
        emit LiquidRegistryUpdated(oldLiquidRegistry, _liquidRegistry);
    }

    /// @notice Sets the Uniswap V4 PoolManager address
    function setPoolManager(address _poolManager) external onlyOwner {
        if (_poolManager == address(0)) revert AddressZero();
        poolManager = _poolManager;
        emit PoolManagerUpdated(_poolManager);
    }

    /// @notice Sets the Uniswap V4 hooks address (optional)
    /// @dev If the hooks contract is LiquidGuard, also requires it to be authorized to add initializers
    function setPoolHooks(address _poolHooks) external onlyOwner {
        if (_poolHooks != address(0) && _poolHooks.code.length == 0) {
            revert InvalidPoolHook(_poolHooks);
        }

        // If hooks is LiquidGuard, ensure it is already authorized for this factory
        if (_poolHooks != address(0)) {
            try ILiquidGuard(_poolHooks).factory() returns (address configuredFactory) {
                if (configuredFactory != address(this)) {
                    revert SwapGuardFactoryMismatch(_poolHooks, configuredFactory, address(this));
                }
            } catch {
                // Non-guard hooks are allowed at configuration time and will be
                // rejected during token creation validation.
            }
        }

        poolHooks = _poolHooks;

        emit PoolHooksUpdated(_poolHooks);
    }

    /// @notice Validates configured hook for MultiCurve launches
    /// @dev Performs comprehensive validation of the pool hooks contract:
    ///      1. Verifies hook has code (is a contract)
    ///      2. Checks hook address has all required LiquidGuard flags (0x20CC):
    ///         BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA
    ///      3. Validates hook address format via isValidHookAddress()
    ///      4. If hook implements ILiquidGuard, verifies factory configuration matches.
    ///      Reverts with specific error codes if validation fails.
    function _validatePoolHook() internal view {
        if (poolHooks.code.length == 0) revert InvalidPoolHook(poolHooks);

        uint160 actualFlags = uint160(poolHooks) & Hooks.ALL_HOOK_MASK;
        uint160 requiredFlags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if ((actualFlags & requiredFlags) != requiredFlags) {
            revert PoolHookMissingFlags(poolHooks, actualFlags, requiredFlags);
        }

        if (!IHooks(poolHooks).isValidHookAddress(0)) {
            revert InvalidPoolHook(poolHooks);
        }

        // Require ILiquidGuard (LiquidGuard-compatible) for initializer allowlisting
        try ILiquidGuard(poolHooks).factory() returns (address configuredFactory) {
            if (configuredFactory != address(0) && configuredFactory != address(this)) {
                revert SwapGuardFactoryMismatch(poolHooks, configuredFactory, address(this));
            }
        } catch {
            revert PoolHookNotGuard(poolHooks);
        }
    }

    /// @notice Sets the Uniswap V4 tick spacing
    function setPoolTickSpacing(int24 _poolTickSpacing) external onlyOwner {
        if (_poolTickSpacing <= 0) revert InvalidTickSpacing();
        poolTickSpacing = _poolTickSpacing;
        emit PoolTickSpacingUpdated(_poolTickSpacing);
    }

    /// @notice Sets the max total supply minted for each new token at launch
    /// @dev Must be greater than zero and greater than the current creatorLaunchReward
    ///      (pool must receive at least 1 token). Only affects future launches.
    /// @param _supply New max total supply
    function setMaxTotalSupply(uint256 _supply) external onlyOwner {
        if (_supply == 0) revert InvalidAmount();
        if (creatorLaunchReward >= _supply) revert InvalidAmount();
        maxTotalSupply = _supply;
        emit MaxTotalSupplyUpdated(_supply);
    }

    /// @notice Sets the creator launch reward for new tokens (tokens sent to creator at launch)
    /// @dev Zero is explicitly allowed (creator receives no carve-out; all tokens go to pool).
    ///      Must be strictly less than maxTotalSupply. Only affects future launches.
    /// @param _reward New creator reward amount
    function setCreatorLaunchReward(uint256 _reward) external onlyOwner {
        if (_reward >= maxTotalSupply) revert InvalidAmount();
        creatorLaunchReward = _reward;
        emit CreatorLaunchRewardUpdated(_reward);
    }

    /// @notice Pauses token creation on this factory.
    /// @dev Emergency stop used during routing, tokenomics, or swap-guard incidents.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses token creation on this factory.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Sets the base token address (RARE)
    /// @dev Must be set before creating Liquid tokens. Used for pool creation.
    /// @param _baseToken The base token address (RARE)
    function setBaseToken(address _baseToken) external onlyOwner {
        if (_baseToken == address(0)) revert AddressZero();
        baseToken = _baseToken;
        emit BaseTokenUpdated(_baseToken);
    }
}
