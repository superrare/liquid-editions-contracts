// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title Mock V4 Quoter for testing
/// @dev Returns configurable quote values for unit tests without forking
contract MockV4Quoter {
    uint256 public mockQuote;
    bool public shouldRevert;

    function setMockQuote(uint256 quote) external {
        mockQuote = quote;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function quoteExactInput(
        PoolKey memory,
        uint256,
        bool
    ) external view returns (uint256) {
        if (shouldRevert) revert("Quoter error");
        return mockQuote;
    }
}
