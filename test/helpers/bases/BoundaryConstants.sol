// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title Boundary Constants for Testing
/// @notice Shared constants for boundary-condition tests (0, 1, max, max-1)
library BoundaryConstants {
    uint256 internal constant ZERO = 0;
    uint256 internal constant ONE = 1;
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant MAX_MINUS_ONE = type(uint256).max - 1;

    uint128 internal constant UINT128_MAX = type(uint128).max;
    uint128 internal constant UINT128_MAX_MINUS_ONE = type(uint128).max - 1;

    uint64 internal constant UINT64_MAX = type(uint64).max;
    uint32 internal constant UINT32_MAX = type(uint32).max;
}
