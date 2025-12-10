# LiquidRouter Client Integration Guide

## TL;DR

✅ **Your contract (`LiquidRouter.sol`) is complete and works with V3/V4 pools**  
✅ **No contract changes needed**  
⚠️ **You need to update your client SDK to use the Smart Order Router**

## What Changed

The Universal Router that your contract uses **already supports V2, V3, and V4 pools**. The routing decision happens at the client level when encoding the `routeData` parameter.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Client / Frontend                                           │
│                                                             │
│  1. Call Smart Router SDK                                  │
│  2. SDK finds best route (V2/V3/V4)                        │
│  3. SDK returns encoded routeData                          │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼ routeData (bytes)
┌─────────────────────────────────────────────────────────────┐
│ LiquidRouter Contract                                       │
│                                                             │
│  1. Takes 3% fee                                           │
│  2. Forwards routeData to Universal Router                 │
│  3. Distributes proceeds                                   │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼ execute(commands, inputs)
┌─────────────────────────────────────────────────────────────┐
│ Uniswap Universal Router                                    │
│                                                             │
│  Executes commands:                                         │
│  - WRAP_ETH / UNWRAP_WETH                                  │
│  - V3_SWAP_EXACT_IN (for V3 pools)                         │
│  - V4_SWAP (for V4 pools)                                  │
│  - V2_SWAP (for V2 pools)                                  │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Options

### Recommended: Uniswap Smart Order Router

**Package**: `@uniswap/smart-order-router`

```typescript
import { AlphaRouter } from '@uniswap/smart-order-router';
import { Token, CurrencyAmount, TradeType } from '@uniswap/sdk-core';

// Initialize router
const router = new AlphaRouter({ 
  chainId: 8453, 
  provider 
});

// Get route
const route = await router.route(
  amountIn,
  outputToken,
  TradeType.EXACT_INPUT,
  {
    recipient: liquidRouterAddress,
    slippageTolerance: new Percent(50, 10000), // 0.5%
    deadline: Math.floor(Date.now() / 1000) + 1200,
    type: SwapType.UNIVERSAL_ROUTER,
  }
);

// Use the encoded calldata
const routeData = route.methodParameters.calldata;
```

**Advantages**:
- ✅ Automatically finds best price across V2/V3/V4
- ✅ Handles multi-hop routes
- ✅ Can split trades across multiple pools
- ✅ No API key required
- ✅ Self-hosted (no rate limits)

**Disadvantages**:
- ⚠️ Larger bundle size (~2MB)
- ⚠️ Requires multiple RPC calls

### Alternative: Manual V3 Integration

If you only need V3 support (no V4), you can stick with your current implementation in `uniswap-quote.ts`.

## Migration Steps

### 1. Install Dependencies

```bash
cd scripts
npm install @uniswap/smart-order-router @uniswap/sdk-core
```

### 2. Update Your Client Code

**Before** (V3 only):
```typescript
import { getBuyQuote } from './uniswap-quote';

const quote = await getBuyQuote({
  token: tokenAddress,
  ethAmount: ethAmount.toString(),
  fee: 3000, // Must specify fee tier
  slippageBps: 50,
}, chainId);
```

**After** (V2/V3/V4 automatic):
```typescript
import { getSmartBuyQuote } from './uniswap-smart-router';

const quote = await getSmartBuyQuote({
  token: tokenAddress,
  tokenDecimals: 18,
  ethAmount: ethAmount.toString(),
  slippageBps: 50,
}, chainId);

console.log(`Best route: ${quote.route}`);
// Example output: "V4(WETH → TOKEN)" or "V3(WETH → USDC, 0.05%) + V3(USDC → TOKEN, 0.3%)"
```

### 3. Contract Interaction (No Change)

```typescript
// This part stays exactly the same
await liquidRouter.buy(
  token,
  recipient,
  orderReferrer,
  quote.minAmountOut,
  quote.routeData,  // Now includes V4 routes automatically
  quote.deadline,
  { value: ethAmount }
);
```

## Testing Strategy

### 1. Test with Known V3 Token
```typescript
// USDC on Base (has V3 pool)
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const quote = await getSmartBuyQuote({
  token: USDC,
  tokenDecimals: 6,
  ethAmount: ethers.utils.parseEther('0.01').toString(),
}, 8453);
// Should route through V3
```

### 2. Test with V4 Token
```typescript
// Once you have a V4 pool deployed
const quote = await getSmartBuyQuote({
  token: YOUR_V4_TOKEN,
  tokenDecimals: 18,
  ethAmount: ethers.utils.parseEther('0.01').toString(),
}, 8453);
// Should route through V4
```

### 3. Test Multi-Hop
```typescript
// Illiquid token that needs intermediate hop
const quote = await getSmartBuyQuote({
  token: ILLIQUID_TOKEN,
  tokenDecimals: 18,
  ethAmount: ethers.utils.parseEther('0.1').toString(),
}, 8453);
// Might route: WETH → USDC → TOKEN
```

