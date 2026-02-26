# Liquid Editions Security Audit Plan (Non-Mutating)

## 1) Title
Comprehensive exploit-focused audit of `LiquidFactory`, `LiquidSwapGuard`, `LiquidGraduated`, `LiquidMultiCurve`, `LiquidRouter`, `LiquidAuctioneer`, `FeeDistributor`, and `BeneficiaryRegistry` with minimal, testable remediations.

## 2) Current System Architecture Notes
- `FeeDistributor` (`src/FeeDistributor.sol`) owns fee policy and split execution; `LiquidRouter`/`LiquidAuctioneer` consume it.
  - Intentionally immutable and designed to be replaced via module swaps.
- `BeneficiaryRegistry` (`src/BeneficiaryRegistry.sol`) owns beneficiary address resolution and is read by both `LiquidRouter` and `LiquidAuctioneer`.
- `LiquidRouter` and `LiquidAuctioneer` are orchestration layers:
  - route validation and policy gating,
  - permissioned administration,
  - delegating all ETH fee split/transfer execution to `FeeDistributor`.
- Protocol economics updates are operationally managed by module swaps (`setFeeDistributor`, `setBeneficiaryRegistry`) rather than redeployment of all system contracts.
- `FeeDistributor` is immutable for:
  - `protocolFeeRecipient` (deployment-time only),
  - `BENEFICIARY_FEE_BPS` (fixed constant).
- `FeeDistributor` keeps mutability where required (`totalFeeBPS`, `setTier3FeeBPS`), with broader policy replacement done via module swaps.
   
## 3) Summary
- Deliver a security audit report focused on concrete exploitability (no speculative claims).
- Keep scope bounded to the listed liquid system contracts.
- Assume Uniswap and the `RARE` token are trusted and non-compromised for this pass.
- Exclude `RAREBurner` from this pass.
- Prioritize exploitability, business impact, and minimal patch surface.

## 4) Scope and Trust Assumptions
1. In-scope contracts:
   - `src/LiquidFactory.sol`
   - `src/LiquidSwapGuard.sol`
   - `src/LiquidGraduated.sol`
   - `src/LiquidMultiCurve.sol`
   - `src/LiquidRouter.sol`
   - `src/LiquidAuctioneer.sol`
   - `src/FeeDistributor.sol`
   - `src/BeneficiaryRegistry.sol`
   - `src/interfaces/IFeeDistributor.sol`
   - `src/interfaces/IBeneficiaryRegistry.sol`
2. Out-of-scope for this pass:
   - `RAREBurner` and any unlisted helper/infra contracts.
3. Trust assumptions:
   - External Uniswap dependencies are trusted and bug-free for this audit.
   - `RARE` token is trusted.
   - `owner` is trusted unless explicitly broken by code-path analysis.
   - `protocolFeeRecipient` is trusted unless explicitly broken by code-path analysis.
4. Severity scale:
   - Critical / High / Medium / Low / Informational.

## 5) Core Audit Questions
1. Can an attacker drain funds or mint unauthorized claim rights via callback accounting defects?
2. Can privileged roles misconfigure contracts into unsafe states via bad module swaps or stale module pointers?
3. Are any administrative functions improperly permissioned? 
4. Can route policy and route-data validation be bypassed to alter intended execution flow?
5. Can fee logic be manipulated through rounding, recipient misdirection, or transfer-failure fallback behavior?
6. Can beneficiary mapping/writer controls be abused to divert fee flow or lock funds?
7. Can unauthorized governance actions produce unsafe immutability assumptions (e.g., zero / wrong module addresses)?
8. Can users be denied service through state-lock conditions, hooks, or pool-id/initialization assumptions?
9. Are rescue/governance override paths sufficiently constrained and auditable?
10. Can swap guard hook be manipulated to permanently brick all pools? 

## 6) Audit Procedure (Execution Order)
1. Static threat mapping pass by attack path
   - Map every external entry and outbound call in:
     - `LiquidFactory.sol`
     - `LiquidRouter.sol`
     - `LiquidAuctioneer.sol`
     - `LiquidSwapGuard.sol`
     - `LiquidMultiCurve.sol`
     - `LiquidGraduated.sol`
     - `FeeDistributor.sol`
     - `BeneficiaryRegistry.sol`
2. Control-flow and trust boundary review
   - Trace user-originated calls and callback origin checks.
   - Verify module handoff assumptions around protocol recipient and beneficiary resolution.
3. Token accounting and balance-delta validation
   - Trace ETH/token deltas per buy/sell/swap/bid path including fees.
   - Validate exact-balance checks, refund behavior, and stale-payment edge cases.
   - Include failure path accounting where transfers fall back to protocol recipient.
4. Route/command-policy validation
   - Verify every `RoutePolicy` gate in `LiquidRouter` and `LiquidAuctioneer`.
   - Confirm malformed commands cannot bypass action constraints or recipient controls.
5. Permission and configurability audit
   - Review all owner/admin setters and module-pointer transitions.
   - Validate what is immutable by design (`FeeDistributor` protocol recipient) versus mutable via module swap.
   - Verify writer allowlists and owner permissions in `BeneficiaryRegistry`.
