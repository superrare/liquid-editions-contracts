/**
 * Live test script for CCA auction mechanics via LiquidAuctioneer
 *
 * State-driven: reads auction status (LiquidGraduated.getAuctionState() + CCA blocks/prices), then:
 * - Status "active" → can bid with ETH, then exit or leave bid.
 * - Status "ended (claim period)" → skip bid; run claim (if CLAIM_BID_ID) then trigger graduation via strategy.migrate()
 * - Status "graduated" → nothing to do.
 * Default: dry run (read state + simulate). Use --broadcast to send transactions.
 *
 * Prerequisites:
 * - LiquidFactory with lbpStrategyFactory, positionManager, protocolFeeRecipient, ccaFactory set
 * - A LiquidGraduated token with an active (or ended) CCA auction:
 *   AUCTION_DURATION_BLOCKS=20 forge script script/CreateTokenWithAuction.s.sol:CreateTokenWithAuction --rpc-url $RPC_URL --broadcast
 *   Then set LIQUID_TOKEN to the created token address.
 *
 * Env:
 * - DEPLOYER_PRIVATE_KEY: signer
 * - LIQUID_TOKEN: LiquidGraduated token address (required)
 * - Chain is auto-detected from the RPC you connect to (Sepolia 11155111, Base Sepolia 84532, Base 8453).
 * - ETH_SEPOLIA, BASE_SEPOLIA, BASE_RPC_URL, or RPC_URL: RPC for the chain
 * - ETH_BID_AMOUNT: ETH to send for bid (default 0.0001)
 * - SKIP_EXIT=1: do not call exit after bid (e.g. to test claim later)
 * - SKIP_GRADUATION=1: do not call strategy.migrate() when auction ended (default: run graduation when ended).
 * - TRIGGER_GRADUATION=1: force graduation when ended (default is to graduate when ended unless SKIP_GRADUATION=1).
 * - CLAIM_BID_ID: when testing claim, set to your bidId (optional). Script checks status and runs claim then graduate when ended.
 * - BID_COUNT: when auction is active, place this many bids (default 1). Use 2 to leave one bid for claim after graduation.
 * - EXIT_BID_IDS: when auction has ended, exit only these bid IDs (e.g. "0" or "0,1"). Exit is only allowed after end block (CCA: CannotPartiallyExitBidBeforeEndBlock).
 * - EXIT_TO_ETH=1: use LiquidAuctioneer exit*ToETH paths (swap RARE refund to ETH). Default is direct CCA exit (refund in RARE) for reliability.
 *
 * Exit semantics: Bids are not withdrawable until the auction has ended. The CCA reverts with CannotPartiallyExitBidBeforeEndBlock
 * if you call exitPartialBidToETH before endBlock. So: place bid(s) while active; after end block run again with EXIT_BID_IDS
 * to exit a subset, then graduation; then use CLAIM_BID_ID to claim any bid you did not exit.
 *
 * Saving test ETH: use a short auction (e.g. AUCTION_DURATION_BLOCKS=20), bid small (0.0001 ETH),
 * then after auction ends run with EXIT_BID_IDS=0 to exit and recover; only fees and gas are spent.
 *
 * ========== STATE-DRIVEN: run the script multiple times, no env vars required ==========
 *
 *   Set LIQUID_TOKEN once (and DEPLOYER_PRIVATE_KEY for --broadcast). Then just run with --broadcast
 *   repeatedly; the script infers the next step from auction status and your bids.
 *
 *   1. Create auction (once): CreateTokenWithAuction.s.sol, then set LIQUID_TOKEN in .env.
 *
 *   2. Run with --broadcast as often as you like (same LIQUID_TOKEN):
 *      - Active   → Place 1 bid (or BID_COUNT=N). Exit not allowed until auction ends.
 *      - Ended    → Auto-discover your unexited bids, exit all, then graduate. (Set EXIT_BID_IDS to exit only specific ids.)
 *      - Graduated → Auto-discover your claimable bids and claim all. (Set CLAIM_BID_ID to claim only one.)
 *
 *   No need to set EXIT_BID_IDS or CLAIM_BID_ID: the script discovers your bids and runs exit/claim for you.
 *
 *   Exit timing: Exits are only available after end block, but still supported after graduation if correct hints are provided
 *   for partially-filled bids (last fully filled checkpoint + optional outbid checkpoint).
 *   For best UX, run once at "ended" (exit + graduate), then again to claim.
 *
 *   Dry run: omit --broadcast to see status and what would be done.
 *
 * Usage:
 *   cd scripts && npx ts-node auction-mechanics-live.ts           # dry run (default)
 *   cd scripts && npx ts-node auction-mechanics-live.ts --broadcast   # send txs
 */

import { ethers } from 'ethers';
import { getManualBuyQuote, getManualSellQuote } from './uniswap-manual-router';
import * as dotenv from 'dotenv';
import * as path from 'path';

dotenv.config({ path: path.resolve(__dirname, '../.env') });

// Network config (matches script/config/NetworkConfig.sol). Chain ID derived from RPC.
const NETWORK_CONFIG: Record<
  number,
  { rareToken: string; weth: string; liquidAuctioneer: string }
