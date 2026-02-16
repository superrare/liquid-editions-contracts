/**
 * Universal Router encoding for LiquidRouter swaps
 * 
 * This script generates the `routeData` parameter needed for LiquidRouter.buy() and
 * LiquidRouter.sell() by encoding Universal Router swap commands.
 * 
 * ROUTING STRATEGY:
 * 1. Query V4 pools directly via V4 Quoter
 * 2. Query V2/V3 pools via AlphaRouter
 * 3. Compare quotes and automatically choose the best price
 * 4. Encode the winning route for Universal Router
 * 
 * SUPPORTED PROTOCOLS:
 * - V2 swaps (via AlphaRouter)
 * - V3 single-hop and multi-hop (via AlphaRouter)
 * - V4 single-hop (via direct V4 Quoter - manual encoding)
 * - Mixed V2+V3 routes (via AlphaRouter)
 * 
 * ENCODING METHODS:
 * - V2/V3: Uses AlphaRouter's route info, manually encodes Universal Router commands
 * - V4: Manual encoding via V4_SWAP command (0x10) with actions/params
 * 
 * For ETH → Token buys:
 *   V2/V3: WRAP_ETH → V2/V3_SWAP (WETH required)
 *   V4:    V4_SWAP only (native ETH accepted via SETTLE_ALL)
 * 
 * For Token → ETH sells:
 *   V2/V3: V2/V3_SWAP → UNWRAP_WETH (outputs WETH, needs unwrapping)
 *   V4:    V4_SWAP only (outputs native ETH via TAKE_ALL)
 */

import { ethers } from 'ethers';
import { Token, CurrencyAmount, TradeType, Percent } from '@uniswap/sdk-core';
import { AlphaRouter, SwapType, SwapRoute } from '@uniswap/smart-order-router';
import { UniversalRouterVersion } from '@uniswap/universal-router-sdk';

// Universal Router command codes
const COMMANDS = {
  V3_SWAP_EXACT_IN: '0x00',
  V3_SWAP_EXACT_OUT: '0x01',
  PERMIT2_TRANSFER_FROM: '0x02',
  PERMIT2_PERMIT_BATCH: '0x03',
  SWEEP: '0x04',
  TRANSFER: '0x05',
  PAY_PORTION: '0x06',
  V2_SWAP_EXACT_IN: '0x08',
  V2_SWAP_EXACT_OUT: '0x09',
  PERMIT2_PERMIT: '0x0a',
  WRAP_ETH: '0x0b',
  UNWRAP_WETH: '0x0c',
  PERMIT2_TRANSFER_FROM_BATCH: '0x0d',
  BALANCE_CHECK_ERC20: '0x0e',
  V4_SWAP: '0x10',
  V3_POSITION_MANAGER_PERMIT: '0x11',
  V3_POSITION_MANAGER_CALL: '0x12',
  V4_POSITION_CALL: '0x13',
};

// Universal Router recipient placeholders
const RECIPIENTS = {
  MSG_SENDER: '0x0000000000000000000000000000000000000001',
  ROUTER: '0x0000000000000000000000000000000000000002',
};

// V4 action codes (from v4-periphery Actions.sol)
const V4_ACTIONS = {
  SWAP_EXACT_IN_SINGLE: 0x06,
  SWAP_EXACT_IN: 0x07, // Multi-hop swap
  SETTLE_ALL: 0x0c,
  SETTLE: 0x09,        // Settle specific amount (for intermediate hops)
  TAKE_ALL: 0x0f,
  TAKE: 0x0d,          // Take specific amount
};

// V4 Quoter ABI
const V4_QUOTER_ABI = [
  'function quoteExactInputSingle(tuple(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) params) external returns (uint256 amountOut, uint256 gasEstimate)',
];

// ABI to read poolKey and use quote functions on a Liquid token contract
const LIQUID_TOKEN_ABI = [
  'function poolKey() external view returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)',
  'function quoteBuy(uint256 rareIn) external returns (uint256 liquidOut, uint160 sqrtPriceX96After)',
  'function quoteSell(uint256 liquidIn) external returns (uint256 rareOut, uint160 sqrtPriceX96After)',
  'function getCurrentPrice() external view returns (uint256 rarePerToken, uint256 tokenPerRare)',
];

// QuoteResult(uint256,uint160) selector - Liquid tokens use revert-as-return for quotes
const QUOTE_RESULT_SELECTOR = '0x' + ethers.utils.id('QuoteResult(uint256,uint160)').slice(2, 10);

/**
 * Call quoteBuy and parse the revert-as-return result.
 * Liquid tokens' quoteBuy() reverts with QuoteResult(amountOut, sqrtPriceX96After).
 */
async function parseQuoteBuyRevert(
  provider: ethers.providers.Provider,
  tokenAddress: string,
  rareIn: ethers.BigNumber
): Promise<ethers.BigNumber | null> {
  return parseQuoteRevert(provider, tokenAddress, 'quoteBuy', [rareIn]);
}

/**
 * Call quoteSell and parse the revert-as-return result.
 * Liquid tokens' quoteSell() reverts with QuoteResult(amountOut, sqrtPriceX96After).
 */
async function parseQuoteSellRevert(
  provider: ethers.providers.Provider,
  tokenAddress: string,
  liquidIn: ethers.BigNumber
): Promise<ethers.BigNumber | null> {
  return parseQuoteRevert(provider, tokenAddress, 'quoteSell', [liquidIn]);
}

/**
 * Generic parser for Liquid token quote revert-as-return.
 * Both quoteBuy and quoteSell revert with QuoteResult(uint256, uint160).
 */
async function parseQuoteRevert(
  provider: ethers.providers.Provider,
  tokenAddress: string,
  fn: 'quoteBuy' | 'quoteSell',
  args: ethers.BigNumber[]
): Promise<ethers.BigNumber | null> {
  const contract = new ethers.Contract(tokenAddress, LIQUID_TOKEN_ABI, provider);
  const calldata = contract.interface.encodeFunctionData(fn, args);

  try {
    const result = await provider.call({ to: tokenAddress, data: calldata });
    return null; // Should not reach - quote functions always revert
  } catch (e: any) {
    // Extract revert data - ethers wraps it; try common locations
    let hex: string | undefined;
    for (const err of [e, e.error, e.error?.error]) {
      if (!err) continue;
      const d = err.data ?? err.result;
      if (d && typeof d === 'string' && d.startsWith('0x') && d.length > 10) {
        hex = d;
        break;
      }
    }
    if (!hex) {
      throw e;
    }
    if (!hex.startsWith(QUOTE_RESULT_SELECTOR)) {
      throw e;
    }
    const decoded = ethers.utils.defaultAbiCoder.decode(
      ['uint256', 'uint160'],
      '0x' + hex.slice(10)
    );
    return ethers.BigNumber.from(decoded[0]);
  }
}

// V4 contract addresses by chain
const V4_CONTRACTS: Record<number, { quoter: string; poolManager: string }> = {
  // Ethereum Mainnet
  1: {
    quoter: '0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203',
    poolManager: '0x000000000004444c5dc75cB358380D2e3dE08A90',
  },
  // Ethereum Sepolia
  11155111: {
    quoter: '0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227',
    poolManager: '0xE03A1074c86CFeDd5C142C4F04F1a1536e203543',
  },
  // Base Sepolia
  84532: {
    quoter: '0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa',
    poolManager: '0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408',
  },
  // Base Mainnet
  8453: {
    quoter: '0x0d5e0F971ED27FBfF6c2837bf31316121532048D',
    poolManager: '0x498581fF718922c3f8e6A244956aF099B2652b2b',
  },
};

// Common V4 fee tiers to check
// Note: Liquid tokens use fee=0, so we include it first
const V4_FEE_TIERS = [0, 100, 500, 3000, 10000]; // 0%, 0.01%, 0.05%, 0.3%, 1%
const V4_TICK_SPACINGS: Record<number, number> = {
  0: 60,    // Liquid tokens use tickSpacing=60 with fee=0
  100: 1,
  500: 10,
  3000: 60,
  10000: 200,
};

interface V4QuoteResult {
  amountOut: ethers.BigNumber;
  fee: number;
  tickSpacing: number;
  hooks: string; // hooks contract address (AddressZero for vanilla pools)
  poolId: string;
  gasEstimate: number;
}

/**
 * Get a direct V4 quote by querying the V4 Quoter
 * @param hooksOverride - If provided, only query pools with this hooks address (skip fee tier scan)
 * @param tickSpacingOverride - If provided, use this tick spacing instead of default for fee tier
 */
