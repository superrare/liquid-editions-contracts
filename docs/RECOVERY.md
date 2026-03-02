# Liquid Recovery Playbook

This document captures operational failure modes and recovery actions for the deployed system.

## Scope

- src/LiquidFactory.sol
- src/LiquidRouter.sol
- src/LiquidGuard.sol
- src/LiquidMigrationExecutor.sol
- src/LiquidRegistry.sol
- src/FeeDistributor.sol
- src/LiquidMultiCurve.sol
- src/LiquidInstant.sol
- script/config/NetworkConfig.sol
- script/DeployLiquidSystem.s.sol

## 1) Recovery posture

### 1.1 Recoverable on-chain (no redeploy)

- LiquidRouter: `setLiquidRegistry`, `addCurrency`, `removeCurrency`, `setUniversalRouter`, `pause`, `unpause`, `rescueTokens`, `rescueETH`
- LiquidFactory: `pause`, `unpause`, `setLiquidRegistry`, `setPoolHooks`, `setPoolManager`, `setBaseToken`, `setProtocolFeeRecipient`, `setCcaFactory`, `setLbpStrategyFactory`, `setMigrationExecutor`, `setLiquidInstantImplementation`, `setLiquidMultiCurveImplementation`, `setLiquidGraduatedImplementation`, `setPoolTickSpacing`, `setMinRareLiquidityWei`, `setLpTickLower`, `setLpTickUpper`
- LiquidMigrationExecutor: `setProtocolVault`, `setLiquidRegistry`, `approveHook`, `setAllowedTickSpacing`, `setAllowedFee`, `transferOwnership`
- LiquidGuard: `setFactory`, `setFeeDistributor`, `addInitializer`, `removeInitializer`
- LiquidRegistry: `setWriter`, `setBeneficiary`, `removeBeneficiary`
- FeeDistributor: `setRareEthPoolKey`, `setMaxSlippageBps`, `setConversionEnabled`, `setBeneficiaryShareBPS`, `setBeneficiaryRegistry`, `setHookApproval`

### 1.2 Hard-stop / hard migration

- Hard migration is limited to:
  - Loss/compromise of owner/governance control on `LiquidRouter`, `LiquidFactory`, `LiquidMigrationExecutor`, `LiquidGuard`, `LiquidRegistry`, or `FeeDistributor`.
  - Immutable policy state changes in `FeeDistributor` that cannot be fixed by setter calls (`totalFeeBPS`, constructor-level recipient/context assumptions).
  - Corruption of invariant-critical state that cannot be repaired by setter recovery (eg. unrecoverable storage/owner-loss scenarios in the active deployment).
- There is no router-side burn control path in this scope; burn/receiver-specific recovery is intentionally out of this plan.

### 1.3 What this runbook cannot fix immediately (with documented mitigation)

- Full key compromise of all available owners/governance accounts for an affected module (system security must be restored out-of-band before operational recovery can proceed).
- Irreversible contract-code assumptions:
  - Immutable fields and constructor-time behavior in `FeeDistributor` (`totalFeeBPS` / constructor context).
  - Any code-level bug in deployed bytecode.
- Corruption outside module control boundaries (chain reorg/extreme RPC fork, L1/L2 infrastructure failure, third-party protocol outages).
- `FeeDistributor` already settled protocol fees to a recipient before controls are applied; settled transfers cannot be clawed back on-chain.
  - Forward fix:
    - rotate recipient flow by replacing `FeeDistributor` and re-wiring via `LiquidGuard.setFeeDistributor(newFeeDistributor)` and `FeeDistributor.setHookApproval(LiquidGuard, true)`.
  - Historical cleanup:
    - snapshot historic settlement events from the old distributor, then run off-chain reconciliation:
      - `cast logs --rpc-url $ETH_SEPOLIA --from-block <start> --to-block latest --address $FEE_DISTRIBUTOR "FeeConvertedAndDistributed(address,address,uint256,uint256,uint256,uint256)"`
      - `cast logs --rpc-url $ETH_SEPOLIA --from-block <start> --to-block latest --address $FEE_DISTRIBUTOR "FeeDistributedInRare(address,address,uint256,uint256,uint256,bytes32)"`
