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

    /// @notice Thrown when tick values are not multiples of poolTickSpacing
    error InvalidTickSpacing();

    /// @notice Thrown when an invalid amount is provided
    error InvalidAmount();

    /// @notice Thrown when the configured PoolHooks address is already bound to another factory
    error SwapGuardFactoryMismatch(address poolHooks, address configuredFactory, address expectedFactory);

    /// @notice Thrown when an invalid pool hooks contract is configured
    error InvalidPoolHook(address poolHooks);

    /// @notice Thrown when a configured pool hook is not a LiquidGuard-compatible hook
    error PoolHookNotGuard(address poolHooks);

    /// @notice Thrown when pool hook flags do not include required permissions
    /// @param poolHooks The hook address
    /// @param actualFlags Flags reported by the hook
    /// @param requiredFlags Minimum required flags mask
    error PoolHookMissingFlags(address poolHooks, uint160 actualFlags, uint160 requiredFlags);

    /// @notice Thrown when poolHooks is address(0) during token creation
    error PoolHooksNotSet();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a new Liquid token is created
    /// @param token The address of the created token
    /// @param creator The address of the token creator
    /// @param tokenUri The token URI
    event LiquidTokenCreated(address indexed token, address indexed creator, string tokenUri);

    /// @notice Emitted when the Uniswap V4 PoolManager address is updated
    event PoolManagerUpdated(address poolManager);

    /// @notice Emitted when the Uniswap V4 hooks address is updated
    event PoolHooksUpdated(address poolHooks);

    /// @notice Emitted when the Uniswap V4 tick spacing is updated
    event PoolTickSpacingUpdated(int24 poolTickSpacing);

    /// @notice Emitted when the max total supply for new tokens is updated
    event MaxTotalSupplyUpdated(uint256 maxTotalSupply);

    /// @notice Emitted when the creator launch reward for new tokens is updated
    event CreatorLaunchRewardUpdated(uint256 creatorLaunchReward);

    /// @notice Emitted when base token address is updated
    /// @param baseToken The base token address (RARE)
    event BaseTokenUpdated(address baseToken);

    /// @notice Emitted when the registry used for token registration is updated
    /// @param oldLiquidRegistry Previous registry address
    /// @param newLiquidRegistry New registry address
    event LiquidRegistryUpdated(address indexed oldLiquidRegistry, address indexed newLiquidRegistry);

    /// @notice Emitted when the migration executor address is updated
    /// @param migrationExecutor The new migration executor address
    event MigrationExecutorUpdated(address indexed migrationExecutor);

    // ============================================
    // FUNCTIONS
    // ============================================

    /// @notice Returns the LiquidMultiCurve implementation used for multicurve token creation.
    /// @dev This implementation is required for all multicurve launches; `ImplementationNotSet` is thrown
    ///      if create paths are invoked before it is configured.
    function liquidMultiCurveImplementation() external view returns (address);

    /// @notice Returns the Uniswap V4 PoolManager address.
    /// @dev Required for pool bootstrap, liquidity ops, and router-owned fee policy enforcement.
    function poolManager() external view returns (address);

    /// @notice Returns the configured V4 hook contract used for new token pools.
    /// @dev New multicurve tokens must pass pool-hook validation before first launch through this hook.
    function poolHooks() external view returns (address);

    /// @notice Returns the max total supply minted for each new token at launch.
    function maxTotalSupply() external view returns (uint256);

    /// @notice Returns the amount of tokens transferred to the creator at launch.
    /// @dev May be zero (all tokens go to the pool).
    function creatorLaunchReward() external view returns (uint256);

    /// @notice Returns the configured pool tick spacing for V4 hooks/pools.
    /// @dev Must be compatible with all generated LP path spacing and pool initialization constraints.
    function poolTickSpacing() external view returns (int24);

    /// @notice Returns the protocol base token address (`baseToken`, typically RARE).
    /// @dev This address is also used as the canonical reward/fee currency in active distributions.
    function baseToken() external view returns (address);

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

    /// @notice Creates a new Liquid token with multicurve liquidity
    /// @dev Uses the factory's current maxTotalSupply and creatorLaunchReward.
    /// @param _creator The address of the token creator (receives fees and launch reward)
    /// @param _tokenUri The ERC20z token URI (metadata link)
    /// @param _name The token name
    /// @param _symbol The token symbol
    /// @param _initialRareLiquidity Optional RARE for head liquidity beyond the curve range (can be 0)
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

    /// @notice Creates a new Liquid token with multicurve liquidity and a custom max total supply
    /// @dev Uses the provided supply and the factory's current creatorLaunchReward.
    /// @param _creator The address of the token creator (receives fees and launch reward)
    /// @param _tokenUri The ERC20z token URI (metadata link)
    /// @param _name The token name
    /// @param _symbol The token symbol
    /// @param _initialRareLiquidity Optional RARE for head liquidity beyond the curve range (can be 0)
    /// @param _curves Curve configuration for multicurve deployment
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
    ) external returns (address token);

    /// @notice Configure the registry used for automatic token registration
    /// @param _liquidRegistry Registry address
    function setLiquidRegistry(address _liquidRegistry) external;

    /// @notice Sets the LiquidMultiCurve implementation (for multicurve anti-sniping launches)
    /// @param _implementation The implementation address
    function setLiquidMultiCurveImplementation(address _implementation) external;

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

    /// @notice Sets the max total supply minted for each new token at launch
    /// @param _supply New max total supply (must be > 0 and > current creatorLaunchReward)
    function setMaxTotalSupply(uint256 _supply) external;

    /// @notice Sets the creator launch reward for new tokens (tokens sent to creator at launch)
    /// @param _reward New creator reward amount (0 is allowed; must be < maxTotalSupply)
    function setCreatorLaunchReward(uint256 _reward) external;
}