> = {
  11155111: {
    rareToken: '0x197FaeF3f59eC80113e773Bb6206a17d183F97CB',
    weth: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14',
    liquidAuctioneer: '0xdb75D1226685d6809C058dC794dB3dE6d773004C',
  },
  84532: {
    rareToken: '0x8b21bC8571d11F7AdB705ad8F6f6BD1deb79cE01',
    weth: '0x4200000000000000000000000000000000000006',
    liquidAuctioneer: '0x0000000000000000000000000000000000000000',
  },
  8453: {
    rareToken: '0x691077C8e8de54EA84eFd454630439F99bd8C92f',
    weth: '0x4200000000000000000000000000000000000006',
    liquidAuctioneer: '0x0000000000000000000000000000000000000000',
  },
};

/** Gas limit for bid (swap + CCA submitBid). Simulation uses this too so dry run matches broadcast. */
const BID_GAS_LIMIT = 1_000_000;
/** Gas limit for exitBidToETH / exitPartialBidToETH. */
const EXIT_GAS_LIMIT = 500_000;
/** Gas limit for strategy.migrate() (sweep + pool creation). */
const GRADUATION_GAS_LIMIT = 800_000;
const MAX_UINT64 = ethers.BigNumber.from('0xffffffffffffffff');
const CHECKPOINT_SCAN_LIMIT = 2048;

/** Decode Solidity panic code (first 4 bytes after selector 0x4e487b71) or custom error for clearer errors. */
function decodeRevertReason(data: string | undefined): string {
  if (!data || data === '0x') return 'unknown';
  const hex = data.startsWith('0x') ? data.slice(2) : data;
  if (hex.length < 8) return data;
  const sig = hex.slice(0, 8);
  if (sig === '4e487b71') {
    const code = parseInt(hex.slice(8, 16), 16);
    const panicMessages: Record<number, string> = {
      0x01: 'assert(false)',
      0x11: 'arithmetic underflow or overflow',
      0x12: 'division or modulo by zero',
      0x41: 'allocates too much memory',
      0x51: 'invalid array pop',
    };
    return `panic: ${panicMessages[code] ?? `0x${code.toString(16)}`}`;
  }
  const knownErrors: Record<string, string> = {
    '0x0ba98457': 'CannotExitBid()',
    '0x6a009455': 'InvalidLastFullyFilledCheckpointHint()',
    '0x516cb4ba': 'InvalidOutbidBlockCheckpointHint()',
    '0x3e90fcc6': 'AllowanceExpired(uint48) (Permit2)',
    '0xd66173a5': 'NotGraduated() (LiquidAuctioneer wrapper)',
  };
  const selector = `0x${sig}`;
  if (knownErrors[selector]) return `${knownErrors[selector]} (${selector})`;
  return data;
}

/** Best-effort extraction of revert data from ethers error shapes. */
function extractRevertData(err: any): string | undefined {
  return err?.data
    ?? err?.error?.data
    ?? err?.error?.error?.data
    ?? err?.receipt?.revertReason
    ?? err?.reason;
}

function expandRpcUrl(url: string | undefined, defaultUrl: string): string {
  if (!url) return defaultUrl;
  if (url.includes('${ALCHEMY_API_KEY}')) {
    const apiKey = process.env.ALCHEMY_API_KEY;
    if (apiKey) return url.replace('${ALCHEMY_API_KEY}', apiKey);
  }
  return url;
}

const RPC_URL = expandRpcUrl(
  process.env.ETH_SEPOLIA || process.env.BASE_SEPOLIA || process.env.BASE_RPC_URL || process.env.RPC_URL,
  'https://ethereum-sepolia-rpc.publicnode.com'
);

const LIQUID_TOKEN_ABI = [
  'function auctionAddress() external view returns (address)',
  'function isGraduated() external view returns (bool)',
  'function getAuctionState() external view returns (address auction, bool graduated, address migratorAddr)',
];
const CCA_ABI = [
  'function startBlock() external view returns (uint64)',
  'function endBlock() external view returns (uint64)',
  'function claimBlock() external view returns (uint64)',
  'function floorPrice() external view returns (uint256)',
  'function clearingPrice() external view returns (uint256)',
  'function currencyRaised() external view returns (uint256)',
  'function nextBidId() external view returns (uint256)',
  'function lastCheckpointedBlock() external view returns (uint64)',
  'function checkpoints(uint64 blockNumber) external view returns (uint256 clearingPrice, uint256 currencyRaisedAtClearingPriceQ96_X7, uint256 cumulativeMpsPerPrice, uint24 cumulativeMps, uint64 prev, uint64 next)',
  'function checkpoint() external',
  'function exitBid(uint256 bidId) external',
  'function exitPartiallyFilledBid(uint256 bidId, uint64 lastFullyFilledCheckpointBlock, uint64 outbidBlock) external',
  'function bids(uint256) external view returns (uint64 startBlock, uint24 startCumulativeMps, uint64 exitedBlock, uint256 maxPrice, address owner, uint256 amountQ96, uint256 tokensFilled)',
];
const AUCTIONEER_ABI = [
  'function bid(address tokenIn, uint256 amountIn, address liquidToken, uint256 maxPrice, address bidOwner, address orderReferrer, uint256 prevTickPrice, uint256 minRareOut, uint256 deadline) external payable returns (uint256 bidId)',
  'function exitBidToETH(address liquidToken, uint256 bidId, address recipient, uint256 minEthOut, bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external returns (uint256 ethReceived)',
  'function exitPartialBidToETH(address liquidToken, uint256 bidId, uint256 lastFullyFilledCheckpointBlock, uint256 outbidBlock, address recipient, uint256 minEthOut, bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external returns (uint256 ethReceived)',
  'function claimAuctionTokens(address liquidToken, uint256 bidId) external',
  'function TOTAL_FEE_BPS() external view returns (uint256)',
];
const STRATEGY_ABI = ['function migrate() external'];
const ERC20_ABI = [
  'function balanceOf(address) external view returns (uint256)',
  'function approve(address spender, uint256 amount) external returns (bool)',
];