async function getV4DirectQuote(
  provider: ethers.providers.Provider,
  chainId: number,
  currencyIn: string, // Use address(0) for native ETH
  currencyOut: string,
  amountIn: ethers.BigNumber,
  isExactIn: boolean = true,
  hooksOverride?: string,
  tickSpacingOverride?: number
): Promise<V4QuoteResult | null> {
  const v4Contracts = V4_CONTRACTS[chainId];
  if (!v4Contracts) {
    return null; // V4 not deployed on this chain
  }

  const quoter = new ethers.Contract(v4Contracts.quoter, V4_QUOTER_ABI, provider);
  
  // Sort currencies for pool key
  let currency0 = currencyIn;
  let currency1 = currencyOut;
  let zeroForOne = true;
  
  if (currencyIn.toLowerCase() > currencyOut.toLowerCase()) {
    currency0 = currencyOut;
    currency1 = currencyIn;
    zeroForOne = false;
  }

  let bestQuote: V4QuoteResult | null = null;

  // If hooks override is provided, only try the specific pool configuration
  const feeTiersToTry = hooksOverride ? [0] : V4_FEE_TIERS;
  const hooksAddress = hooksOverride || ethers.constants.AddressZero;

  // Try all fee tiers to find the best quote
  for (const fee of feeTiersToTry) {
    const tickSpacing = tickSpacingOverride || V4_TICK_SPACINGS[fee] || 60;

    const quoteParams = {
      poolKey: {
        currency0,
        currency1,
        fee,
        tickSpacing,
        hooks: hooksAddress,
      },
      zeroForOne,
      exactAmount: amountIn,
      hookData: '0x',
    };

    try {
      const result = await quoter.callStatic.quoteExactInputSingle(quoteParams);
      const amountOut = ethers.BigNumber.from(result.amountOut);

      // Compute pool ID for reference
      const poolId = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode(
          ['address', 'address', 'uint24', 'int24', 'address'],
          [currency0, currency1, fee, tickSpacing, hooksAddress]
        )
      );

      // Keep best quote (highest output)
      if (!bestQuote || amountOut.gt(bestQuote.amountOut)) {
        bestQuote = {
          amountOut,
          fee,
          tickSpacing,
          hooks: hooksAddress,
          poolId,
          gasEstimate: result.gasEstimate?.toNumber() || 100000,
        };
      }
    } catch {
      // Pool doesn't exist at this fee tier, continue
    }
  }

  return bestQuote;
}

/**
 * Encode a direct V4 swap (single-hop)
 */
function encodeDirectV4Swap(
  currencyIn: string,
  currencyOut: string,
  fee: number,
  tickSpacing: number,
  amountIn: ethers.BigNumber,
  amountOutMin: ethers.BigNumber,
  hooks: string = ethers.constants.AddressZero
): { commands: string; inputs: string[]; description: string } {
  // Sort currencies
  let currency0 = currencyIn;
  let currency1 = currencyOut;
  let zeroForOne = true;

  if (currencyIn.toLowerCase() > currencyOut.toLowerCase()) {
    currency0 = currencyOut;
    currency1 = currencyIn;
    zeroForOne = false;
  }

  const actions = ethers.utils.solidityPack(
    ['uint8', 'uint8', 'uint8'],
    [V4_ACTIONS.SWAP_EXACT_IN_SINGLE, V4_ACTIONS.SETTLE_ALL, V4_ACTIONS.TAKE_ALL]
  );

  const params: string[] = [];

  params.push(ethers.utils.defaultAbiCoder.encode(
    ['tuple(tuple(address,address,uint24,int24,address),bool,uint128,uint128,bytes)'],
    [[
      [currency0, currency1, fee, tickSpacing, hooks],
      zeroForOne,
      amountIn,
      amountOutMin,
      '0x'
    ]]
  ));
  
  params.push(ethers.utils.defaultAbiCoder.encode(
    ['address', 'uint128'],
    [currencyIn, amountIn]
  ));
  
  params.push(ethers.utils.defaultAbiCoder.encode(
    ['address', 'uint128'],
    [currencyOut, amountOutMin]
  ));

  const v4SwapInput = ethers.utils.defaultAbiCoder.encode(
    ['bytes', 'bytes[]'],
    [actions, params]
  );

  const description = `V4(${currencyIn.slice(0, 6)}...${currencyIn.slice(-4)} → [${fee / 10000}%] → ${currencyOut.slice(0, 6)}...${currencyOut.slice(-4)})`;

  return {
    commands: COMMANDS.V4_SWAP,
    inputs: [v4SwapInput],
    description,
  };
}

interface ManualBuyQuoteParams {
  token: string;
  tokenDecimals: number;
  ethAmount: string;
  slippageBps?: number;
  recipient?: string;
  poolFee?: number; // Default 3000 (0.3%)
}

interface QuoteResult {
  amountOut: string;
  minAmountOut: string;
  routeData: string;
  deadline: number;
  route: string;
  gasEstimate: string;
}

function getDeadline(minutes: number = 20): number {
  return Math.floor(Date.now() / 1000) + (minutes * 60);
}

/**
 * Encode a swap path for the Universal Router based on the route type
 */
function encodeSwapPath(route: SwapRoute, isExactIn: boolean): { commands: string; inputs: any[]; description: string } {
  const routeStr = route.route.map((r: any) => r.protocol).join(' + ');
  
  // Detect route type
  const protocols = route.route.map((r: any) => r.protocol);
  if (protocols.includes('V4')) {
    throw new Error('AlphaRouter routes do not include V4. Use encodeDirectV4Swap for V4 pools.');
  }
  const hasV3 = protocols.includes('V3');
  const hasV2 = protocols.includes('V2');
  const hasMixed = new Set(protocols).size > 1;

  if (hasMixed) {
    // Mixed routes require multiple swap commands
    return encodeMixedRoute(route, isExactIn);
  } else if (hasV3) {
    return encodeV3Route(route, isExactIn);
  } else if (hasV2) {
    return encodeV2Route(route, isExactIn);
  } else {
    throw new Error(`Unsupported route type: ${routeStr}`);
  }
}

/**
 * Encode a V3-only route
 */
function encodeV3Route(route: SwapRoute, isExactIn: boolean): { commands: string; inputs: any[]; description: string } {
  const path: string[] = [];
  const fees: number[] = [];
  
  // Extract tokens and fees from route
  route.route.forEach((r: any) => {
    if (r.protocol === 'V3') {
      // V3 route has tokenPath and pools with fee tiers
      if (!path.length) {
        path.push(r.tokenPath[0].address);
      }
      r.tokenPath.slice(1).forEach((token: any, i: number) => {
        path.push(token.address);
        // Get fee from pool if available
        const pool = r.pools?.[i];
        fees.push(pool?.fee || 3000);
      });
    }
  });

  // Encode V3 path: token0 + fee0 + token1 + fee1 + token2...
  const pathTypes: string[] = [];
  const pathValues: any[] = [];
  
  for (let i = 0; i < path.length; i++) {
    pathTypes.push('address');
    pathValues.push(path[i]);
    if (i < path.length - 1) {
      pathTypes.push('uint24');
      pathValues.push(fees[i]);
    }
  }
  
  const pathEncoded = ethers.utils.solidityPack(pathTypes, pathValues);
  
  const description = `V3(${path.map((p, i) => 
    i < path.length - 1 ? `${p.slice(0, 6)}...${p.slice(-4)} → [${fees[i] / 10000}%]` : `${p.slice(0, 6)}...${p.slice(-4)}`
  ).join(' → ')})`;
  
  return {
    commands: isExactIn ? COMMANDS.V3_SWAP_EXACT_IN : COMMANDS.V3_SWAP_EXACT_OUT,
    inputs: [pathEncoded],
    description,
  };
}

/**
 * Encode a V2-only route
 */
function encodeV2Route(route: SwapRoute, isExactIn: boolean): { commands: string; inputs: any[]; description: string } {
  const path: string[] = [];
  
  // Extract tokens from route
  route.route.forEach((r: any) => {
    if (r.protocol === 'V2') {
      if (!path.length) {
        path.push(r.tokenPath[0].address);
      }
      r.tokenPath.slice(1).forEach((token: any) => {
        path.push(token.address);
      });
    }
  });

  const description = `V2(${path.map(p => `${p.slice(0, 6)}...${p.slice(-4)}`).join(' → ')})`;
  
  return {
    commands: isExactIn ? COMMANDS.V2_SWAP_EXACT_IN : COMMANDS.V2_SWAP_EXACT_OUT,
    inputs: [path], // V2 just needs array of addresses
    description,
  };
}

