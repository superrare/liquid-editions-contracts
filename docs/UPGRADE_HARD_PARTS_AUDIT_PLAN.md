# Audit Plan: Upgrade-Risk Review for Hard-to-Update Components

## Scope
- `src/LiquidRegistry.sol`
- `src/LiquidGuard.sol`
- `src/LiquidMultiCurve.sol`
- `src/LiquidInstant.sol`
- `src/LiquidMigrationExecutor.sol`
- `src/LiquidFactory.sol`
- `src/LiquidRouter.sol`
- `src/FeeDistributor.sol`

## Objective
Focus on the parts of the protocol that are difficult to upgrade safely and verify:
- data migration correctness,
- replacement safety

## Threat model for upgrade risk
1. The highest-risk scenario is not a direct exploit, but accidental user impact because of bugs, broken implmentations, or mistakes during module replacement.
2. Primary risks are:
3. silent state divergence across modules,
4. broken accounting after pointer rewires,
5. and non-upgradeable logic drift in token instances.
4. For this plan, severity is tied to user impact and recoverability.

## Key hard-upgrade boundaries
1. `LiquidRegistry` is stateful and holds beneficiary mapping for many tokens.
2. `LiquidGuard` is a hook contract that is immutable in pool keys, so changing it requires migration flow.
3. `LiquidMultiCurve` and `LiquidInstant` are deployed per market and are not beacon-upgradable.
4. Any fix in these paths must preserve backward accounting continuity and avoid stranded liquidity/value.

## Upgrade risk matrix
1. `LiquidRegistry`
   1. Impact scope: `O(totalTokens)`
   2. Upgrade approach: replacement + mapping replay, or careful mutation.
   3. Recovery complexity: high.
2. `LiquidGuard`
   1. Impact scope: pools tied to old hook.
   2. Upgrade approach: controlled migration execution.
   3. Recovery complexity: high.
3. `LiquidMultiCurve`
   1. Impact scope: pool-token instances only.
   2. Upgrade approach: deploy new implementation only for new markets.
   3. Recovery complexity: very high for legacy instances.
4. `LiquidInstant`
   1. Impact scope: pool-token instances only.
   2. Upgrade approach: deploy new implementation only for new markets.
   3. Recovery complexity: very high for legacy instances.

## Phase 1 – Baseline pre-upgrade evidence collection
1. Snapshot registry state before any action:
2. Capture token -> beneficiary mapping for all active tokens using events and read-state dumps.
3. Snapshot hook and migration wiring:
4. `LiquidFactory.poolHooks()`
5. `LiquidGuard`/`LiquidMigrationExecutor` admin and permission state.
6. Snapshot representative market state:
7. fee path assumptions,
8. liquidity positions,
9. swap and governance-facing metadata for both curve models.
10. Capture full dependency map:
11. who reads registry.
12. who references guard addresses.
13. which markets use multicurve vs instant models.
14. Capture governance controls and multisig rotation model for all upgrade actors.

## Phase 2 – `LiquidRegistry` hardening and migration audit
1. Confirm mapping size and write patterns are safe for offline replay.
2. Verify each token’s beneficiary can be recovered from canonical on-chain signals.
3. Validate stale entry precedence and duplicate-write behavior.
4. Validate unset beneficiary behavior and whether this causes default routing surprises.
5. Verify writer permission model:
6. no accidental role creep,
7. no irreversible removal patterns,
8. no event gaps for critical writes.
6. Validate `setBeneficiary` and `removeBeneficiary` semantics under repeated calls and no-op writes.
7. Validate script/config recovery path can safely initialize a replacement registry and replay state.
8. Confirm rewire order:
9. `LiquidFactory`/`LiquidRouter` rewiring,
10. `FeeDistributor` beneficiary registry pointer updates,
11. and post-replay verification.
11. Validate emergency process:
12. what minimum read set is needed to resume distribution safely if replay is interrupted.

### `LiquidRegistry` audit checklist
1. Can registry replacement be performed without losing beneficiary resolution for active markets?
2. Is there a deterministic canonical source-of-truth for each token’s beneficiary?
3. Can replay produce partial, non-idempotent mappings?
4. Can old and new registry states diverge after rewiring?
5. Are there silent assumptions about one-time initialization?

