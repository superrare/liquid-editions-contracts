# Liquid Router Direct Call Examples

These examples show how to build `commands` and `inputs` for direct calls to the
Liquid Router using this Sepolia liquid edition:

```ts
const chainId = 11155111
const liquidRouter = "0x429c3Ee66E7f6CDA12C5BadE4104aF3277aA2305"
const liquidToken = "0x3A011493585f46e625E178a30338A944A456b105"
```

The edition contract resolves to this pool key:

```ts
const rare = "0x197FaeF3f59eC80113e773Bb6206a17d183F97CB"
const usdc = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
const eth = "0x0000000000000000000000000000000000000000"
const noHooks = "0x0000000000000000000000000000000000000000"

const liquidPoolKey = {
  currency0: rare,
  currency1: liquidToken,
  fee: 0,
  tickSpacing: 60,
  hooks: "0x90ef3674D843C7bBeA2e1f2bAfB2652dF18d20Cc",
}
```

## Command And Action Bytes

The examples below are all single `V4_SWAP` router commands:

```ts
const commands = "0x10"
```

The V4 swap command receives one ABI-encoded input:

```ts
abi.encode(["bytes", "bytes[]"], [actions, params])
```

For exact-input routes paid by the caller and paid out to the user, use:

```ts
const actions = "0x070c0f"
// 0x07 = SWAP_EXACT_IN
// 0x0c = SETTLE_ALL
// 0x0f = TAKE_ALL
```

Each `params` array has:

```ts
[
  exactInputSwapParams,
  settleAllParams,
  takeAllParams,
]
```

## Shared Viem Helpers

```ts
import {
  encodeAbiParameters,
  parseAbiParameters,
  type Address,
} from "viem"

const encode = (
  parameters: string,
  values: readonly unknown[]
): `0x${string}` => {
  return encodeAbiParameters(parseAbiParameters(parameters), values)
}

const dynamicOffset32 =
  "0x0000000000000000000000000000000000000000000000000000000000000020"

const prefixDynamicOffset = (value: `0x${string}`): `0x${string}` => {
  return `${dynamicOffset32}${value.slice(2)}` as `0x${string}`
}

const encodeV4ExactInInput = ({
  currencyIn,
  path,
  amountIn,
  minAmountOut,
  currencyOut,
}: {
  currencyIn: Address
  path: readonly (readonly [
    Address,
    number,
    number,
    Address,
    `0x${string}`,
  ])[]
  amountIn: bigint
  minAmountOut: bigint
  currencyOut: Address
}): `0x${string}` => {
  const actions = "0x070c0f"
  const exactInputSwapParams = encode(
    "(address,(address,uint24,int24,address,bytes)[],uint128,uint128)",
    [[currencyIn, path, amountIn, minAmountOut]]
  )

  return encode("bytes actions, bytes[] params", [
    actions,
    [
      currencyIn === eth
        ? exactInputSwapParams
        : prefixDynamicOffset(exactInputSwapParams),
      encode("address currency, uint128 maxAmount", [currencyIn, amountIn]),
      encode("address currency, uint128 minAmount", [
        currencyOut,
        minAmountOut,
      ]),
    ],
  ])
}
```

## ETH To Liquid With `buy`

Path:

```txt
ETH -> RARE -> LIQUID
```

Build the route bytes:

```ts
const ethAmountIn = 10000000000000000n
const minTokensOut = 900000000000000000n
const deadline = BigInt(Math.floor(Date.now() / 1000) + 20 * 60)

const commands = "0x10"
const inputs = [
  encodeV4ExactInInput({
    currencyIn: eth,
    path: [
      [rare, 3000, 60, noHooks, "0x"],
      [liquidToken, 0, 60, liquidPoolKey.hooks, "0x"],
    ],
    amountIn: ethAmountIn,
    minAmountOut: minTokensOut,
    currencyOut: liquidToken,
  }),
]
```

Call the router:

