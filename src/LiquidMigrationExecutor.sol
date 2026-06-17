// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ILiquidMigrationExecutor} from "liquid-editions/interfaces/ILiquidMigrationExecutor.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Position} from "doppler/types/Position.sol";

/// @title LiquidMigrationExecutor
/// @notice Policy gate that validates and executes atomic liquidity migrations for Liquid tokens.
/// @dev Owner calls executeMigration() with a MigrationPlan. The executor validates the plan
///      against safety rules (approved hooks, matching currencies, allowed fees/tick spacings),
///      then delegates to the token's migrateLiquidity() function for atomic in-PoolManager execution.
///      Tokens never leave the PoolManager during migration.
contract LiquidMigrationExecutor is Ownable, ILiquidMigrationExecutor {
    /// @notice Fixed destination for any dust from migrations
    address public protocolVault;

    /// @notice Registry used to validate tokens are registered
    address public liquidRegistry;

    /// @notice Whitelist of hook addresses approved as migration targets
    mapping(address => bool) public approvedHooks;

    /// @notice Set of tick spacings allowed for new pools
    mapping(int24 => bool) public allowedTickSpacings;

    /// @notice Set of fees allowed for new pools
    mapping(uint24 => bool) public allowedFees;

    constructor(
        address _owner,
        address _protocolVault,
        address _liquidRegistry
    ) Ownable(_owner) {
        if (_protocolVault == address(0)) revert AddressZero();
        if (_liquidRegistry == address(0)) revert AddressZero();

        protocolVault = _protocolVault;
        liquidRegistry = _liquidRegistry;
    }

    /// @inheritdoc ILiquidMigrationExecutor
    function executeMigration(MigrationPlan calldata plan) external onlyOwner {
        // Validate token is registered (skip if registry is not a contract, e.g. address(1) sentinel)
        if (liquidRegistry.code.length > 0) {
            if (!ILiquidRegistry(liquidRegistry).isRegistered(plan.token)) {
                revert TokenNotRegistered(plan.token);
            }
        }

        // Read old pool key from token
        (Currency oldCurrency0, Currency oldCurrency1, , , IHooks oldHooks) = ILiquid(plan.token).poolKey();

        // Validate currencies match
        if (
            Currency.unwrap(plan.newPoolKey.currency0) != Currency.unwrap(oldCurrency0) ||
            Currency.unwrap(plan.newPoolKey.currency1) != Currency.unwrap(oldCurrency1)
        ) {
            revert CurrencyMismatch();
        }

        // Validate new hook is approved
        address newHook = address(plan.newPoolKey.hooks);
        if (!approvedHooks[newHook]) revert HookNotApproved(newHook);

        // Validate fee is allowed
        if (!allowedFees[plan.newPoolKey.fee]) revert FeeNotAllowed(plan.newPoolKey.fee);

        // Validate tick spacing is allowed
        if (!allowedTickSpacings[plan.newPoolKey.tickSpacing]) {
            revert TickSpacingNotAllowed(plan.newPoolKey.tickSpacing);
        }

        // Validate positions are provided
        if (plan.newPositions.length == 0) revert NoPositions();

        // Execute atomic migration on the token
        ILiquid(plan.token).migrateLiquidity(
            plan.newPoolKey,
            plan.newSqrtPriceX96,
            plan.newPositions,
            protocolVault,
            plan.maxDust0,
            plan.maxDust1
        );

        emit MigrationExecuted(plan.token, address(oldHooks), newHook);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @inheritdoc ILiquidMigrationExecutor
    function setProtocolVault(address _protocolVault) external onlyOwner {
        if (_protocolVault == address(0)) revert AddressZero();
        protocolVault = _protocolVault;
        emit ProtocolVaultUpdated(_protocolVault);
    }

    /// @inheritdoc ILiquidMigrationExecutor
    function setLiquidRegistry(address _liquidRegistry) external onlyOwner {
        if (_liquidRegistry == address(0)) revert AddressZero();
        liquidRegistry = _liquidRegistry;
        emit LiquidRegistryUpdated(_liquidRegistry);
    }

    /// @inheritdoc ILiquidMigrationExecutor
    function approveHook(address hook, bool approved) external onlyOwner {
        if (hook == address(0)) revert AddressZero();
        approvedHooks[hook] = approved;
        emit HookApprovalUpdated(hook, approved);
    }

    /// @inheritdoc ILiquidMigrationExecutor
    function setAllowedTickSpacing(int24 tickSpacing, bool allowed) external onlyOwner {
        allowedTickSpacings[tickSpacing] = allowed;
        emit AllowedTickSpacingUpdated(tickSpacing, allowed);
    }

    /// @inheritdoc ILiquidMigrationExecutor
    function setAllowedFee(uint24 fee, bool allowed) external onlyOwner {
        allowedFees[fee] = allowed;
        emit AllowedFeeUpdated(fee, allowed);
    }
}