- `LiquidRegistry` bulk beneficiary migration is not one-shot on-chain:
  - Registry beneficiary storage is private mapping (`mapping(address => address)`), so there is no one-call replay.
  - remediation pattern:
    - deploy replacement registry only if needed and rewire `LiquidFactory` / `LiquidRouter` pointers first.
    - set `OLD_REGISTRY` to the compromised registry address.
    - reconstruct active token->beneficiary map from events:
      - `cast logs --rpc-url $ETH_SEPOLIA --from-block <start> --to-block latest --address $OLD_REGISTRY "BeneficiarySet(address,address,address)"`
      - `cast logs --rpc-url $ETH_SEPOLIA --from-block <start> --to-block latest --address $OLD_REGISTRY "BeneficiaryRemoved(address,address)"`
    - replay latest active pairs with `LiquidRegistry.setBeneficiary(token, beneficiary)` (owner/writer) and validate writes.
- Active Uniswap V4 pool hook replacement is not in-place:
  - hooks are immutable in existing pool keys; swap-to-new hook uses migration paths:
    - `LiquidMigrationExecutor.approveHook(newHook, true)`
    - execute controlled `executeMigration(plan)` for each affected token
    - confirm `MigrationExecuted` and run one smoke swap/bid check per migrated token

## 2) Fast incident playbooks

### 0) Rapid diagnostics and triage (`forge`, copy/paste)

```bash
source .env
forge script script/DiagnoseLiquidSystem.s.sol:DiagnoseLiquidSystem --rpc-url $ETH_SEPOLIA --slow
```

This resolves canonical module addresses from `NetworkConfig` for the target chain, applies env overrides (`FACTORY`, `ROUTER`, `LIQUID_GUARD`, `REGISTRY`, `FEE_DISTRIBUTOR`, `MIG_EXEC`, `TOKEN`, etc.), and prints all important read-only state in one pass.

If diagnostics output `DIAG:`:
- `Factory.poolHooks() != LiquidGuard` => section G/N
- `Guard.factory() != Factory` => section G/N
- `Router.liquidRegistry() != Factory.liquidRegistry()` => section H/J/K
- `Registry.isWriter(Factory) == false` => section H/K
- fee distributor wiring or `approvedHooks` mismatch => section A/B
- migration policy mismatch => section D
- token `poolKey` mismatch => section I/L

### 0b) Partial-system rebuild with `DeployLiquidSystem.s.sol` (when manual setter repair is too broad)

Use the deployer when the incident spans multiple control-plane boundaries (for example fee-policy + wiring, guard+registry rewiring, or fresh factory initialization recovery).

- `DEPLOY_LIQUID_REGISTRY=true`  
  - deploys a new `LiquidRegistry` and reconnects router/factory references where owner allows.
- `DEPLOY_FACTORY=true`  
  - deploys a fresh `LiquidFactory` + `liquidInstantImplementation`, `liquidMultiCurveImplementation`, `liquidGraduatedImplementation`.
- `DEPLOY_ROUTER=true`  
  - deploys `LiquidRouter` + implementation and sets registry + universal router + currency whitelist.
- `DEPLOY_LIQUID_GUARD=true`  
  - deploys `LiquidGuard` and a replacement `FeeDistributor`, then attempts guard-factory/fee rewiring.
- `DEPLOY_FEE_DISTRIBUTOR=true`  
  - deploys a replacement `FeeDistributor` only (non-guard module replacement path).
- `DEPLOY_MIGRATION_EXECUTOR=true`  
  - deploys `LiquidMigrationExecutor` and wires factory governance/approvals.

Legacy/off-path modules (`DEPLOY_AUCTIONEER`, `DEPLOY_SWAP_GUARD`, `DEPLOY_INIT_GUARD`, `DEPLOY_BURNER`) are out of scope for this runbook and should be treated as advanced recovery only.

Runbook mapping:
- Use `DEPLOY_LIQUID_GUARD=true` for section A/B when fee module is wrong/immutable in active guard mode.
- Use `DEPLOY_MIGRATION_EXECUTOR=true` for section D.
- Use `DEPLOY_FACTORY=true` for sections H/I/J where launch path needs fresh pointering or missing implementations.
- Use `DEPLOY_LIQUID_REGISTRY=true` + `DEPLOY_FACTORY=true` for section K/H writer/registration coupling.
- Use `DEPLOY_ROUTER=true` for section C only when router pointer and rebind plus currency set are also needed together.

Execution pattern:

