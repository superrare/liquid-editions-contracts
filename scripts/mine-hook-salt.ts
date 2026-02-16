#!/usr/bin/env ts-node
/**
 * Salt Mining Script for Uniswap V4 Hook Addresses
 *
 * This script mines a salt that produces a valid V4 hook address for the
 * FullRangeLBPStrategy. The hook address must have specific bits set in
 * its lowest 14 bits to indicate which hook functions are implemented.
 *
 * For FullRangeLBPStrategy (BEFORE_INITIALIZE only): mask = 0x2000
 *
 * IMPORTANT: The LiquidFactory binds the salt to msg.sender to prevent front-running:
 *   effectiveSalt = keccak256(abi.encode(deployer, userSalt))
 * You must pass --deployer <address> so the miner produces salts valid for that deployer.
 *
 * Modes:
 *
 * 1. Interactive mode (reads config from LiquidFactory):
 *    npx ts-node mine-hook-salt.ts \
 *      --factory <LiquidFactory address> \
 *      --deployer <address that will call createLiquidTokenWithAuction> \
 *      --total-supply <auction supply in wei> \
 *      --config-data <hex encoded config data> \
 *      [--hook-mask <default 0x2000>] \
 *      [--max-iterations <default 1000000>]
 *
 * 2. Full explicit mode:
 *    npx ts-node mine-hook-salt.ts \
 *      --factory <LiquidFactory address> \
 *      --deployer <address that will call createLiquidTokenWithAuction> \
 *      --strategy-factory <FullRangeLBPStrategyFactory address> \
 *      --total-supply <auction supply in wei> \
 *      --config-data <hex encoded config data> \
 *      [--hook-mask <default 0x2000>] \
 *      [--max-iterations <default 1000000>]
 *
 * 3. Forge FFI mode (positional args - pass strategyFactory/impl; factory is fork-only):
 *    npx ts-node mine-hook-salt.ts --ffi \
 *      <strategyFactory> <liquidFactory> <implementation> <totalSupply> <configDataHex> [--deployer <addr>] [hookMask]
 *
 * Output (stdout): The valid salt as a 0x-prefixed hex string
 *
 * Environment:
 *   FORK_URL or MAINNET_RPC_URL - RPC endpoint (reads from ../.env)
 */

import { ethers, utils, BigNumber } from "ethers";
import * as dotenv from "dotenv";
import * as path from "path";
import * as fs from "fs";

// Load .env from project root
dotenv.config({ path: path.resolve(__dirname, "../.env") });

// V4 Hook flag masks
const ALL_HOOK_MASK = BigNumber.from("0x3FFF"); // Lowest 14 bits
const BEFORE_INITIALIZE_FLAG = BigNumber.from("0x2000"); // Bit 13

interface MiningParams {
  strategyFactoryAddress: string;
  liquidFactoryAddress: string;
  graduatedImplementation?: string; // When provided (FFI), skip RPC fetch from factory
  deployer: string; // Address that will call createLiquidTokenWithAuction (msg.sender)
  totalSupply: BigNumber;
  configData: string;
  hookMask: BigNumber;
  maxIterations: number;
  quiet: boolean;
}

interface MiningResult {
  salt: string;
  tokenAddress: string;
  hookAddress: string;
  iterations: number;
}

function formatError(err: unknown): string {
  if (err instanceof Error) return err.message;
  if (typeof err === "string") return err;
  try {
    return JSON.stringify(err);
  } catch {
    return String(err);
  }
}

async function requireContract(
  provider: ethers.providers.Provider,
  address: string,
  label: string
): Promise<void> {
  const code = await provider.getCode(address);
  if (!code || code === "0x") {
    const network = await provider.getNetwork();
    throw new Error(
      `${label} has no contract code at ${address} on chainId ${network.chainId}. Check RPC URL / network.`
    );
  }
}


/**
 * Compute clone address locally using OpenZeppelin Clones pattern
 * This matches Clones.predictDeterministicAddress from @openzeppelin/contracts/proxy/Clones.sol
 * See: clone bytecode = 0x3d602d80600a3d3981f3363d3d373d3d3d363d73 + impl(20 bytes) + 0x5af43d82803e903d91602b57fd5bf3
 * Total: 55 bytes (0x37)
 */
