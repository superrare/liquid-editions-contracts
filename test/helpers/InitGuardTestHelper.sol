// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @title InitGuardTestHelper
/// @notice Deploys a LiquidGuard for tests at a valid 0x20CC hook address.
///         Inherit this in any test that needs a poolHooks-equipped factory.
abstract contract InitGuardTestHelper is Test {
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG
        | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG; // 0x20CC

    uint256 private _initGuardNonce;

    function _deployInitGuardForTest(
        address poolManager,
        address owner
    ) internal returns (address) {
        uint256 nonce = _initGuardNonce++;
        address hookAddr = address(uint160(REQUIRED_HOOK_FLAGS) + uint160(nonce * 0x4000));
        address rareToken = makeAddr("rareToken");
        deployCodeTo(
            "LiquidGuard.sol:LiquidGuard",
            abi.encode(IPoolManager(poolManager), owner, rareToken),
            hookAddr
        );
        return hookAddr;
    }

    function _deployAndSetInitGuard(
        address poolManager,
        address owner,
        LiquidFactory factory
    ) internal returns (address guard) {
        guard = _deployInitGuardForTest(poolManager, owner);
        factory.setPoolHooks(guard);
        LiquidGuard(guard).setFactory(address(factory));
    }
}
