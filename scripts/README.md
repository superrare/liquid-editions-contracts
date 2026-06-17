# LiquidRouter Integration Scripts

TypeScript utilities for integrating with the LiquidRouter contract and Uniswap Universal Router.

## Overview

The LiquidRouter contract enables route-aware trading of any ERC20 token through Uniswap pools (V2/V3/V4). These scripts help you:
1. Find the best swap route across multiple pool versions
2. Encode the route for the Universal Router
3. Measure slippage protection and validate fee-model assumptions

## Setup

```bash
cd scripts
npm install
```

## Two Routing Approaches

### Option 1: Smart Order Router (Recommended) 🚀

**File**: `uniswap-smart-router.ts`

Uses Uniswap's `@uniswap/smart-order-router` SDK to automatically:
- Find best routes across V2, V3, **and V4** pools
- Split trades across multiple pools for better execution
- Optimize for lowest slippage and gas

**Pros**:
- ✅ No API key needed
- ✅ Automatic V3/V4 support
- ✅ Multi-hop and split routing
- ✅ Self-hosted (no rate limits)

**Cons**:
- ⚠️ Larger bundle size (~2MB)
- ⚠️ Requires RPC calls for liquidity data

**Example**:
```typescript
import { getSmartBuyQuote } from './uniswap-smart-router';

const quote = await getSmartBuyQuote({
  token: '0x...',
  tokenDecimals: 18,
  ethAmount: ethers.utils.parseEther('1').toString(),
  slippageBps: 50, // 0.5%
}, 8453); // Base Mainnet

await liquidRouter.buy(
  token,
  recipient,
  orderReferrer,
  quote.minAmountOut,
  quote.commands,
  quote.inputs,
  quote.deadline,
  { value: ethAmount }
);
```

### Option 2: Manual V3 Quoter (Simple)

**File**: `uniswap-quote.ts`

Direct integration with Uniswap V3 QuoterV2 for simple single-pool quotes.

**Pros**:
- ✅ Lightweight
- ✅ Fast for simple routes
- ✅ Easy to understand

**Cons**:
- ⚠️ V3 pools only (no V4)
- ⚠️ Single pool only (no multi-hop optimization)
- ⚠️ Must specify fee tier manually

**Use when**: You know the token has a V3 pool and want minimal dependencies.

## Quick Start

### Buy Tokens with ETH

```typescript
import { getSmartBuyQuote, calculateEthForSwap } from './uniswap-smart-router';
import { ethers } from 'ethers';

// Connect to contract
const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
const signer = new ethers.Wallet(PRIVATE_KEY, provider);
const liquidRouter = new ethers.Contract(ROUTER_ADDRESS, ABI, signer);

// Get quote
const ethAmount = ethers.utils.parseEther('1');
const quote = await getSmartBuyQuote({
  token: TOKEN_ADDRESS,
  tokenDecimals: 18,
  ethAmount: ethAmount.toString(),
  slippageBps: 100, // 1% slippage
}, 8453);

console.log(`Route: ${quote.route}`);
console.log(`Expected tokens: ${quote.amountOut}`);

// Execute buy
const tx = await liquidRouter.buy(
  TOKEN_ADDRESS,
  signer.address,
  ethers.constants.AddressZero, // no referrer
  quote.minAmountOut,
  quote.commands,
  quote.inputs,
  quote.deadline,
  { value: ethAmount }
);

await tx.wait();
```

### Sell Tokens for ETH

```typescript
import { getSmartSellQuote } from './uniswap-smart-router';

// Approve router to spend tokens
const token = new ethers.Contract(TOKEN_ADDRESS, ERC20_ABI, signer);
await token.approve(ROUTER_ADDRESS, tokenAmount);

// Get quote
const tokenAmount = ethers.utils.parseEther('100');
const quote = await getSmartSellQuote({
  token: TOKEN_ADDRESS,
  tokenDecimals: 18,
  tokenAmount: tokenAmount.toString(),
  slippageBps: 100, // 1%
}, 8453);

// quote.minAmountOut is the expected ETH after route execution
console.log(`You'll receive at least: ${ethers.utils.formatEther(quote.minAmountOut)} ETH`);

// Execute sell
const tx = await liquidRouter.sell(
  TOKEN_ADDRESS,
  tokenAmount,
  signer.address,
  ethers.constants.AddressZero,
  quote.minAmountOut, // expected ETH after route execution
  quote.commands,
  quote.inputs,
  quote.deadline
);