## Phase 3 – `LiquidGuard` upgrade and hook migration audit
1. Confirm hook immutability implications are explicit in every decision.
2. Map active pools by hook address and identify migration sets.
3. Validate hook migration payload format and validation in `LiquidMigrationExecutor`.
4. Verify migration preserves:
5. token metadata,
6. beneficiary context,
7. fee path policy,
8. and pool-level economic invariants.
9. Validate pause/owner controls during migration do not leave pools in mixed states.
10. Verify hook replacement execution order and sequencing:
11. approval,
12. token-by-token migration,
13. post-migration verification checks.
14. Validate rollback feasibility for partially migrated environments.

### `LiquidGuard` audit checklist
1. Can migration be stopped safely after partial completion?
2. Can any pool be permanently stranded due to failed hook binding?
3. Are there pools that cannot migrate because of invalid state assumptions?
4. Can migration path be replayed without compounding side effects?
5. Do logs/events allow reliable proof of migration completion per token?

## Phase 4 – `LiquidMultiCurve` and `LiquidInstant` replaceability risk
1. Treat these contracts as immutable once deployed per token market.
2. Confirm there is no hidden expectation that existing instances can be patched in-place.
3. Verify new deployment strategy for future markets does not unintentionally break consistency.
4. Assess whether any existing market requires immediate migration despite implementation immutability.
5. Validate how new global defaults affect old instances via factory pointers and whether that coupling is safe.
6. Confirm `LiquidFactory` does not assume a uniform implementation behavior across all historical instances.

### Per-instance audit checklist
1. For `LiquidMultiCurve`:
2. Price and liquidity math behavior is stable over parameter ranges.
3. Callback execution and accounting do not depend on future patch assumptions.
4. Edge-case behavior with small balances and low-liquidity states does not lock swaps for legacy pools.
5. For `LiquidInstant`:
6. Lifecycle assumptions remain valid as time and block conditions advance.
7. Any implicit invariants documented in old versions are encoded in runtime checks.
8. Check whether silent edge conditions can only be addressed in new instances.

## Phase 5 – System-level integration with partial replacement
1. Validate upgrade sequence for mixed replacement plans:
2. replace `LiquidRegistry`,
3. replace `LiquidGuard` + migrated pools,
4. and introduce new `LiquidMultiCurve`/`LiquidInstant` instances only for fresh markets.
5. Verify old and new instances can coexist under same router/factory config.
6. Validate fallback logic in `LiquidRouter`/`FeeDistributor` does not mask failed rewires.
7. Ensure no assumptions exist that all pools must share same hook or model after upgrade.
8. Validate governance UI or scripts cannot silently deploy an incompatible mix.

## Evidence and artifact requirements
1. Pre-upgrade:
2. registry dump,
3. active pool inventory,
4. hook/pool mapping table.
5. Migration runbook:
6. command list,
7. expected intermediate states,
8. and exit checks.
9. Post-upgrade:
10. state diff by market class,
11. event proof of completion,
12. user-path smoke tests.

## Must-have post-upgrade checks
1. Beneficiary resolution for all active tokens resolves correctly.
2. At least one smoke `buy` and `sell` completes in both:
3. migrated and non-migrated market classes.
4. No abnormal revert pattern for normal users in first 10 blocks after change.
5. All migration and rewiring events are emitted and indexed for reconciliation.

## Remediation patterns for high-risk findings
1. Prefer immutable checkpoints:
2. explicit snapshots before replacement.
3. Prefer idempotent replay scripts:
4. safe re-execution with already-migrated guards.
5. Prefer phased migration:
6. low-risk markets first, then long-tail markets.
7. Add kill-switch gating only when it preserves user funds and enables deterministic recovery.

## Audit deliverables
1. Per-contract upgrade-failure scenario list.
2. For each scenario:
3. user impact,
4. blast radius,
5. required manual intervention,
6. and rollback feasibility.
7. A ranked action list:
8. P0/P1/P2 with exact first-step containment.

## Suggested severity rubric for this plan
1. P0: upgrade action can permanently block trading or claim paths for multiple active markets.
2. P1: upgrade can misroute fees or lose beneficiary intent for active users.
3. P2: upgrade can cause non-trivial partial failure with recoverable remediation.
4. P3: upgrade adds operational burden but can be fully remediated within expected runbook.
