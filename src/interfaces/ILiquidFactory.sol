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

    /// @notice Thrown when a fee value exceeds the maximum allowed
    error FeeTooHigh(uint256 fee, uint256 maxFee);

    /// @notice Thrown when slippage value exceeds the maximum allowed
    error SlippageTooHigh(uint256 slippage, uint256 maxSlippage);

    /// @notice Thrown when an invalid amount is provided
    error InvalidAmount();

    /// @notice Thrown when the configured PoolHooks address is already bound to another factory
    error SwapGuardFactoryMismatch(
        address poolHooks,
        address configuredFactory,
        address expectedFactory
    );

    /// @notice Thrown when an invalid pool hooks contract is configured for multicurve
    error InvalidMultiCurvePoolHook(address poolHooks);

    /// @notice Thrown when a configured multicurve pool hook is not a LiquidSwapGuard
    error MultiCurvePoolHookNotGuard(address poolHooks);

    /// @notice Thrown when multicurve hook flags do not include required permissions
    /// @param poolHooks The hook address
    /// @param actualFlags Flags reported by the hook
    /// @param requiredFlags Minimum required flags mask
    error MultiCurvePoolHookMissingFlags(
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

    /// @notice Emitted when WETH address is updated
    event WethUpdated(address weth);

    /// @notice Emitted when the Uniswap V4 PoolManager address is updated
    event PoolManagerUpdated(address poolManager);

    /// @notice Emitted when the Uniswap V4 Quoter address is updated
    event V4QuoterUpdated(address v4Quoter);

    /// @notice Emitted when the Uniswap V4 hooks address is updated
    event PoolHooksUpdated(address poolHooks);

    /// @notice Emitted when the Uniswap V4 tick spacing is updated
    event PoolTickSpacingUpdated(int24 poolTickSpacing);

    /// @notice Emitted when internal max slippage BPS is updated
    event InternalMaxSlippageBpsUpdated(uint16 internalMaxSlippageBps);

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

    // Implementation addresses
    function liquidMultiCurveImplementation() external view returns (address);

    // Protocol addresses (all public)
    function weth() external view returns (address);

    function poolManager() external view returns (address);

    function v4Quoter() external view returns (address);

    function poolHooks() external view returns (address);

    // Trading knobs (individual public values)
    function internalMaxSlippageBps() external view returns (uint16);

    function minRareLiquidityWei() external view returns (uint256);

    // LP band (individual public values, used only at pool create)
    function lpTickLower() external view returns (int24);

    function lpTickUpper() external view returns (int24);

    function poolTickSpacing() external view returns (int24);

    function baseToken() external view returns (address);

    function protocolFeeRecipient() external view returns (address);

    /// @notice Registry used by factory for automatic token registration
    function liquidRegistry() external view returns (address);

    /// @notice Pause token creation in factory
    function pause() external;

    /// @notice Unpause token creation in factory
    function unpause() external;

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

    /// @notice Configure the registry used for automatic token registration
    /// @param _liquidRegistry Registry address
    function setLiquidRegistry(address _liquidRegistry) external;
}