```bash
source .env
export DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY:-$PRIVATE_KEY}"
export CHAIN_ID=1                # optional; omit to use block.chainid

# Rebuild active fee path in LiquidGuard mode (replaces guard + fee module)
unset DEPLOY_FACTORY DEPLOY_ROUTER DEPLOY_MIGRATION_EXECUTOR DEPLOY_FEE_DISTRIBUTOR DEPLOY_LIQUID_REGISTRY
export DEPLOY_LIQUID_GUARD=true
forge script script/DeployLiquidSystem.s.sol:DeployLiquidSystem \
  --rpc-url $MAINNET_RPC_URL --slow --broadcast --verify
```

```bash
source .env
export DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY:-$PRIVATE_KEY}"

# Recreate factory + implementations, then rewire hooks/registry
export DEPLOY_FACTORY=true
forge script script/DeployLiquidSystem.s.sol:DeployLiquidSystem \
  --rpc-url $MAINNET_RPC_URL --slow --broadcast --verify
```

```bash
source .env
export DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY:-$PRIVATE_KEY}"

# Refresh migration policy executor only
export DEPLOY_MIGRATION_EXECUTOR=true
forge script script/DeployLiquidSystem.s.sol:DeployLiquidSystem \
  --rpc-url $MAINNET_RPC_URL --slow --broadcast --verify
```

When `false`-default flags must keep existing modules, pass explicit `false`:

```bash
export DEPLOY_LIQUID_GUARD=false
export DEPLOY_FACTORY=false
export DEPLOY_ROUTER=false
export DEPLOY_FEE_DISTRIBUTOR=false
export DEPLOY_MIGRATION_EXECUTOR=false
export DEPLOY_LIQUID_REGISTRY=false
```

Hard requirement: confirm pre-run that override addresses exist if you are *not* redeploying modules (`LIQUID_REGISTRY`, `FEE_DISTRIBUTOR` etc). The script will fail fast when dependencies are missing.

### 0c) Forge-driven NetworkConfig read (preferred for canonical addresses)

If you want diagnostics and fixes to source addresses from `script/config/NetworkConfig.sol` instead of maintaining duplicate env values:

```bash
CHAIN_ID=11155111 \
forge script script/ReadNetworkConfig.s.sol:ReadNetworkConfig --rpc-url $RPC_URL
```

For machine-parseable output you can generate shell variables and source them:

```bash
MACHINE_OUTPUT=true CHAIN_ID=11155111 \
forge script script/ReadNetworkConfig.s.sol:ReadNetworkConfig --rpc-url $RPC_URL > /tmp/network-config.env
source /tmp/network-config.env
```

Set `CHAIN_ID` explicitly if you want deterministic chain selection in scripts.

Copy/paste fixes (manual, one-off):

```bash
# Fix control-plane wiring
cast send --private-key $PRIVATE_KEY --rpc-url $MAINNET_RPC_URL $FACTORY "setPoolHooks(address)" $GUARD
cast send --private-key $PRIVATE_KEY --rpc-url $MAINNET_RPC_URL $GUARD "setFactory(address)" $FACTORY
cast send --private-key $PRIVATE_KEY --rpc-url $MAINNET_RPC_URL $ROUTER "setUniversalRouter(address)" $UNIVERSAL_ROUTER
cast send --private-key $PRIVATE_KEY --rpc-url $MAINNET_RPC_URL $FACTORY "setLiquidRegistry(address)" $REGISTRY

# Fix fee module wiring
cast send --private-key $PRIVATE_KEY --rpc-url $MAINNET_RPC_URL $GUARD "setFeeDistributor(address)" $FEE_DISTRIBUTOR
cast send --private-key $PRIVATE_KEY --rpc-url $MAINNET_RPC_URL $FEE_DISTRIBUTOR "setHookApproval(address,bool)" $GUARD true

# Fix migration executor controls
if [ -n "${MIG_EXEC:-}" ]; then
  cast send --private-key $PRIVATE_KEY --rpc-url $MAINNET_RPC_URL $MIG_EXEC "transferOwnership(address)" $NEW_OWNER
  cast send --private-key $PRIVATE_KEY --rpc-url $MAINNET_RPC_URL $MIG_EXEC "setLiquidRegistry(address)" $REGISTRY
  cast send --private-key $PRIVATE_KEY --rpc-url $MAINNET_RPC_URL $MIG_EXEC "approveHook(address,bool)" $TARGET_HOOK true
  cast send --private-key $PRIVATE_KEY --rpc-url $MAINNET_RPC_URL $MIG_EXEC "setAllowedFee(uint24,bool)" $TARGET_FEE true
  cast send --private-key $PRIVATE_KEY --rpc-url $MAINNET_RPC_URL $MIG_EXEC "setAllowedTickSpacing(int24,bool)" $TARGET_TICK_SPACING true
  cast send --private-key $PRIVATE_KEY --rpc-url $MAINNET_RPC_URL $MIG_EXEC "setProtocolVault(address)" $NEW_PROTOCOL_VAULT
fi
```

