// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LiquidFactory} from "../../src/LiquidFactory.sol";

/// @title FactoryTestHelper
/// @notice Shared helper for deploying LiquidFactory with valid hook address in tests
/// @dev Uses CREATE2 salt mining to find valid hook addresses (limited attempts for test performance)
abstract contract FactoryTestHelper is Test {
    struct FactoryParams {
        address admin;
        address protocolFeeRecipient;
        address weth;
        address poolManager;
        address rareBurner;
        uint256 rareBurnFeeBPS;
        uint256 protocolFeeBPS;
        uint256 referrerFeeBPS;
        uint256 totalFeeBPS;
        uint256 creatorFeeBPS;
        int24 lpTickLower;
        int24 lpTickUpper;
        address v4Quoter;
        int24 poolTickSpacing;
        uint16 internalMaxSlippageBps;
        uint128 minOrderSizeWei;
        uint256 minInitialLiquidityWei;
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
                    params.protocolFeeRecipient,
                    params.weth,
                    params.poolManager,
                    params.rareBurner,
                    params.rareBurnFeeBPS,
                    params.protocolFeeBPS,
                    params.referrerFeeBPS,
                    params.totalFeeBPS,
                    params.creatorFeeBPS,
                    params.lpTickLower,
                    params.lpTickUpper,
                    params.v4Quoter,
                    address(0), // _poolHooks is ignored, factory becomes hook
                    params.poolTickSpacing,
                    params.internalMaxSlippageBps,
                    params.minOrderSizeWei,
                    params.minInitialLiquidityWei
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
        address _protocolFeeRecipient,
        address _weth,
        address _poolManager,
        address _rareBurner,
        uint256 _rareBurnFeeBPS,
        uint256 _protocolFeeBPS,
        uint256 _referrerFeeBPS,
        uint256 _totalFeeBPS,
        uint256 _creatorFeeBPS,
        int24 _lpTickLower,
        int24 _lpTickUpper,
        address _v4Quoter,
        int24 _poolTickSpacing,
        uint16 _internalMaxSlippageBps,
        uint128 _minOrderSizeWei,
        uint256 _minInitialLiquidityWei,
        uint256 maxAttempts
    ) internal returns (LiquidFactory) {
        FactoryParams memory params = FactoryParams({
            admin: _admin,
            protocolFeeRecipient: _protocolFeeRecipient,
            weth: _weth,
            poolManager: _poolManager,
            rareBurner: _rareBurner,
            rareBurnFeeBPS: _rareBurnFeeBPS,
            protocolFeeBPS: _protocolFeeBPS,
            referrerFeeBPS: _referrerFeeBPS,
            totalFeeBPS: _totalFeeBPS,
            creatorFeeBPS: _creatorFeeBPS,
            lpTickLower: _lpTickLower,
            lpTickUpper: _lpTickUpper,
            v4Quoter: _v4Quoter,
            poolTickSpacing: _poolTickSpacing,
            internalMaxSlippageBps: _internalMaxSlippageBps,
            minOrderSizeWei: _minOrderSizeWei,
            minInitialLiquidityWei: _minInitialLiquidityWei
        });

        return _deployFactoryAsHookInternal(params, maxAttempts);
    }

    /// @notice Helper with default max attempts (3000)
    function deployFactoryAsHook(
        address _admin,
        address _protocolFeeRecipient,
        address _weth,
        address _poolManager,
        address _rareBurner,
        uint256 _rareBurnFeeBPS,
        uint256 _protocolFeeBPS,
        uint256 _referrerFeeBPS,
        uint256 _totalFeeBPS,
        uint256 _creatorFeeBPS,
        int24 _lpTickLower,
        int24 _lpTickUpper,
        address _v4Quoter,
        int24 _poolTickSpacing,
        uint16 _internalMaxSlippageBps,
        uint128 _minOrderSizeWei,
        uint256 _minInitialLiquidityWei
    ) internal returns (LiquidFactory) {
        FactoryParams memory params = FactoryParams({
            admin: _admin,
            protocolFeeRecipient: _protocolFeeRecipient,
            weth: _weth,
            poolManager: _poolManager,
            rareBurner: _rareBurner,
            rareBurnFeeBPS: _rareBurnFeeBPS,
            protocolFeeBPS: _protocolFeeBPS,
            referrerFeeBPS: _referrerFeeBPS,
            totalFeeBPS: _totalFeeBPS,
            creatorFeeBPS: _creatorFeeBPS,
            lpTickLower: _lpTickLower,
            lpTickUpper: _lpTickUpper,
            v4Quoter: _v4Quoter,
            poolTickSpacing: _poolTickSpacing,
            internalMaxSlippageBps: _internalMaxSlippageBps,
            minOrderSizeWei: _minOrderSizeWei,
            minInitialLiquidityWei: _minInitialLiquidityWei
        });

        return _deployFactoryAsHookInternal(params, 3000);
    }
}
