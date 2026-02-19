/**
 * Discover and stitch fixed Auctioneer routes:
 * - ETH -> RARE
 * - USDC -> RARE
 *
 * The script does two things:
 * 1) Route discovery (quote-time): choose a canonical route template per pair.
 * 2) Route stitching (run-time): inject user amount + minOut into the template
 *    to produce Universal Router `commands` + `inputs`.
 *
 * Usage:
 *   cd scripts
 *   npx ts-node auctioneer-route-planner.ts
 */

import { ethers } from "ethers";
import { AlphaRouter, SwapRoute, SwapType } from "@uniswap/smart-order-router";
import { CurrencyAmount, Percent, Token, TradeType } from "@uniswap/sdk-core";
import { UniversalRouterVersion } from "@uniswap/universal-router-sdk";
import * as dotenv from "dotenv";
import * as path from "path";

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const COMMANDS = {
  V3_SWAP_EXACT_IN: "0x00",
  V2_SWAP_EXACT_IN: "0x08",
  WRAP_ETH: "0x0b",
  V4_SWAP: "0x10",
} as const;

const RECIPIENTS = {
  MSG_SENDER: "0x0000000000000000000000000000000000000001",
  ROUTER: "0x0000000000000000000000000000000000000002",
} as const;

const V4_ACTIONS = {
  SWAP_EXACT_IN_SINGLE: 0x06,
  SETTLE_ALL: 0x0c,
  TAKE_ALL: 0x0f,
} as const;

const V4_QUOTER_ABI = [
  "function quoteExactInputSingle(tuple(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) params) external returns (uint256 amountOut, uint256 gasEstimate)",
];

const ERC20_ABI = [
  "function symbol() external view returns (string)",
  "function decimals() external view returns (uint8)",
];

const V4_CONTRACTS: Record<number, { quoter: string }> = {
  1: { quoter: "0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203" },
  11155111: { quoter: "0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227" },
  84532: { quoter: "0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa" },
  8453: { quoter: "0x0d5e0F971ED27FBfF6c2837bf31316121532048D" },
};

const V4_FEE_TIERS = [0, 100, 500, 3000, 10000];
const V4_TICK_SPACINGS: Record<number, number> = {
  0: 60,
  100: 1,
  500: 10,
  3000: 60,
  10000: 200,
};

const NETWORKS: Record<
  number,
  { rpcEnv: string[]; defaultRpc: string; weth: string; rare: string; usdc: string }
> = {
  1: {
    rpcEnv: ["ETH_MAINNET", "MAINNET_RPC_URL"],
    defaultRpc: "https://ethereum-rpc.publicnode.com",
    weth: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    rare: "0xba5BDe662c17e2aDFF1075610382B9B691296350",
    usdc: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  },
  8453: {
    rpcEnv: ["BASE_MAINNET", "BASE_RPC_URL"],
    defaultRpc: "https://base-rpc.publicnode.com",
    weth: "0x4200000000000000000000000000000000000006",
    rare: "0x691077C8e8de54EA84eFd454630439F99bd8C92f",
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  },
  11155111: {
    rpcEnv: ["ETH_SEPOLIA", "SEPOLIA_RPC_URL"],
    defaultRpc: "https://ethereum-sepolia-rpc.publicnode.com",
    weth: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
    rare: "0x197FaeF3f59eC80113e773Bb6206a17d183F97CB",
    usdc: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
  },
  84532: {
    rpcEnv: ["BASE_SEPOLIA"],
    defaultRpc: "https://sepolia.base.org",
    weth: "0x4200000000000000000000000000000000000006",
    rare: "0x8b21bC8571d11F7AdB705ad8F6f6BD1deb79cE01",
    usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
  },
};

type TemplateKind = "v2" | "v3" | "v4";

type BaseTemplate = {
  pair: "ETH_RARE" | "USDC_RARE";
  kind: TemplateKind;
  quoteProbeIn: string;
  quoteProbeOut: string;
};

type V4Template = BaseTemplate & {
  kind: "v4";
  currencyIn: string;
  currencyOut: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
};

type V3Template = BaseTemplate & {
  kind: "v3";
  path: string[];
  fees: number[];
};

type V2Template = BaseTemplate & {
  kind: "v2";
  path: string[];
};

type RouteTemplate = V2Template | V3Template | V4Template;

type StitchedRoute = {
  commands: string;
  inputs: string[];
  amountIn: string;
  minAmountOut: string;
};

type V4Quote = {
  amountOut: ethers.BigNumber;
  fee: number;
  tickSpacing: number;
  hooks: string;
};

