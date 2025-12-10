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
  SETTLE_ALL: 0x0c,
  TAKE_ALL: 0x0f,
};

// V4 Quoter ABI
const V4_QUOTER_ABI = [
  'function quoteExactInputSingle(tuple(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) params) external returns (uint256 amountOut, uint256 gasEstimate)',
];

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
const V4_FEE_TIERS = [100, 500, 3000, 10000]; // 0.01%, 0.05%, 0.3%, 1%
const V4_TICK_SPACINGS: Record<number, number> = {
  100: 1,
  500: 10,
  3000: 60,
  10000: 200,
};

interface V4QuoteResult {
  amountOut: ethers.BigNumber;
  fee: number;
  tickSpacing: number;
  poolId: string;
  gasEstimate: number;
}

/**
 * Get a direct V4 quote by querying the V4 Quoter
 */
async function getV4DirectQuote(
  provider: ethers.providers.Provider,
  chainId: number,
  currencyIn: string, // Use address(0) for native ETH
  currencyOut: string,
  amountIn: ethers.BigNumber,
  isExactIn: boolean = true
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

  // Try all fee tiers to find the best quote
  for (const fee of V4_FEE_TIERS) {
    const tickSpacing = V4_TICK_SPACINGS[fee] || 60;
    
    const quoteParams = {
      poolKey: {
        currency0,
        currency1,
        fee,
        tickSpacing,
        hooks: ethers.constants.AddressZero,
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
          [currency0, currency1, fee, tickSpacing, ethers.constants.AddressZero]
        )
      );

      // Keep best quote (highest output)
      if (!bestQuote || amountOut.gt(bestQuote.amountOut)) {
        bestQuote = {
          amountOut,
          fee,
          tickSpacing,
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
  amountOutMin: ethers.BigNumber
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
      [currency0, currency1, fee, tickSpacing, ethers.constants.AddressZero],
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
 * Encode Universal Router calldata for ETH → Token buy
 */
export async function getManualBuyQuote(
  params: ManualBuyQuoteParams,
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
  } = params;

  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const ethAmountBN = ethers.BigNumber.from(ethAmount);
  const ethForSwap = ethAmountBN.mul(10000 - liquidRouterFeeBps).div(10000);

  console.log(`Getting quote for ${ethers.utils.formatEther(ethForSwap)} ETH → ${token.slice(0, 10)}...`);
  console.log(`  Checking V4 pools...`);
  const v4Quote = await getV4DirectQuote(
    provider,
    chainId,
    ethers.constants.AddressZero, // Native ETH
    token,
    ethForSwap
  );
  
  if (v4Quote) {
    console.log(`  ✓ V4 Quote: ${ethers.utils.formatUnits(v4Quote.amountOut, tokenDecimals)} tokens (${v4Quote.fee / 10000}% fee)`);
  } else {
    console.log(`  ✗ No V4 pools found`);
  }

  // ============================================
  // Step 2: Get AlphaRouter quote (V2/V3)
  // ============================================
  console.log(`  Checking V2/V3 via AlphaRouter...`);
  const router = new AlphaRouter({ chainId, provider });
  
  const wethToken = new Token(chainId, wethAddress, 18, 'WETH', 'Wrapped Ether');
  const outputToken = new Token(chainId, token, tokenDecimals);
  
  const amountIn = CurrencyAmount.fromRawAmount(wethToken, ethForSwap.toString());
  
  const alphaRoute = await router.route(
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

  const alphaAmountOut = alphaRoute ? ethers.BigNumber.from(alphaRoute.quote.quotient.toString()) : ethers.BigNumber.from(0);
  
  if (alphaRoute) {
    console.log(`  ✓ AlphaRouter Quote: ${ethers.utils.formatUnits(alphaAmountOut, tokenDecimals)} tokens (${alphaRoute.route.map((r: any) => r.protocol).join('+')})`);
  } else {
    console.log(`  ✗ No V2/V3 route found`);
  }

  // ============================================
  // Step 3: Choose best route
  // ============================================
  const useV4 = v4Quote && (!alphaRoute || v4Quote.amountOut.gt(alphaAmountOut));
  
  let amountOut: string;
  let minAmountOut: string;
  let swapEncoding: { commands: string; inputs: any[]; description: string };
  
  if (useV4 && v4Quote) {
    console.log(`\n✓ Best route: V4 (${v4Quote.fee / 10000}% fee)`);
    amountOut = v4Quote.amountOut.toString();
    minAmountOut = v4Quote.amountOut.mul(10000 - slippageBps).div(10000).toString();
    swapEncoding = encodeDirectV4Swap(
      ethers.constants.AddressZero,
      token,
      v4Quote.fee,
      v4Quote.tickSpacing,
      ethForSwap,
      ethers.BigNumber.from(minAmountOut)
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

  console.log(`  Expected out: ${ethers.utils.formatUnits(amountOut, tokenDecimals)} tokens`);
  console.log(`  Min out (${slippageBps / 100}% slippage): ${ethers.utils.formatUnits(minAmountOut, tokenDecimals)}`);
  console.log(`  Route: ${swapEncoding.description}`);

  const deadline = getDeadline();
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
  } else if (swapEncoding.commands === COMMANDS.V2_SWAP_EXACT_IN) {
    swapInputs.push(
      ethers.utils.defaultAbiCoder.encode(
        ['address', 'uint256', 'uint256', 'address[]', 'bool'],
        [RECIPIENTS.MSG_SENDER, ethForSwap, minAmountOut, swapEncoding.inputs[0], false]
      )
    );
  } else if (swapEncoding.commands === COMMANDS.V4_SWAP) {
    swapInputs.push(swapEncoding.inputs[0]);
  } else if (swapEncoding.commands.length > 4) {
    throw new Error('Mixed routes not fully supported');
  } else {
    throw new Error(`Unsupported swap command: ${swapEncoding.commands}`);
  }

  const commands = swapEncoding.commands === COMMANDS.V4_SWAP 
    ? swapEncoding.commands 
    : COMMANDS.WRAP_ETH + swapEncoding.commands.slice(2);
  const inputs = swapEncoding.commands === COMMANDS.V4_SWAP 
    ? swapInputs 
    : [wrapEthInput, ...swapInputs];

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

/**
 * Encode Universal Router calldata for Token → ETH sell
 */
export async function getManualSellQuote(
  params: {
    token: string;
    tokenDecimals: number;
    tokenAmount: string;
    slippageBps?: number;
    recipient?: string;
    poolFee?: number;
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
  } = params;

  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const tokenAmountBN = ethers.BigNumber.from(tokenAmount);

  console.log(`Getting quote for ${ethers.utils.formatUnits(tokenAmount, tokenDecimals)} tokens → ETH...`);
  console.log(`  Checking V4 pools...`);
  const v4Quote = await getV4DirectQuote(
    provider,
    chainId,
    token,
    ethers.constants.AddressZero,
    tokenAmountBN
  );
  
  if (v4Quote) {
    console.log(`  ✓ V4 Quote: ${ethers.utils.formatEther(v4Quote.amountOut)} ETH (${v4Quote.fee / 10000}% fee)`);
  } else {
    console.log(`  ✗ No V4 pools found`);
  }

  // ============================================
  // Step 2: Get AlphaRouter quote (V2/V3)
  // ============================================
  console.log(`  Checking V2/V3 via AlphaRouter...`);
  const router = new AlphaRouter({ chainId, provider });
  
  const inputToken = new Token(chainId, token, tokenDecimals);
  const wethToken = new Token(chainId, wethAddress, 18, 'WETH', 'Wrapped Ether');
  
  const amountIn = CurrencyAmount.fromRawAmount(inputToken, tokenAmount);
  
  const alphaRoute = await router.route(
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

  const alphaAmountOut = alphaRoute ? ethers.BigNumber.from(alphaRoute.quote.quotient.toString()) : ethers.BigNumber.from(0);
  
  if (alphaRoute) {
    console.log(`  ✓ AlphaRouter Quote: ${ethers.utils.formatEther(alphaAmountOut)} ETH (${alphaRoute.route.map((r: any) => r.protocol).join('+')})`);
  } else {
    console.log(`  ✗ No V2/V3 route found`);
  }

  // ============================================
  // Step 3: Choose best route
  // ============================================
  const useV4 = v4Quote && (!alphaRoute || v4Quote.amountOut.gt(alphaAmountOut));
  
  let amountOut: string;
  let minAmountOut: string;
  let swapEncoding: { commands: string; inputs: any[]; description: string };
  
  if (useV4 && v4Quote) {
    console.log(`\n✓ Best route: V4 (${v4Quote.fee / 10000}% fee)`);
    amountOut = v4Quote.amountOut.toString();
    minAmountOut = v4Quote.amountOut.mul(10000 - slippageBps).div(10000).toString();
    swapEncoding = encodeDirectV4Swap(
      token,
      ethers.constants.AddressZero,
      v4Quote.fee,
      v4Quote.tickSpacing,
      tokenAmountBN,
      ethers.BigNumber.from(minAmountOut)
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
  const swapInputs: any[] = [];
  
  if (swapEncoding.commands === COMMANDS.V3_SWAP_EXACT_IN) {
    swapInputs.push(
      ethers.utils.defaultAbiCoder.encode(
        ['address', 'uint256', 'uint256', 'bytes', 'bool'],
        [RECIPIENTS.ROUTER, tokenAmountBN, minAmountOut, swapEncoding.inputs[0], true]
      )
    );
  } else if (swapEncoding.commands === COMMANDS.V2_SWAP_EXACT_IN) {
    swapInputs.push(
      ethers.utils.defaultAbiCoder.encode(
        ['address', 'uint256', 'uint256', 'address[]', 'bool'],
        [RECIPIENTS.ROUTER, tokenAmountBN, minAmountOut, swapEncoding.inputs[0], true]
      )
    );
  } else if (swapEncoding.commands === COMMANDS.V4_SWAP) {
    swapInputs.push(swapEncoding.inputs[0]);
  } else if (swapEncoding.commands.length > 4) {
    throw new Error('Mixed routes not fully supported');
  } else {
    throw new Error(`Unsupported swap command: ${swapEncoding.commands}`);
  }

  const commands = swapEncoding.commands === COMMANDS.V4_SWAP 
    ? swapEncoding.commands 
    : swapEncoding.commands + COMMANDS.UNWRAP_WETH.slice(2);
  const inputs = swapEncoding.commands === COMMANDS.V4_SWAP 
    ? swapInputs 
    : [...swapInputs, ethers.utils.defaultAbiCoder.encode(
        ['address', 'uint256'],
        [RECIPIENTS.MSG_SENDER, minAmountOut]
      )];

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

