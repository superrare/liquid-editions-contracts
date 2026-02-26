// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IFeeDistributor {
    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when total fee exceeds allowed bounds
    error InvalidTotalFee();

    /// @notice Thrown when the distributed value is invalid for the configured payment mode
    error InvalidValue();

    /// @notice Thrown when an address argument is zero when a non-zero address is required
    error InvalidAddress();

    // ============================================
    // getters
    // ============================================

    function totalFeeBPS() external view returns (uint16);

    function protocolFeeRecipient() external view returns (address);

    function quoteFeeBreakdown(
        uint256 grossFee
    )
        external
        view
        returns (uint256 beneficiaryFee, uint256 protocolFee);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when total fee BPS is updated
    event TotalFeeUpdated(uint16 oldFee, uint16 newFee);

    /// @notice Emitted when a fee transfer to a recipient fails
    event FeeTransferFailed(
        address indexed to,
        uint256 amount,
        string reason
    );

    // ============================================
    // mutability
    // ============================================

    function setTotalFeeBPS(uint16 totalFeeBPS) external;

    // ============================================
    // distribution
    // ============================================

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
}
