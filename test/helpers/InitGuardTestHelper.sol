// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {DeployLiquidInitGuard} from "script/deployers/DeployLiquidInitGuard.s.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @title InitGuardTestHelper
/// @notice Deploys a LiquidInitGuard for tests and wires it to a factory.
///         Inherit this in any test that needs a poolHooks-equipped factory.
abstract contract InitGuardTestHelper {
    uint256 private _initGuardNonce;

    /// @notice Deploy LiquidInitGuard with a mined salt valid for test usage.
    ///         Uses a nonce to avoid CREATE2 collisions when deploying multiple guards
    ///         with the same poolManager and owner.
    function _deployInitGuardForTest(
        address poolManager,
        address owner
    ) internal returns (address) {
        uint256 nonce = _initGuardNonce++;
        return DeployLiquidInitGuard.deployForTest(
            IPoolManager(poolManager),
            owner,
            bytes32(0),
            nonce
        );
    }

    /// @notice Deploy init guard, set it as factory poolHooks, and wire the factory on the guard.
    function _deployAndSetInitGuard(
        address poolManager,
        address owner,
        LiquidFactory factory
    ) internal returns (address guard) {
        guard = _deployInitGuardForTest(poolManager, owner);
        factory.setPoolHooks(guard);
        LiquidInitGuard(guard).setFactory(address(factory));
    }
}
