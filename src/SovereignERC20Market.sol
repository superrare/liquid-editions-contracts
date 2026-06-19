// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {SovereignERC20MarketCore} from "liquid-editions/extensions/SovereignERC20MarketCore.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";

/// @title SovereignERC20Market
/// @notice Sovereign ERC20 launched atomically with one-sided RARE market liquidity.
contract SovereignERC20Market is SovereignERC20MarketCore {
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        string memory tokenURI_,
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        Curve[] calldata curves
    ) external initializer {
        _initializeSovereignERC20MarketConfig(initialOwner, tokenURI_, name_, symbol_, initialSupply, curves);
        _initializeSovereignERC20MarketPool(curves);
    }
}