function expandRpcUrl(url: string | undefined, fallback: string): string {
  if (!url) return fallback;
  if (url.includes("${ALCHEMY_API_KEY}")) {
    const key = process.env.ALCHEMY_API_KEY;
    if (key) return url.replace("${ALCHEMY_API_KEY}", key);
  }
  return url;
}

function pickRpc(chainId: number): string {
  const net = NETWORKS[chainId];
  if (!net) throw new Error(`Unsupported chainId=${chainId}`);
  for (const envKey of net.rpcEnv) {
    const value = process.env[envKey];
    if (value) return expandRpcUrl(value, net.defaultRpc);
  }
  return net.defaultRpc;
}

async function getV4DirectQuote(
  provider: ethers.providers.Provider,
  chainId: number,
  currencyIn: string,
  currencyOut: string,
  amountIn: ethers.BigNumber
): Promise<V4Quote | null> {
  const cfg = V4_CONTRACTS[chainId];
  if (!cfg) return null;

  const quoter = new ethers.Contract(cfg.quoter, V4_QUOTER_ABI, provider);
  let currency0 = currencyIn;
  let currency1 = currencyOut;
  let zeroForOne = true;

  if (currencyIn.toLowerCase() > currencyOut.toLowerCase()) {
    currency0 = currencyOut;
    currency1 = currencyIn;
    zeroForOne = false;
  }

  let best: V4Quote | null = null;
  for (const fee of V4_FEE_TIERS) {
    const tickSpacing = V4_TICK_SPACINGS[fee] ?? 60;
    const params = {
      poolKey: {
        currency0,
        currency1,
        fee,
        tickSpacing,
        hooks: ethers.constants.AddressZero,
      },
      zeroForOne,
      exactAmount: amountIn,
      hookData: "0x",
    };
    try {
      const result = await quoter.callStatic.quoteExactInputSingle(params);
      const out = ethers.BigNumber.from(result.amountOut);
      if (!best || out.gt(best.amountOut)) {
        best = {
          amountOut: out,
          fee,
          tickSpacing,
          hooks: ethers.constants.AddressZero,
        };
      }
    } catch {
      // No pool at this tier, skip.
    }
  }
  return best;
}

function parseAlphaSingleProtocol(route: SwapRoute): "V2" | "V3" | null {
  const protocols = route.route.map((r: any) => r.protocol);
  const uniq = [...new Set(protocols)];
  if (uniq.length !== 1) return null;
  if (uniq[0] === "V2" || uniq[0] === "V3") return uniq[0];
  return null;
}

function extractV3Path(route: SwapRoute): { path: string[]; fees: number[] } {
  const path: string[] = [];
  const fees: number[] = [];
  for (const leg of route.route as any[]) {
    if (leg.protocol !== "V3") continue;
    if (!path.length) path.push(leg.tokenPath[0].address);
    leg.tokenPath.slice(1).forEach((token: any, i: number) => {
      path.push(token.address);
      fees.push(leg.pools?.[i]?.fee ?? 3000);
    });
  }
  if (path.length < 2 || fees.length !== path.length - 1) {
    throw new Error("Unable to extract V3 path from Alpha route");
  }
  return { path, fees };
}

function extractV2Path(route: SwapRoute): string[] {
  const path: string[] = [];
  for (const leg of route.route as any[]) {
    if (leg.protocol !== "V2") continue;
    if (!path.length) path.push(leg.tokenPath[0].address);
    leg.tokenPath.slice(1).forEach((token: any) => path.push(token.address));
  }
  if (path.length < 2) throw new Error("Unable to extract V2 path from Alpha route");
  return path;
}

async function getAlphaRouteQuote(
  provider: ethers.providers.BaseProvider,
  chainId: number,
  tokenIn: Token,
  tokenOut: Token,
  amountInRaw: ethers.BigNumber
): Promise<{ amountOut: ethers.BigNumber; protocol: "V2" | "V3"; route: SwapRoute } | null> {
  const router = new AlphaRouter({ chainId, provider });
  const amountIn = CurrencyAmount.fromRawAmount(tokenIn, amountInRaw.toString());
  const route = await router.route(amountIn, tokenOut, TradeType.EXACT_INPUT, {
    type: SwapType.UNIVERSAL_ROUTER,
    recipient: RECIPIENTS.MSG_SENDER,
    slippageTolerance: new Percent(100, 10000),
    version: UniversalRouterVersion.V1_2,
  });
  if (!route) return null;
  const protocol = parseAlphaSingleProtocol(route);
  if (!protocol) return null;
  return {
    amountOut: ethers.BigNumber.from(route.quote.quotient.toString()),
    protocol,
    route,
  };
}

