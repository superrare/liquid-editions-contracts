// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Curve} from "doppler/libraries/Multicurve.sol";

/// @title ILiquidFactory
/// @notice Interface for the LiquidFactory contract
interface ILiquidFactory {
    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when a caller is not authorized to perform the action
    error Unauthorized();

    /// @notice Thrown when an operation is attempted with a zero address
    error AddressZero();

    /// @notice Thrown when an empty token URI is provided
    error InvalidTokenURI();

    /// @notice Thrown when an empty token name is provided
    error InvalidName();

    /// @notice Thrown when an empty token symbol is provided
    error InvalidSymbol();

    /// @notice Thrown when the implementation address is not set
    error ImplementationNotSet();

    /// @notice Thrown when an invalid tick range is provided (lower >= upper)
    error InvalidTickRange();

    /// @notice Thrown when tick values are not multiples of poolTickSpacing
    error InvalidTickSpacing();

    /// @notice Thrown when an invalid amount is provided
    error InvalidAmount();

    /// @notice Thrown when the configured PoolHooks address is already bound to another factory
    error SwapGuardFactoryMismatch(
        address poolHooks,
        address configuredFactory,
        address expectedFactory
    );

    /// @notice Thrown when an invalid pool hooks contract is configured
    error InvalidPoolHook(address poolHooks);

    /// @notice Thrown when a configured pool hook is not a LiquidGuard-compatible hook
    error PoolHookNotGuard(address poolHooks);

    /// @notice Thrown when pool hook flags do not include required permissions
    /// @param poolHooks The hook address
    /// @param actualFlags Flags reported by the hook
    /// @param requiredFlags Minimum required flags mask
    error PoolHookMissingFlags(
        address poolHooks,
        uint160 actualFlags,
        uint160 requiredFlags
    );

    /// @notice Thrown when poolHooks is address(0) during token creation
    error PoolHooksNotSet();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a new Liquid token is created
    /// @param token The address of the created token
    /// @param creator The address of the token creator
    /// @param tokenUri The token URI
    event LiquidTokenCreated(
        address indexed token,
        address indexed creator,
        string tokenUri
    );

    /// @notice Emitted when the Uniswap V4 PoolManager address is updated
    event PoolManagerUpdated(address poolManager);

    /// @notice Emitted when the Uniswap V4 hooks address is updated
    event PoolHooksUpdated(address poolHooks);

    /// @notice Emitted when the Uniswap V4 tick spacing is updated
    event PoolTickSpacingUpdated(int24 poolTickSpacing);

    /// @notice Emitted when minimum RARE liquidity requirement is updated
    event MinRareLiquidityWeiUpdated(uint256 minRareLiquidityWei);

    /// @notice Emitted when the max total supply for new tokens is updated
    event MaxTotalSupplyUpdated(uint256 maxTotalSupply);

    /// @notice Emitted when the creator launch reward for new tokens is updated
    event CreatorLaunchRewardUpdated(uint256 creatorLaunchReward);

    /// @notice Emitted when LP tick lower is updated
    /// @param lpTickLower The requested lower tick (validated to be multiple of tickSpacing)
    event LpTickLowerUpdated(int24 lpTickLower);

    /// @notice Emitted when LP tick upper is updated
    /// @param lpTickUpper The requested upper tick (validated to be multiple of tickSpacing)
    event LpTickUpperUpdated(int24 lpTickUpper);

    /// @notice Emitted when base token address is updated
    /// @param baseToken The base token address (RARE)
    event BaseTokenUpdated(address baseToken);

    /// @notice Emitted when the registry used for token registration is updated
    /// @param oldLiquidRegistry Previous registry address
    /// @param newLiquidRegistry New registry address
    event LiquidRegistryUpdated(
        address indexed oldLiquidRegistry,
        address indexed newLiquidRegistry
    );

    /// @notice Emitted when the migration executor address is updated
    /// @param migrationExecutor The new migration executor address
    event MigrationExecutorUpdated(address indexed migrationExecutor);

    // ============================================
    // FUNCTIONS
    // ============================================

    /// @notice Returns the LiquidInstant implementation used for two-sided AMM token creation.
    /// @dev This implementation is required for all instant launches; `ImplementationNotSet` is thrown
    ///      if create paths are invoked before it is configured.
    function liquidInstantImplementation() external view returns (address);

