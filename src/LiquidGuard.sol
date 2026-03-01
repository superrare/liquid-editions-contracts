// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILiquidGuard} from "./interfaces/ILiquidGuard.sol";
import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";

/// @title LiquidGuard
/// @notice Uniswap V4 hook that skims RARE fees at the pool level during every swap.
/// @dev Implements beforeSwap (when RARE is the specified currency) and afterSwap (when RARE is
///      the unspecified currency), allowing fee collection regardless of which caller initiates the swap.
///      Deploy via CREATE2 with a mined salt so the address low 14 bits = 0x20CC.
///
///      Hook flags (address bit pattern: 0x20CC):
///        Bit 13 (0x2000): BEFORE_INITIALIZE
///        Bit  7 (0x0080): BEFORE_SWAP
///        Bit  6 (0x0040): AFTER_SWAP
///        Bit  3 (0x0008): BEFORE_SWAP_RETURNS_DELTA
///        Bit  2 (0x0004): AFTER_SWAP_RETURNS_DELTA
///
///      Fee logic:
///        - Fees always charged on the RARE side of the pool
///        - If RARE is the specified currency → beforeSwap handles it (returns +fee in specified delta)
///        - If RARE is the unspecified currency → afterSwap handles it (returns +fee as int128)
///        - Non-RARE pools: pass through with zero deltas
contract LiquidGuard is IHooks, Ownable, ILiquidGuard {
    using Hooks for IHooks;

    /// @notice Emitted when fee distribution notification fails and the hook continues with swap accounting.
    event FeeNotifyFailed(address indexed distributor, address indexed liquidToken, uint256 rareAmount);

    // ============================================
    // IMMUTABLES
    // ============================================

    IPoolManager public immutable POOL_MANAGER;

    /// @inheritdoc ILiquidGuard
    address public immutable RARE_TOKEN;

    // ============================================
    // MUTABLE STATE
    // ============================================

    /// @inheritdoc ILiquidGuard
    address public feeDistributor;

    /// @inheritdoc ILiquidGuard
    uint16 public totalFeeBPS;

    /// @inheritdoc ILiquidGuard
    address public factory;

    /// @inheritdoc ILiquidGuard
    mapping(address => bool) public allowedInitializers;

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyPoolManager() {
        _onlyPoolManager();
        _;
    }

    modifier onlyOwnerOrFactory() {
        _onlyOwnerOrFactory();
        _;
    }

    /// @notice Restrict execution to calls from the V4 PoolManager contract.
    /// @dev The hook accounting assumes only authorized PoolManager callbacks can reach callback entrypoints.
    function _onlyPoolManager() internal view {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
    }

    /// @notice Restrict execution to owner or configured factory-maintainer.
    /// @dev Used by initializer allowlist management operations only.
    function _onlyOwnerOrFactory() internal view {
        if (msg.sender != owner() && msg.sender != factory) {
            revert NotOwnerOrFactory();
        }
    }

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @param _poolManager The Uniswap V4 PoolManager
    /// @param _owner The owner (for admin functions)
    /// @param _rareToken The RARE token address (fee currency)
    /// @param _skipValidation If true, skip hook address validation (for testing only)
    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _rareToken,
        bool _skipValidation
    ) Ownable(_owner) {
        require(address(_poolManager) != address(0), "LiquidGuard: zero pool manager");
        require(_rareToken != address(0), "LiquidGuard: zero RARE token");
        POOL_MANAGER = _poolManager;
        RARE_TOKEN = _rareToken;

        if (!_skipValidation) {
            IHooks(this).validateHookPermissions(
                Hooks.Permissions({
                    beforeInitialize: true,      // bit 13: restrict pool init to whitelisted callers
                    afterInitialize: false,
                    beforeAddLiquidity: false,
                    afterAddLiquidity: false,
                    beforeRemoveLiquidity: false,
                    afterRemoveLiquidity: false,
                    beforeSwap: true,            // bit 7: handle fee when RARE is specified
                    afterSwap: true,             // bit 6: handle fee when RARE is unspecified
                    beforeDonate: false,
                    afterDonate: false,
                    beforeSwapReturnDelta: true,  // bit 3: return delta from beforeSwap
                    afterSwapReturnDelta: true,   // bit 2: return delta from afterSwap
                    afterAddLiquidityReturnDelta: false,
                    afterRemoveLiquidityReturnDelta: false
                })
            );
        }
    }

    // ============================================
    // HOOK CALLBACKS
    // ============================================

    function _notifyFee(address distributor, address liquidToken, uint256 rareAmount) internal {
        try IFeeDistributor(distributor).notifyFee(liquidToken, rareAmount) {
            // Intentionally ignored — failures are handled below so swaps remain available.
        } catch {
            emit FeeNotifyFailed(distributor, liquidToken, rareAmount);
        }
    }

    /// @notice V4 hook: restricts pool initialization to whitelisted Liquid token contracts
    function beforeInitialize(
        address sender,
        PoolKey calldata,
        uint160
    ) external view override onlyPoolManager returns (bytes4) {
        if (!allowedInitializers[sender]) revert UnauthorizedInitializer(sender);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice V4 hook: afterInitialize (no-op)
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    /// @notice V4 hook: collects fee when RARE is the specified currency
    /// @dev RARE is specified when:
    ///        - zeroForOne + exactInput  → currency0 is specified
    ///        - !zeroForOne + exactOutput → currency0 is specified
    ///        - !zeroForOne + exactInput  → currency1 is specified
    ///        - zeroForOne + exactOutput → currency1 is specified
    ///      Simplified: rareIsSpecified = (rareIsToken0 == (zeroForOne == exactInput))
    ///      Returns +fee in the specified delta slot so the PM deducts it from the caller.
    ///      Then calls take() so the hook's delta nets to zero after PM applies hookDelta.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (params.amountSpecified == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool rareIsToken0 = Currency.unwrap(key.currency0) == RARE_TOKEN;
        bool rareIsToken1 = Currency.unwrap(key.currency1) == RARE_TOKEN;

        // Skip non-RARE pools entirely
        if (!rareIsToken0 && !rareIsToken1) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool exactInput = params.amountSpecified < 0;
        // rareIsSpecified = (rareIsToken0 == (zeroForOne == exactInput))
        bool rareIsSpecified = rareIsToken0 == (params.zeroForOne == exactInput);

        if (!rareIsSpecified) {
            // RARE is unspecified — afterSwap will handle the fee
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // RARE is specified: compute fee on abs(amountSpecified).
        // Guard against type(int256).min: negating it overflows in signed arithmetic (Solidity 0.8
        // would panic-revert). It is a nonsensical swap amount so treat it as a no-op.
        if (params.amountSpecified == type(int256).min) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 absAmount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        uint256 fee = (absAmount * totalFeeBPS) / 10_000;
        // Clamp fee to prevent HookDeltaExceedsSwapAmount (fee must be < absAmount)
        if (fee >= absAmount) fee = absAmount - 1;
        if (fee == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Determine which currency is liquid (the non-RARE one in the pair)
        address liquidToken = rareIsToken0
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        // Take RARE fee from PoolManager (sends to feeDistributor) and notify it.
        // If no distributor is set, skip fee collection entirely — returning a non-zero delta
        // without a corresponding take() would break PoolManager accounting.
        address dist = feeDistributor;
        if (dist == address(0)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        Currency rareCurrency = Currency.wrap(RARE_TOKEN);
        POOL_MANAGER.take(rareCurrency, dist, fee);
        _notifyFee(dist, liquidToken, fee);

        // Return +fee in specified delta slot.
        // Positive specified delta = hook is owed these tokens (hook took them via take()).
        // PM applies +fee hookDelta to hook's account after callback, netting to zero.
        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(int128(uint128(fee)), 0),
            0
        );
    }

    /// @notice V4 hook: collects fee when RARE is the unspecified currency
    /// @dev Called after the swap. The BalanceDelta contains amounts for both currencies.
    ///      For unspecified output: positive delta amount = caller receives tokens.
    ///      We return +fee as int128 to reduce caller's unspecified RARE output.
    ///      Then calls take() so the hook's delta nets to zero.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        bool rareIsToken0 = Currency.unwrap(key.currency0) == RARE_TOKEN;
        bool rareIsToken1 = Currency.unwrap(key.currency1) == RARE_TOKEN;

        // Skip non-RARE pools entirely
        if (!rareIsToken0 && !rareIsToken1) {
            return (IHooks.afterSwap.selector, 0);
        }

        bool exactInput = params.amountSpecified < 0;
        // rareIsSpecified = (rareIsToken0 == (zeroForOne == exactInput))
        bool rareIsSpecified = rareIsToken0 == (params.zeroForOne == exactInput);

        if (rareIsSpecified) {
            // RARE is specified — beforeSwap already handled the fee
            return (IHooks.afterSwap.selector, 0);
        }

        // RARE is unspecified — get the absolute RARE amount from the delta
        // delta.amount0() is for currency0, delta.amount1() for currency1
        int128 rareRawDelta = rareIsToken0 ? delta.amount0() : delta.amount1();

        // No RARE movement → nothing to fee
        if (rareRawDelta == 0) {
            return (IHooks.afterSwap.selector, 0);
        }

        // Guard against type(int128).min: negating it overflows in Solidity 0.8 checked
        // arithmetic. Treat as a no-op to avoid bricking the swap.
        if (rareRawDelta == type(int128).min) {
            return (IHooks.afterSwap.selector, 0);
        }

        // Fee applies whether RARE is unspecified output (positive delta, caller receives RARE)
        // or unspecified input (negative delta, caller pays RARE). This prevents fee bypass via
        // exact-output swaps where RARE is the unspecified input.
        uint256 rareAmount = rareRawDelta > 0
            ? uint256(uint128(rareRawDelta))
            : uint256(uint128(-rareRawDelta));
        uint256 fee = (rareAmount * totalFeeBPS) / 10_000;
        if (fee >= rareAmount) fee = rareAmount - 1;
        if (fee == 0) {
            return (IHooks.afterSwap.selector, 0);
        }

        address liquidToken = rareIsToken0
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        // Skip fee collection if no distributor — returning non-zero delta without take() breaks accounting.
        address dist = feeDistributor;
        if (dist == address(0)) {
            return (IHooks.afterSwap.selector, 0);
        }

        Currency rareCurrency = Currency.wrap(RARE_TOKEN);
        POOL_MANAGER.take(rareCurrency, dist, fee);
        _notifyFee(dist, liquidToken, fee);

        // Return +fee to reduce caller's unspecified RARE output.
        // Positive afterSwap delta = hook is owed tokens (hook took them via take()).
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    /// @notice V4 hook: beforeAddLiquidity (no-op)
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice V4 hook: afterAddLiquidity (no-op)
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

    /// @notice V4 hook: beforeRemoveLiquidity (no-op)
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice V4 hook: afterRemoveLiquidity (no-op)
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

    /// @notice V4 hook: beforeDonate (no-op)
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    /// @notice V4 hook: afterDonate (no-op)
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @inheritdoc ILiquidGuard
    function setFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert InvalidFactoryAddress();
        address old = factory;
        factory = _factory;
        emit FactoryUpdated(old, _factory);
    }

    /// @inheritdoc ILiquidGuard
    function setFeeDistributor(address _feeDistributor) external onlyOwner {
        // Allow address(0) to disable fee collection; any non-zero address must be a contract.
        if (_feeDistributor != address(0) && _feeDistributor.code.length == 0) {
            revert InvalidFeeDistributor();
        }
        address old = feeDistributor;
        uint16 oldBps = totalFeeBPS;
        feeDistributor = _feeDistributor;
        if (_feeDistributor == address(0)) {
            totalFeeBPS = 0;
        } else {
            totalFeeBPS = IFeeDistributor(_feeDistributor).totalFeeBPS();
            if (totalFeeBPS > 10_000) {
                revert FeeTooLarge(totalFeeBPS, 10_000);
            }
        }
        emit FeeDistributorUpdated(old, _feeDistributor);
        if (totalFeeBPS != oldBps) {
            emit TotalFeeBpsUpdated(oldBps, totalFeeBPS);
        }
    }

    /// @inheritdoc ILiquidGuard
    function addInitializer(address initializer) external onlyOwnerOrFactory {
        allowedInitializers[initializer] = true;
    }

    /// @inheritdoc ILiquidGuard
    function removeInitializer(address initializer) external onlyOwner {
        allowedInitializers[initializer] = false;
    }
}