function encodeMixedRoute(route: SwapRoute, isExactIn: boolean): { commands: string; inputs: any[]; description: string } {
  const commands: string[] = [];
  const inputs: any[] = [];
  const descriptions: string[] = [];
  
  route.route.forEach((r: any) => {
    if (r.protocol === 'V3') {
      const v3Result = encodeV3Route({ route: [r] } as any, isExactIn);
      commands.push(v3Result.commands);
      inputs.push(v3Result.inputs[0]);
      descriptions.push(v3Result.description);
    } else if (r.protocol === 'V2') {
      const v2Result = encodeV2Route({ route: [r] } as any, isExactIn);
      commands.push(v2Result.commands);
      inputs.push(v2Result.inputs[0]);
      descriptions.push(v2Result.description);
    } else {
      throw new Error(`Unsupported protocol in mixed route: ${r.protocol}`);
    }
  });
  
  return {
    commands: commands.join('').replace(/0x/g, (match, offset) => offset === 0 ? '0x' : ''),
    inputs,
    description: descriptions.join(' → '),
  };
}

/**
 * Get multi-hop quote for Liquid tokens: ETH → RARE → Liquid Token
 * This handles the two-hop route required for Liquid tokens which are paired with RARE, not ETH
 */
async function getMultiHopLiquidQuote(
  provider: ethers.providers.Provider,
  chainId: number,
  wethAddress: string,
  baseTokenAddress: string, // RARE address
  liquidTokenAddress: string,
  ethForSwap: ethers.BigNumber,
  slippageBps: number
): Promise<{
  amountOut: ethers.BigNumber;
  rareAmount: ethers.BigNumber;
  v4Quote: V4QuoteResult;
  description: string;
  firstHop: {
    type: 'v4' | 'v3';
    v4Quote?: V4QuoteResult;
    v3Fee?: number;
    usesNativeEth: boolean;
  };
} | null> {
  console.log(`  Checking multi-hop: ETH → RARE → Liquid...`);
  
  // Step 1: Quote ETH → RARE via V4 (or could use V3)
  // First check if there's a V4 pool for ETH/RARE
  // Try both native ETH (address(0)) and WETH addresses
  let ethToRareV4 = await getV4DirectQuote(
    provider,
    chainId,
    ethers.constants.AddressZero, // Native ETH
    baseTokenAddress, // RARE
    ethForSwap
  );
  
  let usesNativeEth = true;
  
  // If no pool found with native ETH, try WETH
  if (!ethToRareV4) {
    ethToRareV4 = await getV4DirectQuote(
      provider,
      chainId,
      wethAddress, // WETH
      baseTokenAddress, // RARE
      ethForSwap
    );
    usesNativeEth = false;
  }
  
  let rareAmount: ethers.BigNumber;
  let ethToRareRoute: string;
  let firstHop: { type: 'v4' | 'v3'; v4Quote?: V4QuoteResult; v3Fee?: number; usesNativeEth: boolean };
  
  if (ethToRareV4) {
    rareAmount = ethToRareV4.amountOut;
    ethToRareRoute = `V4(${ethToRareV4.fee / 10000}%)`;
    firstHop = { type: 'v4', v4Quote: ethToRareV4, usesNativeEth };
    console.log(`    ETH → RARE: ${ethers.utils.formatEther(rareAmount)} RARE via ${ethToRareRoute}`);
  } else {
    // Try V3 for ETH → RARE (common fee tiers)
    // Get V3 Quoter address by chain
    let v3QuoterAddress: string;
    if (chainId === 8453) {
      v3QuoterAddress = '0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a'; // Base Mainnet V3 QuoterV2
    } else if (chainId === 84532) {
      v3QuoterAddress = '0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a'; // Base Sepolia V3 QuoterV2 (same as Base)
    } else if (chainId === 11155111) {
      v3QuoterAddress = '0xEd1f6473345F4150F13EeE36E51F4C2F43f63975'; // Ethereum Sepolia V3 QuoterV2
    } else {
      v3QuoterAddress = '0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6'; // Ethereum Mainnet V3 QuoterV2
    }
    
    const v3Quoter = new ethers.Contract(
      v3QuoterAddress,
      ['function quoteExactInputSingle(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint160 sqrtPriceLimitX96) external returns (uint256 amountOut)'],
      provider
    );
    
    // Try common V3 fee tiers
    const v3FeeTiers = [500, 3000, 10000]; // 0.05%, 0.3%, 1%
    let bestV3Quote: ethers.BigNumber | null = null;
    let bestV3Fee = 0;
    
    for (const fee of v3FeeTiers) {
      try {
        const quote = await v3Quoter.callStatic.quoteExactInputSingle(
          wethAddress,
          baseTokenAddress,
          fee,
          ethForSwap,
          0
        );
        if (!bestV3Quote || quote.gt(bestV3Quote)) {
          bestV3Quote = quote;
          bestV3Fee = fee;
        }
      } catch {
        // Pool doesn't exist at this fee tier
      }
    }
    
    if (bestV3Quote) {
      rareAmount = bestV3Quote;
      ethToRareRoute = `V3(${bestV3Fee / 10000}%)`;
      firstHop = { type: 'v3', v3Fee: bestV3Fee, usesNativeEth: false };
      console.log(`    ETH → RARE: ${ethers.utils.formatEther(rareAmount)} RARE via ${ethToRareRoute}`);
    } else {
      console.log(`    ✗ No ETH → RARE route found`);
      return null;
    }
  }
  
  // Step 2: Quote RARE → Liquid token via V4
  // Read the pool key from the Liquid token to get the correct hooks address and tick spacing
  const liquidTokenContract = new ethers.Contract(liquidTokenAddress, LIQUID_TOKEN_ABI, provider);
  let liquidPoolHooks = ethers.constants.AddressZero;
  let liquidPoolTickSpacing: number | undefined;
  try {
    const poolKeyResult = await liquidTokenContract.poolKey();
    liquidPoolHooks = poolKeyResult.hooks;
    liquidPoolTickSpacing = poolKeyResult.tickSpacing;
    console.log(`    Pool hooks: ${liquidPoolHooks}`);
    console.log(`    Pool tick spacing: ${liquidPoolTickSpacing}`);
  } catch (e: any) {
    console.log(`    ⚠ Could not read poolKey from token (${e.message?.slice(0, 40)}), trying without hooks`);
  }

  // Apply slippage to RARE amount for the next hop
  const rareForSwap = rareAmount.mul(10000 - Math.floor(slippageBps / 2)).div(10000);

  let rareToLiquidV4 = await getV4DirectQuote(
    provider,
    chainId,
    baseTokenAddress, // RARE
    liquidTokenAddress,
    rareForSwap,
    true, // isExactIn
    liquidPoolHooks !== ethers.constants.AddressZero ? liquidPoolHooks : undefined,
    liquidPoolTickSpacing
  );

  // If V4 Quoter fails (common with hooked pools), try the token's own quoteBuy()
  // Note: quoteBuy uses revert-as-return (reverts with QuoteResult) - we must parse the revert data
  // LiquidSwapGuard blocks quoteBuy (swap simulation) - fall back to getCurrentPrice() spot estimate
  if (!rareToLiquidV4) {
    console.log(`    V4 Quoter failed, trying token's quoteBuy()...`);
    try {
      const liquidOut = await parseQuoteBuyRevert(provider, liquidTokenAddress, rareForSwap);
      if (liquidOut && liquidOut.gt(0)) {
        rareToLiquidV4 = {
          amountOut: liquidOut,
          fee: 0,
          tickSpacing: liquidPoolTickSpacing || 60,
          hooks: liquidPoolHooks,
          poolId: '', // Not needed for encoding (we use hooks/fee/tickSpacing)
          gasEstimate: 200000,
        };
        console.log(`    RARE → Liquid: ${ethers.utils.formatEther(liquidOut)} tokens via token quoteBuy()`);
      }
    } catch (e: any) {
      console.log(`    ✗ token quoteBuy() also failed: ${e.message?.slice(0, 60)}`);
    }
  }

  // Fallback: LiquidSwapGuard blocks quoteBuy - use getCurrentPrice() for spot estimate
  if (!rareToLiquidV4) {
    console.log(`    Trying getCurrentPrice() spot estimate (LiquidSwapGuard blocks quoteBuy)...`);
    try {
      const priceResult = await liquidTokenContract.getCurrentPrice();
      const tokenPerRare = ethers.BigNumber.from(priceResult.tokenPerRare);
      if (tokenPerRare.gt(0)) {
        // liquidOut = rareIn * tokenPerRare / 1e18 (spot price, 1e18 scale)
        const liquidOut = rareForSwap.mul(tokenPerRare).div(ethers.constants.WeiPerEther);
        // Apply 5% conservative buffer - spot price underestimates for buys (price moves up)
        const conservativeOut = liquidOut.mul(95).div(100);
        if (conservativeOut.gt(0)) {
          rareToLiquidV4 = {
            amountOut: conservativeOut,
            fee: 0,
            tickSpacing: liquidPoolTickSpacing || 60,
            hooks: liquidPoolHooks,
            poolId: '',
            gasEstimate: 200000,
          };
          console.log(`    RARE → Liquid: ~${ethers.utils.formatEther(conservativeOut)} tokens (spot estimate, 5% buffer)`);
        }
      }
    } catch (e: any) {
      console.log(`    ✗ getCurrentPrice() failed: ${e.message?.slice(0, 50)}`);
    }
  }

  if (!rareToLiquidV4) {
    console.log(`    ✗ No RARE → Liquid V4 pool found`);
    return null;
  }

  if (rareToLiquidV4.poolId !== '') {
    console.log(`    RARE → Liquid: ${ethers.utils.formatEther(rareToLiquidV4.amountOut)} tokens via V4(${rareToLiquidV4.fee / 10000}%)`);
  }

  return {
    amountOut: rareToLiquidV4.amountOut,
    rareAmount,
    v4Quote: rareToLiquidV4,
    description: `ETH → RARE (${ethToRareRoute}) → Liquid (V4 ${rareToLiquidV4.fee / 10000}%)`,
    firstHop,
  };
}

