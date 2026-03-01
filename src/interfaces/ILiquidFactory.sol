// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Curve} from "doppler/libraries/Multicurve.sol";

/// @title ILiquidFactory
/// @notice Interface for the LiquidFactory contract
interface ILiquidFactory {
    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when an operation is attempted with a zero address
    error AddressZero();

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

    /// @notice Returns the Uniswap V4 PoolManager address.
    /// @dev Required for pool bootstrap, liquidity ops, and router-owned fee policy enforcement.
    function poolManager() external view returns (address);

    /// @notice Returns the configured V4 hook contract used for new token pools.
    /// @dev New multicurve tokens must pass pool-hook validation before first launch through this hook.
    function poolHooks() external view returns (address);

    /// @notice Returns the minimum RARE liquidity required for launch-time pool setup.
    /// @dev Applied when creating multicurve launches via `createLiquidTokenMultiCurve`.
    function minRareLiquidityWei() external view returns (uint256);

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

    /// @notice Pause token creation in factory
    function pause() external;

    /// @notice Unpause token creation in factory
    function unpause() external;

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
    /// @dev `_migrator` is intentionally retained only for API compatibility and is ignored.
    ///      Migration is driven by auction config + strategy factory internals.
    /// @param _creator The token creator address (launch beneficiary/authority)
    /// @param _tokenUri Token metadata URI
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param _migrator Compatibility-only address (kept for stable API, not used)
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
        address _migrator,
        uint256 _auctionSupply,
        bytes calldata _auctionConfigData,
        bytes32 _salt
    ) external returns (address token, address auction);

    /// @notice Configure the registry used for automatic token registration
    /// @param _liquidRegistry Registry address
    function setLiquidRegistry(address _liquidRegistry) external;
}
