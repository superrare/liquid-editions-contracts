/**
 * Sell RARE token on Ethereum Sepolia via LiquidRouter
 * 
 * This script:
 * 1. Gets a quote from Uniswap (dynamically routed)
 * 2. Submits the sell transaction through LiquidRouter
 * 
 * Note: LiquidRouter approves Permit2 for token transfers, which is how
 * Universal Router expects to pull tokens during sells.
 * 
 * Usage:
 *   cd scripts
 *   npx ts-node sell-rare-sepolia.ts
 */

import { ethers } from 'ethers';
import { getManualSellQuote } from './uniswap-manual-router';
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
  rareAmount: '0.005',
  slippageBps: 1000, // 10% slippage
};

// ABIs
const LIQUID_ROUTER_ABI = [
  'function sell(address token, uint256 tokenAmount, address recipient, address orderReferrer, uint256 minEthOut, bytes calldata routeData, uint256 deadline) external returns (uint256 ethReceived)',
  'function TOTAL_FEE_BPS() external view returns (uint256)',
  'event RouterSell(address indexed token, address indexed seller, address indexed recipient, address orderReferrer, uint256 tokensIn, uint256 ethReceived, uint256 ethFee, uint256 ethToSeller, uint256 protocolFee, uint256 referrerFee, uint256 beneficiaryFee, uint256 burnFee)',
];

const ERC20_ABI = [
  'function balanceOf(address) external view returns (uint256)',
  'function symbol() external view returns (string)',
  'function approve(address spender, uint256 amount) external returns (bool)',
  'function allowance(address owner, address spender) external view returns (uint256)',
];

// ============================================
// MAIN
// ============================================

async function main() {
  console.log('='.repeat(70));
  console.log('Sell RARE on Ethereum Sepolia via LiquidRouter');
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
  console.log('  RARE Amount:', CONFIG.rareAmount, 'RARE');
  console.log('  Slippage:', CONFIG.slippageBps / 100, '%');
  
  // Check balances before
  const ethBalanceBefore = await provider.getBalance(wallet.address);
  const rareToken = new ethers.Contract(CONFIG.rareToken, ERC20_ABI, wallet);
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
  
  // Parse token amount
  const tokenAmount = ethers.utils.parseEther(CONFIG.rareAmount);
  
  // Check if we have enough tokens
  if (rareBalanceBefore.lt(tokenAmount)) {
    throw new Error(`Insufficient RARE balance. Have: ${ethers.utils.formatEther(rareBalanceBefore)}, Need: ${CONFIG.rareAmount}`);
  }
  
  // Check and set approval if needed
  console.log('\n🔐 Checking token approval...');
  const currentAllowance = await rareToken.allowance(wallet.address, CONFIG.liquidRouter);
  
  if (currentAllowance.lt(tokenAmount)) {
    console.log('  Approving LiquidRouter to spend RARE tokens...');
    const approveTx = await rareToken.approve(CONFIG.liquidRouter, ethers.constants.MaxUint256);
    console.log('  Approval transaction:', approveTx.hash);
    await approveTx.wait();
    console.log('  ✅ Approval confirmed');
  } else {
    console.log('  ✅ Already approved');
  }
  
  // Get quote from Uniswap
  console.log('\n🔍 Getting quote from Uniswap...');
  
  const wethAddress = '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14';
  
  let quote;
  try {
    quote = await getManualSellQuote({
      token: CONFIG.rareToken,
      tokenDecimals: 18,
      tokenAmount: tokenAmount.toString(),
      slippageBps: CONFIG.slippageBps,
      recipient: wallet.address,
      poolFee: 3000, // 0.3% fee tier
    }, CONFIG.chainId, CONFIG.rpcUrl, wethAddress);
    
    console.log('\n✅ Quote received:');
    console.log('  Route:', quote.route);
    console.log('  Expected ETH out:', ethers.utils.formatEther(quote.amountOut), 'ETH (gross)');
    console.log('  Min ETH out (after slippage):', ethers.utils.formatEther(quote.minAmountOut), 'ETH');
    console.log('  Gas estimate:', quote.gasEstimate);
    console.log('  Deadline:', new Date(quote.deadline * 1000).toISOString());
    console.log('  Route data length:', quote.routeData.length, 'chars');
    
  } catch (error: any) {
    console.error('\n❌ Failed to get quote:', error.message);
    throw error;
  }
  
  // Execute sell through LiquidRouter
  console.log('\n📤 Submitting sell transaction...');
  
  const routerWithSigner = router.connect(wallet);
  
  try {
    const tx = await routerWithSigner.sell(
      CONFIG.rareToken,
      tokenAmount,                        // tokensToSell
      wallet.address,                     // recipient
      ethers.constants.AddressZero,       // no referrer
      quote.minAmountOut,                 // minEthOut (with slippage)
      quote.routeData,                    // Universal Router calldata
      quote.deadline,                     // deadline
      { 
        gasLimit: 700000, // Sufficient for swap + fee distribution + RAREBurner quote/burn
      }
    );
    
    console.log('  Transaction hash:', tx.hash);
    console.log('  Waiting for confirmation...');
    
    const receipt = await tx.wait();
    console.log('  ✅ Confirmed in block:', receipt.blockNumber);
    console.log('  Gas used:', receipt.gasUsed.toString());
    
    // Parse events
    const sellEvent = receipt.logs
      .map((log: any) => {
        try {
          return routerWithSigner.interface.parseLog(log);
        } catch {
          return null;
        }
      })
      .find((e: any) => e?.name === 'RouterSell');
    
    if (sellEvent) {
      console.log('\n📊 Trade Details:');
      console.log('  Tokens sold:', ethers.utils.formatEther(sellEvent.args.tokensIn), rareSymbol);
      console.log('  ETH received (gross):', ethers.utils.formatEther(sellEvent.args.ethReceived), 'ETH');
      console.log('  ETH fee:', ethers.utils.formatEther(sellEvent.args.ethFee), 'ETH');
      console.log('  ETH to seller (net):', ethers.utils.formatEther(sellEvent.args.ethToSeller), 'ETH');
      console.log('\n  Fee Distribution:');
      console.log('    Protocol:', ethers.utils.formatEther(sellEvent.args.protocolFee), 'ETH');
      console.log('    Referrer:', ethers.utils.formatEther(sellEvent.args.referrerFee), 'ETH');
      console.log('    Beneficiary:', ethers.utils.formatEther(sellEvent.args.beneficiaryFee), 'ETH');
      console.log('    RARE Burn:', ethers.utils.formatEther(sellEvent.args.burnFee), 'ETH');
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
  console.log('  ETH gained:', ethers.utils.formatEther(ethBalanceAfter.sub(ethBalanceBefore)), 'ETH (net of gas)');
  console.log('  RARE sold:', ethers.utils.formatEther(rareBalanceBefore.sub(rareBalanceAfter)), rareSymbol);
  
  console.log('\n' + '='.repeat(70));
  console.log('✅ Sell complete!');
  console.log('='.repeat(70) + '\n');
}

main().catch((error) => {
  console.error('\n💥 Error:', error.message);
  process.exit(1);
});