/**
 * Encode multi-hop swap: ETH → RARE → Liquid token
 * 
 * For V4→V4 multi-hop, we use a SINGLE V4_SWAP command with both swaps.
 * The PoolManager tracks deltas internally, so:
 * 1. Settle ETH (input)
 * 2. First swap: ETH → RARE (RARE stays as internal delta)
 * 3. Second swap: RARE → Liquid (uses RARE delta from first swap)
 * 4. Take Liquid tokens (output)
 * 
 * For V3→V4 multi-hop, we need separate commands:
 * 1. WRAP_ETH
 * 2. V3_SWAP (outputs RARE to router)
 * 3. V4_SWAP (router has RARE, needs to settle via Permit2)
 */
function encodeMultiHopV4Swap(
  wethAddress: string,
  baseTokenAddress: string, // RARE
  liquidTokenAddress: string,
  ethAmount: ethers.BigNumber,
  rareAmount: ethers.BigNumber,
  liquidTokenAmountMin: ethers.BigNumber,
  v4RareToLiquid: V4QuoteResult,
  firstHop: { type: 'v4' | 'v3'; v4Quote?: V4QuoteResult; v3Fee?: number; usesNativeEth: boolean }
): { commands: string; inputs: string[]; description: string } {
  const commands: string[] = [];
  const inputs: string[] = [];
  const descriptions: string[] = [];
  
  // ============================================
  // CASE 1: V4 → V4 (single V4_SWAP with both hops)
  // ============================================
  if (firstHop.type === 'v4' && firstHop.v4Quote) {
    const v4Quote = firstHop.v4Quote;
    
    // Sort currencies for first hop (ETH → RARE)
    let currency0_1 = firstHop.usesNativeEth ? ethers.constants.AddressZero : wethAddress;
    let currency1_1 = baseTokenAddress;
    let zeroForOne1 = true;
    
    if (currency0_1.toLowerCase() > currency1_1.toLowerCase()) {
      [currency0_1, currency1_1] = [currency1_1, currency0_1];
      zeroForOne1 = false;
    }
    
    // Sort currencies for second hop (RARE → Liquid)
    let currency0_2 = baseTokenAddress;
    let currency1_2 = liquidTokenAddress;
    let zeroForOne2 = true;
    
    if (currency0_2.toLowerCase() > currency1_2.toLowerCase()) {
      [currency0_2, currency1_2] = [currency1_2, currency0_2];
      zeroForOne2 = false;
    }
    
    // Build actions: 
    // 1. First swap (ETH → RARE)
    // 2. Second swap (RARE → Liquid) 
    // 3. Settle ETH input
    // 4. Take Liquid output
    // Note: RARE is intermediate and balances out via internal deltas
    const actions = ethers.utils.solidityPack(
      ['uint8', 'uint8', 'uint8', 'uint8'],
      [
        V4_ACTIONS.SWAP_EXACT_IN_SINGLE, // First swap
        V4_ACTIONS.SWAP_EXACT_IN_SINGLE, // Second swap
        V4_ACTIONS.SETTLE_ALL,           // Settle ETH
        V4_ACTIONS.TAKE_ALL,             // Take Liquid
      ]
    );
    
    const params: string[] = [];
    
    // First swap params (ETH → RARE)
    params.push(ethers.utils.defaultAbiCoder.encode(
      ['tuple(tuple(address,address,uint24,int24,address),bool,uint128,uint128,bytes)'],
      [[
        [currency0_1, currency1_1, v4Quote.fee, v4Quote.tickSpacing, v4Quote.hooks],
        zeroForOne1,
        ethAmount,
        0, // No min for intermediate (we check final output)
        '0x'
      ]]
    ));

    // Second swap params (RARE → Liquid)
    // Use 0 as amountIn to signal "use delta from previous swap"
    // Actually, we need to use the expected rareAmount
    params.push(ethers.utils.defaultAbiCoder.encode(
      ['tuple(tuple(address,address,uint24,int24,address),bool,uint128,uint128,bytes)'],
      [[
        [currency0_2, currency1_2, v4RareToLiquid.fee, v4RareToLiquid.tickSpacing, v4RareToLiquid.hooks],
        zeroForOne2,
        rareAmount,
        liquidTokenAmountMin,
        '0x'
      ]]
    ));
    
    // Settle ETH (input currency)
    params.push(ethers.utils.defaultAbiCoder.encode(
      ['address', 'uint128'],
      [firstHop.usesNativeEth ? ethers.constants.AddressZero : wethAddress, ethAmount]
    ));
    
    // Take Liquid tokens (output currency)
    params.push(ethers.utils.defaultAbiCoder.encode(
      ['address', 'uint128'],
      [liquidTokenAddress, liquidTokenAmountMin]
    ));
    
    const v4SwapInput = ethers.utils.defaultAbiCoder.encode(
      ['bytes', 'bytes[]'],
      [actions, params]
    );
    
    commands.push(COMMANDS.V4_SWAP);
    inputs.push(v4SwapInput);
    descriptions.push(`ETH → RARE (V4 ${v4Quote.fee / 10000}%) → Liquid (V4 ${v4RareToLiquid.fee / 10000}%)`);
    
  } else if (firstHop.type === 'v3' && firstHop.v3Fee !== undefined) {
    // ============================================
    // CASE 2: V3 → V4 (separate commands)
    // ============================================
    // V3 swap requires wrapping ETH first
    // 1. WRAP_ETH
    const wrapEthInput = ethers.utils.defaultAbiCoder.encode(
      ['address', 'uint256'],
      [RECIPIENTS.ROUTER, ethAmount]
    );
    
    commands.push(COMMANDS.WRAP_ETH);
    inputs.push(wrapEthInput);
    descriptions.push('WRAP_ETH');
    
    // 2. V3_SWAP_EXACT_IN (WETH → RARE)
    // Output to ROUTER so we can use it for V4 swap
    const path = ethers.utils.solidityPack(
      ['address', 'uint24', 'address'],
      [wethAddress, firstHop.v3Fee, baseTokenAddress]
    );
    
    const v3SwapInput = ethers.utils.defaultAbiCoder.encode(
      ['address', 'uint256', 'uint256', 'bytes', 'bool'],
      [RECIPIENTS.ROUTER, ethAmount, rareAmount.mul(10000 - 100).div(10000), path, false]
    );
    
    commands.push(COMMANDS.V3_SWAP_EXACT_IN);
    inputs.push(v3SwapInput);
    descriptions.push(`WETH → RARE (V3 ${firstHop.v3Fee / 10000}%)`);
    
    // 3. V4_SWAP (RARE → Liquid)
    // The RARE is now in the Universal Router
    // For V4, we need to transfer RARE to the PoolManager via Permit2
    // But Universal Router has the RARE, and needs to approve Permit2
    // This is complex... let's use a different approach
    
    // Actually, for V3→V4, we need the Universal Router to transfer RARE to PoolManager
    // The Universal Router doesn't auto-approve Permit2 for intermediate tokens
    // So this case is very complex and may not work without custom integration
    
    // For now, let's sort currencies for RARE → Liquid pool
    let currency0 = baseTokenAddress;
    let currency1 = liquidTokenAddress;
    let zeroForOne = true;
    
    if (baseTokenAddress.toLowerCase() > liquidTokenAddress.toLowerCase()) {
      currency0 = liquidTokenAddress;
      currency1 = baseTokenAddress;
      zeroForOne = false;
    }

    // Try using SETTLE (0x09) which takes from msg.sender balance in PoolManager
    // But after V3 swap, the RARE is in Universal Router, not PoolManager
    // This won't work directly...
    
    // Alternative: Use TRANSFER command to move RARE from router to PoolManager
    // But that's also complex...
    
    // For V3→V4, the simplest solution is to:
    // 1. Do the V3 swap with output to MSG_SENDER (LiquidRouter)
    // 2. Have LiquidRouter approve Permit2 for RARE
    // 3. Then V4 can pull RARE via Permit2
    // But this requires changes to LiquidRouter contract...
    
    // For now, throw an error for V3→V4 routes
    throw new Error('V3→V4 multi-hop not yet supported. Please ensure ETH→RARE has a V4 pool.');
    
  } else {
    throw new Error('Invalid first hop type');
  }

  // Combine commands (remove 0x prefix from all but first)
  const combinedCommands = commands.join('').replace(/0x/g, (match, offset) => offset === 0 ? '0x' : '');

  return {
    commands: combinedCommands,
    inputs,
    description: descriptions.join(' → '),
  };
}

