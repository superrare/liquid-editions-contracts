# Liquid Recovery Playbook

This document captures operational failure modes and recovery actions for the deployed system.

## Scope

- src/LiquidFactory.sol
- src/LiquidRouter.sol
- src/LiquidAuctioneer.sol
- src/LiquidSwapGuard.sol
- src/FeeDistributor.sol
- src/BeneficiaryRegistry.sol
- src/LiquidFeeLib.sol
- script/config/NetworkConfig.sol
- script/DeployLiquidSystem.s.sol

## 1) Recovery posture

### 1.1 Recoverable on-chain (no redeploy)

- LiquidRouter: `setUniversalRouter`, `setRareBurner`, `setFeeDistributor`, `setBeneficiaryRegistry`, `pause`, `unpause`, `setTrustedFactory`, `updateBeneficiary`, `removeToken`, `setAllowlistEnabled`
- LiquidAuctioneer: `setUniversalRouter`, `setRareBurner`, `setFeeDistributor`, `setBeneficiaryRegistry`, `pause`, `unpause`, `setBeneficiary`
- LiquidSwapGuard: `setFactory`, `addRouter`, `addCaller`, `removeRouter`, `removeCaller`, `allowlist`
- LiquidFactory: `pause`, `unpause`, `setLiquidRouter`, `setPoolHooks`, `setProtocolFeeRecipient`, `setCcaFactory`, `setLbpStrategyFactory`, `setPositionManager`, fee/market constants
- Rescue: `rescueTokens`, `rescueETH` on router/auctioneer when safe and justified

### 1.2 Hard-stop / hard migration

- Hard migration is limited to:
  - Recovery key loss/compromise of owner/governance control on `LiquidRouter`, `LiquidAuctioneer`, `LiquidSwapGuard`, or `FeeDistributor`.
  - Critical module corruption with no safe setter-based recovery path, for example:
    - FeeDistributor logic that permanently reverts in `distributeFees` and cannot be rotated because dependency ownership/control is unavailable.
    - A pointer swap would land on an incompatible/incorrect module interface and lock all critical flows.
    - Severe on-chain data/state corruption in a module that makes operational validation or emergency rollback impossible.

## 2) Fast incident playbooks

### A) Protocol fee recipient compromised or cannot receive ETH

Note: this path is intentional and the protocol is designed around module replacement for fee policy and recipients.
`FeeDistributor` itself is immutable, but router/auctioneer pointers are replaceable (`setFeeDistributor` in both contracts).

Impact:
1. Router/Auctioneer: fee distribution is delegated to `FeeDistributor.distributeFees`, which reverts trades if protocol recipient transfer fails (`EthTransferFailed`).
2. Protocol recipient is immutable in the active `FeeDistributor` constructor and cannot be changed in-place.

Immediate response (2-minute decision tree):
1. Check if only recipient destination is bad (wrong key, compromised key, temporary ETH-receive issue):
   - Yes: pause (if needed), deploy replacement `FeeDistributor` with corrected recipient, then rotate via `setFeeDistributor(newFeeDistributor)` on router and/or auctioneer, run smoke test, then unpause.
2. If recipient contract or distribution logic is bad (`distributeFees` failure not resolved by recipient replacement):
   - Deploy a replacement `FeeDistributor` and call `setFeeDistributor(newFeeDistributor)` on router and/or auctioneer.
3. If new module unavailable or suspect module corruption:
   - escalate to dependency migration/deployment recovery and stop broad trading until redeploy plan is approved.

Router recovery:
1. Pause the router if incident scope is large.
2. Confirm replacement `FeeDistributor` has correct `protocolFeeRecipient`, `totalFeeBPS`, and expected tier splits.
3. Call `setFeeDistributor(newFeeDistributor)` on router.
4. Smoke test `buy`/`sell` and confirm `EthTransferFailed` stops and protocol fee event accounting is correct.
5. Unpause only after healthy validation.

Auctioneer recovery:
1. Confirm on-chain recipient mismatch in auctioneer config.
2. Call `setFeeDistributor(newFeeDistributor)` on auctioneer.
3. Smoke the CCA flow and confirm fee split continues.

Shared cleanup:
1. Audit recent fee events for abnormal protocol/beneficiary/burn accounting.
2. Verify `feeDistributor().protocolFeeRecipient()` on both router and auctioneer match intended recipient expectations.
3. Rescue stuck ETH only under documented incident SOP (`rescueETH`).
4. Record recipient ownership and postmortem action items.

### B) Fee policy or distribution module issues