6. Cross-contract consistency checks
   - Ensure factory config assumptions align with `LiquidRouter`/`LiquidAuctioneer` behavior.
   - Verify all modules are consistently consumed from active pointers.
7. Compile-time and fuzz-level risk review
   - Inspect edge ranges, zero-value paths, rounding boundaries, and unchecked math expectations.
8. Produce findings and fix proposals
   - For each issue: impact, reproducible sequence, minimal patch, and test cases.

## 7) Findings Framework
1. Each issue entry format:
   - `Title`, `Severity`, `Contract:function`, `Preconditions`, `Attack Sequence`, `Impact`, `Root Cause`, `Minimal Fix`, `Proof Test`.
2. Only include findings tied to concrete state changes or fund movement.
3. Provide reproducibility assumptions:
   - attacker role (EOA/owner/bot/route manager),
   - required preconditions,
   - whether issue is permissioned or permissionless.

## 8) Per-Contract Review Checklist
1. `src/LiquidFactory.sol`
   - clone deployment safety for deterministic salt and factory callback assumptions
   - pool/token initialization invariants and upgradeability assumptions
   - mutable configuration setters and ownership boundaries
2. `src/LiquidSwapGuard.sol`
   - `beforeSwap`/`beforeInitialize` caller chain checks
   - `setFactory` transition semantics and one-time protections
   - hook verification assumptions for non-initialized pools
3. `src/LiquidGraduated.sol`
   - init flow (`poolId` and hook registration expectations)
   - token minting distribution, vesting/supply checks, migration ownership path
4. `src/LiquidMultiCurve.sol`
   - curve parameter math and overflow safety
   - position creation/unwind consistency after callbacks
   - swap/initialize/remove-liquidity callback reentrancy and ordering
5. `src/LiquidRouter.sol`
   - route entry/exit handling for direct swap/buy/sell paths and route policy
   - module pointer safety (`setFeeDistributor`, `setBeneficiaryRegistry`)
   - fallback/revert behavior when distribution module reverts unexpectedly
   - token rescue and ETH rescue governance boundary
6. `src/LiquidAuctioneer.sol`
   - route and bid-path policy assumptions
   - bidder flow, exit accounting, and callback ordering
   - module-backed protocol recipient/beneficiary trust boundaries
   - transferability under edge route/recipient outputs
7. `src/FeeDistributor.sol`
   - immutable protocol recipient and bootstrap guardrails
   - mutability boundaries (`setTotalFeeBPS`, `setTier3FeeBPS`) and their safety checks
   - beneficiary/rule splitting, rounding, fallback transfer behavior
   - zero-value and misrouting transfer outcomes
8. `src/BeneficiaryRegistry.sol`
   - writer allowlist controls and ownership separation
   - mapping mutation safety and zero-address handling
   - dependency on module wiring in router/auctioneer

## 9) Minimal Testable Fixes to Prepare
1. Add explicit invariants and negative tests for:
   - unauthorized config mutation
   - unauthorized module swaps and stale module reads
   - route recipient shape rejection
   - malformed multi-route payloads
   - unauthorized beneficiary writes
2. Add unit tests for boundary inputs:
   - zero input, exact-fee input, tiny fee/rounding cases
   - refund-gated paths and unexpected ETH forwarding
3. Add regression tests for callback accounting:
   - expected final-token and final-ETH deltas equal to computed requirements
4. Add governance safety tests:
   - owner-only transitions and event visibility
   - immutable module config assumptions and module replacement safety
5. Add integration tests for factory->pool->router flows:
   - `create` + trade path + auctioneer path under minimal liquidity and post-unwind scenarios

## 10) Public/API/Type Changes
1. Keep interface boundaries explicit and auditable across module seams.
2. Prefer module-level configuration changes over inline logic mutation:
   - `setFeeDistributor` and `setBeneficiaryRegistry` transitions
   - `FeeDistributor` constructor-bound immutable recipient/economic invariants
3. Ensure sensitive transitions emit stable events with old/new module addresses.
4. Keep behavior changes minimal:
   - prefer stricter validation and safer guards over broad architectural rewrites.

## 11) Acceptance Criteria
1. Zero critical issues accepted without explicit justification and compensating controls.
2. All high findings include PoC-level test path and exact minimal fix.
3. All medium/low findings include clear exploit impact and concrete reproduction.
4. No recommendations that only apply under assumptions violating stated trust model.
5. Final report contains remediation priority and expected risk reduction per finding.

## 12) Assumptions and Defaults
1. Gas-cost optimization is not a security objective unless it creates DoS/leak vectors.
2. Protocol economics adjustments are in-scope only if they create direct fund-loss or fund-lock risk.
3. `owner` is trusted unless explicitly broken by code-path analysis.
4. All fixes must be deploy-safe and compatible with existing storage layout where upgrade mechanics already exist.
5. For fee policy changes, module replacement is the intended operational pattern; inline mutable setters are intentionally minimized.