/**
 * Encode Universal Router calldata for ETH → Token buy
 * 
 * For Liquid tokens (paired with RARE), pass baseTokenAddress to enable multi-hop routing:
 * ETH → RARE → Liquid token
 */
export async function getManualBuyQuote(
  params: ManualBuyQuoteParams & { baseTokenAddress?: string },
  chainId: number,
  rpcUrl: string,
  wethAddress: string,
  liquidRouterFeeBps: number // Fee that LiquidRouter takes (read from contract)
): Promise<QuoteResult> {
  const {
    token,
    tokenDecimals,
    ethAmount,
    slippageBps = 500,
    recipient,
    poolFee = 3000,
    baseTokenAddress, // Optional: RARE address for Liquid tokens
  } = params;

  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const ethAmountBN = ethers.BigNumber.from(ethAmount);
  const ethForSwap = ethAmountBN.mul(10000 - liquidRouterFeeBps).div(10000);

  console.log(`Getting quote for ${ethers.utils.formatEther(ethForSwap)} ETH → ${token.slice(0, 10)}...`);
  
  // ============================================
  // Step 1: Try multi-hop if baseTokenAddress provided (Liquid tokens)
  // ============================================
  let multiHopQuote: Awaited<ReturnType<typeof getMultiHopLiquidQuote>> = null;
  
  if (baseTokenAddress) {
    multiHopQuote = await getMultiHopLiquidQuote(
      provider,
      chainId,
      wethAddress,
      baseTokenAddress,
      token,
      ethForSwap,
      slippageBps
    );
    
    if (multiHopQuote) {
      console.log(`  ✓ Multi-hop Quote: ${ethers.utils.formatEther(multiHopQuote.amountOut)} tokens`);
      console.log(`    Route: ${multiHopQuote.description}`);
    }
  }
  
  // ============================================
  // Step 2: Try direct V4 quote (ETH → token)
  // ============================================
  console.log(`  Checking direct V4 pools...`);
  const v4Quote = await getV4DirectQuote(
    provider,
    chainId,
    ethers.constants.AddressZero, // Native ETH
    token,
    ethForSwap
  );
  
  if (v4Quote) {
    console.log(`  ✓ Direct V4 Quote: ${ethers.utils.formatUnits(v4Quote.amountOut, tokenDecimals)} tokens (${v4Quote.fee / 10000}% fee)`);
  } else {
    console.log(`  ✗ No direct V4 pools found`);
  }

  // ============================================
  // Step 3: Get AlphaRouter quote (V2/V3)
  // ============================================
  console.log(`  Checking V2/V3 via AlphaRouter...`);
  let alphaRoute: SwapRoute | null = null;
  let alphaAmountOut = ethers.BigNumber.from(0);
  
  try {
    const router = new AlphaRouter({ chainId, provider });
    
    const wethToken = new Token(chainId, wethAddress, 18, 'WETH', 'Wrapped Ether');
    const outputToken = new Token(chainId, token, tokenDecimals);
    
    const amountIn = CurrencyAmount.fromRawAmount(wethToken, ethForSwap.toString());
    
    alphaRoute = await router.route(
      amountIn,
      outputToken,
      TradeType.EXACT_INPUT,
      {
        type: SwapType.UNIVERSAL_ROUTER,
        recipient: recipient || RECIPIENTS.MSG_SENDER,
        slippageTolerance: new Percent(slippageBps, 10000),
        version: UniversalRouterVersion.V1_2,
      }
    );

    alphaAmountOut = alphaRoute ? ethers.BigNumber.from(alphaRoute.quote.quotient.toString()) : ethers.BigNumber.from(0);
    
    if (alphaRoute) {
      console.log(`  ✓ AlphaRouter Quote: ${ethers.utils.formatUnits(alphaAmountOut, tokenDecimals)} tokens (${alphaRoute.route.map((r: any) => r.protocol).join('+')})`);
    } else {
      console.log(`  ✗ No V2/V3 route found`);
    }
  } catch (e: any) {
    console.log(`  ✗ AlphaRouter failed: ${e.message?.slice(0, 50) || 'unknown error'}`);
  }

  // ============================================
  // Step 4: Choose best route
  // ============================================
  // Priority: multi-hop (for Liquid) > direct V4 > AlphaRouter
  let amountOut: string;
  let minAmountOut: string;
  let swapEncoding: { commands: string; inputs: any[]; description: string };
  
  // Compare all available quotes
  const quotes: { type: string; amount: ethers.BigNumber; data: any }[] = [];
  
  if (multiHopQuote) {
    quotes.push({ type: 'multihop', amount: multiHopQuote.amountOut, data: multiHopQuote });
  }
  if (v4Quote) {
    quotes.push({ type: 'v4', amount: v4Quote.amountOut, data: v4Quote });
  }
  if (alphaRoute && alphaAmountOut.gt(0)) {
    quotes.push({ type: 'alpha', amount: alphaAmountOut, data: alphaRoute });
  }
  
  if (quotes.length === 0) {
    throw new Error('No route found - no V4, V3, V2, or multi-hop pools available');
  }
  
  // Find best quote
  const bestQuote = quotes.reduce((best, current) => 
    current.amount.gt(best.amount) ? current : best
  );
  
  if (bestQuote.type === 'multihop') {
    const mh = bestQuote.data as NonNullable<typeof multiHopQuote>;
    console.log(`\n✓ Best route: Multi-hop (${mh.description})`);
    amountOut = mh.amountOut.toString();
    minAmountOut = mh.amountOut.mul(10000 - slippageBps).div(10000).toString();
    
    // Encode full multi-hop route: ETH → RARE → Liquid
    swapEncoding = encodeMultiHopV4Swap(
      wethAddress,
      baseTokenAddress!,
      token,
      ethForSwap,
      mh.rareAmount,
      ethers.BigNumber.from(minAmountOut),
      mh.v4Quote,
      mh.firstHop
    );
  } else if (bestQuote.type === 'v4') {
    const v4 = bestQuote.data as V4QuoteResult;
    console.log(`\n✓ Best route: Direct V4 (${v4.fee / 10000}% fee)`);
    amountOut = v4.amountOut.toString();
    minAmountOut = v4.amountOut.mul(10000 - slippageBps).div(10000).toString();
    swapEncoding = encodeDirectV4Swap(
      ethers.constants.AddressZero,
      token,
      v4.fee,
      v4.tickSpacing,
      ethForSwap,
      ethers.BigNumber.from(minAmountOut),
      v4.hooks
    );
  } else {
    const alpha = bestQuote.data as SwapRoute;
    console.log(`\n✓ Best route: ${alpha.route.map((r: any) => r.protocol).join('+')}`);
    amountOut = alphaAmountOut.toString();
    minAmountOut = alphaAmountOut.mul(10000 - slippageBps).div(10000).toString();
    swapEncoding = encodeSwapPath(alpha, true);
  }

  console.log(`  Expected out: ${ethers.utils.formatUnits(amountOut, tokenDecimals)} tokens`);
  console.log(`  Min out (${slippageBps / 100}% slippage): ${ethers.utils.formatUnits(minAmountOut, tokenDecimals)}`);
  console.log(`  Route: ${swapEncoding.description}`);

  const deadline = getDeadline();
  
  // For multi-hop routes, commands and inputs are already fully encoded
  // For single-hop routes, we need to process them differently
  let commands: string;
  let inputs: any[];
  
  if (bestQuote.type === 'multihop') {
    // Multi-hop already has all commands and inputs encoded
    commands = swapEncoding.commands;
    inputs = swapEncoding.inputs;
  } else {
    // Single-hop routes need input processing
    const wrapEthInput = ethers.utils.defaultAbiCoder.encode(
      ['address', 'uint256'],
      [RECIPIENTS.ROUTER, ethForSwap]
    );

    const swapInputs: any[] = [];
    
    if (swapEncoding.commands === COMMANDS.V3_SWAP_EXACT_IN) {
      swapInputs.push(
        ethers.utils.defaultAbiCoder.encode(
          ['address', 'uint256', 'uint256', 'bytes', 'bool'],
          [RECIPIENTS.MSG_SENDER, ethForSwap, minAmountOut, swapEncoding.inputs[0], false]
        )
      );
      // V3 routes need WRAP_ETH first
      commands = COMMANDS.WRAP_ETH + swapEncoding.commands.slice(2);
      inputs = [wrapEthInput, ...swapInputs];
    } else if (swapEncoding.commands === COMMANDS.V2_SWAP_EXACT_IN) {
      swapInputs.push(
        ethers.utils.defaultAbiCoder.encode(
          ['address', 'uint256', 'uint256', 'address[]', 'bool'],
          [RECIPIENTS.MSG_SENDER, ethForSwap, minAmountOut, swapEncoding.inputs[0], false]
        )
      );
      // V2 routes need WRAP_ETH first
      commands = COMMANDS.WRAP_ETH + swapEncoding.commands.slice(2);
      inputs = [wrapEthInput, ...swapInputs];
    } else if (swapEncoding.commands === COMMANDS.V4_SWAP) {
      // Single V4 swap uses native ETH (address(0)), no wrapping needed
      swapInputs.push(swapEncoding.inputs[0]);
      commands = swapEncoding.commands;
      inputs = swapInputs;
    } else {
      throw new Error(`Unsupported swap command: ${swapEncoding.commands}`);
    }
  }

  const universalRouterInterface = new ethers.utils.Interface([
    'function execute(bytes commands, bytes[] inputs, uint256 deadline)',
  ]);

  // Ensure commands is a hex string starting with 0x
  const commandsHex = commands.startsWith('0x') ? commands : '0x' + commands;
  
  const routeData = universalRouterInterface.encodeFunctionData('execute', [
    commandsHex,
    inputs,
    deadline,
  ]);

  const baseGas = 100000;
  const swapGas = swapEncoding.commands === COMMANDS.V3_SWAP_EXACT_IN ? 150000 : 100000;
  const gasEstimate = (baseGas + swapGas).toString();

  return {
    amountOut,
    minAmountOut,
    routeData,
    deadline,
    route: swapEncoding.description,
    gasEstimate,
  };
}

