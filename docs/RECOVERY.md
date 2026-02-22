# Liquid Recovery Playbook

This document captures operational failure modes and recovery actions for the deployed system.

## Scope

- src/LiquidFactory.sol
- src/LiquidRouter.sol
- src/LiquidAuctioneer.sol
- src/LiquidSwapGuard.sol
- src/LiquidFeeLib.sol
- script/config/NetworkConfig.sol
- script/DeployLiquidSystem.s.sol

## 1) Recovery posture

### 1.1 Recoverable on-chain (no redeploy)

- LiquidRouter: `setUniversalRouter`, `setProtocolFeeRecipient`, `setRareBurner`, `pause`, `unpause`, `setTrustedFactory`, `updateBeneficiary`, `removeToken`, `setAllowlistEnabled`
- LiquidSwapGuard: `setFactory`, `addRouter`, `addCaller`, `removeRouter`, `removeCaller`, `allowlist`
- LiquidFactory: `setLiquidRouter`, `setPoolHooks`, `setProtocolFeeRecipient`, `setCcaFactory`, `setLbpStrategyFactory`, `setPositionManager`, fee/market constants
- LiquidAuctioneer: `setUniversalRouter`, `setProtocolFeeRecipient`
- Rescue: `rescueTokens`, `rescueETH` on router/auctioneer when safe and justified

### 1.2 Hard-stop / hard migration

- LiquidAuctioneer immutable config:
  - fee split parameters
- LiquidRouter immutable config:
  - fee split constants

## 2) Fast incident playbooks

### A) Protocol fee recipient compromised or cannot receive ETH

- Impact:
  - Router: `LiquidFeeLib.disperseFees` reverts the trade if protocol recipient transfer fails (`EthTransferFailed`).
  - Auctioneer: protocol recipient is mutable via `setProtocolFeeRecipient`.
- Router recovery:
  1. If blast radius is large, pause the router.
  2. Confirm candidate recipient is non-zero and can accept ETH.
  3. On router, call `setProtocolFeeRecipient(newRecipient)`.
  4. Run smoke `buy`/`sell` trades and confirm `EthTransferFailed` stops and protocol fee events look expected.
  5. Unpause once healthy.
- Auctioneer recovery:
  1. Confirm on-chain recipient mismatch in auctioneer config.
  2. Call `setProtocolFeeRecipient(newRecipient)` on the auctioneer.
  3. Verify fee flows and relaunch any blocked auction path.
- Shared cleanup:
  1. Audit recent fee events for unexpected protocol/beneficiary/burn distribution.
  2. Rescue stuck ETH if safe (`rescueETH`) under incident SOP.
  3. Document root cause and ownership of the replacement recipient path.

### B) Swaps break after chain integration changes

1. Verify `universalRouter` still points to the intended chain address.
2. On router, call `setUniversalRouter(correctAddr)`.
3. Run a small `buy`/`sell` smoke test.

### C) Auctioneer cannot route after chain integration changes

1. Verify `UNIVERSAL_ROUTER` on the auctioneer is the intended chain/router address.
2. On auctioneer, call `setUniversalRouter(correctAddr)`.
3. Validate auction swap/redeem flows before opening broad traffic.

### D) RARE burn is misrouted or not working

1. Confirm current `rareBurner` and test that `IRAREBurner.depositForBurn` is callable.
2. On router, call `setRareBurner(newBurner)`.
3. Run smoke trades and verify expected `rareBurnFee` behavior in events.

### E) New token launch blocked at registration

1. Check `LiquidFactory` trust wiring with router (`setTrustedFactory`).
2. Confirm token creator / beneficiary constraints (`registerToken`) are valid.
3. Verify allowlist and beneficiary settings.

### F) New pool pre-init blocked

1. Verify `poolHooks` and `SwapGuard.factory()` match.
2. If needed, update `LiquidSwapGuard.setFactory`.
3. Call `LiquidFactory.setPoolHooks(guard)` and validate a test launch path.

### G) CCA auction cannot start

1. Confirm `lbpStrategyFactory`, `positionManager`, `protocolFeeRecipient`, and `ccaFactory` are configured.
2. Confirm factory protocol-recipient/beneficiary config.

## 3) Pre-change guardrails

- Before `setProtocolFeeRecipient` (router or auctioneer):
  - confirm recipient is controlled and can receive ETH
  - confirm no active incident where redeploy path is required
  - decide whether to pause before change
  - record a short on-chain and operator plan
- Before `setUniversalRouter` (router or auctioneer):
  - validate router compatibility and expected command policy
  - run a small on-chain smoke test
- Before `setRareBurner`:
  - verify replacement supports `IRAREBurner.depositForBurn`
  - confirm protocol recipient can absorb redirected burn value if needed
  - run a fee-accounting smoke trade
- Before guard/factory rotation:
  - confirm expected `swapGuard`/`factory` binding
  - validate `setPoolHooks` path for the active factory
  - validate `addInitializer` path after rotation

## 4) Operational note

Control ownership is critical because these setters are sensitive. Route recovery-related calls through hardened governance (multisig/timelock), document approvals, and require a post-change smoke test before scaling traffic.