### A) Protocol fee recipient compromised or cannot receive ETH

`FeeDistributor` is the active fee policy and routing module for active swaps.

Impact: recipient misrouting or ETH/beneficiary flow cannot complete.

Immediate response:
1. Identify active fee path:
   - Confirm `LiquidFactory.poolHooks()` points to an active fee-collection configuration.
   - If `LiquidFactory.poolHooks()` is `LiquidGuard`, swap fees flow through `LiquidGuard -> FeeDistributor`.
2. Readback checks:
   - `LiquidFactory.poolHooks()`
   - `LiquidGuard.feeDistributor()` (if guard is active)
   - `FeeDistributor.protocolFeeRecipient()`
   - `FeeDistributor.beneficiaryRegistry()`
   - `FeeDistributor.conversionEnabled()`
   - `FeeDistributor.maxSlippageBps()`
   - `FeeDistributor.approvedHooks(LiquidGuard)` where applicable
3. If only the recipient is bad (`protocolFeeRecipient` mismatch or cannot receive ETH):
   - Deploy replacement `FeeDistributor` with the corrected recipient context.
   - In `LiquidGuard` mode: `LiquidGuard.setFeeDistributor(newFeeDistributor)`, then `FeeDistributor.setHookApproval(LiquidGuard, true)`.
4. If routing mismatch appears to be broader than one beneficiary:
   - Pause trading paths, repair fee distributor pointers, then continue at Step 5.
5. Smoke checks:
   - one `LiquidRouter.buy` or `sell`
   - one low-value launch path relevant to the affected market class
6. Unpause only after:
   - recipient accepts ETH,
   - fee-events indicate expected route behavior (`FeeConvertedAndDistributed` or `FeeDistributedInRare`),
   - no unexpected fee reverts.

### B) Fee policy or distribution module issues

1. Read state before action:
   - `LiquidFactory.poolHooks()`
   - `LiquidGuard.feeDistributor()`
   - `FeeDistributor.maxSlippageBps()`
   - `FeeDistributor.conversionEnabled()`
   - `FeeDistributor.beneficiaryRegistry()`
   - `FeeDistributor.protocolFeeRecipient()`
   - `FeeDistributor.approvedHooks(LiquidGuard)`
2. Interpret live conversion behavior:
   - `STALE_PRICE`: conversion input is too old / stale and falls back.
   - `CONVERT_FAIL`: execution failed and falls back to RARE routing.
   - `NO_KEY`: no usable conversion pool key exists.
3. If recovery is policy tuning only:
   - Use `FeeDistributor.setMaxSlippageBps`, `setConversionEnabled`, `setBeneficiaryShareBPS`, `setBeneficiaryRegistry`.
4. If policy mismatch is structural:
   - Deploy replacement `FeeDistributor` (for immutable mismatches or irreversible policy drift).
   - `LiquidGuard.setFeeDistributor(newFeeDistributor)`.
   - `FeeDistributor.setHookApproval(LiquidGuard, true)`.
5. Validation:
   - smoke one buy/sell path and confirm distribution event stream:
     - conversion expected: `FeeConvertedAndDistributed`
     - fallback expected: `FeeDistributedInRare`

### C) Swaps break after chain integration changes

1. Verify `universalRouter` on `LiquidRouter` points to intended chain router address.
2. Repoint with `LiquidRouter.setUniversalRouter(correctAddr)` if needed.
3. If route coupling is broken, check `LiquidFactory.poolHooks()` and `LiquidGuard.factory()` alignment.
4. Run smoke:
   - `LiquidRouter.buy`
   - `LiquidRouter.sell`
   - `LiquidRouter.swap`
5. Recheck fee path from section B if any `FeeDistributor` conversion changes are observed.

