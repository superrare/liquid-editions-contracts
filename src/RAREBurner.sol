// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath as V4TickMath} from "v4-core/libraries/TickMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IRAREBurner} from "./interfaces/IRAREBurner.sol";

import {IV4Quoter} from "@uniswap/v4-periphery/interfaces/IV4Quoter.sol";
import {QuoterRevert} from "@uniswap/v4-periphery/libraries/QuoterRevert.sol";

/// @title RAREBurner
/// @notice Non-reverting ETH accumulator that performs best-effort RARE token burns via Uniswap V4
/// @dev This contract acts as a buffer between Liquid token trading fees and RARE burns.
///      Key features:
///      - **Non-reverting**: User transactions never fail due to burn issues
///      - **Accumulation**: Buffers ETH when burns fail (slippage, liquidity, pool issues)
///      - **Permissionless flush**: Anyone can trigger burn attempts of accumulated ETH
///      - **Maximum price impact**: Uses all pending ETH per burn attempt for maximum positive price pressure
///      - **Circuit breaker**: Owner can pause and sweep funds if burning becomes problematic
///      - **Self-contained configuration**: All burn parameters stored locally (no external config reads)
///
///      Flow:
///      1. Send ETH via depositForBurn() (synchronous, always succeeds)
///      2. ETH accumulates in pendingEth (buffered)
///      3. Burn is attempted separately via flush() (asynchronous, can fail without affecting trades)
///      4. If burn succeeds: pendingEth decrements, RARE is burned
///      5. If burn fails: pendingEth stays for next attempt
///
///      CRITICAL GUARANTEE: interactions should NEVER revert due to V4 pool or slippage issues.
///      The two-phase design (deposit sync, burn async) ensures graceful degradation when:
///      - V4 pool is not initialized or misconfigured
///      - Liquidity is insufficient for swap
///      - Slippage exceeds tolerance
///      - Contract is paused for maintenance
///
///      This design ensures user trades always succeed while maximizing RARE burn efficiency.
contract RAREBurner is IRAREBurner, IUnlockCallback, ReentrancyGuard, Ownable {
    using QuoterRevert for bytes;

    // ============================================
    // CONSTANTS (Failure reason codes for BurnFailed event)
    // ============================================

    /// @notice Failure reason: V4 swap execution failed
    uint8 public constant FAIL_SWAP = 0;

    /// @notice Failure reason: Quoter returned zero or failed
    uint8 public constant FAIL_QUOTE = 1;

    /// @notice Failure reason: Pool configuration mismatch
    uint8 public constant FAIL_CONFIG = 2;

    // ============================================
    // CONFIGURATION & STORAGE
    // ============================================

    // Pool & Routing Parameters (immutable after deployment - set in constructor)
    /// @notice RARE token address
    address public immutable rareToken;

    /// @notice Uniswap V4 PoolManager
    address public immutable v4PoolManager;

    /// @notice Pool hooks contract (or address(0))
    address public immutable v4Hooks;

    /// @notice Optional quoter for slippage protection (or address(0))
    address public immutable v4Quoter;

    /// @notice Precomputed pool ID (correctness guard)
    bytes32 public immutable v4PoolId;

    /// @notice Pool fee tier (e.g. 3000 for 0.3%)
    uint24 public immutable v4PoolFee;

    /// @notice Pool tick spacing (e.g. 60)
    int24 public immutable v4TickSpacing;

    /// @notice True if native ETH is currency0 vs rareToken (cached computation)
    bool public immutable ethIs0;

    /// @notice Destination for burned RARE tokens
    address public burnAddress;

    // Runtime Controls (updatable via individual setters)
    /// @notice Max slippage (0-1000 BPS, max 10%)
    uint16 public maxSlippageBPS;

    /// @notice Global burn enable/disable
    bool public enabled;

    /// @notice Whether to auto-try burn on deposit vs manual flush
    bool public tryOnDeposit;

    /// @notice One-shot unlock guard for V4 callback protection
    /// @dev Set before unlock(), verified in unlockCallback(), then cleared.
    ///      Prevents reentrancy and unauthorized unlock calls.
    bytes32 private _v4BurnCtx;

    /// @notice Amount of ETH pending burn attempts
    /// @dev Increments on deposits, decrements on successful burns.
    ///      May exceed address(this).balance if someone force-sends ETH via selfdestruct.
    uint256 public pendingEth;

    /// @notice Whether the contract is paused
    /// @dev When paused, deposits and flushes revert. Owner can sweep funds.
    ///      Use as circuit breaker if burns become problematic.
    bool public paused;

    // ============================================
    // ERRORS (internal implementation only - public errors in IRAREBurner)
    // ============================================

    /// @notice Thrown when caller is not the V4 PoolManager
    error OnlyPoolManager();

    /// @notice Thrown when unlock callback is called unexpectedly
    error UnexpectedUnlock();

    /// @notice Thrown when swap returns unexpected delta signs
    error UnexpectedSwapDirection();

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Creates a new RAREBurner with full configuration
    /// @dev Deploys RAREBurner with all parameters set. Full configuration is required on deployment.
    ///      Pool parameters (rareToken, v4PoolManager, fee, tickSpacing, hooks) are immutable after deployment.
    /// @param _owner Owner address for access control (typically protocol multisig)
    /// @param _tryOnDeposit Whether to auto-try burn on deposit (true) or require manual flush (false)
    /// @param _rareToken The address of the RARE token to burn (must not be address(0))
    /// @param _v4PoolManager The Uniswap V4 PoolManager contract address (must not be address(0))
    /// @param _fee Pool fee tier (e.g. 3000 for 0.3%)
    /// @param _tickSpacing Pool tick spacing (e.g. 60)
    /// @param _hooks Pool hooks contract address (or address(0))
    /// @param _burnAddress Destination for burned RARE (must not be address(0))
    /// @param _v4Quoter Optional Quoter address for slippage protection (required if maxSlippageBPS > 0)
    /// @param _maxSlippageBPS Maximum slippage in basis points (0-1000, max 10%)
    /// @param _enabled Whether burning is enabled
    constructor(
        address _owner,
        bool _tryOnDeposit,
        address _rareToken,
        address _v4PoolManager,
        uint24 _fee,
        int24 _tickSpacing,
        address _hooks,
        address _burnAddress,
        address _v4Quoter,
        uint16 _maxSlippageBPS,
        bool _enabled
    ) Ownable(_owner) {
        // Validate critical parameters - full configuration required
        if (_rareToken == address(0)) revert IRAREBurner.AddressZero();
        if (_v4PoolManager == address(0)) revert IRAREBurner.AddressZero();
        if (_maxSlippageBPS > 1000)
            revert IRAREBurner.SlippageTooHigh(_maxSlippageBPS, 1000);
        if (_burnAddress == address(0)) revert IRAREBurner.AddressZero();
        if (_maxSlippageBPS > 0 && _v4Quoter == address(0))
            revert IRAREBurner.AddressZero();

        // Store all configuration parameters
        rareToken = _rareToken;
        v4PoolManager = _v4PoolManager;
        v4Hooks = _hooks;
        v4Quoter = _v4Quoter;
        burnAddress = _burnAddress;
        v4PoolFee = _fee;
        v4TickSpacing = _tickSpacing;
        maxSlippageBPS = _maxSlippageBPS;
        enabled = _enabled;
        tryOnDeposit = _tryOnDeposit;

        // Compute and cache currency ordering
        ethIs0 = uint160(address(0)) < uint160(_rareToken);

        // Build PoolKey and compute PoolId
        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(_rareToken);
        PoolKey memory key = PoolKey({
            currency0: ethIs0 ? ethC : rareC,
            currency1: ethIs0 ? rareC : ethC,
            fee: _fee,
            tickSpacing: _tickSpacing,
            hooks: IHooks(_hooks)
        });
        v4PoolId = PoolId.unwrap(PoolIdLibrary.toId(key));

        // Emit configuration event
        emit ConfigUpdated(_enabled, _maxSlippageBPS);
    }

    // ============================================
    // CONFIGURATION FUNCTIONS (OWNER ONLY)
    // ============================================

    /// @notice Toggles RARE burning on/off (owner only)
    /// @dev Quick kill switch that preserves all configuration
    /// @param _enabled Whether RARE burning should be enabled
    function toggleBurnEnabled(bool _enabled) external onlyOwner {
        enabled = _enabled;
        emit ConfigUpdated(_enabled, maxSlippageBPS);
    }

    /// @notice Updates maximum slippage tolerance (owner only)
    /// @param bps Maximum slippage in basis points (0-1000)
    function setMaxSlippageBPS(uint16 bps) external onlyOwner {
        if (bps > 1000) revert IRAREBurner.SlippageTooHigh(bps, 1000);
        maxSlippageBPS = bps;
        emit ConfigUpdated(enabled, bps);
    }

    /// @notice Updates auto-try on deposit setting (owner only)
    /// @param on Whether to auto-try burn on deposit
    function setTryOnDeposit(bool on) external onlyOwner {
        tryOnDeposit = on;
    }

    /// @notice Updates burn address (owner only)
    /// @param _burnAddress New burn address
    function setBurnAddress(address _burnAddress) external onlyOwner {
        if (_burnAddress == address(0)) revert IRAREBurner.AddressZero();
        burnAddress = _burnAddress;
    }

    /// @notice Pauses or unpauses the contract (owner only)
    /// @dev When paused: deposits and flushes revert, sweep still works
    /// @param _paused New pause status
    function pause(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /// @notice Sweeps ETH to specified address (owner only)
    /// @dev Used for governance control or when burn is permanently disabled
    /// @param to Recipient address
    /// @param amount Amount to sweep (0 = all pendingEth)
    function sweep(address to, uint256 amount) external onlyOwner {
        uint256 toSweep = amount == 0 ? pendingEth : amount;
        if (toSweep > pendingEth)
            revert IRAREBurner.InsufficientPendingEth(toSweep, pendingEth);

        if (address(this).balance < toSweep) {
            revert InsufficientBalance();
        }

        pendingEth -= toSweep;
        // Note: No event emitted for sweep - admin action, state change is on-chain

        (bool success, ) = to.call{value: toSweep}("");
        if (!success) revert IRAREBurner.EthTransferFailed();
    }

    /// @notice Sweeps excess ETH (beyond pendingEth) to specified address (owner only)
    /// @dev Recovers ETH received via selfdestruct or forced sends that bypassed pendingEth accounting.
    ///      Only sends `address(this).balance - pendingEth`, ensuring pendingEth tracking remains intact.
    /// @param to Recipient address
    function sweepExcess(address to) external onlyOwner {
        uint256 excess = address(this).balance > pendingEth
            ? address(this).balance - pendingEth
            : 0;

        if (excess == 0) revert IRAREBurner.NoExcessEth();

        (bool success, ) = to.call{value: excess}("");
        if (!success) revert IRAREBurner.EthTransferFailed();
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Checks if RARE burning is currently active
    /// @dev Returns true only if all required parameters are configured and enabled is true
    /// @return True if burning is active and properly configured
    function isRAREBurnActive() public view returns (bool) {
        return
            enabled &&
            rareToken != address(0) &&
            v4PoolManager != address(0) &&
            v4PoolId != bytes32(0);
    }

    /// @notice Validates that stored pool parameters recompute to stored PoolId
    /// @dev Used to detect misconfigurations that would cause silent burn failures
    /// @return ok True if PoolId matches recomputed value
    function validatePoolConfig() external view returns (bool ok) {
        if (v4PoolId == bytes32(0) || rareToken == address(0)) return false;

        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(rareToken);
        PoolKey memory key = PoolKey({
            currency0: ethIs0 ? ethC : rareC,
            currency1: ethIs0 ? rareC : ethC,
            fee: v4PoolFee,
            tickSpacing: v4TickSpacing,
            hooks: IHooks(v4Hooks)
        });
        return PoolId.unwrap(PoolIdLibrary.toId(key)) == v4PoolId;
    }

    // ============================================
    // EXTERNAL API
    // ============================================

    /// @notice Deposits ETH for burning RARE tokens
    /// @dev Non-reverting: buffers ETH if swap fails, optionally tries burn on deposit.
    ///      This is the main entry point for Liquid tokens to send burn fees.
    ///      Reverts only if paused; never reverts due to burn failures.
    function depositForBurn() external payable nonReentrant {
        if (paused) revert BurnerPaused();

        pendingEth += msg.value;
        emit Deposited(msg.sender, msg.value, pendingEth);

        // Optionally attempt immediate burn (reads from local storage only)
        if (tryOnDeposit) {
            _tryFlush();
        }
    }

    /// @notice Permissionless flush to attempt burning accumulated ETH
    /// @dev Best-effort: does not revert if burn fails, keeps funds pending for next attempt
    function flush() external nonReentrant {
        if (paused) revert BurnerPaused();
        _tryFlush();
    }

    /// @notice Receives ETH without triggering burn (inert)
    /// @dev Accepts ETH but only increments pendingEth when NOT paused.
    ///      When paused, ETH is still accepted (forced sends can't be stopped) but not tracked,
    ///      preventing grief by inflating pendingEth during maintenance.
    receive() external payable {
        if (!paused) {
            pendingEth += msg.value;
            emit Deposited(msg.sender, msg.value, pendingEth);
        }
        // When paused: silently accept ETH without updating pendingEth
        // This prevents grief but allows forced sends (selfdestruct, coinbase) to succeed
    }

    // ============================================
    // INTERNAL BURN LOGIC
    // ============================================

    /// @notice Attempts to flush pending ETH for RARE burns (best-effort, non-reverting)
    /// @dev Core burn orchestration logic. Reads all config from local storage (no external calls).
    ///      Process:
    ///      1. Early return if nothing to burn or not enabled
    ///      2. Calculate ETH amount to use (all pending ETH, respecting actual balance)
    ///      3. Build Uniswap V4 PoolKey from settings
    ///      4. Verify PoolId matches (prevents wrong pool swaps)
    ///      5. Get quote and calculate minOut (if slippage protection enabled)
    ///      6. Attempt swap via _executeV4Swap (wrapped in try/catch)
    ///      7. If successful: decrement pendingEth
    ///      8. If failed: keep pendingEth for retry
    function _tryFlush() internal {
        // Early return if nothing to burn or not enabled
        if (pendingEth == 0 || !enabled) {
            return;
        }

        // Use all pending ETH for maximum price impact
        uint256 ethToUse = pendingEth;

        // Guard against forced ETH: never spend more than actual balance
        if (ethToUse > address(this).balance) {
            ethToUse = address(this).balance;
        }

        // Build Uniswap V4 PoolKey from local settings (no external reads)
        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(rareToken);
        PoolKey memory key = PoolKey({
            currency0: ethIs0 ? ethC : rareC,
            currency1: ethIs0 ? rareC : ethC,
            fee: v4PoolFee,
            tickSpacing: v4TickSpacing,
            hooks: IHooks(v4Hooks)
        });

        // Verify PoolId matches config (critical security check)
        bytes32 computedId = PoolId.unwrap(PoolIdLibrary.toId(key));
        if (computedId != v4PoolId) {
            // Pool config mismatch - do not attempt burn, keep funds pending
            emit BurnFailed(ethToUse, FAIL_CONFIG);
            return;
        }

        // Compute directional price limit (V4 requires non-zero)
        uint160 priceLimit = ethIs0
            ? V4TickMath.MIN_SQRT_PRICE + 1
            : V4TickMath.MAX_SQRT_PRICE - 1;

        // Calculate minOut using quoter if slippage protection is enabled
        uint256 minOut = 0;
        if (maxSlippageBPS > 0 && v4Quoter != address(0)) {
            // Build params for V4 Quoter
            IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter
                .QuoteExactSingleParams({
                    poolKey: key,
                    zeroForOne: ethIs0,
                    exactAmount: _toUint128Safe(ethToUse),
                    hookData: ""
                });

            // V4 Quoter uses revert-to-simulate pattern
            try IV4Quoter(v4Quoter).quoteExactInputSingle(params) returns (
                uint256 _amountOut,
                uint256
            ) {
                if (_amountOut > 0) {
                    minOut = (_amountOut * (10_000 - maxSlippageBPS)) / 10_000;
                } else {
                    // Zero quote means no liquidity - don't attempt swap
                    emit BurnFailed(ethToUse, FAIL_QUOTE);
                    return;
                }
            } catch (bytes memory reason) {
                // Try to parse the quote from revert reason
                try this._parseQuoteAmount(reason) returns (uint256 quote) {
                    if (quote > 0) {
                        minOut = (quote * (10_000 - maxSlippageBPS)) / 10_000;
                    }
                } catch {
                    // Quoter failure - emit event and return (don't attempt burn without quote)
                    emit BurnFailed(ethToUse, FAIL_QUOTE);
                    return;
                }
            }
        }

        // Attempt the swap via unlock callback mechanism
        try
            this._executeV4Swap(
                ethToUse,
                v4PoolManager,
                key,
                priceLimit,
                minOut,
                rareC,
                burnAddress
            )
        {
            // Success - decrement pending ETH (no separate event needed, Burned event is sufficient)
            pendingEth -= ethToUse;
        } catch {
            // Swap failed - emit event but keep funds pending
            emit BurnFailed(ethToUse, FAIL_SWAP);
        }
    }

    /// @notice Executes V4 swap via unlock callback mechanism
    /// @dev External to enable try/catch in _tryFlush. Must be called by self.
    /// @param ethAmount Amount of ETH to swap
    /// @param _v4PoolManager V4 PoolManager address
    /// @param key Pool key for the swap
    /// @param priceLimit Price limit for the swap
    /// @param minOut Minimum RARE output (slippage protection)
    /// @param rareC RARE currency
    /// @param _burnAddress Address to send burned RARE
    function _executeV4Swap(
        uint256 ethAmount,
        address _v4PoolManager,
        PoolKey memory key,
        uint160 priceLimit,
        uint256 minOut,
        Currency rareC,
        address _burnAddress
    ) external {
        if (msg.sender != address(this)) revert IRAREBurner.OnlySelf();

        bytes memory data = abi.encode(
            ethAmount,
            key,
            priceLimit,
            minOut,
            rareC,
            _burnAddress
        );

        _v4BurnCtx = keccak256(data);
        IPoolManager(_v4PoolManager).unlock(data);

        if (_v4BurnCtx != bytes32(0)) revert UnexpectedUnlock();
    }

    // ============================================
    // V4 UNLOCK CALLBACK
    // ============================================

    /// @notice Implementation of IUnlockCallback for V4 RARE burn swaps
    /// @dev Called by Uniswap V4 PoolManager during unlock(). Executes ETH->RARE swap and burns RARE.
    ///      Protected by one-shot context guard. Reads v4PoolManager from local storage.
    /// @param data Encoded swap data (ethAmount, key, priceLimit, minOut, rareC, burnAddress)
    /// @return Empty bytes (required by IUnlockCallback interface)
    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        // Decode swap parameters
        (
            uint256 ethAmount,
            PoolKey memory key,
            uint160 priceLimit,
            uint256 minOut,
            Currency rareC,
            address burnAddr
        ) = abi.decode(
                data,
                (uint256, PoolKey, uint160, uint256, Currency, address)
            );

        // Verify caller is configured PoolManager (read from local storage, no external call)
        if (msg.sender != v4PoolManager) revert OnlyPoolManager();

        // One-shot context guard
        if (_v4BurnCtx == bytes32(0) || _v4BurnCtx != keccak256(data))
            revert UnexpectedUnlock();
        _v4BurnCtx = bytes32(0);

        // Determine swap direction
        bool _ethIs0 = Currency.unwrap(key.currency0) == address(0);

        // Prepare swap parameters
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: _ethIs0,
            amountSpecified: -SafeCast.toInt256(ethAmount),
            sqrtPriceLimitX96: priceLimit
        });

        // Execute swap
        BalanceDelta delta = IPoolManager(v4PoolManager).swap(key, params, "");

        // Find amounts
        int128 ethDelta = _ethIs0 ? delta.amount0() : delta.amount1();
        int128 rareDelta = _ethIs0 ? delta.amount1() : delta.amount0();

        // Validate expected signs: ETH should be negative (paid), RARE should be positive (received)
        if (ethDelta >= 0 || rareDelta <= 0) revert UnexpectedSwapDirection();

        // Cast amounts
        uint256 ethToPay = uint256(uint128(-ethDelta));
        uint256 rareOut = uint256(uint128(rareDelta));

        // Verify slippage protection
        if (minOut > 0 && rareOut < minOut) revert SlippageExceeded();

        // Settle ETH input
        IPoolManager(v4PoolManager).settle{value: ethToPay}();

        // Take RARE output
        IPoolManager(v4PoolManager).take(rareC, address(this), rareOut);

        // Transfer RARE to burn address
        SafeERC20.safeTransfer(
            IERC20(Currency.unwrap(rareC)),
            burnAddr,
            rareOut
        );

        // Emit consolidated burn event
        emit Burned(ethAmount, rareOut);

        return "";
    }

    /// @dev Safe cast from uint256 to uint128 with overflow check
    /// @param value The uint256 value to cast
    /// @return The value as uint128
    function _toUint128Safe(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max)
            revert IRAREBurner.AmountExceedsUint128(value);
        // Casting to uint128 is safe because we checked bounds above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    /// @notice Helper function to parse quote amount from revert reason
    /// @dev External function to enable try-catch in _tryFlush
    function _parseQuoteAmount(
        bytes memory reason
    ) external pure returns (uint256) {
        return reason.parseQuoteAmount();
    }
}
