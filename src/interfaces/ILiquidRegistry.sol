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

    function beneficiaryOf(address token) external view returns (address);

    function isRegistered(address token) external view returns (bool);

    function setBeneficiary(address token, address beneficiary) external;

    function removeBeneficiary(address token) external;

    function setWriter(address writer, bool enabled) external;

    function isWriter(address writer) external view returns (bool);
}
