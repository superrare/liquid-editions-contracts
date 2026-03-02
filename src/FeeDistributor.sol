// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";

/// @title FeeDistributor
/// @notice Receives RARE fees from LiquidGuard.
///
///         When `notifyFee()` is called by an approved hook (inside a V4 unlock context), the
///         contract reads the RARE/ETH pool's current sqrtPriceX96 from `slot0` via StateLibrary
///         and attempts an inline RARE → ETH V4 swap.  The swap is wrapped in `try/catch` via an
///         external self-call so any revert falls back gracefully.  A minOut bound derived from
///         the live spot price and `maxSlippageBps` is enforced to cap MEV extraction.
///
///         MEV risk on the conversion leg is bounded because the fee amount is small (~4% of the
///         user's primary trade), and the user's own `minAmountOut` on the primary swap limits how
///         far an attacker can move the market.
///
///         If conversion is disabled, the pool key is not set, or the conversion swap reverts,
///         RARE is distributed directly to beneficiary and protocol without any swap.
///         The originating user swap is never reverted.
///
///         **Pool currency note:** the RARE/ETH pool uses native ETH (Currency.wrap(address(0))),
///         not WETH.  ETH output from the swap is taken via pm.take() to this contract and then
///         forwarded with low-level calls to the recipients.
///
/// @dev Called via notifyFee() from within a V4 hook callback (already inside an unlock context).
contract FeeDistributor is IFeeDistributor, Ownable {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============================================
    // IMMUTABLES
    // ============================================

    /// @inheritdoc IFeeDistributor
    address public immutable override POOL_MANAGER;

    /// @inheritdoc IFeeDistributor
    address public immutable override RARE_TOKEN;

    /// @inheritdoc IFeeDistributor
    address public immutable override PROTOCOL_FEE_RECIPIENT;

    /// @inheritdoc IFeeDistributor
    uint16 public immutable override totalFeeBPS;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @dev Gas stipend for untrusted beneficiary ETH sends — prevents meaningful reentrant
    ///      execution during v4 unlock while allowing basic receive()/fallback() logging.
    ///      See MEDIUM-01 audit finding.
    uint256 internal constant BENEFICIARY_ETH_GAS_LIMIT = 2300;

    // ============================================
    // CONVERSION STATE
    // ============================================

    /// @inheritdoc IFeeDistributor
    uint16 public override maxSlippageBps;

    /// @inheritdoc IFeeDistributor
    bool public override conversionEnabled;

    // ============================================
    // DISTRIBUTION STATE
    // ============================================

    /// @notice The Uniswap V4 pool key for the RARE/ETH conversion pool
    PoolKey public rareEthPoolKey;

    /// @inheritdoc IFeeDistributor
    uint16 public override beneficiaryShareBPS;

    /// @inheritdoc IFeeDistributor
    address public override beneficiaryRegistry;

    /// @notice Approved hook addresses that can call notifyFee()
    mapping(address => bool) public override approvedHooks;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @param _owner The owner (for admin functions)
    /// @param _poolManager The Uniswap V4 PoolManager address
    /// @param _rareToken The RARE token address
    /// @param _protocolFeeRecipient The protocol fee recipient address
    /// @param _beneficiaryShareBPS Initial beneficiary share in BPS (e.g. 5000 = 50%)
    /// @param _totalFeeBPS Fee basis points charged by LiquidGuard (e.g. 400 = 4%). Immutable — changing requires new deployment.
    /// @dev _poolManager and _rareToken may be address(0) for legacy/auctioneer-only deployments.
    ///      When zero, notifyFee() will always fall back to RARE distribution.
    constructor(
        address _owner,
        address _poolManager,
        address _rareToken,
        address _protocolFeeRecipient,
        uint16 _beneficiaryShareBPS,
        uint16 _totalFeeBPS
    ) Ownable(_owner) {
        if (_protocolFeeRecipient == address(0)) revert AddressZero();
        if (_beneficiaryShareBPS > 10_000) revert InvalidBeneficiaryShare();
        if (_totalFeeBPS > 10_000) revert InvalidTotalFee();

        // V4 addresses must either both be zero (legacy mode) or both be non-zero (full mode)
        bool anyV4Set = _poolManager != address(0) || _rareToken != address(0);
        if (anyV4Set) {
            if (_poolManager == address(0)) revert AddressZero();
            if (_rareToken == address(0)) revert AddressZero();
        }

        POOL_MANAGER = _poolManager;
        RARE_TOKEN = _rareToken;
        PROTOCOL_FEE_RECIPIENT = _protocolFeeRecipient;
        totalFeeBPS = _totalFeeBPS;
        beneficiaryShareBPS = _beneficiaryShareBPS;

        maxSlippageBps = 100;
        conversionEnabled = true;
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyHook() {
        _onlyHook();
        _;
    }

    modifier onlySelf() {
        _onlySelf();
        _;
    }

    /// @notice Restrict to internal re-entrant call path via `this._convertAndDistributeEth`.
    /// @dev This ensures `convert` is only triggered from the external callback retry path in `notifyFee()`.
    ///      External callers cannot invoke conversion directly.
    function _onlySelf() internal view {
        if (msg.sender != address(this)) revert UnauthorizedHook(msg.sender);
    }

    /// @notice Restrict to approved V4 hooks.
    /// @dev Hooks are required to call `notifyFee()` and are validated through `setHookApproval`.
    ///      Non-whitelisted hooks cannot influence fee routing.
    function _onlyHook() internal view {
        if (!approvedHooks[msg.sender]) revert UnauthorizedHook(msg.sender);
    }

    // ============================================
    // DISTRIBUTION
    // ============================================

    /// @inheritdoc IFeeDistributor
    /// @dev MUST NOT REVERT (except on unauthorized caller).
    ///      Called within a V4 unlock context from an approved hook callback.
    ///      The hook has already taken `rareAmount` RARE from the PoolManager to this address.
    function notifyFee(
        address liquidToken,
        uint256 rareAmount
    ) external override onlyHook {
        if (rareAmount == 0) return;

        // Resolve beneficiary
        address beneficiary;
        address reg = beneficiaryRegistry;
        if (reg != address(0)) {
            try ILiquidRegistry(reg).beneficiaryOf(liquidToken) returns (
                address registryBeneficiary
            ) {
                beneficiary = registryBeneficiary;
            } catch {
                // Registry lookup can fail for legacy/edge cases; continue with no beneficiary.
                beneficiary = address(0);
            }
        }

        (uint256 rareBen, uint256 rareProt) = _split(rareAmount, beneficiary);

        // Gate: only attempt conversion when V4 is configured and conversion is enabled
        bool canConvert = POOL_MANAGER != address(0) &&
            RARE_TOKEN != address(0) &&
            conversionEnabled;

        if (!canConvert) {
            _distributeRare(
                liquidToken,
                beneficiary,
                rareBen,
                rareProt,
                "CONVERSION_OFF"
            );
            return;
        }

        // Verify pool key currencies are valid before attempting conversion
        if (!_validPoolKeyCurrencies()) {
            _distributeRare(
                liquidToken,
                beneficiary,
                rareBen,
                rareProt,
                "NO_KEY"
            );
            return;
        }

        // Attempt conversion; fall back to RARE on any failure
        try
            this._convertAndDistributeEth(
                liquidToken,
                beneficiary,
                rareBen,
                rareProt
            )
        {
            // success emitted inside _convertAndDistributeEth
        } catch {
            _distributeRare(
                liquidToken,
                beneficiary,
                rareBen,
                rareProt,
                "CONVERT_FAIL"
            );
        }
    }

    /// @notice Performs the RARE→ETH V4 inline swap and distributes ETH to recipients.
    /// @dev `external` so it can be called via `try this._convertAndDistributeEth(...)`.
    ///      Protected by `onlySelf` — only callable via the try/catch in notifyFee().
    ///      Reverts if minOut is not met (caught by the caller's try/catch).
    function _convertAndDistributeEth(
        address liquidToken,
        address beneficiary,
        uint256 rareBen,
        uint256 rareProt
    ) external onlySelf {
        IPoolManager pm = IPoolManager(POOL_MANAGER);
        PoolKey memory key = rareEthPoolKey;
        uint256 rareTotal = rareBen + rareProt;

        bool rareIsToken0 = Currency.unwrap(key.currency0) == RARE_TOKEN;

        // Read current spot price from the pool's slot0
        (uint160 spotSqrtPriceX96, , , ) = pm.getSlot0(key.toId());

        uint256 minEthOut = _computeMinOut(
            rareTotal,
            rareIsToken0,
            spotSqrtPriceX96
        );

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: rareIsToken0,
            amountSpecified: -int256(rareTotal), // exact input
            // Conservative price limit — we enforce minOut explicitly after the swap
            sqrtPriceLimitX96: rareIsToken0
                ? 4295128739 + 1 // MIN_SQRT_PRICE + 1
                : 1461446703485210103287273052203988822378723970342 - 1 // MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = pm.swap(key, swapParams, "");

        // ETH output is the positive side (amount0 if !rareIsToken0, amount1 if rareIsToken0)
        int128 ethDelta = rareIsToken0 ? delta.amount1() : delta.amount0();
        if (ethDelta <= 0) revert("NO_ETH_OUT");
        uint256 ethTotal = uint256(uint128(ethDelta));

        // Enforce min-out bound to limit MEV extraction
        if (ethTotal < minEthOut) revert("SLIPPAGE_EXCEEDED");

        // Settle RARE input to PoolManager
        Currency rareCurrency = Currency.wrap(RARE_TOKEN);
        pm.sync(rareCurrency);
        IERC20(RARE_TOKEN).safeTransfer(POOL_MANAGER, rareTotal);
        pm.settle();

        // Take ETH output from PoolManager to this contract
        Currency ethCurrency = CurrencyLibrary.ADDRESS_ZERO;
        uint16 benShareBps = beneficiaryShareBPS;

        uint256 ethBen;
        uint256 ethProt;

        if (beneficiary != address(0) && benShareBps > 0) {
            ethBen = (ethTotal * benShareBps) / 10_000;
            ethProt = ethTotal - ethBen;

            // Send protocol share directly from PoolManager to trusted recipient
            pm.take(ethCurrency, PROTOCOL_FEE_RECIPIENT, ethProt);
            // Take only beneficiary share to this contract for stipend-limited push
            pm.take(ethCurrency, address(this), ethBen);

            // Intentionally stipend-limited to prevent beneficiary fallback from performing
            // meaningful reentrant work against PoolManager during v4 unlock (MEDIUM-01).
            if (!_sendEth(beneficiary, ethBen, BENEFICIARY_ETH_GAS_LIMIT)) {
                // Redirect failed beneficiary share to trusted protocol recipient
                _sendEth(PROTOCOL_FEE_RECIPIENT, ethBen, gasleft());
                ethProt += ethBen;
                ethBen = 0;
            }
        } else {
            ethProt = ethTotal;
            pm.take(ethCurrency, PROTOCOL_FEE_RECIPIENT, ethProt);
        }

        emit FeeConvertedAndDistributed(
            liquidToken,
            beneficiary,
            rareTotal,
            ethTotal,
            ethBen,
            ethProt
        );
    }

    /// @notice Distributes RARE directly to beneficiary and protocol (no conversion).
    /// @dev Used as a compatibility path when conversion is not available or fails,
    ///      including stale price, missing pool key, conversion disabled, or conversion revert.
    function _distributeRare(
        address liquidToken,
        address beneficiary,
        uint256 rareBen,
        uint256 rareProt,
        bytes32 reason
    ) internal {
        if (beneficiary != address(0) && rareBen > 0) {
            // If beneficiary transfer fails, redirect their share to protocol
            try this._transferRare(beneficiary, rareBen) {
                // success
            } catch {
                emit FeeTransferFailed(
                    beneficiary,
                    rareBen,
                    "RARE_SEND_FAILED"
                );
                rareProt += rareBen;
                rareBen = 0;
            }
        } else {
            // No beneficiary — re-route their share to protocol
            rareProt += rareBen;
            rareBen = 0;
        }
        if (rareProt > 0) {
            IERC20(RARE_TOKEN).safeTransfer(PROTOCOL_FEE_RECIPIENT, rareProt);
        }

        emit FeeDistributedInRare(
            liquidToken,
            beneficiary,
            rareBen + rareProt,
            rareBen,
            rareProt,
            reason
        );
    }

    // ============================================
    // INTERNAL HELPERS
    // ============================================

    /// @notice Splits rareAmount into beneficiary and protocol shares.
    function _split(
        uint256 rareAmount,
        address beneficiary
    ) internal view returns (uint256 rareBen, uint256 rareProt) {
        uint16 benBps = beneficiaryShareBPS;
        if (beneficiary != address(0) && benBps > 0) {
            rareBen = (rareAmount * benBps) / 10_000;
            rareProt = rareAmount - rareBen;
        } else {
            rareProt = rareAmount;
        }
    }

    /// @notice Checks that rareEthPoolKey currencies are {address(0), RARE_TOKEN} in either order.
    function _validPoolKeyCurrencies() internal view returns (bool) {
        address c0 = Currency.unwrap(rareEthPoolKey.currency0);
        address c1 = Currency.unwrap(rareEthPoolKey.currency1);
        return
            (c0 == address(0) && c1 == RARE_TOKEN) ||
            (c0 == RARE_TOKEN && c1 == address(0));
    }

    /// @notice Computes the minimum acceptable ETH output for `rareIn` using the given spot price.
    /// @dev Uses 512-bit intermediate math to avoid overflow when squaring sqrtPriceX96.
    ///      For exact-input rareIn, the expected ETH out at spot is:
    ///        expectedEth = rareIn * price         (if RARE is token0, price = ETH per RARE)
    ///        expectedEth = rareIn / price         (if RARE is token1, price = RARE per ETH)
    ///      where price = sqrtP² / 2^192, implemented as priceQ128 = sqrtP² / 2^64 then /2^128.
    ///      We then apply (1 - maxSlippageBps/10000) to get minOut.
    function _computeMinOut(
        uint256 rareIn,
        bool rareIsToken0,
        uint160 sqrtPriceX96
    ) internal view returns (uint256 minOut) {
        uint256 sqrtP = uint256(sqrtPriceX96);
        if (sqrtP == 0) return 0;

        // priceQ128 = sqrtP^2 / 2^64 = (sqrtP^2 / 2^192) * 2^128
        uint256 priceQ128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
        if (priceQ128 == 0) return 0;

        uint256 spotEth;
        if (rareIsToken0) {
            // rareIn * (priceQ128 / 2^128)
            spotEth = FullMath.mulDiv(rareIn, priceQ128, 1 << 128);
        } else {
            // rareIn / (priceQ128 / 2^128) = rareIn * 2^128 / priceQ128
            spotEth = FullMath.mulDiv(rareIn, 1 << 128, priceQ128);
        }

        uint16 slipBps = maxSlippageBps;
        minOut = FullMath.mulDiv(spotEth, 10_000 - slipBps, 10_000);
    }

    /// @notice External wrapper for RARE transfer so it can be called via try/catch.
    /// @dev Protected by onlySelf — only callable from _distributeRare's try/catch.
    function _transferRare(address to, uint256 amount) external onlySelf {
        IERC20(RARE_TOKEN).safeTransfer(to, amount);
    }

    /// @notice Sends ETH to a recipient with a caller-specified gas budget; returns false on
    ///         failure so caller can redirect funds.
    /// @dev    Callers should use BENEFICIARY_ETH_GAS_LIMIT for untrusted recipients to prevent
    ///         beneficiary fallback from performing meaningful reentrant work against PoolManager
    ///         during v4 unlock (see MEDIUM-01 audit finding).
    function _sendEth(
        address to,
        uint256 amount,
        uint256 gasLimit
    ) internal returns (bool) {
        if (amount == 0) return true;
        (bool ok, ) = to.call{value: amount, gas: gasLimit}("");
        if (!ok) {
            emit FeeTransferFailed(to, amount, "ETH_SEND_FAILED");
        }
        return ok;
    }

    // ============================================
    // LEGACY STUBS (satisfy IFeeDistributor for LiquidAuctioneer compat)
    // ============================================

    /// @notice Legacy: returns PROTOCOL_FEE_RECIPIENT
    function protocolFeeRecipient() external view override returns (address) {
        return PROTOCOL_FEE_RECIPIENT;
    }

    /// @notice Legacy: returns 0/0 (no-op)
    function quoteFeeBreakdown(
        uint256
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    /// @notice Legacy: no-op
    function distributeFees(
        uint256,
        address,
        address
    ) external payable override returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @inheritdoc IFeeDistributor
    function setRareEthPoolKey(
        PoolKey calldata _rareEthPoolKey
    ) external override onlyOwner {
        if (RARE_TOKEN != address(0)) {
            address c0 = Currency.unwrap(_rareEthPoolKey.currency0);
            address c1 = Currency.unwrap(_rareEthPoolKey.currency1);
            bool valid = (c0 == address(0) && c1 == RARE_TOKEN) ||
                (c0 == RARE_TOKEN && c1 == address(0));
            if (!valid) revert InvalidPoolKeyCurrencies();
        }
        PoolKey memory old = rareEthPoolKey;
        rareEthPoolKey = _rareEthPoolKey;
        emit RareEthPoolKeyUpdated(old, _rareEthPoolKey);
    }

    /// @inheritdoc IFeeDistributor
    function setMaxSlippageBps(
        uint16 _maxSlippageBps
    ) external override onlyOwner {
        if (_maxSlippageBps > 10_000) revert InvalidSlippageBps();
        uint16 old = maxSlippageBps;
        maxSlippageBps = _maxSlippageBps;
        emit MaxSlippageBpsUpdated(old, _maxSlippageBps);
    }

    /// @inheritdoc IFeeDistributor
    function setConversionEnabled(bool _enabled) external override onlyOwner {
        conversionEnabled = _enabled;
        emit ConversionEnabledUpdated(_enabled);
    }

    /// @inheritdoc IFeeDistributor
    function setBeneficiaryShareBPS(
        uint16 _beneficiaryShareBPS
    ) external override onlyOwner {
        if (_beneficiaryShareBPS > 10_000) revert InvalidBeneficiaryShare();
        uint16 old = beneficiaryShareBPS;
        beneficiaryShareBPS = _beneficiaryShareBPS;
        emit BeneficiaryShareBpsUpdated(old, _beneficiaryShareBPS);
    }

    /// @inheritdoc IFeeDistributor
    function setBeneficiaryRegistry(
        address _beneficiaryRegistry
    ) external override onlyOwner {
        if (_beneficiaryRegistry == address(0)) revert AddressZero();
        if (_beneficiaryRegistry.code.length == 0) revert NotContract();
        address old = beneficiaryRegistry;
        beneficiaryRegistry = _beneficiaryRegistry;
        emit BeneficiaryRegistryUpdated(old, _beneficiaryRegistry);
    }

    /// @inheritdoc IFeeDistributor
    function setHookApproval(
        address hook,
        bool approved
    ) external override onlyOwner {
        approvedHooks[hook] = approved;
        emit HookApprovalUpdated(hook, approved);
    }

    /// @notice Rescue stuck ERC20 tokens
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert AddressZero();
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Rescue stuck ETH (from failed ETH sends in _sendEth)
    function rescueETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert AddressZero();
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ETH rescue failed");
    }

    /// @notice Accept ETH returned from the V4 callback path and internal swaps.
    /// @dev ETH is intentionally retained for owner rescue or manual intervention on transfer failure.
    receive() external payable {}
}