### D) Migration executor governance/policy drift

Impact: migrations are blocked or can execute under wrong policy constraints.

1. Confirm active coupling:
   - `LiquidFactory.migrationExecutor()`
   - `LiquidMigrationExecutor.owner()`
   - `LiquidMigrationExecutor.liquidRegistry()`
   - `LiquidMigrationExecutor.protocolVault()`
2. Verify execution allowlists for intended migration paths:
   - `LiquidMigrationExecutor.approvedHooks(targetHook)`
   - `LiquidMigrationExecutor.allowedFees(fee)`
   - `LiquidMigrationExecutor.allowedTickSpacings(tickSpacing)`
3. If owner is stale or compromised:
   - `LiquidMigrationExecutor.transferOwnership(newOwner)` (two-step if using Ownable2Step)
4. If `liquidRegistry` is stale:
   - `LiquidMigrationExecutor.setLiquidRegistry(correctRegistry)`
5. If hook/frequency policy is blocking execution:
   - `LiquidMigrationExecutor.approveHook(hook, true/false)`
   - `LiquidMigrationExecutor.setAllowedFee(fee, true/false)`
   - `LiquidMigrationExecutor.setAllowedTickSpacing(tickSpacing, true/false)`
6. If vault routing is wrong:
   - `LiquidMigrationExecutor.setProtocolVault(newProtocolVault)`
7. Smoke:
   - execute or simulate one controlled migration and verify `MigrationExecuted`.

### E) Non-core route paths (out of scope)

Not in this pass: non-core route/receiver edge cases are intentionally excluded from this pass.

### F) Beneficiary attribution issues

1. Verify source of truth:
   - `LiquidRegistry.beneficiaryOf(token)`
   - `LiquidRegistry.isRegistered(token)`
2. Prefer registry-path fix:
   - `LiquidRegistry.setBeneficiary(token, beneficiary)`
3. Align fee beneficiary module:
   - `FeeDistributor.beneficiaryRegistry()`
   - if needed: `FeeDistributor.setBeneficiaryRegistry(sharedRegistry)`
4. If token-local fee accounting is inconsistent immediately:
   - run one smoke path for the affected token and confirm `LiquidRegistry.beneficiaryOf(token)` updates and on-chain accounting movement.

### G) Control-plane coupling drift between factory / guard / router

Impact: launch and/or swap paths stall if these pointers disagree.

1. Verify architecture mode:
   - `LiquidFactory.poolHooks()` should be set to `LiquidGuard`.
2. In all modes:
   - verify `LiquidFactory.poolHooks()` points to intended hook.
3. In `LiquidGuard` mode:
   - verify `LiquidGuard.factory() == LiquidFactory`
4. If stale:
   - `LiquidFactory.setPoolHooks(...)`
   - `LiquidGuard.setFactory(...)`
6. Validate:
   - one controlled token create path
   - one non-critical swap smoke

### H) New token launch blocked at registration

1. Verify registration base:
   - `LiquidFactory.liquidRegistry()` points to intended `LiquidRegistry`.
   - `LiquidRegistry.isWriter(factory)` must be true.
2. If writer drift exists:
   - `LiquidRegistry.setWriter(factory, true)`
3. Verify launch dependencies:
   - `LiquidFactory.baseToken()`
   - `LiquidFactory.liquidInstantImplementation()`
   - `LiquidFactory.liquidMultiCurveImplementation()`
   - `LiquidFactory.liquidGraduatedImplementation()`
   - `LiquidFactory.implementations(...)` readiness (where deployed config uses it)
4. If any implementation pointer is zero:
   - set the missing implementation via the corresponding setter.
5. Pause only if required, then run one full token create smoke.

### I) New pool pre-init blocked

1. Verify active hook mode and writer coupling:
   - `LiquidFactory.poolHooks()`
   - `LiquidFactory.implementations(...)` for expected pool class
   - `LiquidFactory.liquidRegistry()` and `LiquidRegistry.isWriter(factory)`
2. Verify hook factory wiring:
   - `LiquidGuard.factory()`
3. Ensure initializer allowlist is aligned in active hook:
   - `LiquidGuard.addInitializer(token)`
4. If mismatch:
   - set correct `setFactory` on active guard
   - add initializer for the token
5. Retry controlled create path and confirm pre-init succeeds.