function encodeV4ExactIn(
  currencyIn: string,
  currencyOut: string,
  fee: number,
  tickSpacing: number,
  hooks: string,
  amountIn: ethers.BigNumber,
  amountOutMin: ethers.BigNumber
): { commands: string; inputs: string[] } {
  let currency0 = currencyIn;
  let currency1 = currencyOut;
  let zeroForOne = true;
  if (currencyIn.toLowerCase() > currencyOut.toLowerCase()) {
    currency0 = currencyOut;
    currency1 = currencyIn;
    zeroForOne = false;
  }

  const actions = ethers.utils.solidityPack(
    ["uint8", "uint8", "uint8"],
    [V4_ACTIONS.SWAP_EXACT_IN_SINGLE, V4_ACTIONS.SETTLE_ALL, V4_ACTIONS.TAKE_ALL]
  );
  const params: string[] = [];
  params.push(
    ethers.utils.defaultAbiCoder.encode(
      ["tuple(tuple(address,address,uint24,int24,address),bool,uint128,uint128,bytes)"],
      [[[currency0, currency1, fee, tickSpacing, hooks], zeroForOne, amountIn, amountOutMin, "0x"]]
    )
  );
  params.push(
    ethers.utils.defaultAbiCoder.encode(["address", "uint128"], [currencyIn, amountIn])
  );
  params.push(
    ethers.utils.defaultAbiCoder.encode(["address", "uint128"], [currencyOut, amountOutMin])
  );
  return {
    commands: COMMANDS.V4_SWAP,
    inputs: [ethers.utils.defaultAbiCoder.encode(["bytes", "bytes[]"], [actions, params])],
  };
}

function encodeV3ExactIn(
  path: string[],
  fees: number[],
  amountIn: ethers.BigNumber,
  minOut: ethers.BigNumber,
  payerIsUser: boolean
): { commands: string; inputs: string[] } {
  const pathTypes: string[] = [];
  const pathValues: (string | number)[] = [];
  for (let i = 0; i < path.length; i++) {
    pathTypes.push("address");
    pathValues.push(path[i]);
    if (i < path.length - 1) {
      pathTypes.push("uint24");
      pathValues.push(fees[i]);
    }
  }
  const v3Path = ethers.utils.solidityPack(pathTypes, pathValues);
  const input = ethers.utils.defaultAbiCoder.encode(
    ["address", "uint256", "uint256", "bytes", "bool"],
    [RECIPIENTS.MSG_SENDER, amountIn, minOut, v3Path, payerIsUser]
  );
  return { commands: COMMANDS.V3_SWAP_EXACT_IN, inputs: [input] };
}

function encodeV2ExactIn(
  path: string[],
  amountIn: ethers.BigNumber,
  minOut: ethers.BigNumber,
  payerIsUser: boolean
): { commands: string; inputs: string[] } {
  const input = ethers.utils.defaultAbiCoder.encode(
    ["address", "uint256", "uint256", "address[]", "bool"],
    [RECIPIENTS.MSG_SENDER, amountIn, minOut, path, payerIsUser]
  );
  return { commands: COMMANDS.V2_SWAP_EXACT_IN, inputs: [input] };
}

function stitchEthToRare(
  template: RouteTemplate,
  amountIn: ethers.BigNumber,
  minOut: ethers.BigNumber
): StitchedRoute {
  if (template.pair !== "ETH_RARE") throw new Error("Template is not ETH_RARE");

  if (template.kind === "v4") {
    const encoded = encodeV4ExactIn(
      template.currencyIn,
      template.currencyOut,
      template.fee,
      template.tickSpacing,
      template.hooks,
      amountIn,
      minOut
    );
    return {
      commands: encoded.commands,
      inputs: encoded.inputs,
      amountIn: amountIn.toString(),
      minAmountOut: minOut.toString(),
    };
  }

  const wrap = ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [RECIPIENTS.ROUTER, amountIn]);
  const swap =
    template.kind === "v3"
      ? encodeV3ExactIn(template.path, template.fees, amountIn, minOut, false)
      : encodeV2ExactIn(template.path, amountIn, minOut, false);
  return {
    commands: COMMANDS.WRAP_ETH + swap.commands.slice(2),
    inputs: [wrap, ...swap.inputs],
    amountIn: amountIn.toString(),
    minAmountOut: minOut.toString(),
  };
}