await tx.wait();
```

## Fee Model (canonical)

### Router fees
- Router-level fee fields are zeroed in this architecture (`RouterBuy`/`RouterSell`/`RouterSwap` emit `fee=0`).
- Trading fees are collected inside Uniswap V4 swaps by `LiquidGuard`, then forwarded through `FeeDistributor.notifyFee()`.

### V4 fee conversion/distribution
- `LiquidRouter` forwards the client-provided RARE/ETH price via `setLastRareEthPrice(expectedRareEthSqrtPriceX96)` at the start of each trade.
- `LiquidGuard` takes RARE fees during swap callbacks and forwards them to `FeeDistributor`.
- `FeeDistributor.notifyFee()` converts to ETH when price data is fresh and conversion is healthy, otherwise it falls back to direct RARE split.
- Legacy selector flow in `LiquidAuctioneer` (`totalFeeBPS` + `distributeFees`) is retained for compatibility only.

For SDK-facing behavior, see [`../docs/FLOW.md`](../docs/FLOW.md).

## Supported Networks

| Network | Chain ID | Universal Router | Status |
|---------|----------|------------------|--------|
| Base Mainnet | 8453 | `0x198EF79F1F515F02dFE9e3115eD9fC07183f02fC` | ✅ |
| Base Sepolia | 84532 | `0x050E797f3625EC8785265e1d9BDd4799b97528A1` | ✅ |

## Advanced Usage

### Multi-Hop Routing

The Smart Router automatically handles multi-hop routes:

```typescript
// Will automatically route through best path, e.g.:
// ETH → WETH → USDC → YOUR_TOKEN
const quote = await getSmartBuyQuote({
  token: ILLIQUID_TOKEN,
  tokenDecimals: 18,
  ethAmount: ethAmount.toString(),
}, 8453);

// Route might be: "V3(WETH → USDC, 0.05%) + V4(USDC → TOKEN)"
console.log(quote.route);
```

### Split Routes

The Smart Router can split a large trade across multiple pools:

```typescript
// For large trades, might split like:
// 60% through V3 pool + 40% through V4 pool
const quote = await getSmartBuyQuote({
  token: TOKEN_ADDRESS,
  tokenDecimals: 18,
  ethAmount: ethers.utils.parseEther('100').toString(), // Large trade
}, 8453);
```

### Custom Slippage

```typescript
// Adjust slippage based on market conditions
const volatileQuote = await getSmartBuyQuote({
  token: VOLATILE_TOKEN,
  tokenDecimals: 18,
  ethAmount: ethAmount.toString(),
  slippageBps: 300, // 3% slippage for volatile assets
}, 8453);
```

## Troubleshooting

### "No route found"
- Token may not have sufficient liquidity in any pool
- Try a smaller trade size
- Check token address is correct

### "Too little received" / Slippage exceeded
- Increase `slippageBps` parameter
- Price moved between quote and execution
- Consider breaking large trades into smaller ones

### Gas estimation too high
- Large trades or multi-hop routes use more gas
- Consider using a more liquid token pair
- Check if there's a direct pool (single hop)

## Files

| File | Description |
|------|-------------|
| `uniswap-smart-router.ts` | Smart Order Router integration (V2/V3/V4) ⭐ |
| `uniswap-quote.ts` | Manual V3 quoter (simpler, V3 only) |
| `uniswap-quote-browser.ts` | Browser-compatible V3 quoter |
| `example-usage.ts` | Example integration code |

## Production Considerations

1. **RPC Quality**: Use a reliable RPC provider (Alchemy, Infura, Ankr)
2. **Error Handling**: Always handle "no route" and slippage errors
3. **Deadline**: Set appropriate deadline (20 min default)
4. **Gas Price**: Monitor gas prices on Base for cost efficiency
5. **Caching**: Cache route quotes for a few seconds to reduce RPC calls
6. **Fallback**: Consider having both Smart Router and manual V3 as fallback

## Drift Prevention

Run the repository NatSpec coverage check before merging doc-facing updates:

```bash
./check-natspec-coverage.sh
```

This scan flags public/external Solidity functions under `src/**/*.sol` that may be missing a nearby NatSpec comment.

## Learn More

- [Uniswap Universal Router Docs](https://docs.uniswap.org/contracts/universal-router/overview)
- [Smart Order Router GitHub](https://github.com/Uniswap/smart-order-router)
- [LiquidRouter Contract](../src/LiquidRouter.sol)
