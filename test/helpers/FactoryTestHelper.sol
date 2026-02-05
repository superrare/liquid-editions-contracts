// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LiquidFactory} from "../../src/LiquidFactory.sol";
import {MockRARE} from "./MockRARE.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FactoryTestHelper
/// @notice Shared helper for deploying LiquidFactory with valid hook address in tests
/// @dev Uses CREATE2 salt mining to find valid hook addresses (limited attempts for test performance)
abstract contract FactoryTestHelper is Test {
    struct FactoryParams {
        address admin;
        address weth;
        address poolManager;
        int24 lpTickLower;
        int24 lpTickUpper;
        address v4Quoter;
        int24 poolTickSpacing;
        uint16 internalMaxSlippageBps;
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
                    params.weth,
                    params.poolManager,
                    params.lpTickLower,
                    params.lpTickUpper,
                    params.v4Quoter,
                    address(0), // _poolHooks is ignored, factory becomes hook
                    params.poolTickSpacing,
                    params.internalMaxSlippageBps,
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
        address _weth,
        address _poolManager,
        int24 _lpTickLower,
        int24 _lpTickUpper,
        address _v4Quoter,
        int24 _poolTickSpacing,
        uint16 _internalMaxSlippageBps,
        uint256 _minRareLiquidityWei,
        uint256 maxAttempts
    ) internal returns (LiquidFactory) {
        FactoryParams memory params = FactoryParams({
            admin: _admin,
            weth: _weth,
            poolManager: _poolManager,
            lpTickLower: _lpTickLower,
            lpTickUpper: _lpTickUpper,
            v4Quoter: _v4Quoter,
            poolTickSpacing: _poolTickSpacing,
            internalMaxSlippageBps: _internalMaxSlippageBps,
            minRareLiquidityWei: _minRareLiquidityWei
        });

        return _deployFactoryAsHookInternal(params, maxAttempts);
    }

    /// @notice Helper with default max attempts (3000)
    function deployFactoryAsHook(
        address _admin,
        address _weth,
        address _poolManager,
        int24 _lpTickLower,
        int24 _lpTickUpper,
        address _v4Quoter,
        int24 _poolTickSpacing,
        uint16 _internalMaxSlippageBps,
        uint256 _minRareLiquidityWei
    ) internal returns (LiquidFactory) {
        FactoryParams memory params = FactoryParams({
            admin: _admin,
            weth: _weth,
            poolManager: _poolManager,
            lpTickLower: _lpTickLower,
            lpTickUpper: _lpTickUpper,
            v4Quoter: _v4Quoter,
            poolTickSpacing: _poolTickSpacing,
            internalMaxSlippageBps: _internalMaxSlippageBps,
            minRareLiquidityWei: _minRareLiquidityWei
        });

        return _deployFactoryAsHookInternal(params, 3000);
    }
}
