# Internal Draft: Holder Fee Sharing for Liquid Editions

**Status:** Draft
**Type:** Internal Standards Track
**Created:** 2026-03-12
**Author:** Liquid Editions team
**Requires:** `LiquidGuard`, `FeeDistributor`, liquid token implementations such as `LiquidInstant`

## Simple Summary

This document describes a proposed mechanism for routing a portion of swap fees to current holders of a Liquid Edition token without pushing rewards to every holder on every transfer.

The mechanism uses:

- a global cumulative reward index
- a dynamic eligible supply
- per-account correction offsets
- explicit exclusion of system custody addresses such as `poolManager`

Rewards are claimed lazily by holders.

## Abstract

Liquid Editions currently collect swap fees on the RARE side of the market through `LiquidGuard` and route those fees through `FeeDistributor`.

This draft proposes a holder-fee extension in which:

1. `LiquidGuard` continues to collect a RARE-denominated fee on swaps.
2. `FeeDistributor` allocates a configurable portion of that fee to holders.
3. The token contract, or a tightly coupled reward module, records that holder share using an accumulator-based accounting model.
4. Holders claim rewards on demand.

The design avoids any O(n) iteration over holders and does not require per-fee balance snapshots for every account.

## Motivation

The goals of this proposal are:

- allow a Liquid Edition to share swap fees with holders
- avoid pushing rewards to every holder on each swap
- avoid claim logic that grows linearly with the number of swaps
- avoid giving the pool inventory a claim on holder rewards
- preserve already-earned rewards when balances move

This proposal is motivated by the fact that the current architecture already has a fee capture path, but no holder-facing distribution path.

## Non-Goals

This draft does not attempt to:

- define an official ERC or EIP
- standardize royalty metadata or marketplace integration
- make existing deployed clones upgradeable
- require automatic reward conversion into ETH or any asset other than the fee asset

## Terminology

**Reward Token**
The asset used to pay holder rewards. In the current architecture this is expected to be `RARE`.

**Eligible Account**
An address whose token balance participates in holder rewards.

**Excluded Account**
An address whose token balance does not participate in holder rewards.

**Eligible Supply**
The sum of balances of all eligible accounts.

**Accumulator**
The cumulative reward-per-eligible-token index. This draft uses the term `accRewardPerEligibleToken`.

**Correction**
A per-account signed offset that preserves historical reward ownership when balances move.

## Background

In the current Liquid Editions flow:

1. `LiquidGuard` collects swap fees in RARE during `beforeSwap` and `afterSwap`.
2. `FeeDistributor.notifyFee(liquidToken, rareAmount)` receives the collected fee.
3. `FeeDistributor` currently routes value to protocol and beneficiary flows.

This draft adds a holder-fee branch to that existing path rather than moving fee collection into the token transfer layer.

## Specification

### Overview

An implementation conforming to this draft SHOULD:

1. receive holder rewards as a discrete amount of reward token
2. divide that amount by the current eligible supply
3. increase a cumulative global index
4. adjust per-account correction offsets whenever balances move
5. allow holders to claim accumulated rewards on demand

### Recommended Interface

An implementation MAY expose the following interface or an equivalent internal-only surface:

```solidity
interface IHolderFeeSharing {
    event HolderRewardsAccrued(
        uint256 rewardAmount,
        uint256 eligibleSupply,
        uint256 newAccRewardPerEligibleToken
    );

    event HolderRewardsClaimed(
        address indexed account,
        address indexed recipient,
        uint256 amount
    );

    event RewardsExclusionUpdated(address indexed account, bool excluded);

    function rewardToken() external view returns (address);
    function eligibleSupply() external view returns (uint256);
    function accRewardPerEligibleToken() external view returns (uint256);
    function pendingUndistributedRewards() external view returns (uint256);

    function isRewardsExcluded(address account) external view returns (bool);
    function correctionOf(address account) external view returns (int256);
    function claimedRewardsOf(address account) external view returns (uint256);
    function claimableRewards(address account) external view returns (uint256);

    function claimRewards(address recipient) external returns (uint256);
    function accrueHolderRewards(uint256 amount) external;
}
```

### Required State

An implementation SHOULD maintain, at minimum:

```solidity
address rewardToken;
uint256 accRewardPerEligibleToken;
uint256 eligibleSupply;
uint256 pendingUndistributedRewards;

mapping(address => bool) rewardsExcluded;
mapping(address => int256) rewardCorrections;
mapping(address => uint256) claimedRewards;
```

### Excluded Accounts

An implementation MUST treat the following accounts as excluded:

- `address(0)`
- the token contract itself, if it may custody its own tokens
- the system `poolManager`, if it custodies pool inventory

An implementation MAY exclude additional explicitly designated custody addresses.

An implementation SHOULD NOT exclude all contracts categorically, since many valid holders may use smart contract wallets or vaults.

### Reward Accrual

When holder rewards are deposited, the implementation MUST update the accumulator using the current eligible supply.

If `eligibleSupply > 0`:

```text
accRewardPerEligibleToken += (amount + pendingUndistributedRewards) / eligibleSupply
pendingUndistributedRewards = 0
```

If `eligibleSupply == 0`:

```text
pendingUndistributedRewards += amount
```

Implementations MAY apply fixed-point scaling to preserve precision.

### Claimable Rewards

For any eligible account:

```text
lifetimeEarned(account) =
    balanceOf(account) * accRewardPerEligibleToken
    + rewardCorrections[account]

claimableRewards(account) =
    lifetimeEarned(account)
    - claimedRewards[account]
```

For excluded accounts, `claimableRewards(account)` SHOULD return zero.

