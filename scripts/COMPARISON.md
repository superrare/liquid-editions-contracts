# Routing Options Comparison

Quick reference for choosing between different routing approaches for LiquidRouter integration.

## Side-by-Side Comparison

| Feature | Smart Order Router<br>`uniswap-smart-router.ts` | Manual V3 Quoter<br>`uniswap-quote.ts` | Uniswap API |
|---------|---------------------------------------------|----------------------------------|-------------|
| **V3 Support** | ✅ Yes | ✅ Yes | ✅ Yes |
| **V4 Support** | ✅ Yes | ❌ No | ✅ Yes |
| **V2 Support** | ✅ Yes | ❌ No | ✅ Yes |
| **Multi-hop Routes** | ✅ Automatic | ⚠️ Manual | ✅ Automatic |
| **Split Routes** | ✅ Yes | ❌ No | ✅ Yes |
| **Bundle Size** | ~2MB | ~100KB | ~10KB |
| **API Key Required** | ❌ No | ❌ No | ✅ Yes |
| **Rate Limits** | ❌ None | ❌ None | ✅ Yes (varies) |
| **RPC Calls per Quote** | 5-10 | 1 | 0 |
| **Setup Complexity** | Medium | Low | Very Low |
| **Best For** | Production apps | Simple V3-only | High-scale apps |

## Detailed Breakdown

### Smart Order Router (`uniswap-smart-router.ts`) ⭐ RECOMMENDED

```typescript
import { getSmartBuyQuote } from './uniswap-smart-router';

const quote = await getSmartBuyQuote({
  token: tokenAddress,
  tokenDecimals: 18,
  ethAmount: ethAmount.toString(),
  slippageBps: 50,
}, 8453);
```

**When to use**:
- ✅ Production applications
- ✅ Need best price across all pool types
- ✅ Want automatic V4 support
- ✅ Can handle 2MB bundle size
- ✅ Have reliable RPC provider

**When NOT to use**:
- ❌ Extreme bundle size constraints (<5MB total)
- ❌ Very rate-limited RPC
- ❌ Only trading established tokens with known V3 pools

**Performance**:
- First quote: ~2-3 seconds (on good RPC)
- Subsequent quotes: ~1-2 seconds (cached liquidity)
- Bundle size: ~2MB gzipped

---

### Manual V3 Quoter (`uniswap-quote.ts`)

```typescript
import { getBuyQuote } from './uniswap-quote';

const quote = await getBuyQuote({
  token: tokenAddress,
  ethAmount: ethAmount.toString(),
  fee: 3000, // Must specify pool fee
  slippageBps: 50,
}, 8453);
```

**When to use**:
- ✅ Small bundle size critical
- ✅ Only trading tokens with known V3 pools
- ✅ Simple integration needed
- ✅ Don't need V4 support

**When NOT to use**:
- ❌ Need V4 pool support
- ❌ Trading illiquid tokens (need multi-hop)
- ❌ Want automatic best price discovery

**Performance**:
- Quote time: <500ms
- Bundle size: ~100KB gzipped

---

### Uniswap API (Not Included)

```typescript
const response = await fetch('https://api.uniswap.org/v2/quote', {
  method: 'POST',
  headers: {
    'x-api-key': API_KEY,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    tokenIn: 'ETH',
    tokenOut: tokenAddress,
    amount: ethAmount,
    type: 'EXACT_INPUT',
  }),
});

const { methodParameters } = await response.json();
const routeData = methodParameters.calldata;
```

**When to use**:
- ✅ Have API key access
- ✅ Minimal client-side code
- ✅ High-scale application
- ✅ Want server-side quoting

**When NOT to use**:
- ❌ Can't get API key (currently limited access)
- ❌ Need guaranteed uptime (external dependency)
- ❌ Have privacy concerns (sends trades to Uniswap)

**Performance**:
- Quote time: <200ms (varies by region)
- Bundle size: ~10KB

