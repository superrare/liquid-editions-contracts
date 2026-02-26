// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBeneficiaryRegistry} from "liquid-editions/interfaces/IBeneficiaryRegistry.sol";

/// @title BeneficiaryRegistry
/// @notice Shared mapping from token to beneficiary with an explicit writer allowlist.
/// @dev This registry provides a simple token-to-beneficiary mapping with writer-based access control.
///      It is designed to be a standalone registry that can be used independently or alongside LiquidRegistry.
///
///      **Key Features:**
///      - Writer-based access control (owner can grant write permissions to specific addresses)
///      - Simple beneficiary mapping (token address → beneficiary address)
///      - No built-in registration check (unlike LiquidRegistry which has isRegistered())
///
///      **Relationship to LiquidRegistry:**
///      - BeneficiaryRegistry is a simpler, more generic registry
///      - LiquidRegistry extends this concept with token registration requirements (isRegistered())
///      - Both registries can coexist - use BeneficiaryRegistry when you need simple beneficiary mapping
///        without registration requirements, use LiquidRegistry when you need registration gating
///
///      **Usage:**
///      - Can be used as a standalone beneficiary registry
///      - Can be used alongside LiquidRegistry for different purposes
///      - Factory or other contracts can be granted writer permissions to register tokens
contract BeneficiaryRegistry is IBeneficiaryRegistry, Ownable {
    mapping(address => address) private beneficiaries;
    mapping(address => bool) public isWriter;

    constructor(address _owner) Ownable(_owner) {}

    modifier onlyWriterOrOwner() {
        _onlyWriterOrOwner();
        _;
    }

    /// @notice Ensures caller is owner or an authorized writer
    /// @dev Reverts with UnauthorizedWriter if caller is neither owner nor in isWriter mapping
    function _onlyWriterOrOwner() internal view {
        if (msg.sender != owner() && !isWriter[msg.sender]) {
            revert UnauthorizedWriter();
        }
    }

    /// @notice Returns the beneficiary address for a token
    /// @param token The token address
    /// @return The beneficiary address (address(0) if not set)
    function beneficiaryOf(address token) external view returns (address) {
        return beneficiaries[token];
    }

    /// @notice Sets or removes a writer address (owner only)
    /// @dev Writers can call setBeneficiary and removeBeneficiary.
    /// @param writer The writer address to enable/disable
    /// @param enabled True to enable, false to disable
    function setWriter(address writer, bool enabled) external onlyOwner {
        isWriter[writer] = enabled;
        emit WriterUpdated(writer, enabled);
    }

    /// @notice Sets the beneficiary for a token (writer or owner only)
    /// @dev Updates the token-to-beneficiary mapping. Both addresses must be non-zero.
    /// @param token The token address (must not be address(0))
    /// @param beneficiary The beneficiary address (must not be address(0))
    function setBeneficiary(
        address token,
        address beneficiary
    ) external onlyWriterOrOwner {
        if (token == address(0) || beneficiary == address(0)) {
            revert ZeroAddress();
        }
        beneficiaries[token] = beneficiary;
        emit BeneficiarySet(token, beneficiary, msg.sender);
    }

    /// @notice Removes a token's beneficiary mapping (writer or owner only)
    /// @dev Deletes the beneficiary mapping for the token.
    /// @param token The token address (must not be address(0))
    function removeBeneficiary(address token) external onlyWriterOrOwner {
        if (token == address(0)) {
            revert ZeroAddress();
        }
        delete beneficiaries[token];
        emit BeneficiaryRemoved(token, msg.sender);
    }
}