### Transfer Accounting

Whenever a token balance changes, the implementation MUST update the correction offsets and eligible supply according to the eligibility of the sender and receiver.

#### Eligible -> Eligible

```text
rewardCorrections[from] += accRewardPerEligibleToken * amount
rewardCorrections[to]   -= accRewardPerEligibleToken * amount
eligibleSupply unchanged
```

#### Eligible -> Excluded

```text
rewardCorrections[from] += accRewardPerEligibleToken * amount
eligibleSupply          -= amount
```

#### Excluded -> Eligible

```text
rewardCorrections[to]   -= accRewardPerEligibleToken * amount
eligibleSupply          += amount
```

#### Excluded -> Excluded

```text
no correction change
eligibleSupply unchanged
```

### Mint and Burn Semantics

Mint and burn operations MUST be treated consistently with the transfer rules above.

Mint to eligible:

```text
rewardCorrections[to] -= accRewardPerEligibleToken * amount
eligibleSupply        += amount
```

Burn from eligible:

```text
rewardCorrections[from] += accRewardPerEligibleToken * amount
eligibleSupply          -= amount
```

For excluded accounts, eligible supply MUST NOT change.

### Claiming

Claiming rewards SHOULD:

1. compute the caller's current claimable amount
2. increase `claimedRewards[caller]`
3. transfer reward token to the chosen recipient
4. emit a claim event

Claiming MUST NOT modify the global accumulator.

### Exclusion Toggling

If an implementation supports toggling an address between excluded and eligible, it MUST settle the address at the current accumulator before changing the flag.

Exclude an eligible account with balance `b`:

```text
rewardCorrections[account] += accRewardPerEligibleToken * b
eligibleSupply             -= b
rewardsExcluded[account]    = true
```

Include an excluded account with balance `b`:

```text
rewardCorrections[account] -= accRewardPerEligibleToken * b
eligibleSupply            += b
rewardsExcluded[account]   = false
```

## Integration With Current Liquid Editions Architecture

The intended integration path is:

1. `LiquidGuard` continues to skim the RARE-denominated swap fee.
2. `FeeDistributor` determines the holder share.
3. `FeeDistributor` transfers or otherwise makes available that holder share to the token contract or reward module.
4. The token contract or reward module calls `accrueHolderRewards(amount)`.
5. Holders later call `claimRewards(recipient)`.

This keeps reward capture in the existing fee path and keeps reward ownership logic close to token balance changes.

## Reference Accounting Model

For human-readable modeling, the team can reason about the system with:

```text
Acc = cumulative rewards earned by one eligible token
Corr(account) = historical offset for that account

Claimable(account) =
    Balance(account) * Acc
    + Corr(account)
    - Claimed(account)
```

This model is equivalent to maintaining historical balance snapshots, but compressed into one global index and one signed offset per account.

## Rationale

### Why not push rewards to every holder?

Pushing rewards on every swap or transfer scales with holder count and eventually becomes non-viable.

### Why not use per-fee snapshots?

Per-fee snapshots still require historical balance tracking for each account. Claim cost or transfer cost grows with the number of fee events unless a compressed accounting model is used.

### Why exclude the pool?

Pool inventory is not a normal claimant. If `poolManager` participates in rewards, a large portion of holder fees will accrue to a custody address rather than to actual holders.

### Why use a pending bucket?

At launch, eligible supply may temporarily be zero if all tokens are inside excluded custody and no external holder has yet received tokens. The pending bucket prevents reward loss and prevents divide-by-zero behavior.

## Security Considerations

### Reentrancy

Reward claims SHOULD use checks-effects-interactions ordering and SHOULD be protected against reentrancy.

### Precision and Dust

Accumulator math may leave rounding dust. Implementations SHOULD document whether dust remains in the contract, is rolled forward, or is swept by governance.

### Fee Timing Semantics

Rewards are allocated according to balances at the moment `accrueHolderRewards` executes.

In the current swap architecture, this may differ between flows that accrue during `beforeSwap` and flows that accrue during `afterSwap`. Implementations SHOULD document whether a trade's own fee is intended to benefit pre-trade holders, post-trade holders, or a mixture determined by swap direction.

### Exclusion Misconfiguration

Excluding the wrong addresses can silently redirect or suppress holder rewards. The excluded set SHOULD remain small and explicit.

### Existing Deployments

This draft does not provide backward compatibility for already-deployed Liquid Edition clones that do not contain reward accounting state.

## Backwards Compatibility

This draft is intended for new liquid token implementations or for new reward modules explicitly paired with compatible token implementations.

Existing deployed token clones SHOULD be treated as non-upgradeable for purposes of this feature unless they already expose compatible reward hooks and storage.

## Open Questions

- Should holder rewards always remain in RARE, or MAY they be converted before accrual?
- Should the holder share be configured globally, per token, or per launch type?
- Should the reward logic live directly in the token contract or in a per-token reward module?
- Should the first buyer receive fees from the swap that first makes supply eligible, or SHOULD those fees remain pending until the next accrual?

## Appendix A: Spreadsheet Model

For internal modeling, a spreadsheet may track:

- balances for each eligible holder
- balance for excluded custody
- eligible supply
- accumulator
- correction per holder
- claimed amount per holder
- claimable amount per holder

The core formulas are:

```text
Acc(new) =
    Acc(old) + Fee / EligibleSupply(old)

Claimable(account) =
    Balance(account) * Acc
    + Corr(account)
    - Claimed(account)
```

Transfer correction rules are the same as specified above.

## Copyright

This document is intended for internal team use and does not represent an official ERC, EIP, or public standard.
