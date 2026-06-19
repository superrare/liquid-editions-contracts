// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {SovereignERC20Core} from "liquid-editions/extensions/SovereignERC20Core.sol";
import {ISovereignERC20} from "liquid-editions/interfaces/ISovereignERC20.sol";

/// @title SovereignERC20
/// @notice Owner-controlled ERC20 with permit, optional supply cap, and ERC-1046 metadata.
contract SovereignERC20 is SovereignERC20Core {
    /// @notice Disables initialization on the implementation contract.
    /// @dev EIP-1167 clones have separate storage and can still call initialize().
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a Sovereign ERC20 clone.
    /// @param initialOwner Owner receiving initial supply and controlling future minting.
    /// @param name_ ERC20 name and EIP-712 signing domain name.
    /// @param symbol_ ERC20 symbol.
    /// @param tokenURI_ Optional ERC-1046 token URI. Empty string is allowed.
    /// @param initialSupply Initial supply minted to the owner. May be zero.
    /// @param maxSupply_ Optional supply cap. A value of 0 means uncapped.
    function initialize(
        address initialOwner,
        string memory name_,
        string memory symbol_,
        string memory tokenURI_,
        uint256 initialSupply,
        uint256 maxSupply_
    ) external initializer {
        if (maxSupply_ != 0 && maxSupply_ < initialSupply) {
            revert ISovereignERC20.MaxSupplyBelowInitialSupply(maxSupply_, initialSupply);
        }

        _initializeSovereignERC20Core(initialOwner, name_, symbol_, tokenURI_, maxSupply_);
        _mint(initialOwner, initialSupply);
    }

    /// @notice Mints tokens to an account. Only callable by the owner.
    /// @param to Recipient of the newly minted tokens.
    /// @param amount Amount of tokens to mint.
    function mint(address to, uint256 amount) external onlyOwner {
        _enforceMaxSupply(amount);
        _mint(to, amount);
    }

    /// @inheritdoc SovereignERC20Core
    function burn(uint256 amount) public override(SovereignERC20Core) {
        super.burn(amount);
    }

    /// @inheritdoc SovereignERC20Core
    function burnFrom(address account, uint256 amount) public override(SovereignERC20Core) {
        super.burnFrom(account, amount);
    }

    /// @inheritdoc SovereignERC20Core
    function supportsInterface(bytes4 interfaceId) public view override(SovereignERC20Core) returns (bool) {
        return interfaceId == type(ISovereignERC20).interfaceId || super.supportsInterface(interfaceId);
    }
}
