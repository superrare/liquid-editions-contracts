// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";

/// @title LiquidRegistry
/// @notice Centralized registry of valid Liquid tokens and their beneficiaries with registration gating.
/// @dev This registry serves as the gatekeeper for LiquidRouter and LiquidAuctioneer trading.
///      Only tokens registered here (via factory or admin) can be traded through the router and auctioneer,
///      preventing untrusted contracts from being used. This provides security by ensuring only legitimate
///      Liquid tokens (created via LiquidFactory) are tradeable.
///
///      **Key Features:**
///      - Token registration requirement (isRegistered() check)
///      - Writer-based access control (factory can register tokens automatically)
///      - Beneficiary mapping (token address → beneficiary address)
///      - Registration gating (Router/Auctioneer check isRegistered() before allowing trades)
///
///      **Relationship to beneficiary mapping patterns:**
///      - LiquidRegistry combines beneficiary resolution with token registration requirements
///      - LiquidRegistry adds isRegistered() function which Router/Auctioneer use for security
///      - The registry enforces trading security checks at the protocol level.
///
///      **Registration Requirements:**
///      - LiquidRouter.buy()/sell()/swap() check isRegistered() before executing trades
///      - LiquidAuctioneer.bid() checks isRegistered() before accepting bids
///      - Only registered tokens can receive fee distributions (beneficiary must be set)
///      - Factory automatically registers tokens during creation via setBeneficiary()
///      - Admin can manually register/deregister tokens via setBeneficiary()/removeBeneficiary()
contract LiquidRegistry is ILiquidRegistry, Ownable {
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
    /// @return The beneficiary address (address(0) if not registered)
    function beneficiaryOf(address token) external view returns (address) {
        return beneficiaries[token];
    }

    /// @notice Checks if a token is registered
    /// @dev A token is registered if it has a non-zero beneficiary mapping
    /// @param token The token address
    /// @return True if token is registered
    function isRegistered(address token) external view returns (bool) {
        return beneficiaries[token] != address(0);
    }

    /// @notice Sets or removes a writer address (owner only)
    /// @dev Writers can call setBeneficiary and removeBeneficiary. Used to authorize factory.
    /// @param writer The writer address to enable/disable
    /// @param enabled True to enable, false to disable
    function setWriter(address writer, bool enabled) external onlyOwner {
        if (writer == address(0)) {
            revert ZeroAddress();
        }
        isWriter[writer] = enabled;
        emit WriterUpdated(writer, enabled);
    }

    /// @notice Sets the beneficiary for a token (writer or owner only)
    /// @dev Registers token if not already registered, or updates beneficiary if already registered.
    ///      Setting beneficiary to non-zero effectively registers the token.
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
    /// @dev Deletes the beneficiary mapping, effectively deregistering the token.
    ///      Router and Auctioneer will reject trades for deregistered tokens.
    /// @param token The token address (must not be address(0))
    function removeBeneficiary(address token) external onlyWriterOrOwner {
        if (token == address(0)) {
            revert ZeroAddress();
        }
        delete beneficiaries[token];
        emit BeneficiaryRemoved(token, msg.sender);
    }
}