/** Parse bid struct from CCA (ethers can return named or indexed). */
function parseBid(
  bid: any
): { owner: string; startBlock: number; exitedBlock: number; maxPrice: ethers.BigNumber; tokensFilled: ethers.BigNumber } {
  const b = bid as any;
  const startBlock = typeof b.startBlock?.toNumber === 'function' ? b.startBlock.toNumber() : (b[0]?.toNumber?.() ?? Number(b.startBlock ?? b[0] ?? 0));
  const owner = (b.owner ?? b[4] ?? '').toString();
  const exitedBlock = typeof b.exitedBlock?.toNumber === 'function' ? b.exitedBlock.toNumber() : (b[2]?.toNumber?.() ?? Number(b.exitedBlock ?? b[2] ?? 0));
  const mp = b.maxPrice ?? b[3];
  const maxPrice = ethers.BigNumber.isBigNumber(mp) ? mp : ethers.BigNumber.from(mp ?? 0);
  const tf = b.tokensFilled ?? b[6];
  const tokensFilled = ethers.BigNumber.isBigNumber(tf) ? tf : ethers.BigNumber.from(tf ?? 0);
  return { owner, startBlock, exitedBlock, maxPrice, tokensFilled };
}

/** Parse checkpoint struct from CCA (ethers can return named or indexed). */
function parseCheckpoint(checkpoint: any): {
  clearingPrice: ethers.BigNumber;
  prevBlock: number;
  nextBlock: number;
  isTerminal: boolean;
} {
  const c = checkpoint as any;
  const cp = c.clearingPrice ?? c[0] ?? 0;
  const clearingPrice = ethers.BigNumber.isBigNumber(cp) ? cp : ethers.BigNumber.from(cp);
  const prevRaw = c.prev ?? c[4] ?? 0;
  const nextRaw = c.next ?? c[5] ?? 0;
  const prevBn = ethers.BigNumber.isBigNumber(prevRaw) ? prevRaw : ethers.BigNumber.from(prevRaw);
  const nextBn = ethers.BigNumber.isBigNumber(nextRaw) ? nextRaw : ethers.BigNumber.from(nextRaw);
  const maxSafeBn = ethers.BigNumber.from(Number.MAX_SAFE_INTEGER.toString());
  const prevBlock = prevBn.lte(maxSafeBn)
    ? prevBn.toNumber()
    : 0;
  const isTerminal = nextBn.eq(MAX_UINT64) || nextBn.isZero();
  const nextBlock = isTerminal
    ? 0
    : nextBn.lte(maxSafeBn)
      ? nextBn.toNumber()
      : 0;
  return { clearingPrice, prevBlock, nextBlock, isTerminal };
}

/**
 * Derive CCA exit hints for a bid from the checkpoint linked list.
 * Returns best-effort values; caller should still handle revert fallbacks.
 */
async function deriveExitHintsForBid(
  auction: ethers.Contract,
  bidId: number
): Promise<{ bidStartBlock: number; lastFullyFilledCheckpointBlock: number; outbidBlock: number }> {
  const bid = parseBid(await auction.bids(bidId));
  const bidStartBlock = bid.startBlock;
  const bidMaxPrice = bid.maxPrice;

  let lastFullyFilledCheckpointBlock = bidStartBlock;
  let outbidBlock = 0;

  let checkpointBlock = bidStartBlock;
  let checkpoint = parseCheckpoint(await auction.checkpoints(bidStartBlock));

  if (!checkpoint.clearingPrice.lt(bidMaxPrice)) {
    return { bidStartBlock, lastFullyFilledCheckpointBlock, outbidBlock };
  }

  for (let i = 0; i < CHECKPOINT_SCAN_LIMIT; i++) {
    if (checkpoint.isTerminal || checkpoint.nextBlock === 0) break;

    const nextBlock = checkpoint.nextBlock;
    const nextCheckpoint = parseCheckpoint(await auction.checkpoints(nextBlock));

    if (checkpoint.clearingPrice.lt(bidMaxPrice) && nextCheckpoint.clearingPrice.gte(bidMaxPrice)) {
      lastFullyFilledCheckpointBlock = checkpointBlock;
      if (nextCheckpoint.clearingPrice.gt(bidMaxPrice)) outbidBlock = nextBlock;
      break;
    }

    if (checkpoint.clearingPrice.lt(bidMaxPrice)) {
      lastFullyFilledCheckpointBlock = checkpointBlock;
    }

    checkpointBlock = nextBlock;
    checkpoint = nextCheckpoint;
  }

  return { bidStartBlock, lastFullyFilledCheckpointBlock, outbidBlock };
}

/** Discover bid IDs owned by wallet that are not yet exited (exitedBlock === 0). */
async function discoverUnexitedBidIds(auction: ethers.Contract, walletAddress: string): Promise<number[]> {
  const nextId = await auction.nextBidId();
  const myAddress = walletAddress.toLowerCase();
  const ids: number[] = [];
  for (let id = 0; id < nextId.toNumber(); id++) {
    const bid = await auction.bids(id);
    const { owner, exitedBlock } = parseBid(bid);
    if (owner.toLowerCase() === myAddress && exitedBlock === 0) ids.push(id);
  }
  return ids;
}

