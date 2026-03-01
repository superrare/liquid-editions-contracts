// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface ILiquidRegistry {
    error ZeroAddress();
    error UnauthorizedWriter();

    /// @notice Emitted when a beneficiary is set for a token
    event BeneficiarySet(
        address indexed token,
        address indexed beneficiary,
        address indexed actor
    );

    /// @notice Emitted when a token beneficiary mapping is removed
    event BeneficiaryRemoved(address indexed token, address indexed actor);

    /// @notice Emitted when a writer is enabled or disabled
    event WriterUpdated(address indexed writer, bool enabled);

    /// @notice Return the beneficiary currently mapped to `token`.
    /// @dev The zero address means no active beneficiary registration.
    function beneficiaryOf(address token) external view returns (address);

    /// @notice Returns whether `token` is registered and has an active beneficiary.
    /// @dev Unregistered tokens are blocked from router and auctioneer operations.
    function isRegistered(address token) external view returns (bool);

    /// @notice Set or update token→beneficiary mapping.
    /// @dev A non-zero beneficiary makes the token eligible for router and auctioneer trading flows.
    function setBeneficiary(address token, address beneficiary) external;

    /// @notice Remove token→beneficiary mapping (deregisters token).
    /// @dev After removal, router and auctioneer block the token from trade operations.
    ///      Beneficiary lookup reverts to zero until re-added.
    function removeBeneficiary(address token) external;

    /// @notice Enable or disable a writer that can set/remove beneficiaries.
    /// @dev Writers are used for automated registry writes during factory and protocol-driven flows.
    ///      Only owners may grant writer privileges.
    function setWriter(address writer, bool enabled) external;

    /// @notice Returns whether an address is authorized as a registry writer.
    /// @return True when writes to token beneficiary mappings are allowed.
    function isWriter(address writer) external view returns (bool);
}