function stitchUsdcToRare(
  template: RouteTemplate,
  amountIn: ethers.BigNumber,
  minOut: ethers.BigNumber
): StitchedRoute {
  if (template.pair !== "USDC_RARE") throw new Error("Template is not USDC_RARE");

  let encoded: { commands: string; inputs: string[] };
  if (template.kind === "v4") {
    encoded = encodeV4ExactIn(
      template.currencyIn,
      template.currencyOut,
      template.fee,
      template.tickSpacing,
      template.hooks,
      amountIn,
      minOut
    );
  } else if (template.kind === "v3") {
    encoded = encodeV3ExactIn(template.path, template.fees, amountIn, minOut, true);
  } else {
    encoded = encodeV2ExactIn(template.path, amountIn, minOut, true);
  }
  return {
    commands: encoded.commands,
    inputs: encoded.inputs,
    amountIn: amountIn.toString(),
    minAmountOut: minOut.toString(),
  };
}

async function discoverEthRareTemplate(
  provider: ethers.providers.BaseProvider,
  chainId: number,
  weth: string,
  rare: string
): Promise<RouteTemplate> {
  const probeEthIn = ethers.utils.parseEther("0.10");
  const candidates: { amountOut: ethers.BigNumber; template: RouteTemplate; label: string }[] = [];

  const v4Quote = await getV4DirectQuote(
    provider,
    chainId,
    ethers.constants.AddressZero,
    rare,
    probeEthIn
  );
  if (v4Quote) {
    candidates.push({
      amountOut: v4Quote.amountOut,
      label: "v4-native",
      template: {
        pair: "ETH_RARE",
        kind: "v4",
        currencyIn: ethers.constants.AddressZero,
        currencyOut: rare,
        fee: v4Quote.fee,
        tickSpacing: v4Quote.tickSpacing,
        hooks: v4Quote.hooks,
        quoteProbeIn: probeEthIn.toString(),
        quoteProbeOut: v4Quote.amountOut.toString(),
      },
    });
  }

  const alpha = await getAlphaRouteQuote(
    provider,
    chainId,
    new Token(chainId, weth, 18, "WETH", "Wrapped Ether"),
    new Token(chainId, rare, 18, "RARE", "RARE"),
    probeEthIn
  );
  if (alpha) {
    if (alpha.protocol === "V3") {
      const { path, fees } = extractV3Path(alpha.route);
      candidates.push({
        amountOut: alpha.amountOut,
        label: "alpha-v3",
        template: {
          pair: "ETH_RARE",
          kind: "v3",
          path,
          fees,
          quoteProbeIn: probeEthIn.toString(),
          quoteProbeOut: alpha.amountOut.toString(),
        },
      });
    } else {
      candidates.push({
        amountOut: alpha.amountOut,
        label: "alpha-v2",
        template: {
          pair: "ETH_RARE",
          kind: "v2",
          path: extractV2Path(alpha.route),
          quoteProbeIn: probeEthIn.toString(),
          quoteProbeOut: alpha.amountOut.toString(),
        },
      });
    }
  }

  if (!candidates.length) throw new Error("No viable ETH->RARE route candidate found");
  const best = candidates.reduce((a, b) => (b.amountOut.gt(a.amountOut) ? b : a));
  console.log(`  Selected ETH->RARE: ${best.label} (${best.amountOut.toString()} out @ probe)`);
  return best.template;
}