function computeCloneAddress(
  implementation: string,
  salt: string,
  deployer: string
): string {
  // Normalize: must be 20 bytes (40 hex chars), checksum-free
  const impl = (implementation || "").toLowerCase().replace(/^0x/, "");
  if (impl.length !== 40) {
    throw new Error(`Invalid implementation format: expected 40 hex chars, got ${impl.length}`);
  }
  const creationCode =
    "0x3d602d80600a3d3981f3363d3d373d3d3d363d73" + impl + "5af43d82803e903d91602b57fd5bf3";
  const initCodeHash = utils.keccak256(creationCode);
  return utils.getCreate2Address(deployer, salt, initCodeHash);
}

/**
 * Compute the effective salt used by LiquidFactory.
 * The factory binds the user-supplied salt to msg.sender to prevent front-running:
 *   effectiveSalt = keccak256(abi.encode(deployer, userSalt))
 */
function computeEffectiveSalt(deployer: string, userSalt: string): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(["address", "bytes32"], [deployer, userSalt])
  );
}

/**
 * Mine a salt using batched RPC calls to the deployed contracts
 * Optimized for speed by batching multiple calls
 */
async function mineSaltWithRPC(
  provider: ethers.providers.Provider,
  params: MiningParams
): Promise<MiningResult | null> {
  const {
    strategyFactoryAddress,
    liquidFactoryAddress,
    totalSupply,
    configData,
    hookMask,
    maxIterations,
    quiet,
  } = params;

  // ABI fragments for the calls we need
  const liquidFactoryAbi = [
    "function predictGraduatedTokenAddress(bytes32 salt, address deployer) external view returns (address)",
    "function liquidGraduatedImplementation() external view returns (address)",
    "function lbpStrategyFactory() external view returns (address)",
  ];
  const strategyFactoryAbi = [
    "function getAddress(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt, address sender) external view returns (address)",
  ];

  const strategyFactory = new ethers.Contract(
    strategyFactoryAddress,
    strategyFactoryAbi,
    provider
  );
  await requireContract(provider, strategyFactoryAddress, "Strategy factory");
  const liquidFactory = new ethers.Contract(
    liquidFactoryAddress,
    liquidFactoryAbi,
    provider
  );

  // Use provided implementation (FFI) or fetch from factory (interactive)
  let implementation: string;
  if (params.graduatedImplementation) {
    implementation = params.graduatedImplementation;
  } else {
    implementation = await liquidFactory.liquidGraduatedImplementation();
  }
  if (!quiet) {
    console.error(`  Implementation: ${implementation}`);
  }

  const { deployer } = params;
  if (!quiet) {
    console.error(`  Deployer: ${deployer}`);
  }

  // Preflight one deterministic call so we fail fast on bad config/rpc instead of
  // silently iterating through the full search space.
  const preflightSalt = utils.hexZeroPad("0x00", 32);
  const preflightEffectiveSalt = computeEffectiveSalt(deployer, preflightSalt);
  const preflightToken = computeCloneAddress(
    implementation,
    preflightEffectiveSalt,
    liquidFactoryAddress
  );
  // In FFI mode, liquidFactoryAddress may be a fork-local deployment address that does
  // not exist on the RPC endpoint, so this on-chain check must be optional.
  if (!params.graduatedImplementation) {
    await requireContract(provider, liquidFactoryAddress, "LiquidFactory");
    const predictedToken = await liquidFactory.predictGraduatedTokenAddress(preflightSalt, deployer);
    if (preflightToken.toLowerCase() !== predictedToken.toLowerCase()) {
      throw new Error(
        `Clone address mismatch: local=${preflightToken} factory=${predictedToken}. Check implementation/deployer inputs.`
      );
    }
  }
  try {
    const preflightHook = await strategyFactory.getAddress(
      preflightToken,
      totalSupply,
      configData,
      preflightEffectiveSalt,
      liquidFactoryAddress
    );
    if (!quiet) {
      const preflightLowBits = BigNumber.from(preflightHook).and(ALL_HOOK_MASK);
      console.error(
        `  Preflight lowBits: ${preflightLowBits.toHexString()} (target ${hookMask.toHexString()})`
      );
    }
  } catch (err: unknown) {
    throw new Error(
      `Preflight getAddress failed. Check configData/totalSupply and sender (must be LiquidFactory). Cause: ${formatError(
        err
      )}`
    );
  }

  const startTime = Date.now();
  let lastLogTime = startTime;
  let consecutiveFailureBatches = 0;
  
  // Process in batches for better throughput
  const BATCH_SIZE = 50;

  // Debug: sample first few hook addresses to verify logic (set MINING_DEBUG=1)
  const debug = process.env.MINING_DEBUG === "1";
  if (debug) {
    const sampleSize = 5;
    for (let i = 0; i < sampleSize; i++) {
      const userSalt = utils.hexZeroPad(utils.hexlify(i), 32);
      const effectiveSalt = computeEffectiveSalt(deployer, userSalt);
      const tokenAddress = computeCloneAddress(implementation, effectiveSalt, liquidFactoryAddress);
      const hookAddress = await strategyFactory.getAddress(
        tokenAddress,
        totalSupply,
        configData,
        effectiveSalt,
        liquidFactoryAddress
      );
      const lowBits = BigNumber.from(hookAddress).and(ALL_HOOK_MASK);
      console.error(`  [debug] salt=${i} token=${tokenAddress} hook=${hookAddress} lowBits=${lowBits.toHexString()}`);
    }
  }

  for (let batchStart = 0; batchStart < maxIterations; batchStart += BATCH_SIZE) {
    const batchEnd = Math.min(batchStart + BATCH_SIZE, maxIterations);
    const batchInputs: { salt: string; tokenAddress: string }[] = [];
    const batchPromises: Promise<string>[] = [];

    for (let i = batchStart; i < batchEnd; i++) {
      const userSalt = utils.hexZeroPad(utils.hexlify(i), 32);
      const effectiveSalt = computeEffectiveSalt(deployer, userSalt);
      
      // Compute token address locally (fast) using effective (sender-bound) salt
      const tokenAddress = computeCloneAddress(
        implementation,
        effectiveSalt,
        liquidFactoryAddress
      );

      batchInputs.push({ salt: userSalt, tokenAddress });
      batchPromises.push(
        strategyFactory.getAddress(
          tokenAddress,
          totalSupply,
          configData,
          effectiveSalt,
          liquidFactoryAddress
        )
      );
    }

    // Wait for batch to complete
    const results = await Promise.allSettled(batchPromises);
    let batchFailures = 0;
    
    for (let j = 0; j < results.length; j++) {
      const result = results[j];
      const { salt, tokenAddress } = batchInputs[j];
      if (result.status === "fulfilled") {
        const hookAddress = result.value;
        const hookAddressBN = BigNumber.from(hookAddress);
        const lowBits = hookAddressBN.and(ALL_HOOK_MASK);
        if (!lowBits.eq(hookMask)) continue;

        const iterNum = batchStart + j + 1;
        if (!quiet) {
          console.error(`\nFound valid salt after ${iterNum} iterations!`);
          console.error(`  Salt: ${salt}`);
          console.error(`  Token: ${tokenAddress}`);
          console.error(`  Hook: ${hookAddress}`);
          console.error(
            `  Time: ${((Date.now() - startTime) / 1000).toFixed(2)}s`
          );
        }

        return {
          salt,
          tokenAddress,
          hookAddress,
          iterations: iterNum,
        };
      } else {
        batchFailures++;
        if (!quiet && batchFailures <= 2) {
          console.error(
            `  [warn] getAddress failed at salt ${batchStart + j}: ${formatError(
              result.reason
            )}`
          );
        }
      }
    }

    if (batchFailures === results.length) {
      consecutiveFailureBatches++;
      if (consecutiveFailureBatches >= 3) {
        throw new Error(
          "All getAddress calls are failing repeatedly. Check configData, totalSupply, sender (LiquidFactory), and RPC health."
        );
      }
    } else {
      consecutiveFailureBatches = 0;
    }

    // Progress logging
    if (!quiet && Date.now() - lastLogTime > 5000) {
      const elapsed = (Date.now() - startTime) / 1000;
      const rate = batchEnd / elapsed;
      console.error(
        `  Progress: ${batchEnd}/${maxIterations} (${rate.toFixed(0)}/s)...`
      );
      lastLogTime = Date.now();
    }
  }

  return null;
}