### J) CCA/LBP launch blocked by strategy controls

1. Verify strategy controls:
   - `LiquidFactory.setCcaFactory`
   - `LiquidFactory.setLbpStrategyFactory`
   - `LiquidFactory.setProtocolFeeRecipient` value
   - pool implementation pointers for affected class
2. Repair with:
   - `setCcaFactory`, `setLbpStrategyFactory`, `setProtocolFeeRecipient`
   - missing implementation pointers if this blocks launch
3. Verify registry writer path:
   - `LiquidRegistry.isWriter(factory)`
4. Smoke one controlled strategy launch start.

### K) Beneficiary writer is compromised or disabled in LiquidRegistry

1. Verify writer status for deployment-critical modules:
   - `LiquidRegistry.isWriter(factory)`
2. For compromised or missing writer:
   - `setWriter(badWriter, false)` where possible
   - `setWriter(address, true)` for the correct replacement writer
3. Re-run beneficiary repairs from section F and confirm writes for affected tokens now succeed.

### L) Out-of-band route issues (out of scope)

Not in this pass: route-only edge cases outside active `LiquidGuard` and migration/factory/registry recovery are temporarily excluded.

### M) Legacy guard mismatch (out of scope)

Legacy guard-mode recovery paths are intentionally out of scope in this pass. Handle via section G and section N only for active guard configuration.

### N) LiquidGuard systemic failure (all guarded pools impacted)

1. Determine active guard mode:
   - `LiquidFactory.poolHooks()` should point to `LiquidGuard`.
2. Recovery sequence:
   - focus on `LiquidFactory.setPoolHooks`, `LiquidGuard.setFactory`, and registry registration coupling.
   - Pause affected trading scope.
   - Repoint and clean stale entries.
   - Confirm hook approvals and registry writer status where launch continuity is required.
3. Liquidity continuity:
   - Instant/MultiCurve: token-level unwind path remains `removeLiquidity` (where supported).
4. New market continuity:
   - `LiquidFactory.setPoolHooks(...)` to a functioning hook path.
5. Validate: controlled create + swap smoke before broader restoration.

## 3) Pre-change guardrails

- Before touching fee distribution:
  - confirm active guard is `LiquidGuard` (`LiquidFactory.poolHooks()`).
  - validate `FeeDistributor` assumptions:
    - `protocolFeeRecipient()`
    - `beneficiaryRegistry()`
    - `conversionEnabled()`
    - `maxSlippageBps()`
    - `approvedHooks(LiquidGuard)`
    - immutability of `totalFeeBPS` and constructor-time configuration.
- Before touching control-plane wiring:
  - align in one pass: `setLiquidRegistry`, `setUniversalRouter`, `setPoolHooks`, active guard `setFactory`, `FeeDistributor` rewiring, registry `setWriter`.
  - re-read every touched field.
- Before changing launch wiring:
  - verify implementation pointers:
    - `liquidInstantImplementation`
    - `liquidMultiCurveImplementation`
    - `liquidGraduatedImplementation`
    - `implementations(...)` readiness (where used)
  - verify pool hook/factory coupling:
    - `LiquidFactory.poolHooks()` equals `LiquidGuard`
    - active guard `factory() == LiquidFactory`
- Before changing registry flows:
  - verify `LiquidRegistry.isWriter(factory)` and any other deployment writers you rely on for writes.
- Before changing migration controls:
  - verify `LiquidFactory.migrationExecutor()` points to the intended executor.
  - verify executor readbacks: `governance()`, `protocolVault()`, `liquidFactory()`.
  - verify execution policy: `approvedHooks(...)`, `allowedFees(...)`, `allowedTickSpacings(...)`.
- Post-change acceptance checks (minimum):
  - Router pointer changes: one `LiquidRouter` swap smoke.
  - Factory pointer changes: one controlled token create smoke.
  - Guard changes: run guard coupling smoke via `LiquidFactory.setPoolHooks` / `LiquidGuard.setFactory` path and `LiquidRegistry` writer checks.
  - Registry changes: write one benign beneficiary check/update and confirm `isRegistered` / `beneficiaryOf` readbacks.
- Unpause/restore only after smoke checks and event/readback parity are clean.

## 4) Operational note

Treat these setters as sensitive control-plane operations. Route through owner-approved recovery governance, record approval evidence, and require post-change smoke tests before restoring normal traffic.
