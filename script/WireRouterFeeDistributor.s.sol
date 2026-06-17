// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// This script has been removed.
// Router<->FeeDistributor price-forwarding wiring is no longer needed.
// FeeDistributor now reads the RARE/ETH spot price directly from pool slot0.
//
// To configure fee conversion, ensure:
//   1. FeeDistributor has a valid rareEthPoolKey (setRareEthPoolKey)
//   2. FeeDistributor has the LiquidGuard approved (setHookApproval)
//   3. conversionEnabled is true (default)
