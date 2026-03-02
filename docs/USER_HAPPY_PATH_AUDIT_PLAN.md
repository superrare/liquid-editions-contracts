# Happy-Path Audit Instructions (User Behavior & Normal-Use Correctness)

## Scope
- `src/LiquidFactory.sol`
- `src/LiquidRouter.sol`
- `src/LiquidGuard.sol`
- `src/LiquidMigrationExecutor.sol`
- `src/LiquidRegistry.sol`
- `src/FeeDistributor.sol`
- `src/LiquidMultiCurve.sol`
- `src/LiquidInstant.sol`
- `script/config/NetworkConfig.sol`
- `script/DeployLiquidSystem.s.sol`

## Purpose
This audit checks that the protocol behaves correctly for standard, expected usage (“happy paths”).  
Primary goal: catch foot guns, silent edge cases, and surprising behavior before users interact with those flows.

## Core principles
1. Prioritize **user intent satisfaction** over adversarial abuse.
2. Validate that common operations are:
   - reversible when expected,
   - non-surprising under boundary inputs,
   - and fail with clear reasons when invalid.
3. Treat “works for one wallet” as insufficient; verify for fresh users, repeat users, and stale/rehash states.
4. Track both **on-chain state** and **event evidence**.

## Deliverable (required)
1. A per-flow behavior matrix with pass/fail and expected state deltas.
2. A list of normal-use bugs/foot guns per contract.
3. “Confidence gaps” where intended behavior is not explicitly enforced by code/docs.
4. Minimum corrective suggestions prioritized by user impact.

## Success criteria
1. All expected normal flows complete from cold start without admin intervention.
2. Fees, routes, registry resolution, and beneficiary payouts match user-readable docs or comments.
3. No path depends on undocumented assumptions (e.g., hidden one-shot approvals, fixed ordering, implicit defaults).
4. Edge cases produce deterministic outcomes and clear errors, not silent underpayment or partial execution.

## General happy-path test strategy
1. Define user stories before code paths (launch, trade, migrate, receive fees, admin config, script deploy).
2. For each story, identify:
   - caller role,
   - inputs,
   - contract path,
   - expected events,
   - expected balances/state deltas.
3. Validate each story under:
   - normal value ranges,
   - minimum thresholds,
   - and max values supported by config.
4. Confirm at least one “retry” scenario where a failed path is recoverable.

## User flows to audit

### 1) Project/token launch flow
1. User opens/creates a pool path end-to-end.
2. Validate token acceptance, hook wiring assumptions, and initialization.
3. Confirm resulting pool parameters are what user expects from inputs.
4. Validate no hidden dependency on prior stale writes.
5. Expected checks:
   - pool exists once,
   - owner/pool key consistent,
   - beneficiary/registry pointer in place.

### 2) Buy flow
1. User calls buy path with valid path payload.
2. Validate input checks, fee split, swaps, and net output.
3. Confirm refunds are exact and not truncated unexpectedly.
4. Validate emitted route/fill events and post-trade balances.

### 3) Sell flow
1. User calls sell with valid input.
2. Validate accounting for returned base asset vs slippage constraints.
3. Confirm fee deductions are deterministic and correctly logged.
4. Ensure no user asset is stranded on callback failure.

4) Swap path flow
1. Validate each supported `RoutePolicy` + command sequence.
2. Ensure route preconditions (token whitelist, recipient constraints, path length constraints) are enforced consistently.
3. Confirm slippage guard and final state updates match expected quote model.

### 5) Registry/beneficiary resolution
1. Set beneficiary through normal registry path.
2. Trigger actions that rely on beneficiary lookup.
3. Verify payout goes to expected beneficiary when set, and to documented default when unset.

### 6) Fee conversion/distribution
1. Execute normal `FeeDistributor` integration via swap/launch flows.
2. Validate fee split proportions and beneficiary routing under:
   - conversion enabled,
   - fallback to protocol token path,
   - conversion failure fallback if it occurs.
3. Check no unexpected rounding bias against users.

### 7) Migration flow
1. Prepare and run expected migration plan.
2. Validate token ownership/positions are preserved per documented intent.
3. Ensure migration succeeds without breaking unrelated pools.

### 8) Scripted deploy/rebuild flow
1. Run deployment script in default mode for a known chain.
2. Validate all derived addresses align with config intent.
3. Confirm rewire/replacement operations update all required pointers in a consistent order.

## Contract-by-contract happy-path checks

