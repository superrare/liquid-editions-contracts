// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";

/// @title FactoryTestHelper
/// @notice Shared helper for deploying LiquidFactory with valid hook address in tests
/// @dev Uses CREATE2 salt mining to find valid hook addresses (limited attempts for test performance)
abstract contract FactoryTestHelper is Test {
    struct FactoryParams {
        address admin;
        address poolManager;
        int24 lpTickLower;
        int24 lpTickUpper;
        int24 poolTickSpacing;
        uint256 minRareLiquidityWei;
    }

    /// @notice Helper to deploy LiquidFactory with valid hook address using CREATE2
    /// @dev Mines salt with a limited number of attempts for testing
    /// @param maxAttempts Maximum number of salts to try before reverting
    function _deployFactoryAsHookInternal(
        FactoryParams memory params,
        uint256 maxAttempts
    ) private returns (LiquidFactory) {
        for (uint256 i = 0; i < maxAttempts; ++i) {
            bytes32 salt = bytes32(i);

            try
                new LiquidFactory{salt: salt}(
                    params.admin,
                    params.poolManager,
                    params.lpTickLower,
                    params.lpTickUpper,
                    address(0), // _poolHooks is ignored, factory becomes hook
                    params.poolTickSpacing,
                    params.minRareLiquidityWei
                )
            returns (LiquidFactory deployed) {
                return deployed;
            } catch {
                continue;
            }
        }

        revert("Could not find valid hook address");
    }

    function deployFactoryAsHook(
        address _admin,
        address _poolManager,
        int24 _lpTickLower,
        int24 _lpTickUpper,
        int24 _poolTickSpacing,
        uint256 _minRareLiquidityWei,
        uint256 maxAttempts
    ) internal returns (LiquidFactory) {
        FactoryParams memory params = FactoryParams({
            admin: _admin,
            poolManager: _poolManager,
            lpTickLower: _lpTickLower,
            lpTickUpper: _lpTickUpper,
            poolTickSpacing: _poolTickSpacing,
            minRareLiquidityWei: _minRareLiquidityWei
        });

        return _deployFactoryAsHookInternal(params, maxAttempts);
    }

    /// @notice Helper with default max attempts (3000)
    function deployFactoryAsHook(
        address _admin,
        address _poolManager,
        int24 _lpTickLower,
        int24 _lpTickUpper,
        int24 _poolTickSpacing,
        uint256 _minRareLiquidityWei
    ) internal returns (LiquidFactory) {
        FactoryParams memory params = FactoryParams({
            admin: _admin,
            poolManager: _poolManager,
            lpTickLower: _lpTickLower,
            lpTickUpper: _lpTickUpper,
            poolTickSpacing: _poolTickSpacing,
            minRareLiquidityWei: _minRareLiquidityWei
        });

        return _deployFactoryAsHookInternal(params, 3000);
    }
}
