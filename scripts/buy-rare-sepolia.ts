/**
 * Buy RARE token on Ethereum Sepolia via LiquidRouter
 * 
 * This script:
 * 1. Gets a quote from Uniswap Smart Router
 * 2. Submits the buy transaction through LiquidRouter
 * 
 * Usage:
 *   cd scripts
 *   npx ts-node buy-rare-sepolia.ts
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
  chainId: 11155111,
  rpcUrl: 'https://ethereum-sepolia-rpc.publicnode.com',
  
  // Deployed contracts
  liquidRouter: '0x34a00cd690d892675da7B2Ded1B309EdAB6b6BAe',
  rareToken: '0x197FaeF3f59eC80113e773Bb6206a17d183F97CB',
  
  // Trade parameters
  ethAmount: '0.001',
  slippageBps: 1000, // 10% slippage 
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
];

// ============================================
// MAIN
// ============================================

async function main() {
  console.log('='.repeat(70));
  console.log('Buy RARE on Ethereum Sepolia via LiquidRouter');
  console.log('='.repeat(70));
  
  // Check for private key
  const privateKey = process.env.DEPLOYER_PRIVATE_KEY;
  if (!privateKey) {
    throw new Error('DEPLOYER_PRIVATE_KEY not set in .env file');
  }
  
  // Setup provider and wallet
  const provider = new ethers.providers.JsonRpcProvider(CONFIG.rpcUrl, CONFIG.chainId);
  const wallet = new ethers.Wallet(privateKey, provider);
  
  console.log('\n📋 Configuration:');
  console.log('  Chain: Ethereum Sepolia (11155111)');
  console.log('  Wallet:', wallet.address);
  console.log('  LiquidRouter:', CONFIG.liquidRouter);
  console.log('  RARE Token:', CONFIG.rareToken);
  console.log('  ETH Amount:', CONFIG.ethAmount, 'ETH');
  console.log('  Slippage:', CONFIG.slippageBps / 100, '%');
  
  // Check balances before
  const ethBalanceBefore = await provider.getBalance(wallet.address);
  const rareToken = new ethers.Contract(CONFIG.rareToken, ERC20_ABI, provider);
  const rareBalanceBefore = await rareToken.balanceOf(wallet.address);
  const rareSymbol = await rareToken.symbol();
  
  console.log('\n💰 Balances Before:');
  console.log('  ETH:', ethers.utils.formatEther(ethBalanceBefore), 'ETH');
  console.log('  RARE:', ethers.utils.formatEther(rareBalanceBefore), rareSymbol);
  
  // Get router fee configuration from contract
  const router = new ethers.Contract(CONFIG.liquidRouter, LIQUID_ROUTER_ABI, provider);
  const totalFeeBps = await router.TOTAL_FEE_BPS();
  console.log('\n⚙️  Router Configuration:');
  console.log('  Total Fee:', totalFeeBps.toNumber() / 100, '%');
  
  // Get quote from Uniswap
  console.log('\n🔍 Getting quote from Uniswap...');
  
  const ethAmount = ethers.utils.parseEther(CONFIG.ethAmount);
  const wethAddress = '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14';
  
  let quote;
  try {
    quote = await getManualBuyQuote({
      token: CONFIG.rareToken,
      tokenDecimals: 18,
      ethAmount: ethAmount.toString(),
      slippageBps: CONFIG.slippageBps,
      recipient: wallet.address,
      poolFee: 3000, // 0.3% fee tier
    }, CONFIG.chainId, CONFIG.rpcUrl, wethAddress, totalFeeBps.toNumber());
    
    console.log('\n✅ Quote received:');
    console.log('  Route:', quote.route);
    console.log('  Expected RARE out:', ethers.utils.formatEther(quote.amountOut), rareSymbol);
    console.log('  Min RARE out (after slippage):', ethers.utils.formatEther(quote.minAmountOut), rareSymbol);
    console.log('  Gas estimate:', quote.gasEstimate);
    console.log('  Deadline:', new Date(quote.deadline * 1000).toISOString());
    console.log('  Route data length:', quote.routeData.length, 'chars');
    
  } catch (error: any) {
    console.error('\n❌ Failed to get quote:', error.message);
    throw error;
  }
  
  // Execute buy through LiquidRouter
  console.log('\n📤 Submitting buy transaction...');
  
  const routerWithSigner = router.connect(wallet);
  
  try {
    const tx = await routerWithSigner.buy(
      CONFIG.rareToken,
      wallet.address,                     // recipient
      ethers.constants.AddressZero,       // no referrer
      quote.minAmountOut,                 // minTokensOut (with slippage)
      quote.routeData,                    // Universal Router calldata
      quote.deadline,                     // deadline
      { 
        value: ethAmount,
        gasLimit: 700000, // Sufficient for swap + fee distribution + RAREBurner quote/burn
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
      console.log('  Tokens received:', ethers.utils.formatEther(buyEvent.args.tokensReceived), rareSymbol);
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
    throw error;
  }
  
  // Check balances after
  const ethBalanceAfter = await provider.getBalance(wallet.address);
  const rareBalanceAfter = await rareToken.balanceOf(wallet.address);
  
  console.log('\n💰 Balances After:');
  console.log('  ETH:', ethers.utils.formatEther(ethBalanceAfter), 'ETH');
  console.log('  RARE:', ethers.utils.formatEther(rareBalanceAfter), rareSymbol);
  
  console.log('\n📈 Changes:');
  console.log('  ETH spent:', ethers.utils.formatEther(ethBalanceBefore.sub(ethBalanceAfter)), 'ETH (includes gas)');
  console.log('  RARE gained:', ethers.utils.formatEther(rareBalanceAfter.sub(rareBalanceBefore)), rareSymbol);
  
  console.log('\n' + '='.repeat(70));
  console.log('✅ Buy complete!');
  console.log('='.repeat(70) + '\n');
}

main().catch((error) => {
  console.error('\n💥 Error:', error.message);
  process.exit(1);
});