/**
 * Get multi-hop sell quote for Liquid tokens: Liquid Token → RARE → ETH
 */
async function getMultiHopSellQuote(
  provider: ethers.providers.Provider,
  chainId: number,
  wethAddress: string,
  baseTokenAddress: string, // RARE address
  liquidTokenAddress: string,
  tokenAmount: ethers.BigNumber,
  slippageBps: number
): Promise<{
  amountOut: ethers.BigNumber;
  rareAmount: ethers.BigNumber;
  v4Quote: V4QuoteResult; // First hop: Liquid → RARE
  description: string;
  secondHop: {
    type: 'v4' | 'v3';
    v4Quote?: V4QuoteResult;
    v3Fee?: number;
    usesNativeEth: boolean;
  };
} | null> {
  console.log(`  Checking multi-hop: Liquid → RARE → ETH...`);

  // Read pool key from the Liquid token to get hooks address and tick spacing
  const liquidTokenContract = new ethers.Contract(liquidTokenAddress, LIQUID_TOKEN_ABI, provider);
  let liquidPoolHooks = ethers.constants.AddressZero;
  let liquidPoolTickSpacing: number | undefined;
  try {
    const poolKeyResult = await liquidTokenContract.poolKey();
    liquidPoolHooks = poolKeyResult.hooks;
    liquidPoolTickSpacing = poolKeyResult.tickSpacing;
    console.log(`    Pool hooks: ${liquidPoolHooks}`);
    console.log(`    Pool tick spacing: ${liquidPoolTickSpacing}`);
  } catch (e: any) {
    console.log(`    ⚠ Could not read poolKey from token (${e.message?.slice(0, 40)}), trying without hooks`);
  }

  // Step 1: Quote Liquid → RARE via V4
  let liquidToRareV4 = await getV4DirectQuote(
    provider,
    chainId,
    liquidTokenAddress,
    baseTokenAddress, // RARE
    tokenAmount,
    true, // isExactIn
    liquidPoolHooks !== ethers.constants.AddressZero ? liquidPoolHooks : undefined,
    liquidPoolTickSpacing
  );

  // If V4 Quoter fails (common with hooked pools), try the token's own quoteSell()
  // Note: quoteSell uses revert-as-return (reverts with QuoteResult) - we must parse the revert data
  // LiquidSwapGuard blocks quoteSell - fall back to getCurrentPrice() spot estimate
  if (!liquidToRareV4) {
    console.log(`    V4 Quoter failed, trying token's quoteSell()...`);
    try {
      const rareOut = await parseQuoteSellRevert(provider, liquidTokenAddress, tokenAmount);
      if (rareOut && rareOut.gt(0)) {
        liquidToRareV4 = {
          amountOut: rareOut,
          fee: 0,
          tickSpacing: liquidPoolTickSpacing || 60,
          hooks: liquidPoolHooks,
          poolId: '',
          gasEstimate: 200000,
        };
        console.log(`    Liquid → RARE: ${ethers.utils.formatEther(rareOut)} RARE via token quoteSell()`);
      }
    } catch (e: any) {
      console.log(`    ✗ token quoteSell() also failed: ${e.message?.slice(0, 60)}`);
    }
  }

  // Fallback: LiquidSwapGuard blocks quoteSell - use getCurrentPrice() for spot estimate
  if (!liquidToRareV4) {
    console.log(`    Trying getCurrentPrice() spot estimate (LiquidSwapGuard blocks quoteSell)...`);
    try {
      const priceResult = await liquidTokenContract.getCurrentPrice();
      const rarePerToken = ethers.BigNumber.from(priceResult.rarePerToken);
      if (rarePerToken.gt(0)) {
        // rareOut = liquidIn * rarePerToken / 1e18 (spot price, 1e18 scale)
        const rareOut = tokenAmount.mul(rarePerToken).div(ethers.constants.WeiPerEther);
        // Apply 5% conservative buffer - spot price overestimates for sells (price moves down)
        const conservativeOut = rareOut.mul(95).div(100);
        if (conservativeOut.gt(0)) {
          liquidToRareV4 = {
            amountOut: conservativeOut,
            fee: 0,
            tickSpacing: liquidPoolTickSpacing || 60,
            hooks: liquidPoolHooks,
            poolId: '',
            gasEstimate: 200000,
          };
          console.log(`    Liquid → RARE: ~${ethers.utils.formatEther(conservativeOut)} RARE (spot estimate, 5% buffer)`);
        }
      }
    } catch (e: any) {
      console.log(`    ✗ getCurrentPrice() failed: ${e.message?.slice(0, 50)}`);
    }
  }

  if (!liquidToRareV4) {
    console.log(`    ✗ No Liquid → RARE V4 pool found`);
    return null;
  }
  
  const rareAmount = liquidToRareV4.amountOut;
  console.log(`    Liquid → RARE: ${ethers.utils.formatEther(rareAmount)} RARE via V4(${liquidToRareV4.fee / 10000}%)`);
  
  // Step 2: Quote RARE → ETH via V4 or V3
  // Apply slippage to RARE amount for the next hop
  const rareForSwap = rareAmount.mul(10000 - Math.floor(slippageBps / 2)).div(10000);
  
  // Try both native ETH (address(0)) and WETH addresses
  let rareToEthV4 = await getV4DirectQuote(
    provider,
    chainId,
    baseTokenAddress, // RARE
    ethers.constants.AddressZero, // Native ETH
    rareForSwap
  );
  
  let usesNativeEth = true;
  
  // If no pool found with native ETH, try WETH
  if (!rareToEthV4) {
    rareToEthV4 = await getV4DirectQuote(
      provider,
      chainId,
      baseTokenAddress, // RARE
      wethAddress, // WETH
      rareForSwap
    );
    usesNativeEth = false;
  }
  
  let ethAmount: ethers.BigNumber;
  let rareToEthRoute: string;
  let secondHop: { type: 'v4' | 'v3'; v4Quote?: V4QuoteResult; v3Fee?: number; usesNativeEth: boolean };
  
  if (rareToEthV4) {
    ethAmount = rareToEthV4.amountOut;
    rareToEthRoute = `V4(${rareToEthV4.fee / 10000}%)`;
    secondHop = { type: 'v4', v4Quote: rareToEthV4, usesNativeEth };
    console.log(`    RARE → ETH: ${ethers.utils.formatEther(ethAmount)} ETH via ${rareToEthRoute}`);
  } else {
    // Try V3 for RARE → ETH (common fee tiers)
    // Get V3 Quoter address by chain
    let v3QuoterAddress: string;
    if (chainId === 8453) {
      v3QuoterAddress = '0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a'; // Base Mainnet V3 QuoterV2
    } else if (chainId === 84532) {
      v3QuoterAddress = '0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a'; // Base Sepolia V3 QuoterV2 (same as Base)
    } else if (chainId === 11155111) {
      v3QuoterAddress = '0xEd1f6473345F4150F13EeE36E51F4C2F43f63975'; // Ethereum Sepolia V3 QuoterV2
    } else {
      v3QuoterAddress = '0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6'; // Ethereum Mainnet V3 QuoterV2
    }
    
    const v3Quoter = new ethers.Contract(
      v3QuoterAddress,
      ['function quoteExactInputSingle(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint160 sqrtPriceLimitX96) external returns (uint256 amountOut)'],
      provider
    );
    
    const v3FeeTiers = [500, 3000, 10000];
    let bestV3Quote: ethers.BigNumber | null = null;
    let bestV3Fee = 0;
    
    for (const fee of v3FeeTiers) {
      try {
        const quote = await v3Quoter.callStatic.quoteExactInputSingle(
          baseTokenAddress,
          wethAddress,
          fee,
          rareForSwap,
          0
        );
        if (!bestV3Quote || quote.gt(bestV3Quote)) {
          bestV3Quote = quote;
          bestV3Fee = fee;
        }
      } catch {
        // Pool doesn't exist at this fee tier
      }
    }
    
    if (bestV3Quote) {
      ethAmount = bestV3Quote;
      rareToEthRoute = `V3(${bestV3Fee / 10000}%)`;
      secondHop = { type: 'v3', v3Fee: bestV3Fee, usesNativeEth: false };
      console.log(`    RARE → ETH: ${ethers.utils.formatEther(ethAmount)} ETH via ${rareToEthRoute}`);
    } else {
      console.log(`    ✗ No RARE → ETH route found`);
      return null;
    }
  }
  
  return {
    amountOut: ethAmount,
    rareAmount,
    v4Quote: liquidToRareV4,
    description: `Liquid → RARE (V4 ${liquidToRareV4.fee / 10000}%) → ETH (${rareToEthRoute})`,
    secondHop,
  };
}

