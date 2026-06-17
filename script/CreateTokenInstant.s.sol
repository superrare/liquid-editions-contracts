// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";

/**
 * @title CreateTokenInstant
 * @notice Legacy script kept as a compile-safe placeholder.
 * @dev LiquidFactory no longer exposes createLiquidTokenInstant.
 */
contract CreateTokenInstant is Script {
    function run() external pure {
        revert("CreateTokenInstant is unsupported: LiquidFactory only exposes multicurve creation");
    }
}