/**
 * Parse command line arguments
 */
function parseArgs(): {
  rpcUrl?: string;
  params: Partial<MiningParams> & { liquidFactoryAddress: string };
} {
  const args = process.argv.slice(2);

  // FFI mode (simplified for Forge) - positional args
  // Pass strategyFactory explicitly - it exists on mainnet. LiquidFactory is deployed in fork only.
  if (args[0] === "--ffi") {
    const ffiArgs = args.slice(1);

    if (ffiArgs.length < 5) {
      console.error(
        "FFI Usage: mine-hook-salt.ts --ffi <strategyFactory> <liquidFactory> <implementation> <totalSupply> <configDataHex|--config-file path> [--deployer <addr>] [hookMask]"
      );
      process.exit(1);
    }

    let configData = ffiArgs[4];
    let hookMaskArg: string | undefined;
    let deployerArg: string | undefined;
    let extraIdx = 5; // index of next arg after configData
    if (configData === "--config-file") {
      if (ffiArgs.length < 6) {
        console.error("FFI Usage error: --config-file requires a path argument");
        process.exit(1);
      }
      const configPath = path.resolve(process.cwd(), ffiArgs[5]);
      if (!fs.existsSync(configPath)) {
        console.error(`Config file not found: ${configPath}`);
        console.error("Run the test first to create it: forge test --match-test test_BidWithETH_LiquidAuctioneer --fork-url $MAINNET_RPC_URL");
        process.exit(1);
      }
      configData = fs.readFileSync(configPath, "utf8").trim();
      extraIdx = 6;
    }

    // Parse remaining optional args: --deployer <addr> and hookMask
    for (let i = extraIdx; i < ffiArgs.length; i++) {
      if (ffiArgs[i] === "--deployer" && i + 1 < ffiArgs.length) {
        deployerArg = ffiArgs[++i];
      } else if (!hookMaskArg) {
        hookMaskArg = ffiArgs[i];
      }
    }

    if (!utils.isHexString(configData)) {
      console.error("FFI Usage error: configData must be 0x-prefixed hex");
      process.exit(1);
    }

    // Default deployer to liquidFactory (backwards compat; but callers should pass --deployer)
    const deployer = deployerArg || ffiArgs[1];

    return {
      rpcUrl: process.env.FORK_URL || process.env.MAINNET_RPC_URL || process.env.ETH_MAINNET || process.env.ETH_SEPOLIA,
      params: {
        strategyFactoryAddress: ffiArgs[0],
        liquidFactoryAddress: ffiArgs[1],
        graduatedImplementation: ffiArgs[2],
        deployer,
        totalSupply: BigNumber.from(ffiArgs[3]),
        configData,
        hookMask: hookMaskArg ? BigNumber.from(hookMaskArg) : BEFORE_INITIALIZE_FLAG,
        maxIterations: 500000,
        quiet: true,
      },
    };
  }

  // Full argument parsing for interactive use
  let strategyFactoryAddress = "";
  let liquidFactoryAddress = "";
  let deployer = "";
  let totalSupply = BigNumber.from(0);
  let configData = "";
  let hookMask = BEFORE_INITIALIZE_FLAG;
  let maxIterations = 5000000;
  let quiet = false;
  // Prefer FORK_URL when explicitly set, then mainnet URL, then network-specific fallbacks.
  let rpcUrl = process.env.FORK_URL || process.env.MAINNET_RPC_URL || process.env.ETH_MAINNET || process.env.ETH_SEPOLIA;

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--strategy-factory":
        strategyFactoryAddress = args[++i];
        break;
      case "--factory":
        liquidFactoryAddress = args[++i];
        break;
      case "--deployer":
        deployer = args[++i];
        break;
      case "--total-supply":
        totalSupply = BigNumber.from(args[++i]);
        break;
      case "--config-data":
        configData = args[++i];
        break;
      case "--hook-mask":
        hookMask = BigNumber.from(args[++i]);
        break;
      case "--max-iterations":
        maxIterations = parseInt(args[++i]);
        break;
      case "--rpc-url":
        rpcUrl = args[++i];
        break;
      case "--quiet":
        quiet = true;
        break;
    }
  }

  if (!liquidFactoryAddress) {
    console.error("Error: --factory <LiquidFactory address> is required");
    console.error("\nUsage:");
    console.error("  npx ts-node mine-hook-salt.ts --factory <address> --deployer <address> --total-supply <wei> --config-data <hex>");
    console.error("\nFFI mode:");
    console.error("  npx ts-node mine-hook-salt.ts --ffi <strategyFactory> <liquidFactory> <implementation> <totalSupply> <configDataHex|--config-file path> [--deployer <addr>]");
    process.exit(1);
  }

  if (!deployer) {
    console.error("Error: --deployer <address> is required (the address that will call createLiquidTokenWithAuction)");
    process.exit(1);
  }

  return {
    rpcUrl,
    params: {
      strategyFactoryAddress: strategyFactoryAddress || undefined,
      liquidFactoryAddress,
      deployer,
      totalSupply,
      configData,
      hookMask,
      maxIterations,
      quiet,
    },
  };
}