## Common Patterns

### Pattern 1: Show Quote Before Trading

```typescript
// Get quote
const quote = await getSmartBuyQuote({
  token: tokenAddress,
  tokenDecimals: 18,
  ethAmount: ethAmount.toString(),
  slippageBps: 100,
}, chainId);

// Show user the details
console.log(`Route: ${quote.route}`);
console.log(`Expected output: ${ethers.utils.formatUnits(quote.amountOut, 18)} tokens`);
console.log(`Minimum output: ${ethers.utils.formatUnits(quote.minAmountOut, 18)} tokens`);
console.log(`Estimated gas: ${quote.gasEstimate}`);

// User approves, then execute
await liquidRouter.buy(...);
```

### Pattern 2: Handle "No Route" Gracefully

```typescript
try {
  const quote = await getSmartBuyQuote({
    token: tokenAddress,
    tokenDecimals: 18,
    ethAmount: ethAmount.toString(),
  }, chainId);
  
  // Proceed with trade
  await liquidRouter.buy(...);
  
} catch (error) {
  if (error.message.includes('No route found')) {
    // Show user-friendly message
    console.error('This token does not have sufficient liquidity');
    // Maybe suggest a different token or smaller amount
  } else {
    throw error;
  }
}
```

### Pattern 3: Retry with Higher Slippage

```typescript
let quote;
let slippage = 50; // Start with 0.5%

while (!quote && slippage <= 300) {
  try {
    quote = await getSmartBuyQuote({
      token: tokenAddress,
      tokenDecimals: 18,
      ethAmount: ethAmount.toString(),
      slippageBps: slippage,
    }, chainId);
  } catch (error) {
    // Try again with more slippage
    slippage += 50;
  }
}

if (!quote) {
  throw new Error('Unable to find route even with 3% slippage');
}
```

## Performance Optimization

### Cache Quotes Briefly

```typescript
const quoteCache = new Map();

async function getCachedQuote(params, chainId) {
  const key = JSON.stringify({ params, chainId });
  const cached = quoteCache.get(key);
  
  if (cached && Date.now() - cached.timestamp < 10000) {
    return cached.quote; // Use cache if < 10 seconds old
  }
  
  const quote = await getSmartBuyQuote(params, chainId);
  quoteCache.set(key, { quote, timestamp: Date.now() });
  
  return quote;
}
```

### Use Reliable RPC

```typescript
// Good RPC providers for Base
const RPC_URLS = [
  'https://base-mainnet.g.alchemy.com/v2/YOUR_KEY',
  'https://mainnet.base.org', // Public RPC (fallback)
];
```

## Production Checklist

- [ ] Install `@uniswap/smart-order-router` and `@uniswap/sdk-core`
- [ ] Update quote fetching to use Smart Router
- [ ] Test with V3 tokens (USDC, WETH, etc.)
- [ ] Test with V4 tokens (once available)
- [ ] Add error handling for "no route found"
- [ ] Add slippage retry logic
- [ ] Implement quote caching (10-30 seconds)
- [ ] Use reliable RPC provider
- [ ] Add logging/monitoring for route types used
- [ ] Test on testnet (Base Sepolia) before mainnet

## FAQ

**Q: Do I need to change my smart contract?**  
A: No! `LiquidRouter.sol` is already compatible with V2/V3/V4 pools.

**Q: How does the router choose between V3 and V4?**  
A: The Smart Router SDK checks liquidity and price impact across all pool types and picks the best route automatically.

**Q: What if a token only has a V4 pool?**  
A: The Smart Router will automatically use the V4 pool. No special handling needed.

**Q: Can I force it to use V3 or V4?**  
A: The Smart Router doesn't expose this directly. If you need manual control, you'd need to build your own route encoder.

**Q: What about gas costs?**  
A: V4 pools are generally cheaper than V3. The Smart Router factors gas costs into its routing decision.

**Q: Do I need to wait for V4 to launch?**  
A: No! You can deploy this now. It will work with V3 pools today and automatically support V4 pools when they have liquidity.

## Next Steps

1. **Install packages**: `npm install @uniswap/smart-order-router @uniswap/sdk-core`
2. **Test locally**: Use the provided `uniswap-smart-router.ts` script
3. **Update your client**: Replace manual V3 quotes with Smart Router
4. **Deploy to testnet**: Test on Base Sepolia
5. **Monitor routes**: Log which pool types are being used
6. **Deploy to mainnet**: Once tested and confident

## Support

- Review `scripts/uniswap-smart-router.ts` for full implementation
- Check `scripts/README.md` for usage examples
- See [Uniswap Docs](https://docs.uniswap.org/contracts/universal-router/overview) for Universal Router details

