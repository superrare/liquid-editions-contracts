// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20HolderRewards} from "liquid-editions/extensions/ERC20HolderRewards.sol";
import {SovereignERC20MarketCore} from "liquid-editions/extensions/SovereignERC20MarketCore.sol";
import {IERC20HolderRewards} from "liquid-editions/interfaces/IERC20HolderRewards.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {ILiquidGuard} from "liquid-editions/interfaces/ILiquidGuard.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";

/// @title SovereignERC20MarketRewards
/// @notice Sovereign market token with permissionless pro rata holder rewards.
contract SovereignERC20MarketRewards is SovereignERC20MarketCore, ERC20HolderRewards {
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        string memory tokenURI_,
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        Curve[] calldata curves,
        address rewardToken_
    ) external initializer {
        _initializeSovereignERC20MarketConfig(initialOwner, tokenURI_, name_, symbol_, initialSupply, curves);

        _initializeHolderRewards(rewardToken_, _systemRewardsExclusions());

        _initializeSovereignERC20MarketPool(curves);
        _markHolderRewardsBalanceAccounted();
    }

    function _systemRewardsExclusions() internal view returns (address[] memory accounts) {
        address hooks = ILiquidFactory(factory).poolHooks();
        address feeDistributor;

        if (hooks != address(0)) {
            try ILiquidGuard(hooks).feeDistributor() returns (address configuredFeeDistributor) {
                feeDistributor = configuredFeeDistributor;
            } catch {}
        }

        uint256 count = 2;
        if (hooks != address(0)) count++;
        if (feeDistributor != address(0)) count++;

        accounts = new address[](count);
        accounts[0] = poolManager;
        accounts[1] = factory;

        uint256 index = 2;
        if (hooks != address(0)) {
            accounts[index++] = hooks;
        }
        if (feeDistributor != address(0)) {
            accounts[index] = feeDistributor;
        }
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(SovereignERC20MarketCore, ERC20HolderRewards)
        returns (bool)
    {
        return interfaceId == type(IERC20HolderRewards).interfaceId
            || SovereignERC20MarketCore.supportsInterface(interfaceId);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        _holderRewardsAfterTokenTransfer(from, to, value);
    }

    function _holderRewardsBalanceOf(address account) internal view override returns (uint256) {
        return balanceOf(account);
    }

    function _checkHolderRewardsOwner() internal view override {
        _checkOwner();
    }
}