### `src/LiquidFactory.sol`
1. Confirm factory deployment and ownership assumptions match expected deployment chain.
2. Validate canonical pool creation path:
3. Confirm created pool key is reproducible and unique per expected salt inputs.
4. Check configuration setter behavior:
   - no silent no-op where user expects update,
   - immediate impact is visible on next pool creation path.
5. Verify no unexpected requirement on caller pre-conditions beyond docs/explicit checks.

### `src/LiquidRouter.sol`
1. Validate route decoding and command ordering for all standard entry functions.
2. Confirm user-facing failures map cleanly to invalid path/malformed command scenarios.
3. Verify normal value flow for buy/sell/swap:
   - no extra hidden deductions,
   - post-call event trail is complete.
4. Ensure pause/unpause semantics do not produce partial state mutation for users.

### `src/LiquidGuard.sol`
1. Validate hook behavior in normal initialized/uninitialized pool state.
2. Confirm intended checks are enforced and user-visible errors are explainable.
3. Verify no silent bypass of policy gates under normal route variants.
4. Confirm fee split handoff works under expected call ordering.

### `src/LiquidMigrationExecutor.sol`
1. Validate ordinary migration command encoding and execution.
2. Confirm migration state checks are explicit and return clear reverts.
3. Verify per-token migration does not alter unrelated markets.
4. Confirm rerunnable/retry behavior (if one step fails, user-visible state is not inconsistently left behind).

### `src/LiquidRegistry.sol`
1. Verify normal beneficiary set/get behavior for fresh and existing tokens.
2. Confirm readers and writers use intuitive access paths.
3. Validate duplicate/overwrite patterns are either explicit or prevented.
4. Verify event logs match current mapping state.

### `src/FeeDistributor.sol`
1. Validate fee collection on normal swap traffic.
2. Confirm split percentages + rounding produce expected outcomes for:
   - tiny fees,
   - near-boundary percentages,
   - mixed beneficiary values.
3. Confirm conversion fallback behavior is as documented when conversion is unavailable.
4. Verify outputs in both happy and non-fallback paths are traceable through emitted events.

### `src/LiquidMultiCurve.sol`
1. Validate standard liquidity add/remove and swap math.
2. Ensure output/balance changes match expected formula assumptions.
3. Confirm callback-triggered state transitions complete when user-side liquidity conditions are normal.
4. Validate small-amount boundary and stepwise operations.

### `src/LiquidInstant.sol`
1. Validate instant flow pricing and execution for expected params.
2. Check slippage handling does not penalize otherwise valid tiny trades.
3. Confirm expected user receives same asset outcome across retries with same route state.

### `script/config/NetworkConfig.sol`
1. Verify chain-specific values match expected canonical deployment config.
2. Confirm no unknown/null addresses appear for active network profiles.
3. Validate fallback behavior is intentional and documented.
4. Confirm scripts reading this file receive consistent values over repeated runs.

### `script/DeployLiquidSystem.s.sol`
1. Validate default flags + overrides for a normal successful deploy/rebuild.
2. Confirm only intended modules are deployed/redeployed in each mode.
3. Verify final pointer rewiring (factory/router/registry/migration/guard/fee) is end-to-end consistent.
4. Confirm deploy script emits enough events/output for post-deploy verification.

## Happy-path foot-gun checklist
1. Config drift:
   - A user transaction assumes one module pointer; that module was changed outside docs.
2. Silent fallback dependence:
   - conversion/fallback behavior changed outcomes without explicit warning.
3. Value precision surprises:
   - rounding or division truncation changes output expectation at small sizes.
4. One-shot behavior:
   - one action appears idempotent but is effectively destructive/irreversible for user flows.
5. Route-order dependency:
   - valid route in one order fails in another, causing accidental user lockouts.
6. State desync:
   - `NetworkConfig` vs actual deployed addresses differ after partial script execution.
7. Weak observability:
   - success events exist but do not include key parameters for user diagnosis.

## Expected artifacts
1. A “happy path matrix” table (flow × expected state changes × event trail).
2. A short “common pitfall” section:
   - what users/ops teams might do wrong and expected safe behavior.
3. Prioritized fixes with user impact: `P0`/`P1`/`P2`.

## Reporting format
For each flow issue include:
1. Flow name
2. Reproduction steps
3. Expected vs actual
4. User impact (wrong quote, wrong recipient, failed completion, silent partial completion, confusion)
5. Fix proposal (documentation clarification, guard assertion, behavior normalization, or code change)
