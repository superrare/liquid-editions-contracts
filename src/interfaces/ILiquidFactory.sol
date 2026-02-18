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

    /// @notice Emitted when the implementation address is updated
    /// @param oldImplementation The old implementation address
    /// @param newImplementation The new implementation address
    event ImplementationUpdated(
        address indexed oldImplementation,
        address indexed newImplementation
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

    // ============================================
    // FUNCTIONS
    // ============================================

    // Implementation addresses
    function liquidImplementation() external view returns (address);

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

    /// @notice Creates a new Liquid token instance (permissionless)
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
    ) external returns (address token);

    /// @notice Creates a new Liquid token with multicurve liquidity (anti-sniping launch)
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
}