    /// @notice Returns the LiquidMultiCurve implementation used for multicurve token creation.
    /// @dev This implementation is required for all multicurve launches; `ImplementationNotSet` is thrown
    ///      if create paths are invoked before it is configured.
    function liquidMultiCurveImplementation() external view returns (address);

    /// @notice Returns the LiquidGraduated implementation used for CCA auction token creation.
    /// @dev This implementation is required for createLiquidTokenWithAuction; `ImplementationNotSet` is thrown
    ///      if invoked before it is configured.
    function liquidGraduatedImplementation() external view returns (address);

    /// @notice Returns the CCA (Continuous Clearing Auction) factory address.
    /// @dev Required for createLiquidTokenWithAuction.
    function ccaFactory() external view returns (address);

    /// @notice Returns the LBP strategy factory (FullRangeLBPStrategyFactory) address.
    /// @dev Required for createLiquidTokenWithAuction; deploys strategy per graduated token.
    function lbpStrategyFactory() external view returns (address);

    /// @notice Returns the Uniswap V4 PoolManager address.
    /// @dev Required for pool bootstrap, liquidity ops, and router-owned fee policy enforcement.
    function poolManager() external view returns (address);

    /// @notice Returns the configured V4 hook contract used for new token pools.
    /// @dev New multicurve tokens must pass pool-hook validation before first launch through this hook.
    function poolHooks() external view returns (address);

    /// @notice Returns the minimum RARE liquidity required for instant pool setup.
    /// @dev Applied when creating instant launches via `createLiquidTokenInstant`.
    function minRareLiquidityWei() external view returns (uint256);

    /// @notice Returns the max total supply minted for each new token at launch.
    function maxTotalSupply() external view returns (uint256);

    /// @notice Returns the amount of tokens transferred to the creator at launch.
    /// @dev May be zero (all tokens go to the pool).
    function creatorLaunchReward() external view returns (uint256);

    /// @notice Returns the lower LP tick used for pool creation.
    /// @dev Interpreted relative to token ordering against `baseToken`; see implementation comments.
    function lpTickLower() external view returns (int24);

    /// @notice Returns the upper LP tick used for pool creation.
    /// @dev Interpreted relative to token ordering against `baseToken`; see implementation comments.
    function lpTickUpper() external view returns (int24);

    /// @notice Returns the configured pool tick spacing for V4 hooks/pools.
    /// @dev Must be compatible with all generated LP path spacing and pool initialization constraints.
    function poolTickSpacing() external view returns (int24);

    /// @notice Returns the protocol base token address (`baseToken`, typically RARE).
    /// @dev This address is also used as the canonical reward/fee currency in active distributions.
    function baseToken() external view returns (address);

    /// @notice Returns the protocol fee recipient used across launch and auction flows.
    /// @dev Also injected into legacy CCA parameter wiring by factory token launches.
    function protocolFeeRecipient() external view returns (address);

    /// @notice Registry used by factory for automatic token registration.
    /// @dev When unset or non-contract, registration is skipped to preserve launch flexibility.
    function liquidRegistry() external view returns (address);

    /// @notice Returns the migration executor address.
    /// @dev Only the migration executor can call migrateLiquidity() on Liquid tokens.
    function migrationExecutor() external view returns (address);

    /// @notice Pause token creation in factory
    function pause() external;

    /// @notice Unpause token creation in factory
    function unpause() external;

    /// @notice Predicts the token address for a graduated token deployment.
    /// @dev Use this to compute the token address before calling createLiquidTokenWithAuction.
    ///      Enables off-chain salt mining for valid V4 hook addresses.
    ///      The effective salt is keccak256(abi.encode(_deployer, _salt)) to prevent front-running.
    /// @param _salt The user-supplied salt that will be used for deployment
    /// @param _deployer The address that will call createLiquidTokenWithAuction (msg.sender)
    /// @return The predicted token clone address
    function predictGraduatedTokenAddress(
        bytes32 _salt,
        address _deployer
    ) external view returns (address);

