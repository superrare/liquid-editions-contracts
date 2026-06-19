// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin-upgradeable/contracts/utils/introspection/ERC165Upgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";

import {IERC1046, ISovereignERC20} from "liquid-editions/interfaces/ISovereignERC20.sol";

/// @title SovereignERC20Core
/// @notice Shared clone-friendly ERC20 core used by all Sovereign token variants.
abstract contract SovereignERC20Core is
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable
{
    /// @notice Optional supply cap. A value of 0 means minting is uncapped.
    uint256 public maxSupply;

    string private _tokenURI;

    function _initializeSovereignERC20Core(
        address initialOwner,
        string memory name_,
        string memory symbol_,
        string memory tokenURI_,
        uint256 maxSupply_
    ) internal onlyInitializing {
        if (bytes(name_).length == 0) revert ISovereignERC20.EmptyName();
        if (bytes(symbol_).length == 0) revert ISovereignERC20.EmptySymbol();

        __ERC20_init(name_, symbol_);
        __ERC20Burnable_init();
        __ERC20Permit_init(name_);
        __Ownable_init(initialOwner);
        __ERC165_init();

        _tokenURI = tokenURI_;
        maxSupply = maxSupply_;
    }

    /// @notice Returns the ERC-1046 token URI.
    function tokenURI() public view returns (string memory) {
        return _tokenURI;
    }

    /// @notice Updates the ERC-1046 token URI. Empty string is allowed.
    /// @param newTokenURI New metadata URI.
    function setTokenURI(string calldata newTokenURI) external onlyOwner {
        string memory oldTokenURI = _tokenURI;
        _tokenURI = newTokenURI;
        emit ISovereignERC20.TokenURIUpdated(oldTokenURI, newTokenURI);
    }

    /// @notice Returns the current owner.
    function owner() public view virtual override(OwnableUpgradeable) returns (address) {
        return super.owner();
    }

    /// @inheritdoc ERC20BurnableUpgradeable
    function burn(uint256 amount) public virtual override {
        super.burn(amount);
    }

    /// @inheritdoc ERC20BurnableUpgradeable
    function burnFrom(address account, uint256 amount) public virtual override {
        super.burnFrom(account, amount);
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165Upgradeable) returns (bool) {
        return interfaceId == type(IERC1046).interfaceId || interfaceId == type(IERC20).interfaceId
            || interfaceId == type(IERC20Metadata).interfaceId || interfaceId == type(IERC20Permit).interfaceId
            || interfaceId == type(IERC5267).interfaceId || interfaceId == type(IERC5313).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function _enforceMaxSupply(uint256 mintAmount) internal view {
        uint256 cap = maxSupply;
        if (cap == 0) return;

        uint256 currentSupply = totalSupply();
        if (mintAmount > cap - currentSupply) {
            revert ISovereignERC20.MaxSupplyExceeded(cap, currentSupply, mintAmount);
        }
    }
}