/**
 * Encode multi-hop sell swap: Liquid token → RARE → ETH
 * 
 * For V4→V4 multi-hop, we use a SINGLE V4_SWAP command with both swaps.
 * The PoolManager tracks deltas internally, so:
 * 1. Settle Liquid tokens (input)
 * 2. First swap: Liquid → RARE (RARE stays as internal delta)
 * 3. Second swap: RARE → ETH (uses RARE delta from first swap)
 * 4. Take ETH (output)
 */
function encodeMultiHopV4SellSwap(
  wethAddress: string,
  baseTokenAddress: string, // RARE
  liquidTokenAddress: string,
  tokenAmount: ethers.BigNumber,
  rareAmount: ethers.BigNumber,
  ethAmountMin: ethers.BigNumber,
  v4LiquidToRare: V4QuoteResult,
  secondHop: { type: 'v4' | 'v3'; v4Quote?: V4QuoteResult; v3Fee?: number; usesNativeEth: boolean }
): { commands: string; inputs: string[]; description: string } {
  const commands: string[] = [];
  const inputs: string[] = [];
  const descriptions: string[] = [];
  
  // ============================================
  // CASE 1: V4 → V4 (single V4_SWAP with both hops)
  // ============================================
  if (secondHop.type === 'v4' && secondHop.v4Quote) {
    const v4Quote = secondHop.v4Quote;
    
    // Sort currencies for first hop (Liquid → RARE)
    let currency0_1 = liquidTokenAddress;
    let currency1_1 = baseTokenAddress;
    let zeroForOne1 = true;
    
    if (currency0_1.toLowerCase() > currency1_1.toLowerCase()) {
      [currency0_1, currency1_1] = [currency1_1, currency0_1];
      zeroForOne1 = false;
    }
    
    // Sort currencies for second hop (RARE → ETH)
    let currency0_2 = baseTokenAddress;
    let currency1_2 = secondHop.usesNativeEth ? ethers.constants.AddressZero : wethAddress;
    let zeroForOne2 = true;
    
    if (currency0_2.toLowerCase() > currency1_2.toLowerCase()) {
      [currency0_2, currency1_2] = [currency1_2, currency0_2];
      zeroForOne2 = false;
    }
    
    // Build actions: 
    // 1. First swap (Liquid → RARE)
    // 2. Second swap (RARE → ETH) 
    // 3. Settle Liquid input
    // 4. Take ETH output
    const actions = ethers.utils.solidityPack(
      ['uint8', 'uint8', 'uint8', 'uint8'],
      [
        V4_ACTIONS.SWAP_EXACT_IN_SINGLE, // First swap
        V4_ACTIONS.SWAP_EXACT_IN_SINGLE, // Second swap
        V4_ACTIONS.SETTLE_ALL,           // Settle Liquid tokens
        V4_ACTIONS.TAKE_ALL,             // Take ETH
      ]
    );
    
    const params: string[] = [];
    
    // First swap params (Liquid → RARE)
    params.push(ethers.utils.defaultAbiCoder.encode(
      ['tuple(tuple(address,address,uint24,int24,address),bool,uint128,uint128,bytes)'],
      [[
        [currency0_1, currency1_1, v4LiquidToRare.fee, v4LiquidToRare.tickSpacing, v4LiquidToRare.hooks],
        zeroForOne1,
        tokenAmount,
        0, // No min for intermediate (we check final output)
        '0x'
      ]]
    ));

    // Second swap params (RARE → ETH)
    params.push(ethers.utils.defaultAbiCoder.encode(
      ['tuple(tuple(address,address,uint24,int24,address),bool,uint128,uint128,bytes)'],
      [[
        [currency0_2, currency1_2, v4Quote.fee, v4Quote.tickSpacing, v4Quote.hooks],
        zeroForOne2,
        rareAmount,
        ethAmountMin,
        '0x'
      ]]
    ));
    
    // Settle Liquid tokens (input currency)
    params.push(ethers.utils.defaultAbiCoder.encode(
      ['address', 'uint128'],
      [liquidTokenAddress, tokenAmount]
    ));
    
    // Take ETH (output currency)
    params.push(ethers.utils.defaultAbiCoder.encode(
      ['address', 'uint128'],
      [secondHop.usesNativeEth ? ethers.constants.AddressZero : wethAddress, ethAmountMin]
    ));
    
    const v4SwapInput = ethers.utils.defaultAbiCoder.encode(
      ['bytes', 'bytes[]'],
      [actions, params]
    );
    
    commands.push(COMMANDS.V4_SWAP);
    inputs.push(v4SwapInput);
    descriptions.push(`Liquid → RARE (V4 ${v4LiquidToRare.fee / 10000}%) → ETH (V4 ${v4Quote.fee / 10000}%)`);
    
    // If using WETH output, we need to unwrap to native ETH
    if (!secondHop.usesNativeEth) {
      const unwrapInput = ethers.utils.defaultAbiCoder.encode(
        ['address', 'uint256'],
        [RECIPIENTS.MSG_SENDER, ethAmountMin]
      );
      commands.push(COMMANDS.UNWRAP_WETH);
      inputs.push(unwrapInput);
      descriptions.push('UNWRAP_WETH');
    }
    
  } else if (secondHop.type === 'v3' && secondHop.v3Fee !== undefined) {
    // V4→V3 is complex - not yet supported
    throw new Error('V4→V3 multi-hop sell not yet supported. Please ensure RARE→ETH has a V4 pool.');
  } else {
    throw new Error('Invalid second hop type');
  }

  // Combine commands (remove 0x prefix from all but first)
  const combinedCommands = commands.join('').replace(/0x/g, (match, offset) => offset === 0 ? '0x' : '');

  return {
    commands: combinedCommands,
    inputs,
    description: descriptions.join(' → '),
  };
}

/**
 * Encode Universal Router calldata for Token → ETH sell
 * 
 * For Liquid tokens (paired with RARE), pass baseTokenAddress to enable multi-hop routing:
 * Liquid token → RARE → ETH
 */