    /// @notice Creates a new Liquid token with two-sided AMM liquidity
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
    ) external returns (address token);

    /// @notice Creates a new Liquid token with multicurve liquidity
    /// @param _creator The address of the token creator (receives fees and launch reward)
    /// @param _tokenUri The ERC20z token URI (metadata link)
    /// @param _name The token name
    /// @param _symbol The token symbol
    /// @param _initialRareLiquidity The amount of RARE tokens to provide as initial liquidity
    /// @param _curves Curve configuration for multicurve deployment
    /// @return token The address of the created token
    function createLiquidTokenMultiCurve(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _initialRareLiquidity,
        Curve[] calldata _curves
    ) external returns (address token);

    /// @notice Creates a new token through auction migration setup.
    /// @dev Migration is driven by auction config + strategy factory internals.
    /// @param _creator The token creator address (launch beneficiary/authority)
    /// @param _tokenUri Token metadata URI
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param _auctionSupply Amount of token to seed for auction distribution
    /// @param _auctionConfigData ABI-encoded auction config payload
    /// @param _salt Deterministic salt for token strategy and address prediction
    /// @return token The address of the created graduated token
    /// @return auction The address of the CCA auction contract
    function createLiquidTokenWithAuction(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _auctionSupply,
        bytes calldata _auctionConfigData,
        bytes32 _salt
    ) external returns (address token, address auction);

    /// @notice Configure the registry used for automatic token registration
    /// @param _liquidRegistry Registry address
    function setLiquidRegistry(address _liquidRegistry) external;

    /// @notice Sets the LiquidGraduated implementation (for CCA auction launches)
    /// @param _implementation The implementation address
    function setLiquidGraduatedImplementation(address _implementation) external;

    /// @notice Sets the LiquidMultiCurve implementation (for multicurve anti-sniping launches)
    /// @param _implementation The implementation address
    function setLiquidMultiCurveImplementation(
        address _implementation
    ) external;

    /// @notice Sets the LiquidInstant implementation (for two-sided AMM launches)
    /// @param _implementation The implementation address
    function setLiquidInstantImplementation(address _implementation) external;

    /// @notice Sets the CCA (Continuous Clearing Auction) factory address
    /// @param _ccaFactory The CCA factory address
    function setCcaFactory(address _ccaFactory) external;

    /// @notice Sets the LBP strategy factory (canonical FullRangeLBPStrategy)
    /// @param _lbpStrategyFactory The LBP strategy factory address
    function setLbpStrategyFactory(address _lbpStrategyFactory) external;

    /// @notice Sets the protocol fee recipient used by protocol/auction flows
    /// @param _protocolFeeRecipient The protocol fee recipient address
    function setProtocolFeeRecipient(address _protocolFeeRecipient) external;

    /// @notice Sets the migration executor address
    /// @param _migrationExecutor The migration executor address
    function setMigrationExecutor(address _migrationExecutor) external;

    /// @notice Sets the base token address (RARE)
    /// @param _baseToken The base token address (RARE)
    function setBaseToken(address _baseToken) external;

    /// @notice Sets the Uniswap V4 PoolManager address
    /// @param _poolManager The PoolManager address
    function setPoolManager(address _poolManager) external;

    /// @notice Sets the Uniswap V4 hooks address
    /// @param _poolHooks The pool hooks address (address(0) if none)
    function setPoolHooks(address _poolHooks) external;

    /// @notice Sets the Uniswap V4 tick spacing
    /// @param _poolTickSpacing The pool tick spacing
    function setPoolTickSpacing(int24 _poolTickSpacing) external;

    /// @notice Sets the minimum RARE liquidity required for instant launches
    /// @param _minRareLiquidityWei Minimum RARE tokens (in wei) for instant launches (0 = no minimum)
    function setMinRareLiquidityWei(uint256 _minRareLiquidityWei) external;

    /// @notice Sets the max total supply minted for each new token at launch
    /// @param _supply New max total supply (must be > 0 and > current creatorLaunchReward)
    function setMaxTotalSupply(uint256 _supply) external;

    /// @notice Sets the creator launch reward for new tokens (tokens sent to creator at launch)
    /// @param _reward New creator reward amount (0 is allowed; must be < maxTotalSupply)
    function setCreatorLaunchReward(uint256 _reward) external;

    /// @notice Sets the LP tick lower bound
    /// @param _lower Lower tick for LP positions
    function setLpTickLower(int24 _lower) external;

    /// @notice Sets the LP tick upper bound
    /// @param _upper Upper tick for LP positions
    function setLpTickUpper(int24 _upper) external;
}
