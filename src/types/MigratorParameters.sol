// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title MigratorParameters
/// @notice Parameters for LBP strategy deployment (matches Uniswap liquidity-launcher)
struct MigratorParameters {
    uint64 migrationBlock;
    address currency;
    uint24 poolLPFee;
    int24 poolTickSpacing;
    uint24 tokenSplit; // mps (1e7 = 100%)
    address initializerFactory;
    address positionRecipient;
    uint64 sweepBlock;
    address operator;
    uint128 maxCurrencyAmountForLP;
}
