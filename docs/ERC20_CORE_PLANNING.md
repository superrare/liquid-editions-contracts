# ERC20 Core Planning

## Goal

Define the standards and behaviors that should exist in the new Liquid ERC20 core before adding special-purpose extensions.

The core should stay broadly composable with wallets, routers, indexers, and common token tooling. Feature variants can build on this base through separate implementations selected by the factory.

The first new factory option should be a sovereign owner-controlled ERC20: no Liquid pool, no bonding curve, no auction, and no special transfer mechanics. It gives creators a standard ERC20 they can deploy through the Liquid factory, mint an initial supply at deployment, and continue minting later through an owner-only `mint` function.

This plan is additive. The existing `LiquidMultiCurve` deployment path should remain available through the factory unchanged.

## Proposed Core

| Area | Standard / Feature | Status | Notes |
| --- | --- | --- | --- |
| Fungible token base | [ERC-20](https://eips.ethereum.org/EIPS/eip-20) | Core | Required baseline for balances, transfers, allowances, and events. |
| Token metadata | ERC20 metadata (`name`, `symbol`, `decimals`) | Core | Common ERC20 extension expected by wallets, explorers, and DEX tooling. |
| Signed approvals | [ERC-2612 Permit](https://eips.ethereum.org/EIPS/eip-2612) | Core | Allows approvals by EIP-712 signature instead of a separate approval transaction. |
| EIP-712 domain discovery | [ERC-5267](https://eips.ethereum.org/EIPS/eip-5267) | Core | Lets clients inspect the EIP-712 domain used by permit and future signature flows. |
| Interface detection | [ERC-165](https://eips.ethereum.org/EIPS/eip-165) | Core introspection | Lets contracts and clients query supported optional extension interfaces. Do not rely on this as the only ERC20 detection mechanism. |
| Standard token errors | [ERC-6093](https://eips.ethereum.org/EIPS/eip-6093) | Core | Standard custom errors for ERC20 failure cases. Improves gas and client decoding. |
| Token URI metadata | [ERC-1046](https://eips.ethereum.org/EIPS/eip-1046) | Core | Adds optional ERC20 `tokenURI()` for JSON metadata, similar to NFT metadata flows. Owner-updatable with an explicit update event. |
| Burning | Burn / burnFrom | Core | Existing Liquid behavior; useful for supply reduction and creator-token workflows. |
| Owner minting | Initial supply + `mint` | Core for sovereign ERC20 | Factory deploys with an initial supply, then token owner can mint more later. |
| Supply bounds | Optional cap | Recommended config | A cap is safer for trust assumptions, but the sovereign ERC20 may support uncapped minting if that is the explicit product choice. |

## First Factory Token Option: Sovereign ERC20

The factory should offer a sovereign owner-controlled ERC20 implementation alongside Liquid-specific launch tokens.

Working name:

```text
SovereignERC20
```

Expected factory behavior:

```solidity
function createSovereignERC20(
    address owner,
    string calldata tokenURI,
    string calldata name,
    string calldata symbol,
    uint256 initialSupply,
    uint256 maxSupply
) external returns (address token);
```

Expected token behavior:

```solidity
function mint(address to, uint256 amount) external onlyOwner;
function setTokenURI(string calldata newTokenURI) external onlyOwner;
function tokenURI() external view returns (string memory);
function burn(uint256 amount) external;
function burnFrom(address account, uint256 amount) external;
```

Initialization notes:

- `owner` controls future minting and token URI updates.
- `initialSupply` is minted during deployment.
- `owner` receives the initial supply.
- `maxSupply` should be optional by convention for the sovereign no-market ERC20. If `maxSupply == 0`, treat minting as uncapped. If non-zero, `totalSupply() + amount` must not exceed `maxSupply`.
- `initialSupply` may be zero for `SovereignERC20` because the owner can mint later.
- If `maxSupply != 0`, `maxSupply` must be greater than or equal to `initialSupply`.
- The factory should emit a token-created event that identifies this as the sovereign owner-controlled token type.
- Factory authorization should reuse the existing delegated creation model: caller must be the `owner` or an approved creator delegate for that `owner`.

Trust model:

- If minting is uncapped, holders must trust the owner not to inflate supply.
- If minting is capped, holders can verify the maximum possible supply onchain.
- Ownership transfer and renounce behavior should be deliberate. Renouncing ownership freezes owner-only minting and metadata updates.

Decisions:

- Use regular OpenZeppelin `Ownable` for the first version.
- Keep `tokenURI()` simple and static: stored URI, owner-updatable by `setTokenURI`, no render-contract delegation for this token family.
- Use fixed 18 decimals for all Sovereign ERC20 variants.
- Reject empty `name` and `symbol`; only `tokenURI` may be an empty string.
- Allow normal OpenZeppelin ownership renounce behavior.
- Allow uncapped minting for sovereign no-market ERC20s when `maxSupply == 0`.
- Do not allow new supply creation for market-enabled ERC20s. Market-enabled deployments should use `initialSupply` as their only supply parameter, mint 100% of that supply at creation, and add it to the liquidity pool.
- Do not expose a public `mint` function on market-enabled ERC20s. ERC20 does not require `mint`, and a reverting `mint` function would make the ABI misleading.
- Permit should use a stable EIP-712 version string, likely `"1"`. This is the version included in the signature domain so wallets and clients know which signing domain they are approving for.

## ERC-1046 Metadata Notes

ERC-1046 defines:

```solidity
function tokenURI() external view returns (string);
```

The core should store the active token URI and allow the owner to update it:

```solidity
event TokenURIUpdated(string oldTokenURI, string newTokenURI);

function setTokenURI(string calldata newTokenURI) external onlyOwner;
```

An empty string is valid and means no token URI is set. `tokenURI()` should return `""` when metadata is intentionally omitted.

This gives indexers and frontends a deterministic signal when offchain metadata should be refreshed. The event is intentionally ERC20-specific, while serving the same practical role as NFT metadata update events such as ERC-4906 `MetadataUpdate`.

The resolved JSON should be ERC-1046-compatible. For Liquid tokens, the metadata should keep the following fields aligned with the contract getters when present:

- `name`
- `symbol`
- `decimals`

Useful optional fields:

- `description`
- `image`
- `images`
- `icons`
- Liquid-specific launch, creator, or market metadata

## First Special Extension: Market Setup

The first special extension should be reusable market setup. `LiquidMultiCurve` already performs this today and should be treated as the working reference for Uniswap V4 setup. Do not reinvent the pool initialization, hook allowlisting, multicurve position calculation, or PoolManager unlock pattern unless a specific incompatibility appears.

The new goal is to reuse that proven market setup pattern across multiple ERC20 configurations.

Working names:

```text
MarketExtension
MarketInitializer
LiquidMarketDeployer
```

What it should cover:

- Build a Uniswap V4 `PoolKey` for a token/RARE pair.
- Validate and/or allowlist the configured hook before pool initialization.
- Calculate multicurve launch positions from `Curve[]`.
- Initialize the pool at the intended launch price.
- Add liquidity positions.
- Return dust or excess base token to the configured recipient.
- Emit a market-created event that factory/indexers can rely on.

Implementation reference:

- Start from the `LiquidMultiCurve` pool setup flow.
- Preserve the same security ordering: factory validates hook, allowlists the token as initializer, then token initializes the pool.
- Preserve the PoolManager unlock callback pattern for initialize-and-add-liquidity.
- Reuse Doppler `Multicurve` curve adjustment and position calculation where possible.
- Keep changes scoped to token ownership/supply semantics and the reduced external market surface.

Important ownership decision:

- If the token contract calls `PoolManager.modifyLiquidity`, the token owns the V4 positions.
- If an external market setup contract calls `PoolManager.modifyLiquidity`, that market setup contract owns the V4 positions.
- If we want code reuse while keeping positions owned by each token, the reusable code should be an internal library or abstract base inherited by market-enabled token implementations.
- If we are comfortable with a separate market contract owning and managing LP, the factory can deploy or call a market module during setup, and tokens can expose market state through that module.

Market base-token invariant:

- RARE should be the required base token for `SovereignERC20Market` and `SovereignERC20MarketRewards` liquidity pools.
- The factory should provide the canonical RARE address as `baseToken`.
- Market setup should reject any non-RARE base token for these variants.
- The pool may order currencies by address as required by Uniswap V4, but conceptually and in UI/indexing the market is always Sovereign token against RARE.
- Reward token selection is separate from the pool base token. Rewards can be RARE or the Sovereign token itself, but market liquidity should still be against RARE.

Market setup decisions:

- Market creation is atomic during token deployment.
- Market-enabled deployments use one-sided liquidity: 100% of the Sovereign token supply is added to the pool at creation.
- Market-enabled deployments must reject `initialSupply == 0`.
- Do not include initial RARE liquidity support for Sovereign market variants.
- Curves are user-provided through `Curve[]`.
- Reuse the `LiquidMultiCurve` position cap. `MAX_POSITIONS = 25` is the starting limit because gas cost expands with the number of curves/positions.
- Reuse the proven `LiquidMultiCurve` curve validation and position calculation flow. Add client-side previews where possible because user-provided curves can create sharp market outcomes.
- LP positions are token-owned.
- Do not expose owner liquidity management in the first version. Liquidity is created at launch and remains controlled by the token mechanics.
- Do not include LP migration in the first version unless a concrete emergency-migration design is needed. Migration creates front-running and operational risks. If added later, it should be protocol/emergency-only with strict authority and explicit events, not owner liquidity management.
- Use the current LiquidGuard-style hook if possible.
- Route fees through the existing `FeeDistributor` path if possible.
- `SovereignERC20Market` and `SovereignERC20MarketRewards` only need to expose `poolKey()` and `poolId()` for convenience. They do not need to expose the full `LiquidMultiCurve` quote or market-state surface.

Current hook/distributor assessment:

- `LiquidGuard` appears reusable for Sovereign markets because it is keyed on RARE pools, whitelisted initializers, and `feeDistributor`; it does not require the non-RARE token to implement Liquid-specific interfaces.
- The factory can still allowlist Sovereign market tokens before pool initialization through the existing `addInitializer` flow.
- `FeeDistributor` can remain focused on existing fee routing. `SovereignERC20Market` can likely use the current distributor model by registering the owner as beneficiary, subject to the desired global conversion settings.
- `SovereignERC20MarketRewards` does not require Uniswap swap fees to be routed directly into holder rewards. Holder rewards are funded through explicit reward deposits from any source.
- `notifyHolderRewards` only needs to be called when a reward deposit should be accrued to holders. It does not need to be called by `LiquidGuard` or `FeeDistributor`.
- A future distributor or adapter can route a share of market fees into holder rewards, but that is optional integration work rather than a requirement of the reward extension.

Preferred direction for the first version:

Use a dedicated market-enabled token implementation that inherits shared market setup code, rather than arbitrary runtime `delegatecall` modules. This preserves token-owned liquidity, keeps storage easier to audit, and still lets the factory offer multiple token configurations:

```text
SovereignERC20
SovereignERC20Market
SovereignERC20MarketRewards
LiquidMultiCurve
future variants...
```

Factory ABI direction:

Prefer explicit factory parameters for public create functions, matching the existing `createLiquidTokenMultiCurveWithSupply` style. This keeps the ABI easier to read in explorers, scripts, and client code. Use structs internally if needed to avoid stack-depth issues.

Create functions should not be payable. Native ETH is not part of the Sovereign ERC20 deployment or reward design.

```solidity
function createSovereignERC20Market(
    address owner,
    string calldata tokenURI,
    string calldata name,
    string calldata symbol,
    uint256 initialSupply,
    Curve[] calldata curves
) external returns (address token);

function createSovereignERC20MarketRewards(
    address owner,
    string calldata tokenURI,
    string calldata name,
    string calldata symbol,
    uint256 initialSupply,
    Curve[] calldata curves,
    address rewardToken
) external returns (address token);
```

Reward token parameter semantics:

```solidity
address public constant SELF_REWARD_TOKEN = address(1);
```

- Pass an ERC20 token address to use that token as the immutable reward token.
- Pass `SELF_REWARD_TOKEN` to use the deployed Sovereign token itself as the immutable reward token.
- `address(0)` is invalid and remains reserved for native ETH semantics elsewhere in the protocol.
- External reward token addresses must be on a factory-managed allowlist. `SELF_REWARD_TOKEN` is always allowed.

Possible token behavior:

```solidity
function poolKey() external view returns (...);
function poolId() external view returns (...);
```

## Second Special Extension: Holder Rewards

The next optional extension should let an ERC20 distribute an external reward token to current holders. This should be designed as a general ERC20 extension, not as something coupled directly to the existing Liquid token implementation.

Working names:

```text
HolderRewardsExtension
ERC20HolderRewards
SovereignERC20MarketRewards
```

Core idea:

- The token has a configured `rewardToken`.
- Reward funding is deposited into the token contract.
- Deposited rewards are allocated pro rata across eligible token holders.
- Accounting uses a global cumulative index and per-account signed corrections.
- Holders claim rewards on demand.
- System custody addresses can be excluded from reward eligibility.

This gives a factory-deployed ERC20 a holder incentive without requiring offchain reward accounting or iterating over holders.

Expected extension state:

```solidity
address public rewardToken;
uint256 public accRewardPerEligibleToken;
uint256 public eligibleSupply;
uint256 public pendingUndistributedRewards;

mapping(address account => bool excluded) public rewardsExcluded;
mapping(address account => int256 correction) public rewardCorrections;
mapping(address account => uint256 claimed) public claimedRewards;
```

Expected external surface:

```solidity
function rewardToken() external view returns (address);
function eligibleSupply() external view returns (uint256);
function rewardsExcluded(address account) external view returns (bool);
function claimableRewards(address account) external view returns (uint256);

function notifyHolderRewards(uint256 amount) external;
function syncRewards() external returns (uint256 synced);
function claimRewards(address recipient) external returns (uint256 claimed);
function addRewardsExcluded(address account) external onlyOwner;
function removeRewardsExcluded(address account) external onlyOwner;
```

`notifyHolderRewards(uint256 amount)` should not blindly trust `amount`. The safer pattern is for the function to pull reward tokens from `msg.sender` using `transferFrom`, measure the reward-token balance before and after the pull, and accrue only the actual received amount. This handles fee-on-transfer or non-standard ERC20 behavior more defensively.

`syncRewards()` should be permissionless and accrue any excess reward-token balance that was transferred directly to the contract without calling `notifyHolderRewards`. Internally, `_syncRewards()` can be called before `notifyHolderRewards` and `claimRewards` so direct transfers are swept into reward accounting on the next reward or claim action.

Expected events:

```solidity
event HolderRewardsNotified(address indexed funder, uint256 amount);
event HolderRewardsSynced(uint256 amount);
event HolderRewardsClaimed(address indexed account, address indexed recipient, uint256 amount);
event RewardsExcluded(address indexed account);
event RewardsIncluded(address indexed account);
```

Accumulator model:

```solidity
accRewardPerEligibleToken += (amount * 1e18) / eligibleSupply;
```

Transfer accounting should adjust corrections whenever balances move:

```solidity
int256 delta = int256(amount * accRewardPerEligibleToken);
rewardCorrections[from] += delta;
rewardCorrections[to] -= delta;
```

The exact implementation must account for exclusions:

- If both `from` and `to` are eligible, adjust corrections for both accounts.
- If `from` is eligible and `to` is excluded, reduce `eligibleSupply`.
- If `from` is excluded and `to` is eligible, increase `eligibleSupply`.
- If both are excluded, do not adjust reward corrections or eligible supply.
- `address(0)` mint and burn paths must update `eligibleSupply` according to the receiving or sending account eligibility.
- Boundary moves between eligible and excluded accounts still need correction updates for the eligible account, so tokens entering eligibility do not receive historical rewards and tokens leaving eligibility keep already-earned rewards.

Funding model:

- Reward funding is permissionless. Any source can approve reward tokens and call `notifyHolderRewards(amount)`.
- Direct reward-token transfers to the contract should not immediately accrue rewards, but they should not be stranded. They become claimable when `syncRewards()` or an internal `_syncRewards()` call accounts for the excess balance.
- Reward funding is independent from Uniswap fee routing by default.
- For a market-enabled ERC20, swap fees can be routed into this extension later as one possible funding source, but the first version does not require that integration.
- For the current Liquid architecture, `LiquidGuard` and `FeeDistributor` can continue their existing fee path unless we intentionally add a holder-reward routing adapter.

Reward token:

- `rewardToken` is set at initialization and immutable after deployment.
- Metadata such as `tokenURI` can change, but reward currency should not. Changing reward token would make accounting and user expectations harder to reason about.
- `rewardToken` may be an external ERC20 token, or the Sovereign ERC20 token itself.
- `rewardToken` must be an ERC20 token, not native ETH.
- External reward tokens must be allowlisted by the factory before deployment. This is an intentional safety tradeoff: the reward feature is permissionless for deposits, but deployment only supports reward assets the protocol has accepted as safe enough to avoid obvious malicious or incompatible ERC20 behavior. The allowlist can be edited by the factory owner.
- Factory input should use `SELF_REWARD_TOKEN = address(1)` as the self-token reward sentinel. The token should store the resolved reward token as `address(this)`, not `address(1)`.
- `address(0)` must be rejected for reward token configuration.
- If `rewardToken == address(this)`, rewards must come from actual market activity or other existing token balances, not from new minting. Market-enabled reward tokens do not expose owner minting, so same-token rewards are a redistribution of economically acquired tokens rather than an inflationary emission.
- Same-token rewards require the token contract itself to be excluded from eligibility so unclaimed reward inventory does not earn rewards while it sits in the contract.
- Start with one immutable reward token. Multiple simultaneous reward tokens are out of scope for the first version.

Trust and safety notes:

- If `eligibleSupply == 0`, new rewards should be buffered in `pendingUndistributedRewards` instead of silently ignored.
- `notifyHolderRewards` should revert if the actual received amount is zero.
- `notifyHolderRewards` should verify the actual reward-token balance increase where possible, rather than trusting the input amount blindly.
- Rounding dust should stay in the contract and roll into later reward accruals. Do not add a reward sweep path in the first version.
- Claims should update accounting before transferring reward tokens.
- Claims should reject `recipient == address(this)` so a holder cannot mark rewards claimed while leaving the reward balance accounted inside the token contract.
- Excluding an account should preserve already-earned claimable rewards and only affect future accrual. This is simpler for users and avoids surprising loss of accrued rewards.
- Default excluded system addresses should include the token contract itself, the pool custody/manager address, and any market/LP custody address that should not earn holder rewards.
- `address(0)` should never be reward eligible.
- Reward exclusions have two classes. System exclusions are immutable and cannot be removed; owner-managed exclusions can be added or removed by the owner. Renouncing ownership freezes owner-managed exclusion changes.
- Owner/team addresses receive no special treatment by default. If the owner wants a team, treasury, or vesting address excluded, they can add it to the exclusion list.
- For same-token rewards, claiming transfers tokens from an excluded contract balance to an eligible holder balance. Those claimed tokens should begin earning only future rewards, not past accumulator history.
- Same-token market rewards should mark any post-pool token balance held by the token contract as already accounted, so initial LP dust cannot be synced later as holder rewards.

New factory configurations:

```text
SovereignERC20
SovereignERC20Market
SovereignERC20MarketRewards
```

The first new implementation set should stay limited to these three options. A `SovereignERC20Rewards` option can be considered later, but it is not part of the initial plan because the market gives holder rewards a natural funding source.

## Solidity Testing Plan

Use focused Foundry unit tests for each contract layer, plus integration tests for the factory and market setup path.

Core token tests:

- `SovereignERC20` initializes owner, name, symbol, optional token URI, initial supply, and max supply correctly.
- Empty `name` and `symbol` revert.
- Empty `tokenURI` is allowed and returns `""`.
- `setTokenURI` is owner-only and emits `TokenURIUpdated`.
- `mint` is owner-only.
- `maxSupply == 0` allows uncapped minting on `SovereignERC20`.
- `maxSupply != 0` enforces `totalSupply() + amount <= maxSupply`.
- `maxSupply < initialSupply` reverts.
- `initialSupply == 0` is allowed for `SovereignERC20`.
- `burn` and `burnFrom` work with balances and allowances.
- Permit works with EIP-712 version `"1"`.
- Renouncing ownership freezes owner-only actions.

Factory tests:

- Factory can deploy `SovereignERC20`, `SovereignERC20Market`, and `SovereignERC20MarketRewards`.
- Existing `createLiquidTokenMultiCurve` behavior remains unchanged.
- Delegated creator flow works for all Sovereign deployment paths.
- Non-owner/non-delegate deployment for another owner reverts.
- Factory create functions are not payable.
- `SovereignTokenCreated` emits with the expected `kind`, `token`, `owner`, and `tokenURI`.
- Reward-token allowlist accepts allowed ERC20s and rejects disallowed ERC20s.
- `SELF_REWARD_TOKEN` is accepted without being stored in the external-token allowlist.
- `address(0)` reward token input reverts.

Market tests:

- Market deployments reject `initialSupply == 0`.
- 100% of `initialSupply` is minted and used for pool liquidity.
- Owner receives no token allocation on market variants.
- Market variants expose no public `mint` function.
- Market pools always use RARE as the base token.
- Non-RARE base token configuration reverts.
- User-provided curves are adjusted and validated using the proven `LiquidMultiCurve` flow.
- Empty or invalid curves revert.
- Position count above `MAX_POSITIONS = 25` reverts.
- Factory validates hooks and allowlists the token before pool initialization.
- Pool initialization uses the same PoolManager unlock pattern as `LiquidMultiCurve`.
- `poolKey()` and `poolId()` return expected values.
- LP positions are token-owned.
- No owner liquidity-management path exists.

Reward tests:

- `rewardToken` is immutable after initialization.
- External reward token must be factory-allowlisted.
- `SELF_REWARD_TOKEN` resolves to `address(this)` in token storage.
- Native ETH / `address(0)` reward token configuration reverts.
- `notifyHolderRewards` pulls tokens from caller and accrues only the actual received amount.
- `notifyHolderRewards` reverts when actual received amount is zero.
- Direct reward-token transfers do not immediately accrue.
- `syncRewards()` accrues direct reward-token transfers.
- Internal `_syncRewards()` runs before `notifyHolderRewards` and `claimRewards`.
- Rewards buffer when `eligibleSupply == 0`.
- Buffered rewards distribute when eligible supply appears.
- Rounding dust rolls into later reward accruals.
- `claimRewards` updates accounting before transfer.
- Claims emit `HolderRewardsClaimed`.
- System exclusions are immutable.
- Owner-managed exclusions can be added and removed before renounce.
- Renounce freezes owner-managed exclusion changes.
- Excluding an account preserves already-earned claimable rewards and affects only future accrual.
- Same-token rewards exclude the token contract balance.
- Same-token reward claims move tokens from an excluded balance to an eligible holder balance without granting historical rewards.

Reward invariants:

- `eligibleSupply` equals total balances of non-excluded accounts under tested actors.
- A token entering eligibility after rewards accrue cannot claim historical rewards.
- A token leaving eligibility keeps rewards earned before exclusion or transfer.
- Total claimed rewards plus pending claimable rewards never exceeds accounted rewards, except for expected rounding dust.
- Direct transfers plus `syncRewards()` cannot double-count already-accounted rewards.

## Factory Options And Composability

Prefer explicit factory options over feature flags for the first version. This keeps deployment choices easy to reason about and avoids a combinatorial feature matrix.

Factory options after this work:

```text
Existing Liquid path: LiquidMultiCurve
Core: SovereignERC20
Core + Market: SovereignERC20Market
Core + Market + Rewards: SovereignERC20MarketRewards
```

`LiquidMultiCurve` should continue to use the current factory creation flow and behavior. The new core ERC20 options should not require changes to the existing Liquid token mechanics.

Recommended factory registry shape:

```solidity
struct TokenImplementation {
    address implementation;
    bool enabled;
}

mapping(bytes32 kind => TokenImplementation) public tokenImplementations;
```

Factory reward-token allowlist:

```solidity
mapping(address rewardToken => bool allowed) public sovereignRewardTokenAllowed;
```

- `SELF_REWARD_TOKEN` does not need to be stored in the allowlist; it is a sentinel handled by the factory.
- `address(0)` must never be allowed.
- The factory owner can add or remove external ERC20 reward tokens from the allowlist for future deployments. Existing deployed reward tokens remain immutable.

Create event direction:

Use one create event with a type/kind field rather than separate events, since the relevant difference is the deployment kind.

```solidity
event SovereignTokenCreated(
    bytes32 indexed kind,
    address indexed token,
    address indexed owner,
    string tokenURI
);
```

Market and reward variants can emit additional setup events from the token if they need to expose pool or reward configuration.

Example kinds:

```solidity
bytes32 constant KIND_SOVEREIGN_ERC20 = keccak256("SOVEREIGN_ERC20");
bytes32 constant KIND_SOVEREIGN_ERC20_MARKET = keccak256("SOVEREIGN_ERC20_MARKET");
bytes32 constant KIND_SOVEREIGN_ERC20_MARKET_REWARDS = keccak256("SOVEREIGN_ERC20_MARKET_REWARDS");
```

The existing `liquidMultiCurveImplementation` can remain as-is for the current Liquid deployment path, or later be represented in the registry as a compatibility entry. Do not make registry adoption a prerequisite for preserving existing `createLiquidTokenMultiCurve` behavior.

Registry note:

- Keeping `LiquidMultiCurve` separate means preserving the current `liquidMultiCurveImplementation` field and `createLiquidTokenMultiCurve` path exactly as-is.
- Listing `LiquidMultiCurve` in the registry later would only help discovery and admin consistency. It should not change behavior.

ERC-165 should still be part of the composability plan. It gives deployed tokens a standard `supportsInterface(bytes4)` surface for optional extension interfaces. Use it for Liquid-defined interfaces such as:

```text
ISovereignERC20
IERC20TokenURI
IERC20MarketExtension
IERC20HolderRewards
```

The factory kind tells users what they are deploying. ERC-165 tells other contracts what a deployed token supports. That should be enough for this first pass without capability flags.
