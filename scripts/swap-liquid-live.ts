/**
 * Swap between two LiquidEdition tokens on live network via LiquidRouter
 * 
 * This script:
 * 1. Gets quotes for both legs: tokenIn -> ETH and ETH -> tokenOut
 * 2. Submits the swap transaction through LiquidRouter.swap()
 * 
 * Uses REAL RARE token (not mock) for multi-hop routing
 * 
 * Usage:
 *   cd scripts
 *   npx ts-node swap-liquid-live.ts
 */

import { ethers } from 'ethers';
import { getManualBuyQuote, getManualSellQuote } from './uniswap-manual-router';
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
  liquidRouter: '0x889b8bc562a4bed31510a1352FD351649D8EebB2', // Ethereum Sepolia LiquidRouter (NEW)
  
  // Token addresses
  tokenIn: '0x626Cad21a54A1e62a0fEEa372345e5C9D7C165f6', // Your LiquidEdition token (input)
  tokenOut: '0x36C7C927BE66d95618C3dfcB644Bbdc3a2765e73', // Your LiquidEdition token (output) - UPDATE THIS
  
  // Real RARE token addresses (from NetworkConfig)
  rareToken: '0x197FaeF3f59eC80113e773Bb6206a17d183F97CB', // Ethereum Sepolia RARE
  
  // Trade parameters
  tokenAmount: '10000', // Amount of input tokens to swap
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
  'function swap(address tokenIn, uint256 amountIn, address tokenOut, address recipient, address orderReferrer, uint256 minAmountOut, bytes calldata leg1Commands, bytes[] calldata leg1Inputs, bytes calldata leg2Commands, bytes[] calldata leg2Inputs, uint256 deadline) external payable returns (uint256 amountOut)',
  'function TOTAL_FEE_BPS() external view returns (uint256)',
  'event RouterSwap(address indexed tokenIn, address indexed tokenOut, address indexed sender, address recipient, address orderReferrer, uint256 amountIn, uint256 ethAtMidpoint, uint256 fee, uint256 amountOut, uint256 protocolFee, uint256 referrerFee, uint256 beneficiaryFeeA, uint256 beneficiaryFeeB, uint256 burnFee)',
];

const ERC20_ABI = [
  'function balanceOf(address) external view returns (uint256)',
  'function symbol() external view returns (string)',
  'function name() external view returns (string)',
  'function approve(address spender, uint256 amount) external returns (bool)',
  'function allowance(address owner, address spender) external view returns (uint256)',
  'function decimals() external view returns (uint8)',
];

// ============================================
// MAIN
// ============================================

