/**
 * Check Routes Script
 * 
 * This script checks what routes our uniswap-manual-router.ts finds for various
 * token pairs, including direct V4 pool queries. It shows which protocol 
 * (V2, V3, or V4) is actually chosen for each swap.
 * 
 * Usage:
 *   cd scripts
 *   npx ts-node check-routes.ts
 */

import { ethers } from 'ethers';
import { getManualBuyQuote } from './uniswap-manual-router';
import * as dotenv from 'dotenv';
import * as path from 'path';

dotenv.config({ path: path.resolve(__dirname, '../.env') });

// ============================================
// CONFIGURATION
// ============================================

const CONFIG = {
  chainId: 11155111, // Ethereum Sepolia
  rpcUrl: 'https://ethereum-sepolia-rpc.publicnode.com',
  weth: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14',
  
  // Test tokens on Sepolia
  tokens: {
    USDC: { address: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238', decimals: 6 },
    WBTC: { address: '0x835EF3b3D6fB94B98bf0A3F5390668e4B83731c5', decimals: 8 },
    UNI: { address: '0x6727002ad781e0fB768ba11E404965ABA89aFfca', decimals: 18 },
    RARE: { address: '0x197FaeF3f59eC80113e773Bb6206a17d183F97CB', decimals: 18 },
  },
  
  // Amount to quote (in ETH)
  quoteAmount: '0.01', // 0.01 ETH
};

// ============================================
// HELPERS
// ============================================

interface RouteResult {
  pair: string;
  found: boolean;
  protocol?: 'V2' | 'V3' | 'V4' | 'Mixed';
  routeDetails?: string;
  amountOut?: string;
  minAmountOut?: string;
  error?: string;
}

function extractProtocol(routeDescription: string): 'V2' | 'V3' | 'V4' | 'Mixed' {
  if (routeDescription.startsWith('V4(')) return 'V4';
  if (routeDescription.startsWith('V3(')) return 'V3';
  if (routeDescription.startsWith('V2(')) return 'V2';
  if (routeDescription.includes(' → ')) return 'Mixed';
  return 'V3'; // Default fallback
}

async function checkETHRoute(
  tokenSymbol: string,
  tokenAddress: string,
  tokenDecimals: number,
  ethAmount: string
): Promise<RouteResult> {
  const pairName = `ETH → ${tokenSymbol}`;
  
  try {
    const quote = await getManualBuyQuote(
      {
        token: tokenAddress,
        tokenDecimals,
        ethAmount: ethers.utils.parseEther(ethAmount).toString(),
        slippageBps: 500,
      },
      CONFIG.chainId,
      CONFIG.rpcUrl,
      CONFIG.weth,
      300 // 3% LiquidRouter fee
    );

    const protocol = extractProtocol(quote.route);

    return {
      pair: pairName,
      found: true,
      protocol,
      routeDetails: quote.route,
      amountOut: ethers.utils.formatUnits(quote.amountOut, tokenDecimals),
      minAmountOut: ethers.utils.formatUnits(quote.minAmountOut, tokenDecimals),
    };
  } catch (error: any) {
    return {
      pair: pairName,
      found: false,
      error: error.message || 'Unknown error',
    };
  }
}

// ============================================
// MAIN
// ============================================

async function main() {
  console.log('='.repeat(80));
  console.log('Route Discovery Check - Ethereum Sepolia');
  console.log('='.repeat(80));
  console.log(`\nRPC: ${CONFIG.rpcUrl}`);
  console.log(`Chain ID: ${CONFIG.chainId}`);
  console.log(`Quote Amount: ${CONFIG.quoteAmount} ETH`);
  console.log(`\nThis script uses getManualBuyQuote() which:`);
  console.log(`  1. Queries V4 pools directly via V4 Quoter`);
  console.log(`  2. Queries V2/V3 via AlphaRouter`);
  console.log(`  3. Chooses the best rate automatically\n`);

  console.log('Checking routes...\n');

  const results: RouteResult[] = [];
  
  for (const [symbol, info] of Object.entries(CONFIG.tokens)) {
    console.log(`\n${'─'.repeat(60)}`);
    const result = await checkETHRoute(symbol, info.address, info.decimals, CONFIG.quoteAmount);
    results.push(result);
    
    if (result.found) {
      console.log(`\n📊 Result: ${result.pair}`);
      console.log(`   Protocol: ${result.protocol}`);
      console.log(`   Route: ${result.routeDetails}`);
      console.log(`   Output: ${result.amountOut} ${symbol}`);
    } else {
      console.log(`\n❌ ${result.pair}: ${result.error}`);
    }
  }

  // Summary
  console.log('\n' + '='.repeat(80));
  console.log('SUMMARY');
  console.log('='.repeat(80) + '\n');

  const v2Routes = results.filter(r => r.protocol === 'V2');
  const v3Routes = results.filter(r => r.protocol === 'V3');
  const v4Routes = results.filter(r => r.protocol === 'V4');
  const mixedRoutes = results.filter(r => r.protocol === 'Mixed');
  const noRoutes = results.filter(r => !r.found);

  console.log('📊 Protocol Statistics (ACTUAL routes chosen):');
  console.log(`   V4 Routes: ${v4Routes.length}`);
  console.log(`   V3 Routes: ${v3Routes.length}`);
  console.log(`   V2 Routes: ${v2Routes.length}`);
  console.log(`   Mixed Routes: ${mixedRoutes.length}`);
  console.log(`   No Routes: ${noRoutes.length}\n`);

  if (v4Routes.length > 0) {
    console.log('✅ V4 Routes Chosen (best price on V4):');
    for (const route of v4Routes) {
      console.log(`   ${route.pair}: ${route.amountOut} (${route.routeDetails})`);
    }
    console.log('');
  }

  if (v3Routes.length > 0) {
    console.log('✅ V3 Routes Chosen (best price on V3):');
    for (const route of v3Routes) {
      console.log(`   ${route.pair}: ${route.amountOut} (${route.routeDetails})`);
    }
    console.log('');
  }

  if (v2Routes.length > 0) {
    console.log('✅ V2 Routes Chosen (best price on V2):');
    for (const route of v2Routes) {
      console.log(`   ${route.pair}: ${route.amountOut} (${route.routeDetails})`);
    }
    console.log('');
  }

  if (noRoutes.length > 0) {
    console.log('❌ No Routes Found:');
    for (const route of noRoutes) {
      console.log(`   ${route.pair}: ${route.error}`);
    }
    console.log('');
  }

  console.log('='.repeat(80));
  console.log('✅ Route discovery complete!');
  console.log('='.repeat(80) + '\n');
}

main().catch((error) => {
  console.error('\n💥 Error:', error.message);
  process.exit(1);
});
