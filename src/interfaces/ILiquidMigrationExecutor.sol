// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Position} from "doppler/types/Position.sol";

/// @title ILiquidMigrationExecutor
/// @notice Interface for the migration executor that safely migrates Liquid token pool liquidity
///         to a new Uniswap V4 pool with a different hook configuration.
interface ILiquidMigrationExecutor {
    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when an operation is attempted with a zero address
    error AddressZero();

    /// @notice Thrown when the new pool key's hooks are not in the approved whitelist
    error HookNotApproved(address hook);

    /// @notice Thrown when the new pool key's tick spacing is not allowed
    error TickSpacingNotAllowed(int24 tickSpacing);

    /// @notice Thrown when the new pool key's fee is not allowed
    error FeeNotAllowed(uint24 fee);

    /// @notice Thrown when the new pool key's currencies don't match the old pool
    error CurrencyMismatch();

    /// @notice Thrown when the token is not registered in the Liquid registry
    error TokenNotRegistered(address token);

    /// @notice Thrown when no positions are provided for the new pool
    error NoPositions();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a migration is successfully executed
    /// @param token The Liquid token whose liquidity was migrated
    /// @param oldHooks The old hook contract address
    /// @param newHooks The new hook contract address
    event MigrationExecuted(
        address indexed token,
        address indexed oldHooks,
        address indexed newHooks
    );

    /// @notice Emitted when a hook is added to or removed from the approved whitelist
    /// @param hook The hook address
    /// @param approved Whether the hook is approved
    event HookApprovalUpdated(address indexed hook, bool approved);

    /// @notice Emitted when an allowed tick spacing is added or removed
    /// @param tickSpacing The tick spacing value
    /// @param allowed Whether the tick spacing is allowed
    event AllowedTickSpacingUpdated(int24 tickSpacing, bool allowed);

    /// @notice Emitted when an allowed fee is added or removed
    /// @param fee The fee value
    /// @param allowed Whether the fee is allowed
    event AllowedFeeUpdated(uint24 fee, bool allowed);

    /// @notice Emitted when the protocol vault address is updated
    /// @param newVault The new vault address
    event ProtocolVaultUpdated(address indexed newVault);

    /// @notice Emitted when the registry address is updated
    /// @param newRegistry The new registry address
    event LiquidRegistryUpdated(address indexed newRegistry);

    // ============================================
    // STRUCTS
    // ============================================

    /// @notice Describes a migration plan for moving liquidity to a new pool
    /// @param token The Liquid token to migrate
    /// @param newPoolKey The target pool configuration (must have approved hooks, matching currencies)
    /// @param newSqrtPriceX96 The starting price for the new pool
    /// @param newPositions The liquidity positions to create in the new pool
    /// @param maxDust0 Maximum allowed positive net delta for currency0 (bounds dust to dustRecipient)
    /// @param maxDust1 Maximum allowed positive net delta for currency1 (bounds dust to dustRecipient)
    struct MigrationPlan {
        address token;
        PoolKey newPoolKey;
        uint160 newSqrtPriceX96;
        Position[] newPositions;
        uint256 maxDust0;
        uint256 maxDust1;
    }

    // ============================================
    // FUNCTIONS
    // ============================================

    /// @notice Execute a migration plan to move a token's liquidity to a new pool
    /// @dev Only callable by owner. Validates the plan against safety rules, then calls
    ///      token.migrateLiquidity() which performs the atomic in-PoolManager migration.
    /// @param plan The migration plan to execute
    function executeMigration(MigrationPlan calldata plan) external;

    /// @notice Returns the protocol vault address (dust sweep destination)
    function protocolVault() external view returns (address);

    /// @notice Returns the registry address used to validate tokens before migration.
    /// @dev If set to a non-contract sentinel (e.g. address(1)), the registration check is skipped.
    function liquidRegistry() external view returns (address);

    /// @notice Returns whether a hook is approved for migration targets
    function approvedHooks(address hook) external view returns (bool);

    /// @notice Returns whether a tick spacing is allowed for migration targets
    function allowedTickSpacings(int24 tickSpacing) external view returns (bool);

    /// @notice Returns whether a fee is allowed for migration targets
    function allowedFees(uint24 fee) external view returns (bool);

    /// @notice Set the protocol vault address
    /// @param _protocolVault The new vault address
    function setProtocolVault(address _protocolVault) external;

    /// @notice Set the registry address
    /// @param _liquidRegistry The new registry address
    function setLiquidRegistry(address _liquidRegistry) external;

    /// @notice Add or remove a hook from the approved whitelist
    /// @param hook The hook address
    /// @param approved Whether the hook should be approved
    function approveHook(address hook, bool approved) external;

    /// @notice Add or remove a tick spacing from the allowed set
    /// @param tickSpacing The tick spacing value
    /// @param allowed Whether the tick spacing should be allowed
    function setAllowedTickSpacing(int24 tickSpacing, bool allowed) external;

    /// @notice Add or remove a fee from the allowed set
    /// @param fee The fee value
    /// @param allowed Whether the fee should be allowed
    function setAllowedFee(uint24 fee, bool allowed) external;
}
