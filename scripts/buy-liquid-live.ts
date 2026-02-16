/**
 * Buy LiquidEdition token on live network via LiquidRouter
 * 
 * This script:
 * 1. Gets a quote from Uniswap Smart Router (multi-hop: ETH → RARE → Liquid)
 * 2. Submits the buy transaction through LiquidRouter
 * 
 * Uses REAL RARE token (not mock) for multi-hop routing
 * 
 * Usage:
 *   cd scripts
 *   npx ts-node buy-liquid-live.ts
 */

import { ethers } from 'ethers';
import { getManualBuyQuote } from './uniswap-manual-router';
import * as dotenv from 'dotenv';
import * as path from 'path';

dotenv.config({ path: path.resolve(__dirname, '../.env') });

// Helper to expand environment variables in RPC URL
function expandRpcUrl(url: string | undefined, defaultUrl: string): string {
  if (!url) return defaultUrl;
  // Replace ${ALCHEMY_API_KEY} with actual API key if present
  if (url.includes('${ALCHEMY_API_KEY}')) {
    const apiKey = process.env.ALCHEMY_API_KEY;
    if (apiKey) {
      return url.replace('${ALCHEMY_API_KEY}', apiKey);
    }
  }
  return url;
}

// ============================================
// CONFIGURATION
// ============================================

const CONFIG = {
  chainId: 11155111, // Ethereum Sepolia (has working ETH/RARE pool with liquidity)
  rpcUrl: expandRpcUrl(process.env.ETH_SEPOLIA || process.env.SEPOLIA_RPC_URL, 'https://ethereum-sepolia-rpc.publicnode.com'),
  
  // Deployed contracts (Ethereum Sepolia)
  liquidRouter: '0x6Ac1182EdC9A35c0f956b18A9d9F95Dc0171E7F0', // Ethereum Sepolia LiquidRouter
  liquidToken: '0x23C8701Dd299E742a1e03e2AE046Cf2356f26f34', // Your LiquidEdition token
  
  // Real RARE token addresses (from NetworkConfig)
  rareToken: '0x197FaeF3f59eC80113e773Bb6206a17d183F97CB', // Ethereum Sepolia RARE
  
  // Trade parameters
  ethAmount: '0.001',
  slippageBps: 500, // 5% slippage
};

// Real RARE token addresses by chain
const RARE_TOKENS: Record<number, string> = {
  1: '0xba5BDe662c17e2aDFF1075610382B9B691296350',      // Ethereum Mainnet
  8453: '0x691077C8e8de54EA84eFd454630439F99bd8C92f',    // Base Mainnet
  84532: '0x8b21bC8571d11F7AdB705ad8F6f6BD1deb79cE01',   // Base Sepolia
  11155111: '0x197FaeF3f59eC80113e773Bb6206a17d183F97CB', // Ethereum Sepolia
};

const WETH_ADDRESSES: Record<number, string> = {
  1: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',      // Ethereum Mainnet
  8453: '0x4200000000000000000000000000000000000006',   // Base Mainnet
  84532: '0x4200000000000000000000000000000000000006',  // Base Sepolia
  11155111: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14', // Ethereum Sepolia
};

// ABIs
const LIQUID_ROUTER_ABI = [
  'function buy(address token, address recipient, address orderReferrer, uint256 minTokensOut, bytes calldata routeData, uint256 deadline) external payable returns (uint256 tokensReceived)',
  'function TOTAL_FEE_BPS() external view returns (uint256)',
  'event RouterBuy(address indexed token, address indexed buyer, address indexed recipient, address orderReferrer, uint256 ethAmount, uint256 ethFee, uint256 ethSwapped, uint256 tokensReceived, uint256 protocolFee, uint256 referrerFee, uint256 beneficiaryFee, uint256 burnFee)',
];

const ERC20_ABI = [
  'function balanceOf(address) external view returns (uint256)',
  'function symbol() external view returns (string)',
  'function name() external view returns (string)',
];

// ============================================
// MAIN
// ============================================