```ts
await walletClient.writeContract({
  address: liquidRouter,
  abi: LiquidRouterAbi,
  functionName: "buy",
  args: [
    liquidToken,
    recipient,
    minTokensOut,
    commands,
    inputs,
    deadline,
  ],
  value: ethAmountIn,
})
```

## Liquid To ETH With `sell`

Path:

```txt
LIQUID -> RARE -> ETH
```

Approve the router to spend `tokenAmount` of the liquid token before calling
`sell`.

Build the route bytes:

```ts
const tokenAmount = 1000000000000000000n
const minEthOut = 9000000000000000n
const deadline = BigInt(Math.floor(Date.now() / 1000) + 20 * 60)

const commands = "0x10"
const inputs = [
  encodeV4ExactInInput({
    currencyIn: liquidToken,
    path: [
      [rare, 0, 60, liquidPoolKey.hooks, "0x"],
      [eth, 3000, 60, noHooks, "0x"],
    ],
    amountIn: tokenAmount,
    minAmountOut: minEthOut,
    currencyOut: eth,
  }),
]
```

Call the router:

```ts
await walletClient.writeContract({
  address: liquidRouter,
  abi: LiquidRouterAbi,
  functionName: "sell",
  args: [
    liquidToken,
    tokenAmount,
    recipient,
    minEthOut,
    commands,
    inputs,
    deadline,
  ],
})
```

## RARE To Liquid With `swap`

Path:

```txt
RARE -> LIQUID
```

Approve the router to spend `rareAmountIn` before calling `swap`.

Build the route bytes:

```ts
const rareAmountIn = 1000000000000000000n
const minTokensOut = 900000000000000000n
const deadline = BigInt(Math.floor(Date.now() / 1000) + 20 * 60)

const commands = "0x10"
const inputs = [
  encodeV4ExactInInput({
    currencyIn: rare,
    path: [[liquidToken, 0, 60, liquidPoolKey.hooks, "0x"]],
    amountIn: rareAmountIn,
    minAmountOut: minTokensOut,
    currencyOut: liquidToken,
  }),
]
```

Call the router:

```ts
await walletClient.writeContract({
  address: liquidRouter,
  abi: LiquidRouterAbi,
  functionName: "swap",
  args: [
    rare,
    rareAmountIn,
    liquidToken,
    recipient,
    minTokensOut,
    commands,
    inputs,
    deadline,
  ],
})
```

## USDC To Liquid With `swap`

Path:

```txt
USDC -> ETH -> RARE -> LIQUID
```

Approve the router to spend `usdcAmountIn` before calling `swap`. Sepolia USDC
uses 6 decimals.

Build the route bytes:

```ts
const usdcAmountIn = 10000000n
const minTokensOut = 900000000000000000n
const deadline = BigInt(Math.floor(Date.now() / 1000) + 20 * 60)

const commands = "0x10"
const inputs = [
  encodeV4ExactInInput({
    currencyIn: usdc,
    path: [
      [eth, 3000, 60, noHooks, "0x"],
      [rare, 3000, 60, noHooks, "0x"],
      [liquidToken, 0, 60, liquidPoolKey.hooks, "0x"],
    ],
    amountIn: usdcAmountIn,
    minAmountOut: minTokensOut,
    currencyOut: liquidToken,
  }),
]
```

Call the router:

```ts
await walletClient.writeContract({
  address: liquidRouter,
  abi: LiquidRouterAbi,
  functionName: "swap",
  args: [
    usdc,
    usdcAmountIn,
    liquidToken,
    recipient,
    minTokensOut,
    commands,
    inputs,
    deadline,
  ],
})
```

## Notes

- `minTokensOut`, `minEthOut`, and `minAmountOut` should come from a quote with
  the user's chosen slippage.
- ETH routes use the zero address as the V4 native currency.
- `buy` with ETH must send `msg.value = ethAmountIn`.
- `sell` and ERC-20 `swap` routes require token approval for the Liquid Router.
- V4 exact-input params for ERC-20 input routes are prefixed with a 32-byte
  dynamic offset before being passed as `params[0]`; ETH input routes use the
  direct tuple encoding.
