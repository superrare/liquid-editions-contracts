# MultiCurve Liquidity: How It Works

## Overview

When a Liquid Edition token is created with MultiCurve, it deploys a Uniswap V4 concentrated liquidity pool with a built-in bonding curve. The bonding curve is funded entirely by LIQUID tokens — creators do not need to provide RARE to make it work.

At creation:
- **1,000,000 LIQUID tokens** are minted
- **100,000** go to the creator (launch reward)
- **900,000** are deposited into the Uniswap V4 pool as concentrated liquidity positions across the configured curve ranges

The pool starts at the cheap end of the curve. As buyers send RARE, the price moves up through the curve, and they receive LIQUID tokens from the pool positions.

## The Mental Model

Think of the 900,000 LIQUID tokens as the bonding curve itself. They sit in the pool waiting to be bought. No RARE is needed upfront because of how Uniswap V4 concentrated liquidity works:

- A position only holds the token that's on the **correct side of the current price**
- At launch, the price starts at the bottom of the curve
- All curve positions are above the current price → they hold only LIQUID
- As buyers push the price up, RARE flows into the positions and LIQUID flows out

This is fundamentally different from a traditional AMM where you need to seed both sides of the pool.

## Curve Configuration

Each curve is defined by four parameters:

| Parameter | Type | Description |
|---|---|---|
| `tickLower` | int24 | Lower tick boundary (cheap end of this segment) |
| `tickUpper` | int24 | Upper tick boundary (expensive end of this segment) |
| `numPositions` | uint16 | How many sub-positions within this range |
| `shares` | uint256 | Fraction of 900K tokens allocated (in WAD, must sum to 1e18) |

### Example Configuration

```json
[
  {
    "tickLower": -27000,
    "tickUpper": 0,
    "numPositions": 2,
    "shares": "100000000000000000"
  },
  {
    "tickLower": 0,
    "tickUpper": 28440,
    "numPositions": 3,
    "shares": "400000000000000000"
  },
  {
    "tickLower": 28440,
    "tickUpper": 60000,
    "numPositions": 5,
    "shares": "500000000000000000"
  }
]
```

This creates three bonding curve segments:

| Segment | Tick Range | % of Supply | LIQUID Tokens | Purpose |
|---|---|---|---|---|
| Trip Wire | -27000 → 0 | 10% | 90,000 | Early price discovery / anti-sniping |
| Distribution | 0 → 28440 | 40% | 360,000 | Main distribution phase |
| Steady State | 28440 → 60000 | 50% | 450,000 | Long-term price appreciation |

## How `numPositions` Works (Anti-Sniping)

Within each curve segment, the `numPositions` parameter controls how many overlapping concentrated liquidity positions are created. This is the anti-sniping mechanism.

With `numPositions: 1`, all tokens sit in a single position. A sniper could buy the entire allocation in one large trade at the cheapest price.

With `numPositions: 5`, the tokens are split across 5 overlapping positions that start at staggered ticks:

```
Position 0: [startTick₀, farTick] — covers the full range
Position 1: [startTick₁, farTick] — starts slightly higher
Position 2: [startTick₂, farTick] — starts higher still
...
```

Each position has the same number of tokens but covers a progressively narrower range. As the price moves up, new positions become active. A sniper trying to buy everything at the cheapest price only gets `1/numPositions` of the tokens before the price starts climbing.

More positions = stronger anti-sniping, but higher gas cost at initialization.

## What Happens During Trading

### Buying (RARE → LIQUID)

1. Buyer sends RARE to the pool via the LiquidRouter
2. Price moves up through curve positions
3. Buyer receives LIQUID tokens from positions as the price crosses their ranges
4. RARE accumulates in the positions (replacing the LIQUID that was sold)

### Selling (LIQUID → RARE)

1. Seller sends LIQUID to the pool via the LiquidRouter
2. Price moves down through curve positions
3. Seller receives RARE from positions (the RARE that was deposited by previous buyers)
4. LIQUID returns to the positions

### At the Top of the Curve

When the price reaches the top of the highest curve:
- All 900K LIQUID have been sold to buyers
- The curve positions are now full of RARE
- No more LIQUID can be bought (supply is exhausted)
- Sellers can still sell — pushing the price back down and extracting RARE from the pool
- The pool is fully self-sustaining at this point

**The top of the highest curve is effectively the price ceiling** for the token under normal operation.

## The Optional Head Position (Initial RARE)

The `_initialRareLiquidity` parameter is optional (can be 0). When non-zero, it creates an additional liquidity position that extends beyond the top of the highest curve, funded with the creator's RARE.

In practice, this position is rarely useful because:

1. The price can only reach it if ALL 900K LIQUID tokens have been bought
2. It sits beyond the curve range where there are no LIQUID tokens to sell
3. The price cannot organically move into this range through normal buy operations
4. With `LP_FEE = 0`, there's no incentive for external LPs to provide liquidity beyond the curve

**For most launches, setting initial RARE to 0 is recommended.** The bonding curve is fully functional without it.

## Tick-to-Price Relationship

Uniswap V4 ticks represent prices on a logarithmic scale. The formula is:

```
price = 1.0001^tick
```

Some reference points:

| Tick | Price (token1/token0) | Approximate Meaning |
|---|---|---|
| -27000 | ~0.067 | Very cheap LIQUID |
| 0 | 1.0 | 1:1 parity |
| 28440 | ~17.2 | ~17x from parity |
| 60000 | ~403 | ~400x from parity |

**Important**: The actual RARE/LIQUID price depends on token ordering (which address sorts lower). The ticks may be negated if LIQUID is token1 rather than token0. The `adjustCurves` function handles this automatically.

All ticks must be multiples of the pool's `tickSpacing` (default: 60).

## Supply Breakdown

| Allocation | Amount | Where It Goes |
|---|---|---|
| Creator Reward | 100,000 LIQUID | Sent directly to creator wallet at initialization |
| Pool Supply | 900,000 LIQUID | Distributed across curve positions in the Uniswap V4 pool |
| **Total** | **1,000,000 LIQUID** | |

The pool supply is distributed across curves proportionally to their `shares` values.

## Configuration Guidelines

### Wider Range = Thinner Liquidity
Spreading 900K tokens across a wide tick range means less liquidity density at any given price. This means:
- Lower slippage per dollar traded
- More RARE required to move the price significantly
- Smoother price curves

### Narrower Range = Denser Liquidity
Concentrating tokens in a narrow range means very high liquidity density:
- Individual trades get more tokens per RARE
- But the price moves faster through the range
- The entire supply can be bought with less total RARE

### Anti-Sniping: Use More Positions in Early Curves
The first curve segment (cheapest prices) is most vulnerable to sniping. Use higher `numPositions` values there. Later segments matter less for sniping since the price has already risen.

### Shares Must Sum to 1e18 (WAD)
The `shares` values across all curves must sum to exactly `1000000000000000000` (1e18). This represents 100% of the pool supply.