/** Discover bid IDs owned by wallet that are exited and have tokens to claim (tokensFilled > 0). */
async function discoverClaimableBidIds(auction: ethers.Contract, walletAddress: string): Promise<string[]> {
  const nextId = await auction.nextBidId();
  const myAddress = walletAddress.toLowerCase();
  const ids: string[] = [];
  for (let id = 0; id < nextId.toNumber(); id++) {
    const bid = await auction.bids(id);
    const { owner, exitedBlock, tokensFilled } = parseBid(bid);
    if (owner.toLowerCase() === myAddress && exitedBlock !== 0 && tokensFilled.gt(0)) ids.push(String(id));
  }
  return ids;
}

async function main() {
  const liquidTokenAddress = process.env.LIQUID_TOKEN;
  if (!liquidTokenAddress) {
    throw new Error('LIQUID_TOKEN env required (LiquidGraduated token address)');
  }

  const broadcast = process.argv.includes('--broadcast');
  const dryRun = !broadcast;
  const skipExit = process.env.SKIP_EXIT === '1';
  const skipGraduation = process.env.SKIP_GRADUATION === '1';
  const triggerGraduation = process.env.TRIGGER_GRADUATION === '1';
  const exitToEth = process.env.EXIT_TO_ETH === '1';
  const ethBidAmount = process.env.ETH_BID_AMOUNT || '0.0001';
  const bidCount = Math.max(1, parseInt(process.env.BID_COUNT || '1', 10));
  const exitBidIdsRaw = process.env.EXIT_BID_IDS; // e.g. "0" or "0,1"
  const exitBidIds: number[] = exitBidIdsRaw
    ? exitBidIdsRaw.split(',').map((s) => parseInt(s.trim(), 10)).filter((n) => !isNaN(n))
    : [];

  const privateKey = process.env.DEPLOYER_PRIVATE_KEY;
  if (!privateKey && broadcast) {
    throw new Error('DEPLOYER_PRIVATE_KEY required when using --broadcast');
  }

  const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
  const network = await provider.getNetwork();
  const chainId = network.chainId;
  const networkConfig = NETWORK_CONFIG[chainId];
  if (!networkConfig) {
    throw new Error(`Unsupported chain ${chainId}. Supported: 11155111 (Sepolia), 84532 (Base Sepolia), 8453 (Base)`);
  }
  const rareToken = process.env.RARE_TOKEN || networkConfig.rareToken;
  const weth = process.env.WETH || networkConfig.weth;
  const liquidAuctioneer = process.env.LIQUID_AUCTIONEER || networkConfig.liquidAuctioneer;
  if (liquidAuctioneer === ethers.constants.AddressZero) {
    throw new Error(
      `LiquidAuctioneer not deployed on chain ${chainId}. Set LIQUID_AUCTIONEER in env or use Sepolia (11155111).`
    );
  }

  const wallet = privateKey ? new ethers.Wallet(privateKey, provider) : null;

  console.log('='.repeat(70));
  console.log('Auction mechanics live test (LiquidAuctioneer)');
  console.log('='.repeat(70));
  console.log('Chain:', chainId, '| RPC:', RPC_URL);
  console.log('Liquid token:', liquidTokenAddress);
  console.log('LiquidAuctioneer:', liquidAuctioneer);
  console.log('Mode:', dryRun ? 'dry run (use --broadcast to send txs)' : 'BROADCAST');
  console.log('SKIP_EXIT:', skipExit, '| SKIP_GRADUATION:', skipGraduation, '| EXIT_TO_ETH:', exitToEth);
  console.log('ETH bid amount:', ethBidAmount, '| BID_COUNT:', bidCount);
  if (exitBidIds.length) console.log('EXIT_BID_IDS:', exitBidIds.join(', '));
  if (dryRun) console.log('\n[DRY RUN – no transactions will be sent]\n');

  const liquidToken = new ethers.Contract(liquidTokenAddress, LIQUID_TOKEN_ABI, provider);
  const auctionAddress = await liquidToken.auctionAddress();
  if (auctionAddress === ethers.constants.AddressZero) {
    throw new Error('Token has no auction (invalid or instant-launch token)');
  }

  const auction = new ethers.Contract(auctionAddress, CCA_ABI, provider);
  const [stateResult, startBlock, endBlock, claimBlock, floorPrice, clearingPrice, currencyRaised] = await Promise.all([
    liquidToken.getAuctionState(),
    auction.startBlock(),
    auction.endBlock(),
    auction.claimBlock(),
    auction.floorPrice(),
    auction.clearingPrice().catch(() => ethers.BigNumber.from(0)),
    auction.currencyRaised().catch(() => ethers.BigNumber.from(0)),
  ]);

  const currentBlock = await provider.getBlockNumber();
  const isEnded = currentBlock >= endBlock;
  const canClaim = currentBlock >= claimBlock;
  const isGraduated = Array.isArray(stateResult) ? stateResult[1] : stateResult.graduated;
  const strategyAddr = Array.isArray(stateResult) ? stateResult[2] : stateResult.strategyAddr;

  const status = isGraduated ? 'graduated' : isEnded ? 'ended (claim period)' : 'active';
  const doGraduation = isEnded && !isGraduated && (triggerGraduation || !skipGraduation);

  console.log('\n--- Auction status (from getAuctionState + CCA) ---');
  console.log('Status:', status);
  console.log('Auction:', auctionAddress, '| Strategy:', strategyAddr);
  console.log('Blocks: current', currentBlock, '| start', startBlock.toString(), '| end', endBlock.toString(), '| claim', claimBlock.toString());
  console.log('floorPrice:', ethers.utils.formatEther(floorPrice), '| clearingPrice:', ethers.utils.formatEther(clearingPrice));
  const raisedStr = currencyRaised.isZero()
    ? '0'
    : currencyRaised.lt(ethers.utils.parseEther('0.01'))
      ? `${currencyRaised.toString()} wei`
      : ethers.utils.formatEther(currencyRaised);
  console.log('currencyRaised:', raisedStr);
  console.log('Will run graduation when ended:', doGraduation, '(set SKIP_GRADUATION=1 to skip; TRIGGER_GRADUATION=1 to force)');

  if (dryRun) {
    // Dry run only does read-only state above; it does NOT simulate the bid. So we simulate here via eth_call.
    if (wallet && !isEnded) {
      console.log('\n--- Simulating bid (eth_call, no gas spent) ---');
      const auctioneer = new ethers.Contract(liquidAuctioneer, AUCTIONEER_ABI, provider);
      const feeBps = (await auctioneer.TOTAL_FEE_BPS()).toNumber();
      const ethAmountWei = ethers.utils.parseEther(ethBidAmount);
      const ethForSwap = ethAmountWei.mul(10000 - feeBps).div(10000);
      try {
        const quote = await getManualBuyQuote(
          {
            token: rareToken,
            tokenDecimals: 18,
            ethAmount: ethForSwap.toString(),
            slippageBps: 500,
            recipient: wallet.address,
          },
          chainId,
          RPC_URL,
          weth,
          0
        );
        const deadline = quote.deadline;
        const minRareOut = ethers.BigNumber.from(quote.minAmountOut);
        const rareAmountOut = ethers.BigNumber.from(quote.amountOut);
        const maxPrice = floorPrice.add(ethers.utils.parseEther('1'));
        const prevTickPrice = floorPrice;
        await provider.call(
          {
            to: liquidAuctioneer,
            from: wallet.address,
            value: ethAmountWei,
            data: auctioneer.interface.encodeFunctionData('bid', [
              ethers.constants.AddressZero,
              0,
              liquidTokenAddress,
              maxPrice,
              wallet.address,
              ethers.constants.AddressZero,
              prevTickPrice,
              minRareOut,
              deadline,
            ]),
            gasLimit: BID_GAS_LIMIT,
          },
          'latest'
        );
        console.log('Simulation: bid would succeed (eth_call with same gas limit as broadcast).');
        if (bidCount > 1) {
          console.log('Simulation: will place', bidCount, 'bids when run with --broadcast.');
        }
        // Exit is only allowed after auction end block (CCA: CannotPartiallyExitBidBeforeEndBlock).
        if (!skipExit) {
          console.log('\n--- Exit (only after auction ends) ---');
          console.log('Exit is only allowed after auction end block (CCA: CannotPartiallyExitBidBeforeEndBlock).');
          console.log('While active, exit is skipped. After end block run with EXIT_BID_IDS to exit, then graduation.');
        }
      } catch (simErr: any) {
        console.error('Simulation: bid would REVERT.');
        if (simErr.reason) console.error('  Reason:', simErr.reason);
        if (simErr.data) console.error('  Data:', simErr.data);
        if (simErr.error?.message) console.error('  Error:', simErr.error.message);
        console.log('\nFix the revert before using --broadcast.');
      }
    }
    if (wallet && isEnded && !isGraduated) {
      const unexited = await discoverUnexitedBidIds(auction, wallet.address);
      if (unexited.length > 0) console.log('\n--- Exit + graduate (ended) ---\nWould exit', unexited.length, 'bid(s) then graduate. Run with --broadcast.');
      if (doGraduation && strategyAddr && strategyAddr !== ethers.constants.AddressZero) {
        console.log('\n--- Simulating graduation (eth_call, same gas as broadcast) ---');
        const strategyForSim = new ethers.Contract(strategyAddr, STRATEGY_ABI, provider);
        try {
          await provider.call(
            {
              to: strategyAddr,
              from: wallet.address,
              data: strategyForSim.interface.encodeFunctionData('migrate'),
              gasLimit: GRADUATION_GAS_LIMIT,
            },
            'latest'
          );
          console.log('Simulation: strategy.migrate() would succeed.');
        } catch (gradErr: any) {
          const reason = decodeRevertReason(gradErr.data ?? gradErr.error?.data);
          console.error('Simulation: strategy.migrate() would REVERT.', reason);
          if (gradErr.reason) console.error('  Reason:', gradErr.reason);
        }
      }
    }
    if (wallet && isGraduated && canClaim) {
      const claimable = await discoverClaimableBidIds(auction, wallet.address);
      if (claimable.length > 0) console.log('\n--- Claim (graduated) ---\nWould claim', claimable.length, 'bid(s). Run with --broadcast to claim.');
    }
    console.log('\n[DRY RUN done – run with --broadcast to execute]');
    return;
  }

  const auctioneer = new ethers.Contract(liquidAuctioneer, AUCTIONEER_ABI, provider).connect(wallet!);
  const feeBps = (await auctioneer.TOTAL_FEE_BPS()).toNumber();
  const ethAmountWei = ethers.utils.parseEther(ethBidAmount);
  const ethForSwap = ethAmountWei.mul(10000 - feeBps).div(10000);

  // --- Step 1: Bid (only when auction active) ---
  const placedBidIds: string[] = [];
  if (!isEnded) {
    console.log('\n--- Step 1: Bid with ETH (BID_COUNT=' + bidCount + ') ---');
    const maxPrice = floorPrice.add(ethers.utils.parseEther('1')); // floor + 1 token worth
    const prevTickPrice = floorPrice;
    const ccaIface = new ethers.utils.Interface(['event BidSubmitted(uint256 indexed id, address indexed owner, uint256 price, uint128 amount)']);

    for (let i = 0; i < bidCount; i++) {
      const quote = await getManualBuyQuote(
        {
          token: rareToken,
          tokenDecimals: 18,
          ethAmount: ethForSwap.toString(),
          slippageBps: 500,
          recipient: wallet!.address,
        },
        chainId,
        RPC_URL,
        weth,
        0
      );
      const deadline = quote.deadline;
      const minRareOut = ethers.BigNumber.from(quote.minAmountOut);
      const rareAmountOut = ethers.BigNumber.from(quote.amountOut);
      if (i === 0) {
        console.log('ETH for swap (after fee):', ethers.utils.formatEther(ethForSwap));
        console.log('Expected RARE out:', ethers.utils.formatEther(rareAmountOut));
      }

      let txBid: ethers.ContractTransaction;
      try {
        txBid = await auctioneer.bid(
          ethers.constants.AddressZero,
          0,
          liquidTokenAddress,
          maxPrice,
          wallet!.address,
          ethers.constants.AddressZero,
          prevTickPrice,
          minRareOut,
          deadline,
          { value: ethAmountWei, gasLimit: BID_GAS_LIMIT }
        );
      } catch (err: any) {
        if (err.transactionHash) {
          console.error('Bid tx reverted:', err.transactionHash);
          try {
            const revertData = await provider.call(
            {
              to: liquidAuctioneer,
              from: wallet!.address,
              value: ethAmountWei,
              data: auctioneer.interface.encodeFunctionData('bid', [
                ethers.constants.AddressZero,
                0,
                liquidTokenAddress,
                maxPrice,
                wallet!.address,
                ethers.constants.AddressZero,
                prevTickPrice,
                minRareOut,
                deadline,
              ]),
            },
            'latest'
          );
        } catch (callErr: any) {
          if (callErr.data) console.error('Revert data:', callErr.data);
          if (callErr.reason) console.error('Revert reason:', callErr.reason);
          if (callErr.error?.data) console.error('Revert (error.data):', callErr.error.data);
        }
      }
        throw err;
      }
      const recBid = await txBid.wait();
      let bidIdFromLog: string | null = null;
      for (const log of recBid.logs) {
        try {
          const parsed = ccaIface.parseLog(log);
          if (parsed.name === 'BidSubmitted') {
            bidIdFromLog = parsed.args.id.toString();
            break;
          }
        } catch { /* skip */ }
      }
      if (bidIdFromLog) placedBidIds.push(bidIdFromLog);
      console.log('Bid', i + 1, 'tx:', txBid.hash, '| bidId:', bidIdFromLog ?? '(check logs)');
    }
    console.log('Placed bidIds:', placedBidIds.join(', ') || '(none)');
    console.log('Exit only available after auction ends. Run again after end block with EXIT_BID_IDS to exit then graduate.');
  } else {
    if (isGraduated) {
      console.log('\nAuction already graduated. Will try to exit any unexited bids (so you can then claim), then claim.');
    } else {
      console.log('\nAuction ended – skipping bid. Running exit (all your bids by default), then graduation (unless SKIP_GRADUATION=1).');
    }
    // --- Step 2 (ended or graduated): Exit unexited bids. You get unfilled RARE back (we swap to ETH); then you can claim Liquid tokens for the filled part.
    const exitBidIdsToUse: number[] = exitBidIds.length > 0 ? exitBidIds : await discoverUnexitedBidIds(auction, wallet!.address);
    if (!skipExit && exitBidIdsToUse.length > 0) {
      console.log('\n--- Step 2: Exit bids ---');
      if (exitBidIds.length === 0) console.log('(auto-discovered', exitBidIdsToUse.length, 'unexited bid(s) for your wallet)');
      // When already graduated, ensure CCA end block is checkpointed so exitPartiallyFilledBid(outbidBlock=0) can pass the block check.
      const auctionWithWallet = new ethers.Contract(auctionAddress, CCA_ABI, provider).connect(wallet!);
      if (isGraduated) {
        try {
          const txCheckpoint = await auctionWithWallet.checkpoint({ gasLimit: 500000 });
          await txCheckpoint.wait();
          console.log('CCA checkpoint() tx:', txCheckpoint.hash);
        } catch (e: any) {
          console.log('CCA checkpoint() call skipped or failed:', e?.reason || e?.message || e);
        }
      }
      let exitCommands = '0x';
      let exitInputs: string[] = [];
      let exitDeadline = 0;
      if (exitToEth) {
        console.log('Using LiquidAuctioneer exit-to-ETH mode (requires working Permit2 path and good EXIT_RARE_ESTIMATE).');
        const rareTokenContract = new ethers.Contract(rareToken, ERC20_ABI, provider);
        const approveTx = await rareTokenContract.connect(wallet!).approve(liquidAuctioneer, ethers.constants.MaxUint256);
        await approveTx.wait();
        const exitRareEstimate = ethers.utils.parseEther(process.env.EXIT_RARE_ESTIMATE || '0.05');
        const quote = await getManualSellQuote(
          {
            token: rareToken,
            tokenDecimals: 18,
            tokenAmount: exitRareEstimate.toString(),
            slippageBps: 500,
            recipient: wallet!.address,
          },
          chainId,
          RPC_URL,
          weth
        );
        exitCommands = quote.commands;
        exitInputs = quote.inputs;
        exitDeadline = quote.deadline;
      } else {
        console.log('Using direct CCA exit mode (refund stays in RARE). Set EXIT_TO_ETH=1 to attempt swap to ETH.');
      }

      const tryDirectCcaExit = async (
        bidId: number,
        bidStartBlockNum: number,
        lastFullyFilledHint: number,
        derivedOutbidHint: number
      ): Promise<boolean> => {
        const tried = new Set<string>();
        const candidates: Array<{ label: string; run: () => Promise<ethers.ContractTransaction>; simulate: () => Promise<any> }> = [];

        candidates.push({
          label: 'exitBid',
          run: () => auctionWithWallet.exitBid(bidId, { gasLimit: EXIT_GAS_LIMIT }),
          simulate: () => auctionWithWallet.callStatic.exitBid(bidId, { gasLimit: EXIT_GAS_LIMIT }),
        });

        const variants: Array<{ lower: number; outbid: number; label: string }> = [
          { lower: lastFullyFilledHint, outbid: derivedOutbidHint, label: 'derived hints' },
          { lower: lastFullyFilledHint, outbid: 0, label: 'derived lower + outbid=0' },
          { lower: bidStartBlockNum, outbid: 0, label: 'bidStart + outbid=0' },
        ];
        for (const v of variants) {
          const key = `${v.lower}-${v.outbid}`;
          if (tried.has(key)) continue;
          tried.add(key);
          candidates.push({
            label: `exitPartiallyFilledBid(${v.label})`,
            run: () => auctionWithWallet.exitPartiallyFilledBid(bidId, v.lower, v.outbid, { gasLimit: EXIT_GAS_LIMIT }),
            simulate: () => auctionWithWallet.callStatic.exitPartiallyFilledBid(bidId, v.lower, v.outbid, { gasLimit: EXIT_GAS_LIMIT }),
          });
        }

        for (const c of candidates) {
          try {
            await c.simulate();
          } catch (simErr: any) {
            const simReason = decodeRevertReason(extractRevertData(simErr));
            console.log(`${c.label} preflight reverted:`, simReason);
            continue;
          }

          try {
            const tx = await c.run();
            await tx.wait();
            console.log('Direct CCA', c.label, 'bidId', bidId, 'tx:', tx.hash, '(refund in RARE)');
            return true;
          } catch (sendErr: any) {
            const sendReason = decodeRevertReason(extractRevertData(sendErr));
            console.log(`${c.label} broadcast reverted after preflight:`, sendReason);
          }
        }

        return false;
      };

      for (const bidId of exitBidIdsToUse) {
        const hints = await deriveExitHintsForBid(auction, bidId);
        const bidStartBlockNum = hints.bidStartBlock;
        const lastFullyFilledHint = hints.lastFullyFilledCheckpointBlock;
        const derivedOutbidHint = hints.outbidBlock;
        console.log(
          'Bid',
          bidId,
          'hints:',
          'bidStart=',
          bidStartBlockNum,
          'lastFullyFilled=',
          lastFullyFilledHint,
          'outbid=',
          derivedOutbidHint
        );

        if (!exitToEth) {
          const ok = await tryDirectCcaExit(bidId, bidStartBlockNum, lastFullyFilledHint, derivedOutbidHint);
          if (!ok) {
            console.error('Exit failed for bidId', bidId, 'in direct mode.');
            console.error('Continuing to claim step (any already-exited bids can still be claimed).');
          }
          continue;
        }

        const blockAtExit = await provider.getBlockNumber();
        let txExit: ethers.ContractTransaction;
        try {
          txExit = await auctioneer.exitBidToETH(
            liquidTokenAddress,
            bidId,
            wallet!.address,
            0, // minEthOut: accept any amount
            exitCommands,
            exitInputs,
            exitDeadline,
            { gasLimit: EXIT_GAS_LIMIT }
          );
          await txExit.wait();
          console.log('Exit bidId', bidId, 'tx:', txExit.hash);
        } catch (err: any) {
          console.log('exitBidToETH(', bidId, ') reverted; trying exitPartialBidToETH(derived hints)...');
          try {
            txExit = await auctioneer.exitPartialBidToETH(
              liquidTokenAddress,
              bidId,
              lastFullyFilledHint,
              derivedOutbidHint,
              wallet!.address,
              0, // minEthOut: accept any amount
              exitCommands,
              exitInputs,
              exitDeadline,
              { gasLimit: EXIT_GAS_LIMIT }
            );
            await txExit.wait();
            console.log('Exit bidId', bidId, 'tx:', txExit.hash);
          } catch (err2: any) {
            const reason2 = decodeRevertReason(extractRevertData(err2));
            console.log('exitPartialBidToETH(derived hints) reverted:', reason2);
            console.log('Trying exitPartialBidToETH(lastFullyFilled=derived, outbidBlock=current)...');
            try {
              txExit = await auctioneer.exitPartialBidToETH(
                liquidTokenAddress,
                bidId,
                lastFullyFilledHint,
                blockAtExit,
                wallet!.address,
                0, // minEthOut: accept any amount
                exitCommands,
                exitInputs,
                exitDeadline,
                { gasLimit: EXIT_GAS_LIMIT }
              );
              await txExit.wait();
              console.log('Exit bidId', bidId, 'tx:', txExit.hash);
            } catch (err3: any) {
              const reason3 = decodeRevertReason(extractRevertData(err3));
              console.log('exitPartialBidToETH(derived, currentBlock) reverted:', reason3);
              console.log('Trying exitPartialBidToETH(lastFullyFilled=bidStart, outbidBlock=0)...');
              try {
                txExit = await auctioneer.exitPartialBidToETH(
                  liquidTokenAddress,
                  bidId,
                  bidStartBlockNum,
                  0,
                  wallet!.address,
                  0, // minEthOut: accept any amount
                  exitCommands,
                  exitInputs,
                  exitDeadline,
                  { gasLimit: EXIT_GAS_LIMIT }
                );
                await txExit.wait();
                console.log('Exit bidId', bidId, 'tx:', txExit.hash);
              } catch (err4: any) {
                const reason4 = decodeRevertReason(extractRevertData(err4));
                console.error('Exit failed for bidId', bidId, '(all variants reverted).');
                console.error('Last revert:', reason4);
                console.error('Falling back to direct CCA exit (refund in RARE, no swap).');
                const ok = await tryDirectCcaExit(bidId, bidStartBlockNum, lastFullyFilledHint, derivedOutbidHint);
                if (!ok) {
                  console.error('Direct fallback also failed for bidId', bidId, '.');
                  console.error('Continuing to claim step (any already-exited bids can still be claimed).');
                }
              }
            }
          }
        }
      }
    }
  }

  // --- Step 3: Claim (only after graduation; state-driven: discover all claimable bids for wallet)
  let claimedCount = 0;
  if (isGraduated && canClaim && wallet) {
    const claimBidIdEnv = process.env.CLAIM_BID_ID;
    const toClaim: string[] =
      claimBidIdEnv !== undefined && claimBidIdEnv !== '' ? [claimBidIdEnv.trim()] : await discoverClaimableBidIds(auction, wallet.address);
    if (toClaim.length > 0) {
      console.log('\n--- Step 3: Claim auction tokens ---');
      if (!claimBidIdEnv || claimBidIdEnv === '') console.log('(auto-discovered', toClaim.length, 'claimable bid(s))');
      for (const bidId of toClaim) {
        const txClaim = await auctioneer.claimAuctionTokens(liquidTokenAddress, bidId, { gasLimit: 300000 });
        await txClaim.wait();
        console.log('Claim bidId', bidId, 'tx:', txClaim.hash);
        claimedCount++;
      }
    } else {
      console.log('\n--- Step 3: Claim ---');
      console.log('No claimable bids found. (Exit Step 2 above first: exit sends unfilled RARE back; then claim sends you Liquid tokens for the filled part.)');
    }
  }

  // --- Step 4: Trigger graduation via strategy.migrate() (when auction ended, not graduated, and not skipped) ---
  if (doGraduation && strategyAddr && strategyAddr !== ethers.constants.AddressZero) {
    console.log('\n--- Step 4: Trigger graduation (strategy.migrate) ---');
    const strategy = new ethers.Contract(strategyAddr, STRATEGY_ABI, wallet!);
    const gradCalldata = strategy.interface.encodeFunctionData('migrate');
    try {
      await provider.call(
        { to: strategyAddr, from: wallet!.address, data: gradCalldata, gasLimit: GRADUATION_GAS_LIMIT },
        'latest'
      );
    } catch (preflightErr: any) {
      const reason = decodeRevertReason(preflightErr.data ?? preflightErr.error?.data);
      console.error('Pre-flight simulation failed (will not send tx):', reason);
      if (preflightErr.reason) console.error('  Reason:', preflightErr.reason);
      throw preflightErr;
    }
    const txGrad = await strategy.migrate({ gasLimit: GRADUATION_GAS_LIMIT });
    try {
      await txGrad.wait();
      console.log('Graduation tx:', txGrad.hash);
    } catch (waitErr: any) {
      const data = waitErr.data ?? waitErr.error?.data ?? (waitErr.receipt?.status === 0 ? waitErr.transaction?.data : undefined);
      console.error('Graduation tx reverted:', decodeRevertReason(data));
      throw waitErr;
    }
  }

  // --- Next steps (just run again; script infers what to do) ---
  const finalStateResult = await liquidToken.getAuctionState();
  const finalIsGraduated = Array.isArray(finalStateResult) ? finalStateResult[1] : finalStateResult.graduated;
  const finalBlock = await provider.getBlockNumber();
  const finalIsEnded = finalBlock >= endBlock.toNumber();

  console.log('\n--- Next steps ---');
  if (finalIsGraduated) {
    if (claimedCount > 0) {
      console.log('Claimed', claimedCount, 'bid(s). Nothing more to do for this auction.');
    } else {
      console.log('Auction is graduated. No claimable bids found. Nothing more to do.');
    }
  } else if (finalIsEnded) {
    console.log('Auction ended. Run again with --broadcast to exit your bids and graduate (no env vars needed).');
    if (placedBidIds.length) console.log('Your bidIds from this run:', placedBidIds.join(', '));
  } else {
    console.log('Wait until block >=', endBlock.toString(), 'then run again with --broadcast.');
    if (placedBidIds.length) console.log('Your bidIds from this run:', placedBidIds.join(', '));
  }

  console.log('\n' + '='.repeat(70));
  console.log('Done.');
  console.log('='.repeat(70));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
