// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";

/// @notice Resolves the controlling address for a Liquid-linked render contract.
/// @dev Prefer the Liquid token's owner() when exposed, otherwise fall back to tokenCreator().
library LiquidRenderOwnerResolver {
    error InvalidLiquidEdition();

    function resolve(address liquidEdition) internal view returns (address renderOwner) {
        if (liquidEdition == address(0)) revert InvalidLiquidEdition();

        (bool success, bytes memory data) = liquidEdition.staticcall(abi.encodeWithSignature("owner()"));
        if (success && data.length >= 32) {
            renderOwner = abi.decode(data, (address));
            if (renderOwner != address(0)) return renderOwner;
        }

        (success, data) = liquidEdition.staticcall(abi.encodeCall(ILiquid.tokenCreator, ()));
        if (!success || data.length < 32) revert InvalidLiquidEdition();

        renderOwner = abi.decode(data, (address));
        if (renderOwner == address(0)) revert InvalidLiquidEdition();
    }
}