async function main() {
  console.log('='.repeat(70));
  console.log('Buy LiquidEdition Token via LiquidRouter (LIVE TEST)');
  console.log('='.repeat(70));
  
  // Check for private key
  const privateKey = process.env.DEPLOYER_PRIVATE_KEY;
  if (!privateKey) {
    throw new Error('DEPLOYER_PRIVATE_KEY not set in .env file');
  }
  
  // Auto-detect RARE token and WETH based on chain ID
  const rareToken = RARE_TOKENS[CONFIG.chainId] || CONFIG.rareToken;
  const wethAddress = WETH_ADDRESSES[CONFIG.chainId];
  
  if (!rareToken || !wethAddress) {
    throw new Error(`Unsupported chain ID: ${CONFIG.chainId}. Update RARE_TOKENS and WETH_ADDRESSES.`);
  }
  
  // Setup provider and wallet
  const provider = new ethers.providers.JsonRpcProvider(CONFIG.rpcUrl, CONFIG.chainId);
  const wallet = new ethers.Wallet(privateKey, provider);
  
  console.log('\n📋 Configuration:');
  console.log('  Chain ID:', CONFIG.chainId);
  console.log('  RPC URL:', CONFIG.rpcUrl);
  console.log('  Wallet:', wallet.address);
  console.log('  LiquidRouter:', CONFIG.liquidRouter);
  console.log('  Liquid Token:', CONFIG.liquidToken);
  console.log('  RARE Token (real):', rareToken);
  console.log('  WETH:', wethAddress);
  console.log('  ETH Amount:', CONFIG.ethAmount, 'ETH');
  console.log('  Slippage:', CONFIG.slippageBps / 100, '%');
  
  // Verify router is deployed
  if (CONFIG.liquidRouter === '0x0000000000000000000000000000000000000000') {
    throw new Error('⚠️  Please update CONFIG.liquidRouter with your deployed router address');
  }
  
  // Check balances before
  const ethBalanceBefore = await provider.getBalance(wallet.address);
  const liquidToken = new ethers.Contract(CONFIG.liquidToken, ERC20_ABI, provider);
  const tokenBalanceBefore = await liquidToken.balanceOf(wallet.address);
  const tokenSymbol = await liquidToken.symbol();
  const tokenName = await liquidToken.name();
  
  console.log('\n💰 Balances Before:');
  console.log('  ETH:', ethers.utils.formatEther(ethBalanceBefore), 'ETH');
  console.log('  Token:', ethers.utils.formatEther(tokenBalanceBefore), tokenSymbol);
  
  // Get router fee configuration
  const router = new ethers.Contract(CONFIG.liquidRouter, LIQUID_ROUTER_ABI, provider);
  const totalFeeBps = await router.TOTAL_FEE_BPS();
  console.log('\n⚙️  Router Configuration:');
  console.log('  Total Fee:', totalFeeBps.toNumber() / 100, '%');
  
  // Get quote from Uniswap
  console.log('\n🔍 Getting quote from Uniswap...');
  console.log('  Route: ETH → RARE → Liquid token (multi-hop)');
  
  const ethAmount = ethers.utils.parseEther(CONFIG.ethAmount);
  
  let quote;
  try {
    // For Liquid tokens, we need multi-hop routes: ETH → RARE → Liquid token
    // Pass baseTokenAddress (RARE) to enable multi-hop routing
    quote = await getManualBuyQuote({
      token: CONFIG.liquidToken,
      tokenDecimals: 18,
      ethAmount: ethAmount.toString(),
      slippageBps: CONFIG.slippageBps,
      recipient: wallet.address,
      poolFee: 0, // Liquid tokens use 0% fee V4 pools
      baseTokenAddress: rareToken, // REAL RARE token for multi-hop
    }, CONFIG.chainId, CONFIG.rpcUrl, wethAddress, totalFeeBps.toNumber());
    
    console.log('\n✅ Quote received:');
    console.log('  Route:', quote.route);
    console.log('  Expected tokens out:', ethers.utils.formatEther(quote.amountOut), tokenSymbol);
    console.log('  Min tokens out (after slippage):', ethers.utils.formatEther(quote.minAmountOut), tokenSymbol);
    console.log('  Gas estimate:', quote.gasEstimate);
    console.log('  Deadline:', new Date(quote.deadline * 1000).toISOString());
    console.log('  Route data length:', quote.routeData.length, 'chars');
    
  } catch (error: any) {
    console.error('\n❌ Failed to get quote:', error.message);
    console.error('\nNote: V4 route generation for Liquid tokens requires:');
    console.error('  - Valid ETH → RARE pool');
    console.error('  - Valid RARE → Liquid token V4 pool');
    console.error('  - Proper Uniswap V4 quoter integration');
    throw error;
  }
  
  // Execute buy through LiquidRouter
  console.log('\n📤 Submitting buy transaction...');
  console.log('  ⚠️  This is a LIVE transaction on chain ID', CONFIG.chainId);
  
  const routerWithSigner = router.connect(wallet);
  
  try {
    const tx = await routerWithSigner.buy(
      CONFIG.liquidToken,
      wallet.address,
      ethers.constants.AddressZero,
      quote.minAmountOut,
      quote.routeData,
      quote.deadline,
      { 
        value: ethAmount,
        gasLimit: 1000000,
      }
    );
    
    console.log('  Transaction hash:', tx.hash);
    console.log('  Waiting for confirmation...');
    
    const receipt = await tx.wait();
    console.log('  ✅ Confirmed in block:', receipt.blockNumber);
    console.log('  Gas used:', receipt.gasUsed.toString());
    
    // Parse events
    const buyEvent = receipt.logs
      .map((log: any) => {
        try {
          return routerWithSigner.interface.parseLog(log);
        } catch {
          return null;
        }
      })
      .find((e: any) => e?.name === 'RouterBuy');
    
    if (buyEvent) {
      console.log('\n📊 Trade Details:');
      console.log('  Tokens received:', ethers.utils.formatEther(buyEvent.args.tokensReceived), tokenSymbol);
      console.log('  ETH fee:', ethers.utils.formatEther(buyEvent.args.ethFee), 'ETH');
      console.log('  ETH swapped:', ethers.utils.formatEther(buyEvent.args.ethSwapped), 'ETH');
      console.log('\n  Fee Distribution:');
      console.log('    Protocol:', ethers.utils.formatEther(buyEvent.args.protocolFee), 'ETH');
      console.log('    Referrer:', ethers.utils.formatEther(buyEvent.args.referrerFee), 'ETH');
      console.log('    Beneficiary:', ethers.utils.formatEther(buyEvent.args.beneficiaryFee), 'ETH');
      console.log('    RARE Burn:', ethers.utils.formatEther(buyEvent.args.burnFee), 'ETH');
    }
    
  } catch (error: any) {
    console.error('\n❌ Transaction failed:', error.message);
    if (error.error?.message) {
      console.error('  Reason:', error.error.message);
    }
    if (error.reason) {
      console.error('  Revert reason:', error.reason);
    }
    throw error;
  }
  
  // Check balances after
  const ethBalanceAfter = await provider.getBalance(wallet.address);
  const tokenBalanceAfter = await liquidToken.balanceOf(wallet.address);
  
  console.log('\n💰 Balances After:');
  console.log('  ETH:', ethers.utils.formatEther(ethBalanceAfter), 'ETH');
  console.log('  Token:', ethers.utils.formatEther(tokenBalanceAfter), tokenSymbol);
  
  console.log('\n📈 Changes:');
  console.log('  ETH spent:', ethers.utils.formatEther(ethBalanceBefore.sub(ethBalanceAfter)), 'ETH (includes gas)');
  console.log('  Tokens gained:', ethers.utils.formatEther(tokenBalanceAfter.sub(tokenBalanceBefore)), tokenSymbol);
  
  console.log('\n' + '='.repeat(70));
  console.log('✅ Buy complete!');
  console.log('='.repeat(70) + '\n');
}

main().catch((error) => {
  console.error('\n💥 Error:', error.message);
  process.exit(1);
});
