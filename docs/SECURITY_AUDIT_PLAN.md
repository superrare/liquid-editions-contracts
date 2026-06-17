# Security Audit Instructions (Liquid Editions)

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

## Objective
Produce a security-focused, exploitability-first audit of the listed files.
Prioritize findings that can cause:
- unauthorized fund movement,
- permanent state lock,
- forced misrouting of fees/beneficiaries,
- or denial of critical protocol functions.

Avoid speculative findings unless backed by reproducible conditions.

## Core assumptions
1. Core infrastructure (Chains, RPC endpoints, Uniswap pool mechanics, `RARE` token) is trusted for this pass.
2. Privileged roles are external accounts, not multisig-specific assumptions.
3. The audit is non-mutating unless explicitly validating script behavior with forked simulations.

## Required outputs
1. Threat model map with trusted/untrusted boundaries.
2. Full issue list with severity (Critical/High/Medium/Low/Informational).
3. For each issue: attacker type, preconditions, reproducible sequence, impact, root cause, minimum safe fix, and test idea.
4. Remediation priority matrix: P0/P1/P2/P3.
5. Module-level risk summary for each contract + overall system risk.

## Working rules
1. Track all external calls and verify expected revert behavior if they fail.
2. Verify invariants after every critical state transition, not only on happy paths.
3. Confirm every admin setter has:
- correct role check,
- sensible zero-address guard,
- event coverage,
- and safe failure mode.
4. Flag any unchecked `call`/`transfer`/`send` or fallback pathway that can trap value.
5. Confirm immutable/config boundaries are explicit and cannot be silently bypassed by admin changes.

## Suggested audit order
1. `script/config/NetworkConfig.sol`
2. `src/LiquidFactory.sol`
3. `src/LiquidGuard.sol`
4. `src/LiquidMigrationExecutor.sol`
5. `src/FeeDistributor.sol`
6. `src/LiquidRouter.sol`
7. `src/LiquidRegistry.sol`
8. `src/LiquidInstant.sol`
9. `src/LiquidMultiCurve.sol`
10. `script/DeployLiquidSystem.s.sol`

Starting with config and factory surfaces makes pointer/initialization risks explicit before deeper hook logic.

## Contract-level checklist

### `src/LiquidFactory.sol`
1. Verify ownership and pause controls for all administrative functions.
2. Validate all mutable addresses (registry, hooks, managers, executors, implementations) are only changed by authorized roles.
3. Check that implementation address swaps cannot break initialization assumptions.
4. Validate pool creation flow for callback origin, salt/replay assumptions, and token initialization constraints.
5. Audit tick/frequency/funding bounds checks for griefing or invalid-state locks.
6. Confirm `create` and similar flows are internally consistent with expected swap hooks.
7. Verify events are emitted for all critical admin and state transitions.
8. Confirm `set*` functions prevent unsafe zero/zero-like states.

### `src/LiquidRouter.sol`
1. Verify every route entrypoint has command validation and strict route policy checks.
2. Audit `buy`/`sell`/`swap`/single/aggregated path validation and anti-bypass constraints.
3. Trace ETH and token value flows end-to-end:
- amount-in checks,
- fee deduction,
- beneficiary split,
- refunds,
- revert-on-shortfall behavior.
4. Confirm hook/module pointer reads are consistent across execution and not stale at critical points.
5. Review rescue functions for owner-only gating and unintended value sinkholes.
6. Validate pause and safety logic in relation to route execution.

### `src/LiquidGuard.sol`
1. Review all hook entry points (`beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`) for:
- sender authenticity,
- route policy enforcement,
- and non-initialized pool behavior.
2. Validate that module wiring (factory, distributor, whitelist-like controls) cannot be overwritten into unsafe state.
3. Confirm initializer/registrar functions are role-gated and have safe failure behavior.
4. Inspect any fee logic coupling with `FeeDistributor` and whether bypass conditions exist.

### `src/LiquidMigrationExecutor.sol`
1. Verify ownership restrictions for migration execution and all parameter mutators.
2. Audit migration plan parsing for size, ordering, and target type validation.
3. Confirm hooks and fee settings whitelist checks cannot be disabled to execute unsafe migrations.
4. Validate pause/emergency safety behavior around stateful migration operations.
5. Confirm protocol vault and protocol-related fields have immutable/safe transitions and clear failure modes.

