# Liquid Contract Flow Map

This is the canonical behavioral map for onboarding and troubleshooting.
Any contract behavior should be interpreted against these paths.

## Universal rule

- In this architecture, router contract fees are not collected in `LiquidRouter.buy/sell/swap`.
- Router forwards the client-provided RARE/ETH price by calling `IFeeDistributor.setLastRareEthPrice(sqrtPriceX96)`.
- All active V4 fee capture happens inside `LiquidGuard` hooks (`beforeSwap` / `afterSwap`) and flows into
  `FeeDistributor.notifyFee()`.
- Legacy selector paths on `IFeeDistributor` (`totalFeeBPS`, `protocolFeeRecipient`, `quoteFeeBreakdown`,
  `distributeFees`, `setTotalFeeBPS`) are compatibility-only and behave as no-op/stable compatibility wrappers.

## Feature flow map

### 1) Create (token launch)
- **File:** `src/LiquidFactory.sol`
- **Primary functions:** `createLiquidTokenMultiCurve`, `createLiquidTokenWithAuction`
- **Steps:**
  1. Factory validates module pointers and constructor settings.
  2. For multicurve, it deploys a clone, initializes pool, and registers token/beneficiary.
  3. For auction flow, it creates a `LiquidGraduated` clone, initializes strategy, and starts auction setup.
  4. Registry registration is updated via `_registerToken`.
- **Compatibility note:** `_migrator` in `createLiquidTokenWithAuction` is intentionally ignored (API stable only).
- **Core events:** `LiquidTokenCreated`, `LiquidGraduated`/implementation init events, registry events.

### 2) Buy (ETH -> token)
- **File:** `src/LiquidRouter.sol`
- **Primary functions:** `buy`, `_updateFeeDistributorPrice`, `_executeSwap`
- **Steps:**
  1. Router validates token registration and parameters.
  2. Router forwards client-provided `RARE/ETH` price by calling `IFeeDistributor.setLastRareEthPrice(expectedRareEthSqrtPriceX96)`.
  3. It executes the Universal Router command payload.
  4. It verifies `minTokensOut` after execution and transfers tokens to recipient.
- **Fee handling:** no router-side split; emitted `RouterBuy` fee fields are zero.
- **Fee events:** no dedicated fee event in this path.

### 3) Sell (token -> ETH)
- **File:** `src/LiquidRouter.sol`
- **Primary functions:** `sell`, `_pullTokens`, `_executeSwap`, `_verifyTokensConsumed`
- **Steps:**
  1. Router validates registration and pulls the input token.
  2. Router forwards client-provided fee context via `setLastRareEthPrice(expectedRareEthSqrtPriceX96)`.
  3. Swap executes through Universal Router.
  4. Router verifies exact input consumption and sends ETH to recipient.
- **Fee handling:** no router-side split; emitted `RouterSell` fee fields are zero.

### 4) Swap (generic token -> token/ETH)
- **File:** `src/LiquidRouter.sol`
- **Primary functions:** `swap`, `_updateFeeDistributorPrice`, `_executeSwap`
- **Steps:**
  1. Router validates registration and routes input/output semantics by `tokenIn` and `tokenOut`.
  2. It updates the fee context once at start.
  3. It executes one leg (`tokenIn -> ETH`) and optional second leg (`ETH -> tokenOut`) through Universal Router.
  4. Router verifies slippage and emitted amounts for both legs.
- **Fee handling:** no router-side split; emitted `RouterSwap` fee fields are zero.

### 5) Auction bid (bid for `LiquidGraduated`)
- **File:** `src/LiquidAuctioneer.sol`
- **Primary functions:** `bid`, `_buildTokenToRareRoute`, `_submitBid`
- **Steps:**
  1. `bid` validates token registration and resolves route preset for `tokenIn`.
  2. For ETH bids, it computes legacy compatibility fee via basis-point math over `msg.value` and `_feeDistributor.totalFeeBPS()`.
  3. For non-ETH bids, it swaps ERC20/V4 through configured routes to RARE and prepares Permit2 allowance.
  4. It submits the bid to auction contract.
  5. Legacy compatibility `distributeFees` is invoked where code-paths still include it.
- **Compatibility note:** `totalFeeBPS` and `distributeFees` are retained for historical callers and are effectively
  no-ops for routed trades in the active distributor path.
- **Core events:** `FeeDistributorUpdated`, `LiquidRegistryUpdated`, `TokenRouteUpdated`, and downstream CCA events.

### 6) Fee conversion and distribution (active V4 path)
- **File:** `src/FeeDistributor.sol`
- **Primary functions:** `notifyFee`, `_convertAndDistributeEth`, `_distributeRare`
- **Steps:**
  1. `LiquidGuard` takes RARE and calls `notifyFee(liquidToken, fee)`.
  2. `notifyFee` splits by beneficiary and checks conversion preconditions:
     - `conversionEnabled`
     - fresh `lastSqrtPriceX96`
     - valid `rareEthPoolKey`
  3. If valid, it attempts `RARE -> ETH` swap and sends ETH shares.
  4. On stale/disabled/error, it falls back to `_distributeRare` to avoid reverting user swaps.
- **Events:** `FeeConvertedAndDistributed` or `FeeDistributedInRare`.

### 7) Burn path
- **File:** `src/RAREBurner.sol`
- **Primary functions:** `depositForBurn`, `_executeV4Swap`, `_tryFlush`
- **Steps:**
  1. Router/binder sends ETH to burner.
  2. Burner accumulates ETH and optionally executes V4 swaps into RARE.
  3. Swapped RARE is moved to burn address.

## Feature -> files -> functions -> events mapping

| Feature | Files | Functions | Events |
|---|---|---|---|
| Create | `src/LiquidFactory.sol` | `createLiquidTokenMultiCurve`, `createLiquidTokenWithAuction` | `LiquidTokenCreated`, `BeneficiarySet` |
| Buy/Sell/Swap | `src/LiquidRouter.sol` | `buy`, `sell`, `swap` | `RouterBuy`, `RouterSell`, `RouterSwap` |
| Auction Bid | `src/LiquidAuctioneer.sol` | `bid` | External auction strategy events (bid submit/exit lifecycle), `TokenRouteUpdated` |
| Fee capture | `src/LiquidGuard.sol` | `beforeSwap`, `afterSwap` | none (returns hook deltas) |
| Fee distribution | `src/FeeDistributor.sol` | `notifyFee`, `_convertAndDistributeEth`, `_distributeRare` | `FeeConvertedAndDistributed`, `FeeDistributedInRare`, `FeeTransferFailed` |
| Burn | `src/RAREBurner.sol` | `depositForBurn`, `flush` | `Deposited`, `Burned`, `BurnFailed`, `ConfigUpdated` |

## Compatibility glossary

- `IFeeDistributor.totalFeeBPS`, `quoteFeeBreakdown`, `distributeFees`, `setTotalFeeBPS`
  are retained for historical API compatibility.
- These selectors do not drive active `LiquidRouter`/V4 routing economics in the active path.
- Route-level fee behavior should be reasoned from `LiquidGuard` + `FeeDistributor.notifyFee()`.