async function discoverUsdcRareTemplate(
  provider: ethers.providers.BaseProvider,
  chainId: number,
  usdc: string,
  rare: string
): Promise<RouteTemplate> {
  const usdcToken = new ethers.Contract(usdc, ERC20_ABI, provider);
  const usdcDecimals: number = await usdcToken.decimals();
  const probeUsdcIn = ethers.utils.parseUnits("500", usdcDecimals);
  const candidates: { amountOut: ethers.BigNumber; template: RouteTemplate; label: string }[] = [];

  const v4Quote = await getV4DirectQuote(provider, chainId, usdc, rare, probeUsdcIn);
  if (v4Quote) {
    candidates.push({
      amountOut: v4Quote.amountOut,
      label: "v4-direct",
      template: {
        pair: "USDC_RARE",
        kind: "v4",
        currencyIn: usdc,
        currencyOut: rare,
        fee: v4Quote.fee,
        tickSpacing: v4Quote.tickSpacing,
        hooks: v4Quote.hooks,
        quoteProbeIn: probeUsdcIn.toString(),
        quoteProbeOut: v4Quote.amountOut.toString(),
      },
    });
  }

  const alpha = await getAlphaRouteQuote(
    provider,
    chainId,
    new Token(chainId, usdc, usdcDecimals, "USDC", "USD Coin"),
    new Token(chainId, rare, 18, "RARE", "RARE"),
    probeUsdcIn
  );
  if (alpha) {
    if (alpha.protocol === "V3") {
      const { path, fees } = extractV3Path(alpha.route);
      candidates.push({
        amountOut: alpha.amountOut,
        label: "alpha-v3",
        template: {
          pair: "USDC_RARE",
          kind: "v3",
          path,
          fees,
          quoteProbeIn: probeUsdcIn.toString(),
          quoteProbeOut: alpha.amountOut.toString(),
        },
      });
    } else {
      candidates.push({
        amountOut: alpha.amountOut,
        label: "alpha-v2",
        template: {
          pair: "USDC_RARE",
          kind: "v2",
          path: extractV2Path(alpha.route),
          quoteProbeIn: probeUsdcIn.toString(),
          quoteProbeOut: alpha.amountOut.toString(),
        },
      });
    }
  }

  if (!candidates.length) throw new Error("No viable USDC->RARE route candidate found");
  const best = candidates.reduce((a, b) => (b.amountOut.gt(a.amountOut) ? b : a));
  console.log(`  Selected USDC->RARE: ${best.label} (${best.amountOut.toString()} out @ probe)`);
  return best.template;
}

async function main() {
  const chainId = Number(process.env.CHAIN_ID ?? "11155111");
  const net = NETWORKS[chainId];
  if (!net) throw new Error(`Unsupported CHAIN_ID=${chainId}`);
  const rpcUrl = pickRpc(chainId);
  const provider = new ethers.providers.JsonRpcProvider(rpcUrl, chainId);

  const rareSymbol = await new ethers.Contract(net.rare, ERC20_ABI, provider).symbol();
  const usdcSymbol = await new ethers.Contract(net.usdc, ERC20_ABI, provider).symbol();
  const usdcDecimals: number = await new ethers.Contract(net.usdc, ERC20_ABI, provider).decimals();

  console.log("=".repeat(72));
  console.log("Auctioneer Route Planner");
  console.log("=".repeat(72));
  console.log(`Chain: ${chainId}`);
  console.log(`RPC: ${rpcUrl}`);
  console.log(`RARE: ${net.rare} (${rareSymbol})`);
  console.log(`USDC: ${net.usdc} (${usdcSymbol})`);
  console.log(`WETH: ${net.weth}`);

  console.log("\nDiscovering route templates...");
  const ethTemplate = await discoverEthRareTemplate(provider, chainId, net.weth, net.rare);
  const usdcTemplate = await discoverUsdcRareTemplate(provider, chainId, net.usdc, net.rare);

  const templates = {
    chainId,
    generatedAt: new Date().toISOString(),
    addresses: {
      weth: net.weth,
      rare: net.rare,
      usdc: net.usdc,
    },
    templates: {
      ethToRare: ethTemplate,
      usdcToRare: usdcTemplate,
    },
  };

  // Example stitch values (override via env for quick copy/paste testing)
  const ethForSwap = ethers.BigNumber.from(
    process.env.ETH_FOR_SWAP_WEI ?? ethers.utils.parseEther("0.05").toString()
  );
  const usdcIn = ethers.BigNumber.from(
    process.env.USDC_IN_RAW ?? ethers.utils.parseUnits("100", usdcDecimals).toString()
  );
  const minRareOut = ethers.BigNumber.from(process.env.MIN_RARE_OUT_RAW ?? "1");

  const stitchedEth = stitchEthToRare(ethTemplate, ethForSwap, minRareOut);
  const stitchedUsdc = stitchUsdcToRare(usdcTemplate, usdcIn, minRareOut);

  console.log("\n--- Route Templates (persist these) ---");
  console.log(JSON.stringify(templates, null, 2));

  console.log("\n--- Stitched payloads (user amount + minRareOut injected) ---");
  console.log(
    JSON.stringify(
      {
        exampleInputs: {
          ETH_FOR_SWAP_WEI: ethForSwap.toString(),
          USDC_IN_RAW: usdcIn.toString(),
          MIN_RARE_OUT_RAW: minRareOut.toString(),
        },
        stitched: {
          ethToRare: stitchedEth,
          usdcToRare: stitchedUsdc,
        },
      },
      null,
      2
    )
  );

  console.log("\nDone.");
}

main().catch((err) => {
  console.error("\nError:", err?.message ?? err);
  process.exit(1);
});

