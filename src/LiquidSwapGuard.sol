// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IMsgSender} from "v4-periphery/interfaces/IMsgSender.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LiquidSwapGuard
/// @notice Uniswap V4 hook that restricts swaps to only those originating from whitelisted callers (e.g. LiquidRouter).
/// @dev Uses the IMsgSender trusted-router pattern: the sender (e.g. UniversalRouter) must implement msgSender()
///      and return a whitelisted caller address (e.g. LiquidRouter). Deploy via CREATE2 with a mined salt so the
///      hook address has BEFORE_SWAP_FLAG (bit 7) set in its lowest 14 bits.
contract LiquidSwapGuard is IHooks, Ownable {
    using Hooks for IHooks;

    /// @notice Thrown when the swap router is not in the verified routers list
    error UnverifiedRouter(address router);

    /// @notice Thrown when the caller returned by msgSender() is not in the allowed callers list
    error UnauthorizedCaller(address caller);

    /// @notice Thrown when the router does not implement IMsgSender.msgSender()
    error RouterDoesNotImplementMsgSender(address router);

    /// @notice Thrown when the caller is not the PoolManager
    error NotPoolManager();

    // forge-lint: disable-next-line(screaming-snake-case-immutable) -- matches v4 BaseHook/ImmutableState convention
    IPoolManager public immutable poolManager;
    mapping(address => bool) public verifiedRouters;
    mapping(address => bool) public allowedCallers;

    modifier onlyPoolManager() {
        _onlyPoolManager();
        _;
    }

    /// @notice Ensures caller is the configured PoolManager
    /// @dev Reverts with NotPoolManager if msg.sender is not the pool manager
    function _onlyPoolManager() internal view {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    /// @notice Creates a LiquidSwapGuard hook for the given PoolManager
    /// @param _poolManager The Uniswap V4 PoolManager
    /// @param _owner The owner (for add/remove router and caller)
    /// @param _skipValidation If true, skip hook address validation (for testing only)
    constructor(
        IPoolManager _poolManager,
        address _owner,
        bool _skipValidation
    ) Ownable(_owner) {
        // Store PoolManager reference for callback verification
        poolManager = _poolManager;

        // Validate hook address has correct permissions (required for V4 hook deployment)
        // Skip in tests where hook address may not match expected bit pattern
        if (!_skipValidation) {
            IHooks(this).validateHookPermissions(
                Hooks.Permissions({
                    beforeInitialize: false,
                    afterInitialize: false,
                    beforeAddLiquidity: false,
                    afterAddLiquidity: false,
                    beforeRemoveLiquidity: false,
                    afterRemoveLiquidity: false,
                    beforeSwap: true,
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

    /// @notice V4 hook: restricts swaps to those originating from whitelisted routers and callers
    /// @dev Uses IMsgSender trusted-router pattern: sender (e.g. UniversalRouter) must implement msgSender()
    ///      and return a whitelisted caller (e.g. LiquidRouter). This prevents unauthorized direct swaps.
    /// @param sender The address initiating the swap (router contract)
    /// @return selector The beforeSwap hook selector
    /// @return delta Zero delta (no modification to swap)
    /// @return feeOverride 0 (use pool fee)
    function beforeSwap(
        address sender,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        // Reject if the router (e.g. UniversalRouter) is not in our verified list
        if (!verifiedRouters[sender]) revert UnverifiedRouter(sender);

        // Get the actual caller via IMsgSender - router must implement this to pass through msg.sender
        address caller;
        try IMsgSender(sender).msgSender() returns (address _caller) {
            caller = _caller;
        } catch {
            revert RouterDoesNotImplementMsgSender(sender);
        }

        // Reject if the underlying caller (e.g. LiquidRouter) is not whitelisted
        if (!allowedCallers[caller]) revert UnauthorizedCaller(caller);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Stub implementations - never called when only beforeSwap is permissioned
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert("not implemented");
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert("not implemented");
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert("not implemented");
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert("not implemented");
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert("not implemented");
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert("not implemented");
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, int128) {
        revert("not implemented");
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert("not implemented");
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert("not implemented");
    }

    // ============ Admin ============

    /// @notice Adds a router address to the verified routers list
    /// @dev Swaps originating from this router will pass the first check in beforeSwap
    /// @param router The router contract address (e.g. Universal Router)
    function addRouter(address router) external onlyOwner {
        verifiedRouters[router] = true;
    }

    /// @notice Removes a router from the verified routers list
    /// @param router The router address to remove
    function removeRouter(address router) external onlyOwner {
        verifiedRouters[router] = false;
    }

    /// @notice Adds a caller address to the allowed callers list
    /// @dev The caller is the address returned by router.msgSender() - typically LiquidRouter
    /// @param caller The caller address to whitelist
    function addCaller(address caller) external onlyOwner {
        allowedCallers[caller] = true;
    }

    /// @notice Removes a caller from the allowed callers list
    /// @param caller The caller address to remove
    function removeCaller(address caller) external onlyOwner {
        allowedCallers[caller] = false;
    }
}
