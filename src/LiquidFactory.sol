// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {LiquidGraduated} from "liquid-editions/LiquidGraduated.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {IDistributionStrategy} from "continuous-clearing-auction/interfaces/external/IDistributionStrategy.sol";
import {AuctionParameters} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {MigratorParameters} from "liquid-editions/types/MigratorParameters.sol";
import {IDistributionContract} from "liquid-editions/interfaces/IDistributionContract.sol";
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

    /// @notice The LiquidInstant implementation (for two-sided AMM launches)
    address public liquidInstantImplementation;

    /// @notice The LiquidGraduated implementation (for CCA auction launches)
    address public liquidGraduatedImplementation;

    /// @notice The LiquidMultiCurve implementation (for multicurve anti-sniping launches)
    address public liquidMultiCurveImplementation;

    /// @notice CCA factory for deploying auctions
    address public ccaFactory;

    /// @notice Deploys the LBP strategy per graduated token (our deployment of Uniswap's FullRangeLBPStrategyFactory).
    ///         Required for createLiquidTokenWithAuction. LiquidFactory remains the single entry point; this is the
    ///         contract that creates each strategy instance when a graduated token is created.
    address public lbpStrategyFactory;

    /// @notice Recipient for LP position at migration (LBP strategy positionRecipient)
    address public protocolFeeRecipient;
    /// @notice Registry used for token registration and beneficiary mapping
    address public liquidRegistry;

    // Protocol addresses
    address public poolManager;
    address public poolHooks;
    address public baseToken; // RARE token address

    uint256 public minRareLiquidityWei; // Minimum RARE for optional head position (0 = no RARE required)

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
    /// @param _poolManager The Uniswap V4 PoolManager address
    /// @param _lpTickLower The lower tick for LP positions (defines price range).
    ///                      NOTE: Semantic meaning depends on token ordering - see lpTickLower documentation.
    /// @param _lpTickUpper The upper tick for LP positions (defines price range).
    ///                      NOTE: Semantic meaning depends on token ordering - see lpTickLower documentation.
    /// @param _poolHooks The Uniswap V4 hooks contract for the pool (address(0) if none)
    /// @param _poolTickSpacing Tick spacing to use when initializing the V4 pool
    /// @param _minRareLiquidityWei Minimum RARE tokens (in wei) for optional head position (0 = no RARE required)
    constructor(
        address _owner,
        address _poolManager,
        int24 _lpTickLower,
        int24 _lpTickUpper,
        address _poolHooks,
        int24 _poolTickSpacing,
        uint256 _minRareLiquidityWei
    ) Ownable(_owner) {
        if (_owner == address(0)) {
            revert AddressZero();
        }

        if (_poolManager == address(0)) {
            revert AddressZero();
        }

        // Validate tick range (lower must be less than upper)
        if (_lpTickLower >= _lpTickUpper) {
            revert InvalidTickRange();
        }

        // Validate pool tick spacing (must be positive)
        if (_poolTickSpacing <= 0) revert InvalidTickSpacing();

        // Validate that ticks are multiples of tick spacing
        if (
            _lpTickLower % _poolTickSpacing != 0 ||
            _lpTickUpper % _poolTickSpacing != 0
        ) {
            revert InvalidTickSpacing();
        }

        poolManager = _poolManager;
        poolHooks = _poolHooks;
        lpTickLower = _lpTickLower;
        lpTickUpper = _lpTickUpper;
        poolTickSpacing = _poolTickSpacing;
        minRareLiquidityWei = _minRareLiquidityWei;
    }

    // ============================================
    // TOKEN CREATION
    // ============================================

    /// @notice Creates a new Liquid token with multicurve liquidity
    /// @dev Deploys a clone of liquidMultiCurveImplementation, distributes liquidity across
    ///      multiple concentrated positions per the provided curves. The bonding curve is funded
    ///      by LIQUID tokens (900K), not by creator RARE. Optional RARE creates a head position
    ///      beyond the curve range for post-curve liquidity (can be 0).
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
        return
            _createLiquidTokenMultiCurve(
                _creator,
                _tokenUri,
                _name,
                _symbol,
                _initialRareLiquidity,
                _curves
            );
    }

    /// @notice Internal function that creates a LiquidMultiCurve token clone and initializes it
    /// @dev This function handles the complete deployment flow:
    ///      1. Validates all inputs (implementation, baseToken, creator, curves)
    ///      2. Creates EIP-1167 minimal proxy clone of liquidMultiCurveImplementation
    ///      3. Optionally transfers RARE tokens from caller to clone (for head position beyond curve range)
    ///      4. Validates pool hooks configuration (must have BEFORE_INITIALIZE_FLAG)
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
    /// @return token The address of the created token clone
    function _createLiquidTokenMultiCurve(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _initialRareLiquidity,
        Curve[] memory _curves
    ) internal returns (address token) {
        // Validate implementation is set
        if (liquidMultiCurveImplementation == address(0)) {
            revert ImplementationNotSet();
        }
        // Validate base token is configured
        if (baseToken == address(0)) revert AddressZero();
        // Validate creator address
        if (_creator == address(0)) revert AddressZero();
        // Validate curves array is non-empty
        if (_curves.length == 0) revert InvalidAmount();
        // Validate initial liquidity meets minimum threshold
        if (_initialRareLiquidity < minRareLiquidityWei) revert InvalidAmount();

        // Create EIP-1167 minimal proxy clone (gas-efficient deployment)
        address clone = Clones.clone(liquidMultiCurveImplementation);

        // Transfer RARE tokens from caller to clone (for optional head position beyond curve range)
        if (_initialRareLiquidity > 0) {
            IERC20(baseToken).safeTransferFrom(
                msg.sender,
                clone,
                _initialRareLiquidity
            );
        }

        // CRITICAL SECURITY STEP: Validate and whitelist clone BEFORE initialize() is called
        // This prevents pool pre-initialization DoS attacks where attackers front-run token deployment
        // by initializing the pool first with a hostile price. Only whitelisted addresses can initialize.
        if (poolHooks == address(0)) revert PoolHooksNotSet();
        // Validate hook has correct permissions (BEFORE_INITIALIZE_FLAG required)
        _validatePoolHook();
        // Whitelist clone as allowed initializer (must happen before clone.initialize() calls pm.initialize())
        // Use ILiquidGuard (LiquidGuard) interface for allowlisting
        ILiquidGuard(poolHooks).addInitializer(clone);

        // Initialize the clone (this creates the Uniswap V4 pool with multicurve liquidity)
        LiquidMultiCurve liquid = LiquidMultiCurve(payable(clone));
        liquid.initialize(
            _creator,
            _tokenUri,
            _name,
            _symbol,
            minRareLiquidityWei,
            _curves
        );

        // Emit event and register token in registry
        emit LiquidTokenCreated(clone, _creator, _tokenUri);
        _registerToken(clone, _creator);
        return clone;
    }

    /// @notice Creates a new Liquid token with two-sided AMM liquidity
    /// @dev Deploys a clone of liquidInstantImplementation and seeds a single concentrated liquidity
    ///      position with both LIQUID and RARE. The pool starts at an optimal price that uses all
    ///      provided RARE alongside the 900K LIQUID pool supply. Uses the factory's lpTickLower and
    ///      lpTickUpper to define the LP range.
    /// @param _creator The address of the token creator (receives fees and launch reward)
    /// @param _tokenUri The ERC20z token URI (metadata link)
    /// @param _name The token name
    /// @param _symbol The token symbol
    /// @param _initialRareLiquidity Amount of RARE to seed the pool (must be > 0)
    /// @return token The address of the created token
    function createLiquidTokenInstant(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _initialRareLiquidity
    ) external whenNotPaused returns (address token) {
        return
            _createLiquidTokenInstant(
                _creator,
                _tokenUri,
                _name,
                _symbol,
                _initialRareLiquidity
            );
    }

    /// @notice Internal function that creates a LiquidInstant token clone and initializes it
    /// @dev This function handles the complete deployment flow:
    ///      1. Validates all inputs (implementation, baseToken, creator, RARE > 0)
    ///      2. Creates EIP-1167 minimal proxy clone of liquidInstantImplementation
    ///      3. Transfers RARE tokens from caller to clone (required for two-sided pool seeding)
    ///      4. Validates pool hooks configuration (must have BEFORE_INITIALIZE_FLAG)
    ///      5. Whitelists clone as allowed pool initializer in hooks contract (CRITICAL: must happen before initialize())
    ///      6. Calls clone.initialize() which creates the Uniswap V4 pool at the optimal starting price
    ///      7. Registers token in LiquidRegistry with creator as beneficiary
    ///
    ///      **Security Note**: Hook validation and whitelisting MUST happen before initialize()
    ///      to prevent pool pre-initialization DoS attacks.
    /// @param _creator The address of the token creator (receives fees and launch reward)
    /// @param _tokenUri The ERC20z token URI (metadata link)
    /// @param _name The token name
    /// @param _symbol The token symbol
    /// @param _initialRareLiquidity Amount of RARE to seed the pool (must be > 0)
    /// @return token The address of the created token clone
    function _createLiquidTokenInstant(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _initialRareLiquidity
    ) internal returns (address token) {
        // Validate implementation is set
        if (liquidInstantImplementation == address(0)) {
            revert ImplementationNotSet();
        }
        // Validate base token is configured
        if (baseToken == address(0)) revert AddressZero();
        // Validate creator address
        if (_creator == address(0)) revert AddressZero();
        // RARE is required — LiquidInstant needs both sides to seed the pool
        if (_initialRareLiquidity == 0) revert InvalidAmount();

        // Create EIP-1167 minimal proxy clone (gas-efficient deployment)
        address clone = Clones.clone(liquidInstantImplementation);

        // Transfer RARE tokens from caller to clone (used to seed the two-sided pool)
        IERC20(baseToken).safeTransferFrom(
            msg.sender,
            clone,
            _initialRareLiquidity
        );

        // CRITICAL SECURITY STEP: Validate and whitelist clone BEFORE initialize() is called
        // This prevents pool pre-initialization DoS attacks where attackers front-run token deployment
        // by initializing the pool first with a hostile price. Only whitelisted addresses can initialize.
        if (poolHooks == address(0)) revert PoolHooksNotSet();
        // Validate hook has correct permissions (BEFORE_INITIALIZE_FLAG required)
        _validatePoolHook();
        // Whitelist clone as allowed initializer (must happen before clone.initialize() calls pm.initialize())
        ILiquidGuard(poolHooks).addInitializer(clone);

        // Initialize the clone (creates the Uniswap V4 pool with optimal two-sided liquidity)
        LiquidInstant liquid = LiquidInstant(payable(clone));
        liquid.initialize(
            _creator,
            _tokenUri,
            _name,
            _symbol,
            _initialRareLiquidity
        );

        // Emit event and register token in registry
        emit LiquidTokenCreated(clone, _creator, _tokenUri);
        _registerToken(clone, _creator);
        return clone;
    }

    /// @notice Predicts the token address for a graduated token deployment
    /// @dev Use this to compute the token address before calling createLiquidTokenWithAuction.
    ///      This enables off-chain salt mining for valid V4 hook addresses.
    ///      The effective salt is keccak256(abi.encode(_deployer, _salt)) to prevent front-running.
    /// @param _salt The user-supplied salt that will be used for deployment
    /// @param _deployer The address that will call createLiquidTokenWithAuction (msg.sender)
    /// @return The predicted token clone address
    function predictGraduatedTokenAddress(
        bytes32 _salt,
        address _deployer
    ) external view returns (address) {
        if (liquidGraduatedImplementation == address(0))
            revert ImplementationNotSet();
        bytes32 effectiveSalt = keccak256(abi.encode(_deployer, _salt));
        return
            Clones.predictDeterministicAddress(
                liquidGraduatedImplementation,
                effectiveSalt,
                address(this)
            );
    }

    /// @notice Creates a new Liquid token with a CCA auction (graduated launch)
    /// @dev Uses canonical FullRangeLBPStrategy via FullRangeLBPStrategyFactory. Strategy creates auction and migrates to v4.
    ///      Requires lbpStrategyFactory, positionManager, and protocolFeeRecipient to be set.
    ///      Uses deterministic clone deployment so callers can predict the token address and mine valid V4 hook salts.
    /// @param _creator The address of the token creator (receives launch reward)
    /// @param _tokenUri The ERC20 token URI (metadata link)
    /// @param _name The token name
    /// @param _symbol The token symbol
    /// @param _migrator Unused (kept for API compatibility; migration via strategy.migrate())
    /// @param _auctionSupply Token amount sent to strategy (900_000e18, split between auction and reserve)
    /// @param _auctionConfigData Encoded CCA AuctionParameters (fundsRecipient/tokensRecipient overwritten)
    /// @param _salt Salt for deterministic token clone and strategy/auction address
    /// @return token The address of the created LiquidGraduated token
    /// @return auction The address of the CCA auction (strategy.initializer() after onTokensReceived)
    function createLiquidTokenWithAuction(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        address _migrator,
        uint256 _auctionSupply,
        bytes calldata _auctionConfigData,
        bytes32 _salt
    ) external whenNotPaused returns (address token, address auction) {
        if (liquidGraduatedImplementation == address(0))
            revert ImplementationNotSet();
        if (lbpStrategyFactory == address(0)) revert AddressZero();
        if (protocolFeeRecipient == address(0)) revert AddressZero();
        if (ccaFactory == address(0)) revert AddressZero();
        if (baseToken == address(0)) revert AddressZero();
        if (_creator == address(0)) revert AddressZero();
        if (_auctionSupply > 900_000e18) revert InvalidAmount();
        _migrator; // silence unused (kept for API compatibility)

        // Bind salt to msg.sender to prevent front-running / salt squatting.
        // An attacker who copies the salt from the mempool cannot claim the same
        // deterministic address because their msg.sender differs.
        bytes32 effectiveSalt = keccak256(abi.encode(msg.sender, _salt));

        // Use deterministic clone deployment so callers can predict the token address
        // and mine valid V4 hook salts off-chain before deployment
        address clone = Clones.cloneDeterministic(
            liquidGraduatedImplementation,
            effectiveSalt
        );

        // Decode auction config and override recipients
        AuctionParameters memory params = abi.decode(
            _auctionConfigData,
            (AuctionParameters)
        );
        params.fundsRecipient = address(1); // MSG_SENDER: strategy gets funds when it calls CCA factory
        if (params.tokensRecipient == address(0))
            params.tokensRecipient = protocolFeeRecipient;
        bytes memory auctionParams = abi.encode(params);

        // tokenSplit: 5e6 = 50% of 900K to auction (450K), 50% reserve (450K)
        // This is 50% of the strategy's total supply, not 50% of the 1M total
        MigratorParameters memory migratorParams = MigratorParameters({
            migrationBlock: params.endBlock + 1,
            currency: params.currency,
            poolLPFee: 0,
            poolTickSpacing: poolTickSpacing,
            tokenSplit: 5e6, // 50% to auction (450K of 900K), 50% reserve (450K)
            initializerFactory: ccaFactory,
            positionRecipient: protocolFeeRecipient,
            sweepBlock: params.endBlock + 1000,
            operator: protocolFeeRecipient,
            maxCurrencyAmountForLP: type(uint128).max
        });

        // Create LBP strategy (creates auction, will migrate to V4 on graduation)
        bytes memory configData = abi.encode(migratorParams, auctionParams);
        address strategyAddr = address(
            IDistributionStrategy(lbpStrategyFactory).initializeDistribution(
                clone,
                _auctionSupply,
                configData,
                effectiveSalt
            )
        );

        // Initialize graduated token with strategy (strategy is also pool hooks)
        LiquidGraduated(payable(clone)).initialize(
            _creator,
            _tokenUri,
            _name,
            _symbol,
            strategyAddr,
            strategyAddr
        );

        // Strategy receives POOL_LAUNCH_SUPPLY - notify it to set up auction
        IDistributionContract(strategyAddr).onTokensReceived();

        address auctionAddr = _getInitializer(strategyAddr);

        emit LiquidTokenCreated(clone, _creator, _tokenUri);
        _registerToken(clone, _creator);
        return (clone, auctionAddr);
    }

    /// @notice Registers a token with its beneficiary in the LiquidRegistry
    /// @dev Called after token creation to register the token-beneficiary mapping.
    ///      Silently skips registration if registry is not set or has no code (allows factory to work without registry).
    /// @param token The token address to register
    /// @param beneficiary The beneficiary address (receives creator fees)
    function _registerToken(
        address token,
        address beneficiary
    ) internal {
        if (liquidRegistry == address(0)) return;
        if (liquidRegistry.code.length == 0) return;
        ILiquidRegistry(liquidRegistry).setBeneficiary(token, beneficiary);
    }

    /// @notice Returns the CCA auction address from a strategy contract
    /// @dev Strategy exposes initializer() which returns the auction address
    /// @param strategyAddr The LBP strategy contract address
    /// @return The auction (initializer) address, or address(0) if call fails
    function _getInitializer(
        address strategyAddr
    ) internal view returns (address) {
        (bool ok, bytes memory data) = strategyAddr.staticcall(
            abi.encodeWithSignature("initializer()")
        );
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @notice Sets the LiquidGraduated implementation (for CCA auction launches)
    /// @param _implementation The implementation address
    function setLiquidGraduatedImplementation(
        address _implementation
    ) external onlyOwner {
        if (_implementation == address(0)) revert AddressZero();
        liquidGraduatedImplementation = _implementation;
    }

    /// @notice Sets the LiquidMultiCurve implementation (for multicurve anti-sniping launches)
    /// @param _implementation The implementation address
    function setLiquidMultiCurveImplementation(
        address _implementation
    ) external onlyOwner {
        if (_implementation == address(0)) revert AddressZero();
        liquidMultiCurveImplementation = _implementation;
    }

    /// @notice Sets the LiquidInstant implementation (for two-sided AMM launches)
    /// @param _implementation The implementation address
    function setLiquidInstantImplementation(
        address _implementation
    ) external onlyOwner {
        if (_implementation == address(0)) revert AddressZero();
        liquidInstantImplementation = _implementation;
    }

    /// @notice Sets the CCA (Continuous Clearing Auction) factory address
    /// @param _ccaFactory The CCA factory address
    function setCcaFactory(
        address _ccaFactory
    ) external onlyOwner {
        if (_ccaFactory == address(0)) revert AddressZero();
        ccaFactory = _ccaFactory;
    }

    /// @notice Sets the LBP strategy factory (canonical FullRangeLBPStrategy)
    /// @dev Required for createLiquidTokenWithAuction - must be set along with positionManager and protocolFeeRecipient
    function setLbpStrategyFactory(
        address _lbpStrategyFactory
    ) external onlyOwner {
        if (_lbpStrategyFactory == address(0)) revert AddressZero();
        lbpStrategyFactory = _lbpStrategyFactory;
    }

    /// @notice Sets the protocol fee recipient used by protocol/auction flows.
    /// @dev Required for createLiquidTokenWithAuction. Also used as the tokensRecipient for unsold auction tokens and operator for sweeps.
    function setProtocolFeeRecipient(
        address _protocolFeeRecipient
    ) external onlyOwner {
        if (
            _protocolFeeRecipient == address(0) ||
            _protocolFeeRecipient == address(1) ||
            _protocolFeeRecipient == address(2)
        ) {
            revert AddressZero();
        }
        protocolFeeRecipient = _protocolFeeRecipient;
    }

    /// @notice Sets the registry used for automatic token registration
    /// @dev Factory must be a writer on the registry to register tokens.
    function setLiquidRegistry(
        address _liquidRegistry
    ) external onlyOwner {
        if (_liquidRegistry == address(0)) revert AddressZero();
        address oldLiquidRegistry = liquidRegistry;
        liquidRegistry = _liquidRegistry;
        emit LiquidRegistryUpdated(oldLiquidRegistry, _liquidRegistry);
    }

    /// @notice Sets the Uniswap V4 PoolManager address
    function setPoolManager(
        address _poolManager
    ) external onlyOwner {
        if (_poolManager == address(0)) revert AddressZero();
        poolManager = _poolManager;
        emit PoolManagerUpdated(_poolManager);
    }

    /// @notice Sets the Uniswap V4 hooks address (optional)
    /// @dev If the hooks contract is LiquidGuard, also requires it to be authorized to add initializers
    function setPoolHooks(
        address _poolHooks
    ) external onlyOwner {
        if (_poolHooks != address(0) && _poolHooks.code.length == 0) {
            revert InvalidPoolHook(_poolHooks);
        }

        // If hooks is LiquidGuard, ensure it is already authorized for this factory
        if (_poolHooks != address(0)) {
            try ILiquidGuard(_poolHooks).factory() returns (
                address configuredFactory
            ) {
                if (configuredFactory != address(this)) {
                    revert SwapGuardFactoryMismatch(
                        _poolHooks,
                        configuredFactory,
                        address(this)
                    );
                }
            } catch {
                // Non-guard hooks are allowed at configuration time and will be
                // rejected during token creation validation.
            }
        }

        poolHooks = _poolHooks;
        
        emit PoolHooksUpdated(_poolHooks);
    }

    /// @notice Validates configured hook for Instant and MultiCurve launches
    /// @dev Performs comprehensive validation of the pool hooks contract:
    ///      1. Verifies hook has code (is a contract)
    ///      2. Checks hook address has BEFORE_INITIALIZE_FLAG set (required to prevent pool pre-initialization DoS)
    ///      3. Validates hook address format via isValidHookAddress()
    ///      4. If hook implements ILiquidGuard, verifies factory configuration matches.
    ///      Primarily supports LiquidGuard (init+swap+fees, 0x20CC).
    ///      Reverts with specific error codes if validation fails.
    function _validatePoolHook() internal view {
        if (poolHooks.code.length == 0) revert InvalidPoolHook(poolHooks);

        uint160 actualFlags = uint160(poolHooks) & Hooks.ALL_HOOK_MASK;
        uint160 requiredFlags = Hooks.BEFORE_INITIALIZE_FLAG;
        if ((actualFlags & requiredFlags) != requiredFlags) {
            revert PoolHookMissingFlags(
                poolHooks,
                actualFlags,
                requiredFlags
            );
        }

        if (!IHooks(poolHooks).isValidHookAddress(0)) {
            revert InvalidPoolHook(poolHooks);
        }

        // Require ILiquidGuard (LiquidGuard-compatible) for initializer allowlisting
        try ILiquidGuard(poolHooks).factory() returns (address configuredFactory) {
            if (
                configuredFactory != address(0) &&
                configuredFactory != address(this)
            ) {
                revert SwapGuardFactoryMismatch(
                    poolHooks,
                    configuredFactory,
                    address(this)
                );
            }
        } catch {
            revert PoolHookNotGuard(poolHooks);
        }
    }

    /// @notice Sets the Uniswap V4 tick spacing
    /// @dev Validates that current lpTickLower and lpTickUpper are multiples of the new spacing
    function setPoolTickSpacing(
        int24 _poolTickSpacing
    ) external onlyOwner {
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

    /// @notice Sets the minimum RARE liquidity for optional head position
    /// @param _minRareLiquidityWei Minimum RARE tokens (in wei) for head position (0 = no RARE required)
    function setMinRareLiquidityWei(
        uint256 _minRareLiquidityWei
    ) external onlyOwner {
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
    ) external onlyOwner {
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
    ) external onlyOwner {
        if (lpTickLower >= _upper) revert InvalidTickRange();
        if (_upper % poolTickSpacing != 0) revert InvalidTickSpacing();
        lpTickUpper = _upper;
        emit LpTickUpperUpdated(_upper);
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
    function setBaseToken(
        address _baseToken
    ) external onlyOwner {
        if (_baseToken == address(0)) revert AddressZero();
        baseToken = _baseToken;
        emit BaseTokenUpdated(_baseToken);
    }
}