### `src/LiquidRegistry.sol`
1. Review writer model:
- writer role definition,
- add/remove writer,
- and who can call protected functions.
2. Validate beneficiary map updates are not susceptible to overwrite or stale-entry confusion.
3. Confirm beneficiary writes validate non-zero/allowed addresses per policy.
4. Trace read-path defaults and behavior for unset beneficiaries.
5. Audit owner/zero-address transitions for data-loss or lock state.

### `src/FeeDistributor.sol`
1. Treat fee logic as critical funds flow:
- conversion path,
- split calculations,
- beneficiary resolution,
- fallback routing.
2. Verify split arithmetic for rounding direction and edge underflow/overflow.
3. Validate conversion failure handling:
- stale prices,
- conversion path missing,
- protocol fallback correctness.
4. Confirm immutable vs mutable economics are intentionally separated and documented.
5. Check event consistency for fee split and distribution outcomes.
6. Review all external value transfers for reentrancy and transfer-failure trapping.

### `src/LiquidMultiCurve.sol`
1. Audit formula path for pricing math and exponent/overflow risk.
2. Validate swap and init callbacks for expected state updates and authorization.
3. Confirm slippage and quote checks are binding at execution time.
4. Ensure position lifecycle transitions (open/close/liquidation) preserve invariant balances.
5. Review edge cases for zero liquidity, one-sided adds, tiny inputs, and rounding truncation.

### `src/LiquidInstant.sol`
1. Review instant liquidity/position logic for accounting correctness.
2. Verify callback ordering and state mutation points for race/reentrancy.
3. Confirm token/ETH accounting is exact for all branches including failure and partial-execution paths.
4. Validate input limits and parameter sanitization for swap and mint/remove operations.
5. Check for mismatches between virtual accounting and actual ERC20 balance deltas.

### `script/config/NetworkConfig.sol`
1. Ensure chain-id selection is deterministic and not influenced by ambiguous defaults.
2. Validate per-chain address sets for factory/router/guard/migration/registry/distributor are internally consistent.
3. Confirm no zero/placeholder addresses are silently accepted for critical modules.
4. Audit fallback defaults and override precedence for config safety.
5. Confirm this file does not hardcode unsafe admin/deployment assumptions into test/mainnet flows.

### `script/DeployLiquidSystem.s.sol`
1. Review all deploy flags and ensure safe defaults.
2. Validate conditional deployment paths avoid partial-state deployment in failure cases.
3. Audit owner/deployer assumptions and address override precedence.
4. Confirm deployment wiring does not create mixed-chain or mixed-implementation state.
5. Ensure all replacement/rewire operations validate post-deploy pointers before exit.
6. Check for missing checks in script-side security assumptions that may not be present on-chain.

## Cross-contract interaction checks
1. Verify `LiquidFactory`, `LiquidRouter`, `LiquidGuard`, `LiquidMigrationExecutor`, and `LiquidRegistry` address pointers are coherent.
2. Confirm fee path (`Factory -> Router -> Guard -> FeeDistributor -> Registry`) cannot be routed through stale or unauthorized contracts.
3. Validate all script-driven module swaps preserve compatibility with storage and interface expectations.
4. Check event logs for atomic sequence correctness when module pointers change.
5. Trace upgrade/replace/redeploy paths for temporary states that can process transactions in an inconsistent configuration.

## Evidence collection
1. For each finding, capture the exact call sequence and pre/post state that reproduces impact.
2. Include a minimal PoC for:
- state corruption,
- unauthorized state transition,
- misrouting of value,
- or irreversible DoS.
3. Note exact function selectors and any relevant constants/arguments.
4. Keep one reference scenario per issue showing both trigger and mitigation path.

## Recommended test ideas for validation
1. Permission tests for all admin setters and initializer-style paths.
2. Property/invariant tests around fee conservation and beneficiary accounting.
3. Reentrancy and external call failure tests around fee distribution.
4. Config mutation tests that attempt zero/invalid values and cross-module pointer swaps.
5. Migration and deployment script tests using fork mode to validate sequencing and post-state assertions.

## Findings format (mandatory template)
1. Title
2. Severity
3. Affected file:line/function
4. Preconditions
5. Attack sequence
6. Impact (funds/confidentiality/availability)
7. Root cause
8. Minimum patch
9. Test to prove fix

## Stop criteria
1. All critical and high-severity issues in the scope are assigned and justified.
2. No unresolved critical/high issues before sign-off.
3. Any item blocked by trust assumptions is explicitly marked as "assumption-dependent".