export async function getManualSellQuote(
  params: {
    token: string;
    tokenDecimals: number;
    tokenAmount: string;
    slippageBps?: number;
    recipient?: string;
    poolFee?: number;
    baseTokenAddress?: string; // Optional: RARE address for Liquid tokens
  },
  chainId: number,
  rpcUrl: string,
  wethAddress: string
): Promise<QuoteResult> {
  const {
    token,
    tokenDecimals,
    tokenAmount,
    slippageBps = 500,
    recipient,
    poolFee = 3000,
    baseTokenAddress,
  } = params;

  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const tokenAmountBN = ethers.BigNumber.from(tokenAmount);

  console.log(`Getting quote for ${ethers.utils.formatUnits(tokenAmount, tokenDecimals)} tokens → ETH...`);
  
  // ============================================
  // Step 1: Try multi-hop if baseTokenAddress provided (Liquid tokens)
  // ============================================
  let multiHopQuote: Awaited<ReturnType<typeof getMultiHopSellQuote>> = null;
  
  if (baseTokenAddress) {
    multiHopQuote = await getMultiHopSellQuote(
      provider,
      chainId,
      wethAddress,
      baseTokenAddress,
      token,
      tokenAmountBN,
      slippageBps
    );
    
    if (multiHopQuote) {
      console.log(`  ✓ Multi-hop Quote: ${ethers.utils.formatEther(multiHopQuote.amountOut)} ETH`);
      console.log(`    Route: ${multiHopQuote.description}`);
    }
  }
  
  // ============================================
  // Step 2: Try direct V4 quote
  // ============================================
  console.log(`  Checking direct V4 pools...`);
  const v4Quote = await getV4DirectQuote(
    provider,
    chainId,
    token,
    ethers.constants.AddressZero,
    tokenAmountBN
  );
  
  if (v4Quote) {
    console.log(`  ✓ Direct V4 Quote: ${ethers.utils.formatEther(v4Quote.amountOut)} ETH (${v4Quote.fee / 10000}% fee)`);
  } else {
    console.log(`  ✗ No direct V4 pools found`);
  }

  // ============================================
  // Step 3: Get AlphaRouter quote (V2/V3)
  // ============================================
  console.log(`  Checking V2/V3 via AlphaRouter...`);
  let alphaRoute: SwapRoute | null = null;
  let alphaAmountOut = ethers.BigNumber.from(0);
  
  try {
    const router = new AlphaRouter({ chainId, provider });
    
    const inputToken = new Token(chainId, token, tokenDecimals);
    const wethToken = new Token(chainId, wethAddress, 18, 'WETH', 'Wrapped Ether');
    
    const amountIn = CurrencyAmount.fromRawAmount(inputToken, tokenAmount);
    
    alphaRoute = await router.route(
      amountIn,
      wethToken,
      TradeType.EXACT_INPUT,
      {
        type: SwapType.UNIVERSAL_ROUTER,
        recipient: recipient || RECIPIENTS.ROUTER,
        slippageTolerance: new Percent(slippageBps, 10000),
        version: UniversalRouterVersion.V1_2,
      }
    );

    alphaAmountOut = alphaRoute ? ethers.BigNumber.from(alphaRoute.quote.quotient.toString()) : ethers.BigNumber.from(0);
    
    if (alphaRoute) {
      console.log(`  ✓ AlphaRouter Quote: ${ethers.utils.formatEther(alphaAmountOut)} ETH (${alphaRoute.route.map((r: any) => r.protocol).join('+')})`);
    } else {
      console.log(`  ✗ No V2/V3 route found`);
    }
  } catch (e: any) {
    console.log(`  ✗ AlphaRouter failed: ${e.message?.slice(0, 50) || 'unknown error'}`);
  }

  // ============================================
  // Step 4: Choose best route
  // ============================================
  // Compare all available quotes
  const quotes: { type: string; amount: ethers.BigNumber; data: any }[] = [];
  
  if (multiHopQuote) {
    quotes.push({ type: 'multihop', amount: multiHopQuote.amountOut, data: multiHopQuote });
  }
  if (v4Quote) {
    quotes.push({ type: 'v4', amount: v4Quote.amountOut, data: v4Quote });
  }
  if (alphaRoute && alphaAmountOut.gt(0)) {
    quotes.push({ type: 'alpha', amount: alphaAmountOut, data: alphaRoute });
  }
  
  if (quotes.length === 0) {
    throw new Error('No route found - no V4, V3, V2, or multi-hop pools available');
  }
  
  // Find best quote
  const bestQuote = quotes.reduce((best, current) => 
    current.amount.gt(best.amount) ? current : best
  );
  
  let amountOut: string;
  let minAmountOut: string;
  let swapEncoding: { commands: string; inputs: any[]; description: string };
  
  if (bestQuote.type === 'multihop') {
    const mh = bestQuote.data as NonNullable<typeof multiHopQuote>;
    console.log(`\n✓ Best route: Multi-hop (${mh.description})`);
    amountOut = mh.amountOut.toString();
    minAmountOut = mh.amountOut.mul(10000 - slippageBps).div(10000).toString();
    
    // Encode full multi-hop route: Liquid → RARE → ETH
    swapEncoding = encodeMultiHopV4SellSwap(
      wethAddress,
      baseTokenAddress!,
      token,
      tokenAmountBN,
      mh.rareAmount,
      ethers.BigNumber.from(minAmountOut),
      mh.v4Quote,
      mh.secondHop
    );
  } else if (bestQuote.type === 'v4' && v4Quote) {
    console.log(`\n✓ Best route: V4 (${v4Quote.fee / 10000}% fee)`);
    amountOut = v4Quote.amountOut.toString();
    minAmountOut = v4Quote.amountOut.mul(10000 - slippageBps).div(10000).toString();
    swapEncoding = encodeDirectV4Swap(
      token,
      ethers.constants.AddressZero,
      v4Quote.fee,
      v4Quote.tickSpacing,
      tokenAmountBN,
      ethers.BigNumber.from(minAmountOut),
      v4Quote.hooks
    );
  } else if (alphaRoute) {
    console.log(`\n✓ Best route: ${alphaRoute.route.map((r: any) => r.protocol).join('+')}`);
    amountOut = alphaAmountOut.toString();
    minAmountOut = alphaAmountOut.mul(10000 - slippageBps).div(10000).toString();
    
    // Encode V2/V3 route
    swapEncoding = encodeSwapPath(alphaRoute, true);
  } else {
    throw new Error('No route found - no V4, V3, or V2 pools available');
  }

  console.log(`  Expected out: ${ethers.utils.formatEther(amountOut)} ETH`);
  console.log(`  Min out (${slippageBps / 100}% slippage): ${ethers.utils.formatEther(minAmountOut)} ETH`);
  console.log(`  Route: ${swapEncoding.description}`);

  const deadline = getDeadline();
  
  // For multi-hop routes, commands and inputs are already fully encoded
  // For single-hop routes, we need to process them differently
  let commands: string;
  let inputs: any[];
  
  if (bestQuote.type === 'multihop') {
    // Multi-hop already has all commands and inputs encoded
    commands = swapEncoding.commands;
    inputs = swapEncoding.inputs;
  } else {
    // Single-hop routes need input processing
    const swapInputs: any[] = [];
    
    if (swapEncoding.commands === COMMANDS.V3_SWAP_EXACT_IN) {
      swapInputs.push(
        ethers.utils.defaultAbiCoder.encode(
          ['address', 'uint256', 'uint256', 'bytes', 'bool'],
          [RECIPIENTS.ROUTER, tokenAmountBN, minAmountOut, swapEncoding.inputs[0], true]
        )
      );
      // V3 routes need UNWRAP_WETH after
      commands = swapEncoding.commands + COMMANDS.UNWRAP_WETH.slice(2);
      inputs = [...swapInputs, ethers.utils.defaultAbiCoder.encode(
        ['address', 'uint256'],
        [RECIPIENTS.MSG_SENDER, minAmountOut]
      )];
    } else if (swapEncoding.commands === COMMANDS.V2_SWAP_EXACT_IN) {
      swapInputs.push(
        ethers.utils.defaultAbiCoder.encode(
          ['address', 'uint256', 'uint256', 'address[]', 'bool'],
          [RECIPIENTS.ROUTER, tokenAmountBN, minAmountOut, swapEncoding.inputs[0], true]
        )
      );
      // V2 routes need UNWRAP_WETH after
      commands = swapEncoding.commands + COMMANDS.UNWRAP_WETH.slice(2);
      inputs = [...swapInputs, ethers.utils.defaultAbiCoder.encode(
        ['address', 'uint256'],
        [RECIPIENTS.MSG_SENDER, minAmountOut]
      )];
    } else if (swapEncoding.commands === COMMANDS.V4_SWAP) {
      // Single V4 swap outputs native ETH directly
      swapInputs.push(swapEncoding.inputs[0]);
      commands = swapEncoding.commands;
      inputs = swapInputs;
    } else {
      throw new Error(`Unsupported swap command: ${swapEncoding.commands}`);
    }
  }

  const universalRouterInterface = new ethers.utils.Interface([
    'function execute(bytes commands, bytes[] inputs, uint256 deadline)',
  ]);

  const routeData = universalRouterInterface.encodeFunctionData('execute', [
    commands,
    inputs,
    deadline,
  ]);

  const baseGas = 100000;
  const swapGas = swapEncoding.commands === COMMANDS.V3_SWAP_EXACT_IN ? 150000 : 100000;
  const gasEstimate = (baseGas + swapGas).toString();

  return {
    amountOut,
    minAmountOut,
    routeData,
    deadline,
    route: swapEncoding.description,
    gasEstimate,
  };
}

