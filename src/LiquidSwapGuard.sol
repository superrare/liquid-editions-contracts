// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IMsgSender} from "v4-periphery/interfaces/IMsgSender.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LiquidSwapGuard
/// @notice Uniswap V4 hook that restricts swaps and pool initialization to whitelisted callers.
/// @dev Implements two security mechanisms:
///      1. beforeInitialize: Only whitelisted initializers (Liquid token contracts) can initialize pools.
///         This prevents pool pre-initialization DoS attacks where attackers front-run token deployment
///         by initializing the pool first with a hostile price.
///      2. beforeSwap: Only whitelisted routers/callers (LiquidRouter via UniversalRouter) can swap.
///         Uses the IMsgSender trusted-router pattern.
///      Deploy via CREATE2 with a mined salt so the hook address has both BEFORE_INITIALIZE_FLAG (bit 13)
///      and BEFORE_SWAP_FLAG (bit 7) set in its lowest 14 bits (pattern: 0x2080).
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

    /// @notice Thrown when an unauthorized address attempts to initialize a pool
    /// @dev This prevents pool pre-initialization DoS attacks
    /// @param sender The address that attempted to initialize the pool
    error UnauthorizedInitializer(address sender);

    /// @notice Thrown when caller is not owner or factory
    error NotOwnerOrFactory();

    /// @notice Thrown when an invalid factory address is passed
    error InvalidFactoryAddress();

    // forge-lint: disable-next-line(screaming-snake-case-immutable) -- matches v4 BaseHook/ImmutableState convention
    IPoolManager public immutable poolManager;
    mapping(address => bool) public verifiedRouters;
    mapping(address => bool) public allowedCallers;

    /// @notice Addresses allowed to initialize pools (Liquid token contracts)
    /// @dev These are the token contracts that call pm.initialize() during their deployment
    mapping(address => bool) public allowedInitializers;

    /// @notice Factory address that can add initializers (set by owner)
    /// @dev Allows factory to whitelist token contracts during deployment
    address public factory;

    modifier onlyPoolManager() {
        _onlyPoolManager();
        _;
    }

    modifier onlyOwnerOrFactory() {
        _onlyOwnerOrFactory();
        _;
    }

    /// @notice Ensures caller is owner or factory
    /// @dev Reverts with NotOwnerOrFactory if caller is neither owner nor factory
    function _onlyOwnerOrFactory() internal view {
        if (msg.sender != owner() && msg.sender != factory) {
            revert NotOwnerOrFactory();
        }
    }

    /// @notice Ensures caller is the configured PoolManager
    /// @dev Reverts with NotPoolManager if msg.sender is not the pool manager
    function _onlyPoolManager() internal view {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    /// @notice Creates a LiquidSwapGuard hook for the given PoolManager
    /// @param _poolManager The Uniswap V4 PoolManager
    /// @param _owner The owner (for add/remove router, caller, and initializer)
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
                    beforeInitialize: true, // Protects against pool pre-initialization DoS
                    afterInitialize: false,
                    beforeAddLiquidity: false,
                    afterAddLiquidity: false,
                    beforeRemoveLiquidity: false,
                    afterRemoveLiquidity: false,
                    beforeSwap: true, // Restricts swaps to whitelisted callers
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

    /// @notice V4 hook: restricts pool initialization to whitelisted Liquid token contracts
    /// @dev Prevents pool pre-initialization DoS attacks where attackers front-run token deployment
    ///      by initializing the pool first with a hostile price. Only addresses in allowedInitializers
    ///      (the Liquid token contracts themselves) can initialize pools using this hook.
    /// @param sender The address initiating the pool initialization (should be a Liquid token contract)
    /// @return selector The beforeInitialize hook selector on success
    function beforeInitialize(
        address sender,
        PoolKey calldata,
        uint160
    ) external view override onlyPoolManager returns (bytes4) {
        // Only whitelisted Liquid token contracts can initialize pools
        // This prevents attackers from front-running pool creation with hostile prices
        if (!allowedInitializers[sender]) revert UnauthorizedInitializer(sender);

        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

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

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

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

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
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

    /// @notice Sets the factory address that can add initializers
    /// @dev Can be called by owner, or by the factory itself during initial setup (if factory is address(0))
    /// @param _factory The LiquidFactory contract address
    function setFactory(address _factory) external {
        if (_factory == address(0)) revert InvalidFactoryAddress();
        // Owner can always set factory
        if (msg.sender == owner()) {
            factory = _factory;
            return;
        }
        
        // Factory can set itself if not already set (one-time initial setup)
        if (factory == address(0) && msg.sender == _factory) {
            factory = _factory;
            return;
        }
        
        revert NotOwnerOrFactory();
    }

    /// @notice Adds an initializer address to the allowed initializers list
    /// @dev This should be called for each Liquid token contract after deployment.
    ///      The token contract must be whitelisted BEFORE it attempts to initialize its pool.
    ///      Can be called by owner or factory.
    /// @param initializer The Liquid token contract address that will initialize a pool
    function addInitializer(address initializer) external onlyOwnerOrFactory {
        allowedInitializers[initializer] = true;
    }

    /// @notice Removes an initializer from the allowed initializers list
    /// @param initializer The initializer address to remove
    function removeInitializer(address initializer) external onlyOwner {
        allowedInitializers[initializer] = false;
    }
}