1. Compare `TOTAL_FEE_BPS()`, `protocolFeeBPS()`, `rareBurnFeeBPS()`, and `referrerFeeBPS()` on router and auctioneer.
2. Confirm `feeDistributor()` and `beneficiaryRegistry()` point to expected modules and owners are controlled.
3. If fees are mis-priced, a new leg is required, or distribution starts failing, this is intentionally handled by module migration: deploy a replacement `FeeDistributor` and call `setFeeDistributor(newFeeDistributor)` on `LiquidRouter` and `LiquidAuctioneer`.
4. Verify calls on replacement by running a small `buy`/`sell` smoke flow.
5. If only beneficiary attribution is wrong, validate `beneficiaryRegistry()` and the per-token entries.
6. If registry writes are blocked or data is corrupted, rotate with `setBeneficiaryRegistry(newRegistry)`.

### C) Swaps break after chain integration changes

1. Verify router `universalRouter` points to the intended chain address.
2. On router, call `setUniversalRouter(correctAddr)`.
3. Run a small `buy`/`sell` smoke test.

### D) Auctioneer cannot route after chain integration changes

1. Verify `universalRouter` on the auctioneer is the intended chain/router address.
2. On auctioneer, call `setUniversalRouter(correctAddr)`.
3. Validate auction swap/redeem flows before broadening traffic.

### E) RARE burn is misrouted or not working

1. Confirm current `rareBurner` on router and test `IRAREBurner.depositForBurn`.
2. On router, call `setRareBurner(newBurner)`.
3. Run smoke trades and validate burn/event accounting.

### F) Beneficiary attribution issues

1. Check whether `beneficiaryRegistry()` is expected on router and auctioneer.
2. Fix individual token mapping using `updateBeneficiary` (router) / `setBeneficiary` (auctioneer) when possible.
3. If module-level mapping is broken, rotate `setBeneficiaryRegistry(newRegistry)`.
4. Confirm call path with registration and one trade/auction smoke test.

### G) Control-plane coupling drift between factory / router / swap guard

1. Impact: `setPoolHooks`, `setLiquidRouter`, `setTrustedFactory`, and swap-guard allowlists must match chain-wide.
2. Impact detail:
   - `LiquidFactory.setPoolHooks` requires `LiquidSwapGuard.factory()` to match.
   - `LiquidSwapGuard` must allow the active Universal Router + `LiquidRouter` caller.
   - `LiquidRouter` must trust the same factory and that factory must point back to it.
3. Failure effect: launches may succeed but swaps fail, or pool init may fail because hooks reject.
4. Recovery:
   - Pause router/auctioneer first if the blast radius is broad.
   - Rebind `setFactory`, `addRouter`, `addCaller` on guard.
   - Align `LiquidFactory.setLiquidRouter` and `LiquidRouter.setTrustedFactory`.
   - Validate with one non-critical launch and one secondary swap smoke test.

### H) New token launch blocked at registration

1. Check `LiquidFactory` trusted wiring with router (`setTrustedFactory`).
2. Confirm token creator/beneficiary constraints (`registerToken`) are valid.
3. Verify allowlist and beneficiary settings.

### I) New pool pre-init blocked

1. Verify `poolHooks` and `LiquidSwapGuard.factory()` match.
2. If needed, update guard via `LiquidSwapGuard.setFactory`.
3. Call `LiquidFactory.setPoolHooks(guard)` and validate a test launch path.

### J) CCA auction cannot start

1. Confirm `lbpStrategyFactory`, `positionManager`, `protocolFeeRecipient`, and `ccaFactory` are configured.
2. Verify factory protocol recipient and beneficiary config.

### K) Beneficiary writer is compromised or disabled in BeneficiaryRegistry

1. Impact:
   - `BeneficiaryRegistry.setWriter` is owner-controlled; bad writer keys can redirect or block future beneficiary writes.
2. Recovery:
   - Pause router/auctioneer if ongoing beneficiary-sensitive flows are live.
   - For known bad tokens, patch per-token mappings (`updateBeneficiary` on router, `setBeneficiary` on auctioneer).
   - If registry trust is broken, deploy a replacement registry and rotate:
     - `LiquidRouter.setBeneficiaryRegistry(newRegistry)`
     - `LiquidAuctioneer.setBeneficiaryRegistry(newRegistry)`
   - Replay known beneficiary mappings and validate `buy`/`bid` accounting with a smoke flow.

### L) Auctioneer token->RARE route misconfiguration

