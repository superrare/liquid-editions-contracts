// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILiquidSwapGuard} from "./interfaces/ILiquidSwapGuard.sol";

/// @title LiquidInitGuard
/// @notice Lightweight Uniswap V4 hook that restricts pool initialization to whitelisted callers.
/// @dev Only implements beforeInitialize — swaps are unrestricted. Use this as the default
///      poolHooks when swap restriction (LiquidSwapGuard) is not needed.
///      Deploy via CREATE2 with a mined salt so the hook address has BEFORE_INITIALIZE_FLAG
///      (bit 13) set in its lowest 14 bits (pattern: 0x2000).
contract LiquidInitGuard is IHooks, Ownable, ILiquidSwapGuard {
    using Hooks for IHooks;

    IPoolManager public immutable POOL_MANAGER;

    /// @notice Addresses allowed to initialize pools (Liquid token contracts)
    mapping(address => bool) public allowedInitializers;

    /// @notice Factory address that can add initializers (set by owner)
    address public factory;

    modifier onlyPoolManager() {
        _onlyPoolManager();
        _;
    }

    modifier onlyOwnerOrFactory() {
        _onlyOwnerOrFactory();
        _;
    }

    /// @notice Restrict execution to calls from the Uniswap V4 PoolManager.
    /// @dev Required for all hook callback entrypoints in this lightweight init-only guard.
    function _onlyPoolManager() internal view {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
    }

    /// @notice Restrict execution to owner or factory-maintainer.
    /// @dev Used for initializer allowlist mutations that affect future pool creation.
    function _onlyOwnerOrFactory() internal view {
        if (msg.sender != owner() && msg.sender != factory) {
            revert NotOwnerOrFactory();
        }
    }

    /// @param _poolManager The Uniswap V4 PoolManager
    /// @param _owner The owner (for add/remove initializer and setFactory)
    /// @param _skipValidation If true, skip hook address validation (for testing only)
    constructor(
        IPoolManager _poolManager,
        address _owner,
        bool _skipValidation
    ) Ownable(_owner) {
        POOL_MANAGER = _poolManager;

        if (!_skipValidation) {
            IHooks(this).validateHookPermissions(
                Hooks.Permissions({
                    beforeInitialize: true,
                    afterInitialize: false,
                    beforeAddLiquidity: false,
                    afterAddLiquidity: false,
                    beforeRemoveLiquidity: false,
                    afterRemoveLiquidity: false,
                    beforeSwap: false,
                    afterSwap: false,
                    beforeDonate: false,
                    afterDonate: false,
                    beforeSwapReturnDelta: false,
                    afterSwapReturnDelta: false,
                    afterAddLiquidityReturnDelta: false,
                    afterRemoveLiquidityReturnDelta: false
                })
            );
        }
    }

    // ============ Hook callbacks ============

    /// @notice V4 hook: restricts pool initialization to whitelisted Liquid token contracts
    function beforeInitialize(
        address sender,
        PoolKey calldata,
        uint160
    ) external view override onlyPoolManager returns (bytes4) {
        if (!allowedInitializers[sender]) revert UnauthorizedInitializer(sender);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice V4 hook: afterInitialize (no-op, required by interface)
    /// @dev Returns selector only - no restrictions on post-initialization
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    /// @notice V4 hook: beforeAddLiquidity (no-op, required by interface)
    /// @dev Returns selector only - liquidity additions are unrestricted
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice V4 hook: afterAddLiquidity (no-op, required by interface)
    /// @dev Returns selector and zero delta - no modifications to liquidity add
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice V4 hook: beforeRemoveLiquidity (no-op, required by interface)
    /// @dev Returns selector only - liquidity removals are unrestricted
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice V4 hook: afterRemoveLiquidity (no-op, required by interface)
    /// @dev Returns selector and zero delta - no modifications to liquidity removal
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice V4 hook: beforeSwap (no-op, required by interface)
    /// @dev Returns selector and zero delta - swaps are unrestricted (only beforeInitialize is restricted)
    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external pure override returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice V4 hook: afterSwap (no-op, required by interface)
    /// @dev Returns selector and zero delta - no modifications to swap
    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    /// @notice V4 hook: beforeDonate (no-op, required by interface)
    /// @dev Returns selector only - donations are unrestricted
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    /// @notice V4 hook: afterDonate (no-op, required by interface)
    /// @dev Returns selector only - no post-donation actions
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // ============ Admin ============

    /// @notice Init-only guard: swap router/caller management not supported (returns false / reverts)
    function verifiedRouters(address) external pure returns (bool) {
        return false;
    }

    function allowedCallers(address) external pure returns (bool) {
        return false;
    }

    function addRouter(address) external pure {
        revert("Init-only guard: swap management not supported");
    }

    function removeRouter(address) external pure {
        revert("Init-only guard: swap management not supported");
    }

    function addCaller(address) external pure {
        revert("Init-only guard: swap management not supported");
    }

    function removeCaller(address) external pure {
        revert("Init-only guard: swap management not supported");
    }

    /// @notice Sets the factory address that can add initializers
    function setFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert InvalidFactoryAddress();
        factory = _factory;
    }

    /// @notice Adds an initializer address to the allowed initializers list
    function addInitializer(address initializer) external onlyOwnerOrFactory {
        allowedInitializers[initializer] = true;
    }

    /// @notice Removes an initializer from the allowed initializers list
    function removeInitializer(address initializer) external onlyOwner {
        allowedInitializers[initializer] = false;
    }
}
