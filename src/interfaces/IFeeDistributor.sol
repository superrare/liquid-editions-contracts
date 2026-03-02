// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {PoolKey} from "v4-core/types/PoolKey.sol";

interface IFeeDistributor {
    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when total fee exceeds allowed bounds (legacy, kept for backward compat)
    error InvalidTotalFee();

    /// @notice Thrown when beneficiaryShareBPS is out of range
    error InvalidBeneficiaryShare();

    /// @notice Thrown when the caller is not an approved hook
    error UnauthorizedHook(address caller);

    /// @notice Thrown when pool key currencies do not consist of {RARE_TOKEN, address(0)}
    error InvalidPoolKeyCurrencies();

    /// @notice Thrown when maxSlippageBps is out of range
    error InvalidSlippageBps();

    /// @notice Thrown when the distributed value is invalid (legacy)
    error InvalidValue();

    /// @notice Thrown when the beneficiary registry address is zero
    error AddressZero();

    /// @notice Thrown when the beneficiary registry address is not a contract
    error NotContract();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when fees are collected, converted to ETH, and distributed
    /// @param liquidToken The liquid token whose pool generated the fee
    /// @param beneficiary The beneficiary address for this liquid token
    /// @param rareIn Amount of RARE converted
    /// @param ethOut Total ETH received from the RARE→ETH swap
    /// @param ethBeneficiary ETH sent to the beneficiary
    /// @param ethProtocol ETH sent to the protocol fee recipient
    event FeeConvertedAndDistributed(
        address indexed liquidToken,
        address indexed beneficiary,
        uint256 rareIn,
        uint256 ethOut,
        uint256 ethBeneficiary,
        uint256 ethProtocol
    );

    /// @notice Emitted when conversion is skipped and RARE is distributed directly.
    /// @param liquidToken The liquid token whose pool generated the fee
    /// @param beneficiary The beneficiary address for this liquid token
    /// @param rareTotal Total RARE distributed
    /// @param rareBeneficiary RARE sent to beneficiary
    /// @param rareProtocol RARE sent to protocol fee recipient
    /// @param reason Short reason code: "STALE_PRICE", "CONVERT_FAIL", "NO_KEY"
    event FeeDistributedInRare(
        address indexed liquidToken,
        address indexed beneficiary,
        uint256 rareTotal,
        uint256 rareBeneficiary,
        uint256 rareProtocol,
        bytes32 reason
    );

    /// @notice Emitted when conversion is killed/re-enabled
    event ConversionEnabledUpdated(bool enabled);

    /// @notice Emitted when a fee transfer to a recipient fails (legacy)
    event FeeTransferFailed(address indexed to, uint256 amount, string reason);

    /// @notice Emitted when the RARE/ETH pool key is updated
    event RareEthPoolKeyUpdated(PoolKey oldKey, PoolKey newKey);

    /// @notice Emitted when the beneficiary share BPS is updated
    event BeneficiaryShareBpsUpdated(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when the beneficiary registry is updated
    event BeneficiaryRegistryUpdated(
        address indexed oldRegistry,
        address indexed newRegistry
    );

    /// @notice Emitted when an approved hook is added or removed
    event HookApprovalUpdated(address indexed hook, bool approved);

    /// @notice Emitted when maxSlippageBps is updated
    event MaxSlippageBpsUpdated(uint16 oldBps, uint16 newBps);

    // ============================================
    // FEE CONFIGURATION
    // ============================================

    /// @notice Returns the total fee in basis points (e.g. 400 = 4%).
    /// @dev Immutable — set at construction. Changing requires deploying a new FeeDistributor
    ///      and calling LiquidGuard.setFeeDistributor() to re-sync the cached value.
    function totalFeeBPS() external view returns (uint16);

    // ============================================
    // LEGACY / AUCTION-COMPATIBILITY FUNCTIONS
    // ============================================
    // These selectors are preserved for interface compatibility with legacy auctioneer callers.

    /// @notice Legacy protocol recipient accessor preserved for compatibility.
    function protocolFeeRecipient() external view returns (address);

    /// @notice Legacy quote helper preserved for compatibility only.
    /// @dev Returns zero values; split behavior is resolved by `notifyFee`.
    function quoteFeeBreakdown(
        uint256 grossFee
    ) external view returns (uint256 beneficiaryFee, uint256 protocolFee);

    /// @notice Legacy distribution entrypoint preserved for compatibility.
    /// @dev No-op on this V4-native distributor; fee distribution for routed trades happens via
    ///      `notifyFee()` and conversion fallback logic.
    function distributeFees(
        uint256 grossFee,
        address beneficiaryA,
        address beneficiaryB
    )
        external
        payable
        returns (
            uint256 protocolFee,
            uint256 beneficiaryFeeA,
            uint256 beneficiaryFeeB
        );

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Returns the POOL_MANAGER address
    function POOL_MANAGER() external view returns (address);

    /// @notice Returns the RARE token address
    function RARE_TOKEN() external view returns (address);

    /// @notice Returns the protocol fee recipient address
    function PROTOCOL_FEE_RECIPIENT() external view returns (address);

    /// @notice Returns the beneficiary share in BPS (e.g. 5000 = 50%)
    function beneficiaryShareBPS() external view returns (uint16);

    /// @notice Returns the beneficiary registry address
    function beneficiaryRegistry() external view returns (address);

    /// @notice Returns whether an address is an approved hook
    function approvedHooks(address hook) external view returns (bool);

    /// @notice Returns the maximum acceptable slippage on RARE→ETH conversion in BPS
    function maxSlippageBps() external view returns (uint16);

    /// @notice Returns whether ETH conversion is enabled (kill-switch)
    function conversionEnabled() external view returns (bool);

    // ============================================
    // MUTABILITY
    // ============================================

    /// @notice Sets the RARE/ETH V4 pool key used for the inline RARE→ETH conversion swap
    /// @dev Currencies must be exactly {address(0), RARE_TOKEN} (native ETH + RARE)
    function setRareEthPoolKey(PoolKey calldata _rareEthPoolKey) external;

    /// @notice Sets the beneficiary share in basis points
    function setBeneficiaryShareBPS(uint16 _beneficiaryShareBPS) external;

    /// @notice Sets the beneficiary registry address
    function setBeneficiaryRegistry(address _beneficiaryRegistry) external;

    /// @notice Approves or revokes a hook address
    function setHookApproval(address hook, bool approved) external;

    /// @notice Sets the maximum slippage allowed on RARE→ETH conversion in BPS
    function setMaxSlippageBps(uint16 _maxSlippageBps) external;

    /// @notice Enable or disable ETH conversion (emergency kill-switch)
    function setConversionEnabled(bool _enabled) external;

    // ============================================
    // DISTRIBUTION
    // ============================================

    /// @notice Called by an approved hook after taking RARE fees from PoolManager.
    ///         If conversion is enabled: converts RARE→ETH via V4 inline and distributes ETH.
    ///         If conversion is off or fails: distributes RARE directly.
    /// @dev Must be called within a PoolManager unlock context (hook callback).
    ///      MUST NOT REVERT except on unauthorized caller.
    /// @param liquidToken The liquid token in the pool that generated the fee
    /// @param rareAmount Amount of RARE to distribute (already taken from PM via hook's take() call)
    function notifyFee(address liquidToken, uint256 rareAmount) external;
}