## Decision Tree

```
Start
  │
  ├─ Do you have Uniswap API key?
  │   ├─ Yes → Use Uniswap API
  │   └─ No  ↓
  │
  ├─ Do you need V4 pool support?
  │   ├─ Yes → Use Smart Order Router ⭐
  │   └─ No  ↓
  │
  ├─ Is bundle size critical (<5MB total)?
  │   ├─ Yes → Manual V3 Quoter
  │   └─ No  → Smart Order Router ⭐
  │
  └─ Trading illiquid tokens?
      ├─ Yes → Smart Order Router ⭐
      └─ No  → Either works (Manual V3 is simpler)
```

## Migration Path

### Phase 1: V3 Only (Current)
```
Use: uniswap-quote.ts (Manual V3)
Status: Works today
```

### Phase 2: Add V4 Support (Recommended)
```
Use: uniswap-smart-router.ts (Smart Router)
Status: Deploy now, V4 support automatic when pools exist
Migration: Update client code, test on testnet
```

### Phase 3: Scale (Optional)
```
Use: Uniswap API
Status: When you get API access
Migration: Simplify client code, move quoting server-side
```

## Real-World Examples

### Example 1: NFT Marketplace

**Scenario**: Users buy/sell creator tokens alongside NFTs

**Best Choice**: **Smart Order Router**

**Why**:
- Creator tokens may have V4 pools
- Some creators may have illiquid pools (need multi-hop)
- 2MB bundle is acceptable for marketplace UI
- Self-hosted (no API key needed)

---

### Example 2: Simple Token Swap Widget

**Scenario**: Widget for swapping between USDC and a specific token

**Best Choice**: **Manual V3 Quoter**

**Why**:
- USDC/Token pool is known to be V3
- Bundle size matters for embeddable widget
- Simple use case doesn't need advanced routing

---

### Example 3: DEX Aggregator

**Scenario**: Platform comparing prices across protocols

**Best Choice**: **Smart Order Router**

**Why**:
- Need best possible prices
- Users expect multi-hop routing
- V4 support gives competitive advantage
- RPC costs acceptable for this use case

---

### Example 4: Trading Bot

**Scenario**: High-frequency automated trading

**Best Choice**: **Uniswap API** (if available)

**Why**:
- Fast response times
- Server-side quoting reduces latency
- Can batch multiple quotes
- No client bundle size concerns

## Cost Analysis

### RPC Costs (per quote)

| Method | RPC Calls | Cost per Quote<br>(at $5/1M requests) |
|--------|-----------|--------------------------------|
| Smart Order Router | ~8 calls | $0.00004 |
| Manual V3 Quoter | 1 call | $0.000005 |
| Uniswap API | 0 calls | $0 |

**Notes**:
- Costs are negligible for most applications
- Smart Router can cache liquidity data to reduce calls
- Consider if processing 1M+ quotes per day

### Development Time

| Method | Initial Setup | Maintenance |
|--------|--------------|-------------|
| Smart Order Router | 2-4 hours | Low |
| Manual V3 Quoter | 1-2 hours | Low |
| Uniswap API | 30 minutes | Very Low |

## Summary Recommendation

**For most projects integrating with LiquidRouter**:

```typescript
// Use Smart Order Router (uniswap-smart-router.ts)
import { getSmartBuyQuote, getSmartSellQuote } from './uniswap-smart-router';
```

**Why**:
1. ✅ Future-proof (V4 support built-in)
2. ✅ Best prices (automatic optimization)
3. ✅ No API key hassles
4. ✅ Self-hosted (no rate limits)
5. ✅ 2MB is acceptable for modern apps

**Only use Manual V3 Quoter if**:
- Bundle size is critical AND
- You only trade established tokens with V3 pools AND
- You don't need V4 support

**Use Uniswap API if**:
- You have API key access AND
- Building high-scale application

---

Still have questions? See `INTEGRATION_GUIDE.md` for full migration instructions.