async function main() {
  console.log('='.repeat(70));
  console.log('Swap LiquidEdition Tokens via LiquidRouter (LIVE TEST)');
  console.log('='.repeat(70));
  
  // Check for private key
  const privateKey = process.env.DEPLOYER_PRIVATE_KEY;
  if (!privateKey) {
    throw new Error('DEPLOYER_PRIVATE_KEY not set in .env file');
  }
  
  // Validate token addresses
  if (CONFIG.tokenIn === CONFIG.tokenOut) {
    throw new Error('⚠️  tokenIn and tokenOut must be different addresses');
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
  console.log('  Token In:', CONFIG.tokenIn);
  console.log('  Token Out:', CONFIG.tokenOut);
  console.log('  RARE Token (real):', rareToken);
  console.log('  WETH:', wethAddress);
  console.log('  Slippage:', CONFIG.slippageBps / 100, '%');
  
  // Verify router is deployed
  if (CONFIG.liquidRouter === '0x0000000000000000000000000000000000000000') {
    throw new Error('⚠️  Please update CONFIG.liquidRouter with your deployed router address');
  }
  
  // Get token contracts and info
  const tokenIn = new ethers.Contract(CONFIG.tokenIn, ERC20_ABI, wallet);
  const tokenOut = new ethers.Contract(CONFIG.tokenOut, ERC20_ABI, provider);
  
  const tokenInSymbol = await tokenIn.symbol();
  const tokenInName = await tokenIn.name();
  const tokenInDecimals = await tokenIn.decimals();
  
  const tokenOutSymbol = await tokenOut.symbol();
  const tokenOutName = await tokenOut.name();
  const tokenOutDecimals = await tokenOut.decimals();
  
  // Check balances before
  const ethBalanceBefore = await provider.getBalance(wallet.address);
  const tokenInBalanceBefore = await tokenIn.balanceOf(wallet.address);
  const tokenOutBalanceBefore = await tokenOut.balanceOf(wallet.address);
  
  console.log('\n💰 Balances Before:');
  console.log('  ETH:', ethers.utils.formatEther(ethBalanceBefore), 'ETH');
  console.log(`  ${tokenInSymbol}:`, ethers.utils.formatUnits(tokenInBalanceBefore, tokenInDecimals), tokenInSymbol);
  console.log(`  ${tokenOutSymbol}:`, ethers.utils.formatUnits(tokenOutBalanceBefore, tokenOutDecimals), tokenOutSymbol);
  
  if (tokenInBalanceBefore.eq(0)) {
    throw new Error(`No ${tokenInSymbol} tokens to swap!`);
  }
  
  // Determine token amount to swap
  let tokenAmount: ethers.BigNumber;
  if (CONFIG.tokenAmount.toLowerCase() === 'half') {
    tokenAmount = tokenInBalanceBefore.div(2);
  } else {
    tokenAmount = ethers.utils.parseUnits(CONFIG.tokenAmount, tokenInDecimals);
    if (tokenAmount.gt(tokenInBalanceBefore)) {
      throw new Error(`Insufficient balance. Have: ${ethers.utils.formatUnits(tokenInBalanceBefore, tokenInDecimals)}, Requested: ${CONFIG.tokenAmount}`);
    }
  }
  
  console.log(`\n💸 Swapping: ${ethers.utils.formatUnits(tokenAmount, tokenInDecimals)} ${tokenInSymbol}`);
  
  // Get router fee configuration
  const router = new ethers.Contract(CONFIG.liquidRouter, LIQUID_ROUTER_ABI, provider);
  const totalFeeBps = await router.TOTAL_FEE_BPS();
  console.log('\n⚙️  Router Configuration:');
  console.log('  Total Fee:', totalFeeBps.toNumber() / 100, '%');
  
  // Check and set approval if needed
  console.log('\n🔐 Checking token approval...');
  const currentAllowance = await tokenIn.allowance(wallet.address, CONFIG.liquidRouter);
  
  if (currentAllowance.lt(tokenAmount)) {
    console.log('  Approving LiquidRouter to spend tokens...');
    const approveTx = await tokenIn.approve(CONFIG.liquidRouter, ethers.constants.MaxUint256);
    console.log('  Approval transaction:', approveTx.hash);
    await approveTx.wait();
    console.log('  ✅ Approval confirmed');
  } else {
    console.log('  ✅ Already approved');
  }
  
  // ============================================
  // LEG 1: Get quote for tokenIn -> ETH
  // ============================================
  console.log('\n🔍 Getting quote for LEG 1: tokenIn -> ETH...');
  console.log(`  Route: ${tokenInSymbol} → RARE → ETH (multi-hop)`);
  
  let leg1Quote;
  try {
    leg1Quote = await getManualSellQuote(
      {
        token: CONFIG.tokenIn,
        tokenDecimals: tokenInDecimals,
        tokenAmount: tokenAmount.toString(),
        slippageBps: CONFIG.slippageBps,
        recipient: wallet.address,
        poolFee: 0, // Liquid tokens use 0% fee V4 pools
        baseTokenAddress: rareToken, // REAL RARE token for multi-hop
      },
      CONFIG.chainId,
      CONFIG.rpcUrl,
      wethAddress
    );
    
    console.log('\n✅ LEG 1 Quote received:');
    console.log('  Route:', leg1Quote.route);
    console.log('  Expected ETH out (gross):', ethers.utils.formatEther(leg1Quote.amountOut), 'ETH');
    console.log('  Min ETH out (after slippage):', ethers.utils.formatEther(leg1Quote.minAmountOut), 'ETH');
    
  } catch (error: any) {
    console.error('\n❌ Failed to get LEG 1 quote:', error.message);
    console.error('\nNote: V4 route generation for Liquid tokens requires:');
    console.error('  - Valid tokenIn → RARE V4 pool');
    console.error('  - Valid RARE → ETH pool');
    console.error('  - Proper Uniswap V4 quoter integration');
    throw error;
  }
  
  // Calculate ETH after router fee (this is what will be available for leg2)
  const grossEthFromLeg1 = ethers.BigNumber.from(leg1Quote.amountOut);
  const fee = grossEthFromLeg1.mul(totalFeeBps).div(10000);
  const ethForLeg2 = grossEthFromLeg1.sub(fee);
  
  console.log('\n💰 Fee Calculation:');
  console.log('  Gross ETH from leg1:', ethers.utils.formatEther(grossEthFromLeg1), 'ETH');
  console.log('  Router fee:', ethers.utils.formatEther(fee), 'ETH');
  console.log('  ETH available for leg2:', ethers.utils.formatEther(ethForLeg2), 'ETH');
  
  // ============================================
  // LEG 2: Get quote for ETH -> tokenOut
  // ============================================
  // Note: getManualBuyQuote expects the full ETH amount and will subtract the router fee.
  // But in swap(), leg2 receives ethForLeg2 which is already net of fees.
  // So we need to pass a higher ETH amount such that after getManualBuyQuote subtracts
  // the fee, we get ethForLeg2. This simulates what tokens we'd get from swapping ethForLeg2.
  const ethAmountForLeg2Quote = ethForLeg2.mul(10000).div(10000 - totalFeeBps);
  
  console.log('\n🔍 Getting quote for LEG 2: ETH -> tokenOut...');
  console.log(`  Route: ETH → RARE → ${tokenOutSymbol} (multi-hop)`);
  console.log(`  Note: Using ${ethers.utils.formatEther(ethAmountForLeg2Quote)} ETH for quote (will result in ${ethers.utils.formatEther(ethForLeg2)} ETH after fee)`);
  
  let leg2Quote;
  try {
    leg2Quote = await getManualBuyQuote(
      {
        token: CONFIG.tokenOut,
        tokenDecimals: tokenOutDecimals,
        ethAmount: ethAmountForLeg2Quote.toString(),
        slippageBps: CONFIG.slippageBps,
        recipient: wallet.address,
        poolFee: 0, // Liquid tokens use 0% fee V4 pools
        baseTokenAddress: rareToken, // REAL RARE token for multi-hop
      },
      CONFIG.chainId,
      CONFIG.rpcUrl,
      wethAddress,
      totalFeeBps.toNumber()
    );
    
    console.log('\n✅ LEG 2 Quote received:');
    console.log('  Route:', leg2Quote.route);
    console.log('  Expected tokens out:', ethers.utils.formatUnits(leg2Quote.amountOut, tokenOutDecimals), tokenOutSymbol);
    console.log('  Min tokens out (after slippage):', ethers.utils.formatUnits(leg2Quote.minAmountOut, tokenOutDecimals), tokenOutSymbol);
    
  } catch (error: any) {
    console.error('\n❌ Failed to get LEG 2 quote:', error.message);
    console.error('\nNote: V4 route generation for Liquid tokens requires:');
    console.error('  - Valid ETH → RARE pool');
    console.error('  - Valid RARE → tokenOut V4 pool');
    console.error('  - Proper Uniswap V4 quoter integration');
    throw error;
  }
  
  // Calculate final expected output (after leg2, no additional fee since fee was taken at midpoint)
  const expectedTokenOut = ethers.BigNumber.from(leg2Quote.amountOut);
  const minTokenOut = ethers.BigNumber.from(leg2Quote.minAmountOut);
  
  console.log('\n📊 Combined Swap Summary:');
  console.log(`  Input: ${ethers.utils.formatUnits(tokenAmount, tokenInDecimals)} ${tokenInSymbol}`);
  console.log(`  Expected Output: ${ethers.utils.formatUnits(expectedTokenOut, tokenOutDecimals)} ${tokenOutSymbol}`);
  console.log(`  Min Output (slippage protection): ${ethers.utils.formatUnits(minTokenOut, tokenOutDecimals)} ${tokenOutSymbol}`);
  console.log(`  Deadline: ${new Date(leg1Quote.deadline * 1000).toISOString()}`);
  
  // ============================================
  // Execute swap through LiquidRouter
  // ============================================
  console.log('\n📤 Submitting swap transaction...');
  console.log('  ⚠️  This is a LIVE transaction on chain ID', CONFIG.chainId);
  
  const routerWithSigner = router.connect(wallet);
  
  try {
    const tx = await routerWithSigner.swap(
      CONFIG.tokenIn,
      tokenAmount,
      CONFIG.tokenOut,
      wallet.address,
      ethers.constants.AddressZero, // No referrer
      minTokenOut,
      leg1Quote.commands, // leg1: tokenIn -> ETH
      leg1Quote.inputs,
      leg2Quote.commands, // leg2: ETH -> tokenOut
      leg2Quote.inputs,
      leg1Quote.deadline, // Use same deadline for both legs
      { 
        gasLimit: 1500000, // Higher gas limit for two-leg swap
      }
    );
    
    console.log('  Transaction hash:', tx.hash);
    console.log('  Waiting for confirmation...');
    
    const receipt = await tx.wait();
    console.log('  ✅ Confirmed in block:', receipt.blockNumber);
    console.log('  Gas used:', receipt.gasUsed.toString());
    
    // Parse events
    const swapEvent = receipt.logs
      .map((log: any) => {
        try {
          return routerWithSigner.interface.parseLog(log);
        } catch {
          return null;
        }
      })
      .find((e: any) => e?.name === 'RouterSwap');
    
    if (swapEvent) {
      console.log('\n📊 Trade Details:');
      console.log(`  Tokens in: ${ethers.utils.formatUnits(swapEvent.args.amountIn, tokenInDecimals)} ${tokenInSymbol}`);
      console.log('  ETH at midpoint (gross):', ethers.utils.formatEther(swapEvent.args.ethAtMidpoint), 'ETH');
      console.log('  Fee collected:', ethers.utils.formatEther(swapEvent.args.fee), 'ETH');
      console.log(`  Tokens out: ${ethers.utils.formatUnits(swapEvent.args.amountOut, tokenOutDecimals)} ${tokenOutSymbol}`);
      console.log('\n  Fee Distribution:');
      console.log('    Protocol:', ethers.utils.formatEther(swapEvent.args.protocolFee), 'ETH');
      console.log('    Referrer:', ethers.utils.formatEther(swapEvent.args.referrerFee), 'ETH');
      console.log(`    Beneficiary (${tokenInSymbol}):`, ethers.utils.formatEther(swapEvent.args.beneficiaryFeeA), 'ETH');
      console.log(`    Beneficiary (${tokenOutSymbol}):`, ethers.utils.formatEther(swapEvent.args.beneficiaryFeeB), 'ETH');
      console.log('    RARE Burn:', ethers.utils.formatEther(swapEvent.args.burnFee), 'ETH');
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
  const tokenInBalanceAfter = await tokenIn.balanceOf(wallet.address);
  const tokenOutBalanceAfter = await tokenOut.balanceOf(wallet.address);
  
  console.log('\n💰 Balances After:');
  console.log('  ETH:', ethers.utils.formatEther(ethBalanceAfter), 'ETH');
  console.log(`  ${tokenInSymbol}:`, ethers.utils.formatUnits(tokenInBalanceAfter, tokenInDecimals), tokenInSymbol);
  console.log(`  ${tokenOutSymbol}:`, ethers.utils.formatUnits(tokenOutBalanceAfter, tokenOutDecimals), tokenOutSymbol);
  
  console.log('\n📈 Changes:');
  console.log(`  ${tokenInSymbol} spent:`, ethers.utils.formatUnits(tokenInBalanceBefore.sub(tokenInBalanceAfter), tokenInDecimals), tokenInSymbol);
  console.log(`  ${tokenOutSymbol} gained:`, ethers.utils.formatUnits(tokenOutBalanceAfter.sub(tokenOutBalanceBefore), tokenOutDecimals), tokenOutSymbol);
  console.log('  ETH change:', ethers.utils.formatEther(ethBalanceAfter.sub(ethBalanceBefore)), 'ETH (net of gas)');
  
  console.log('\n' + '='.repeat(70));
  console.log('✅ Swap complete!');
  console.log('='.repeat(70) + '\n');
}

main().catch((error) => {
  console.error('\n💥 Error:', error.message);
  process.exit(1);
});