async function main() {
  const { rpcUrl, params } = parseArgs();

  if (!rpcUrl) {
    console.error(
      "Error: No RPC URL provided. Set FORK_URL or MAINNET_RPC_URL env var, or use --rpc-url"
    );
    process.exit(1);
  }

  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const quiet = params.quiet ?? false;

  // Fetch strategy factory from LiquidFactory if not provided (interactive mode only)
  let strategyFactoryAddress: string = params.strategyFactoryAddress ?? "";
  if (!strategyFactoryAddress) {
    if (!quiet) {
      console.error("Fetching lbpStrategyFactory from LiquidFactory...");
    }
    const liquidFactoryAbi = [
      "function lbpStrategyFactory() external view returns (address)",
    ];
    const liquidFactory = new ethers.Contract(
      params.liquidFactoryAddress,
      liquidFactoryAbi,
      provider
    );
    strategyFactoryAddress = await liquidFactory.lbpStrategyFactory();
    if (!quiet) {
      console.error(`  Strategy Factory: ${strategyFactoryAddress}`);
    }
  }

  const fullParams: MiningParams = {
    strategyFactoryAddress: strategyFactoryAddress,
    graduatedImplementation: params.graduatedImplementation,
    liquidFactoryAddress: params.liquidFactoryAddress,
    deployer: params.deployer ?? params.liquidFactoryAddress,
    totalSupply: params.totalSupply ?? BigNumber.from(0),
    configData: params.configData ?? "",
    hookMask: params.hookMask ?? BEFORE_INITIALIZE_FLAG,
    maxIterations: params.maxIterations ?? 1000000,
    quiet,
  };

  if (!utils.isAddress(fullParams.liquidFactoryAddress)) {
    console.error(`Error: Invalid LiquidFactory address: ${fullParams.liquidFactoryAddress}`);
    process.exit(1);
  }
  if (!utils.isAddress(fullParams.strategyFactoryAddress)) {
    console.error(`Error: Invalid strategy factory address: ${fullParams.strategyFactoryAddress}`);
    process.exit(1);
  }
  if (!utils.isAddress(fullParams.deployer)) {
    console.error(`Error: Invalid deployer address: ${fullParams.deployer}`);
    process.exit(1);
  }
  if (fullParams.totalSupply.lte(0)) {
    console.error("Error: --total-supply must be greater than 0");
    process.exit(1);
  }
  if (!utils.isHexString(fullParams.configData)) {
    console.error("Error: --config-data must be 0x-prefixed hex");
    process.exit(1);
  }
  if (!Number.isInteger(fullParams.maxIterations) || fullParams.maxIterations <= 0) {
    console.error("Error: --max-iterations must be a positive integer");
    process.exit(1);
  }

  if (!quiet) {
    console.error("Mining salt for V4 hook address...");
    console.error(`  Liquid Factory: ${fullParams.liquidFactoryAddress}`);
    console.error(`  Strategy Factory: ${fullParams.strategyFactoryAddress}`);
    console.error(`  Deployer: ${fullParams.deployer}`);
    console.error(`  Hook Mask: ${fullParams.hookMask.toHexString()}`);
    console.error(`  Max Iterations: ${fullParams.maxIterations}`);
  }

  const result = await mineSaltWithRPC(provider, fullParams);

  if (result) {
    // Output just the salt for FFI consumption (to stdout)
    console.log(result.salt);
    
    // Also output useful info to stderr for interactive use
    if (!quiet) {
      console.error("\n=== Result ===");
      console.error(`Salt: ${result.salt}`);
      console.error(`Token Address: ${result.tokenAddress}`);
      console.error(`Hook Address: ${result.hookAddress}`);
      console.error(`Iterations: ${result.iterations}`);
    }
  } else {
    console.error("Failed to find valid salt within iteration limit");
    process.exit(1);
  }
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
