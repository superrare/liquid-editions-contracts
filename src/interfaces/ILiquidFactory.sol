// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

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

    /// @notice Thrown when TIER 3 fee distribution is invalid (must sum to exactly 10000 BPS / 100%)
    error InvalidFeeDistribution();

    /// @notice Thrown when tick values are not multiples of poolTickSpacing
    error InvalidTickSpacing();

    /// @notice Thrown when a fee value exceeds the maximum allowed
    error FeeTooHigh(uint256 fee, uint256 maxFee);

    /// @notice Thrown when slippage value exceeds the maximum allowed
    error SlippageTooHigh(uint256 slippage, uint256 maxSlippage);

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

    /// @notice Emitted when protocol fee recipient address is updated
    event ProtocolFeeRecipientUpdated(address protocolFeeRecipient);

    /// @notice Emitted when WETH address is updated
    event WethUpdated(address weth);

    /// @notice Emitted when RARE burner address is updated
    event RareBurnerUpdated(address rareBurner);

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

    /// @notice Emitted when minimum order size is updated
    event MinOrderSizeWeiUpdated(uint128 minOrderSizeWei);

    /// @notice Emitted when minimum initial liquidity is updated
    event MinInitialLiquidityWeiUpdated(uint256 minInitialLiquidityWei);

    /// @notice Emitted when RARE burn fee BPS is updated
    event RareBurnFeeBPSUpdated(uint256 rareBurnFeeBPS);

    /// @notice Emitted when protocol fee BPS is updated
    event ProtocolFeeBPSUpdated(uint256 protocolFeeBPS);

    /// @notice Emitted when referrer fee BPS is updated
    event ReferrerFeeBPSUpdated(uint256 referrerFeeBPS);

    /// @notice Emitted when LP tick lower is updated
    /// @param lpTickLower The requested lower tick (validated to be multiple of tickSpacing)
    event LpTickLowerUpdated(int24 lpTickLower);

    /// @notice Emitted when LP tick upper is updated
    /// @param lpTickUpper The requested upper tick (validated to be multiple of tickSpacing)
    event LpTickUpperUpdated(int24 lpTickUpper);

    // ============================================
    // FUNCTIONS
    // ============================================

    // Protocol addresses (all public)
    function protocolFeeRecipient() external view returns (address);

    function weth() external view returns (address);

    function rareBurner() external view returns (address);

    function poolManager() external view returns (address);

    function v4Quoter() external view returns (address);

    function poolHooks() external view returns (address);

    // Trading knobs (individual public values)
    function internalMaxSlippageBps() external view returns (uint16);

    function minOrderSizeWei() external view returns (uint128);

    function minInitialLiquidityWei() external view returns (uint256);

    // Fee splits (individual public values)
    function rareBurnFeeBPS() external view returns (uint256);

    function protocolFeeBPS() external view returns (uint256);

    function referrerFeeBPS() external view returns (uint256);

    // LP band (individual public values, used only at pool create)
    function lpTickLower() external view returns (int24);

    function lpTickUpper() external view returns (int24);

    function poolTickSpacing() external view returns (int24);
}