1. Impact:
   - `LiquidAuctioneer` `bid` depends on per-token route presets.
   - Any bad `setTokenRouteV4/V3/V2` config, bad path, or stale hook/tick config causes `InvalidPresetRoute`.
2. Recovery:
   - Pause `LiquidAuctioneer`.
   - Correct preset for affected token(s) with `setTokenRouteV4/V3/V2` or `removeTokenRoute`.
   - Verify with targeted `bid` flows before unpause.

### M) Allowlist mismatch in LiquidSwapGuard

1. Impact:
   - Wrong `verifiedRouters` or `allowedCallers` entries immediately blocks swaps.
   - This is intended as fail-closed behavior.
2. Recovery:
   - Pause impacted paths.
   - Re-add missing entries with `addRouter` and `addCaller`.
   - Remove stale entries and run token launch + swap smoke tests.
   - Reconcile `setFactory` binding when guard/factory pairing drifted.

### N) LiquidSwapGuard systemic failure (all guarded pools impacted)

1. Impact:
   - If `LiquidSwapGuard` breaks (bad configuration, compromised owner, or bad initialization), every market using it at the hook level can stall.
   - Existing pools are already bound to a hook at pool creation and cannot be retroactively rebound to a replacement guard.
   - This creates two impact classes:
      - **Future pools:** blocked or misconfigured during creation via `LiquidFactory.setPoolHooks`.
      - **Existing pools:** swap path blocked while hook still points to faulty guard.
2. Recovery for immediate safety:
   - Pause router and/or auctioneer to freeze outbound liquidity flow if blast radius is broad.
   - Use guarded-owner controls to repair:
      - `LiquidSwapGuard.setFactory`
      - `LiquidSwapGuard.addRouter` / `removeRouter`
      - `LiquidSwapGuard.addCaller` / `removeCaller`
   - Verify the restored allowlist and factory pairing, then run a controlled create + swap smoke test.
3. Recovery for liquidity and continuity:
   - Liquidity in **existing guard-bound Instant/MultiCurve pools**:
      - `protocolFeeRecipient` (PFR) can call token-level `removeLiquidity(recipient)` on each token market to unwind LP from the current pool.
      - This is the only direct on-chain way to recover LP from those markets.
   - Liquidity in **Graduated markets**:
      - `removeLiquidity` is not supported at token level (`LiquidGraduated` intentionally reverts).
      - Recovery depends on strategy/position-manager governance flows and is not covered by swap-guard owner controls.
   - `LiquidFactory.setPoolHooks` only affects future deployments, so continuity requires:
      - deploy replacement guard safely (factory owner),
      - update factory hooks,
      - launch replacement markets,
      - and communicate migration steps for users/LP to move to new markets.
4. Who can move, repair, and migrate:
   - `LiquidSwapGuard` owner/admin: can fix allowlists and factory binding.
   - `LiquidFactory` owner: can only affect future markets via `setPoolHooks`, `pause`, and `unpause`.
   - `protocolFeeRecipient`: can unwind LP only on Instant/MultiCurve via `removeLiquidity`.
   - Users: must migrate to new markets through announced off-chain coordination once replacement markets are live.

## 3) Pre-change guardrails

- Before changing protocol recipient (by replacing `FeeDistributor`): verify the new recipient is non-zero, under owner control, and can receive ETH; decide on pause strategy; broadcast/change plan with event IDs.
- Before changing universal router (`setUniversalRouter` on router or auctioneer): validate command compatibility and run a smoke test.
- Before changing fee module (`setFeeDistributor`): verify distributor interface compatibility, ownership state, that this module replacement is the intended fee policy shape (including any new/removed legs), and smoke fee breakpoints (`totalFeeBPS`, `setTier3FeeBPS` assumptions).
- Before changing protocol recipient, confirm the active `feeDistributor()` on the target contract is the expected one and owned by trusted governance.
- Before changing beneficiary module (`setBeneficiaryRegistry`): verify new module can read/write expected token beneficiaries and writer policy is aligned.
- Before changing burn target (`setRareBurner`): verify `depositForBurn()` behavior and confirm protocol recipient can absorb redirected burn value if deposits fail.
- Before guard/factory rotation: confirm expected `swapGuard`/`factory` binding and validate `setPoolHooks` with a test launch path after rotation.
- Before changing factory live-state: define whether stop is for launches only (pause) vs trading controls too, and predefine unpause success criteria.

## 4) Operational note

Treat these setters as sensitive control-plane operations. Route through hardened governance (multisig/timelock), require explicit approval evidence, and complete pre-production smoke tests before returning systems to full traffic.
