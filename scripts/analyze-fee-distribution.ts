#!/usr/bin/env ts-node

/**
 * Script to analyze fee distribution from a transaction
 * Usage: ts-node scripts/analyze-fee-distribution.ts <txHash>
 */

import { ethers } from "ethers";
import * as dotenv from "dotenv";

dotenv.config();

const ETH_SEPOLIA_RPC = process.env.ETH_SEPOLIA || `https://eth-sepolia.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`;

// FeeDistributor ABI (minimal for events)
const FEE_DISTRIBUTOR_ABI = [
  "event FeeDistributedInRare(address indexed liquidToken, address indexed beneficiary, uint256 rareTotal, uint256 rareBeneficiary, uint256 rareProtocol, bytes32 reason)",
  "event FeeConvertedAndDistributed(address indexed liquidToken, address indexed beneficiary, uint256 rareIn, uint256 ethOut, uint256 ethBeneficiary, uint256 ethProtocol)",
  "function totalFeeBPS() view returns (uint16)",
  "function beneficiaryShareBPS() view returns (uint16)",
  "function PROTOCOL_FEE_RECIPIENT() view returns (address)",
  "function RARE_TOKEN() view returns (address)",
  "function conversionEnabled() view returns (bool)",
];

// Sepolia addresses
const FEE_DISTRIBUTOR_ADDRESS = "0x4e350B3c5BC3b97238644a1ac583cAdDfA7c1920";
const RARE_TOKEN_ADDRESS = "0x197FaeF3f59eC80113e773Bb6206a17d183F97CB";
const PROTOCOL_RECIPIENT = "0xBa68422A154e459f7b4992a95Ad358d412b6bd1d";

async function analyzeFeeDistribution(txHash: string) {
  const provider = new ethers.JsonRpcProvider(ETH_SEPOLIA_RPC);
  const feeDistributor = new ethers.Contract(FEE_DISTRIBUTOR_ADDRESS, FEE_DISTRIBUTOR_ABI, provider);

  console.log("=== Fee Distribution Analysis ===\n");
  console.log(`Transaction Hash: ${txHash}`);
  console.log(`Network: Sepolia (Chain ID: 11155111)\n`);

  // Get transaction receipt
  const receipt = await provider.getTransactionReceipt(txHash);
  if (!receipt) {
    throw new Error("Transaction not found");
  }

  console.log(`Block Number: ${receipt.blockNumber}`);
  console.log(`Status: ${receipt.status === 1 ? "Success" : "Failed"}\n`);

  // Get FeeDistributor configuration
  console.log("=== Fee Distributor Configuration ===");
  const totalFeeBPS = await feeDistributor.totalFeeBPS();
  const beneficiaryShareBPS = await feeDistributor.beneficiaryShareBPS();
  const protocolRecipient = await feeDistributor.PROTOCOL_FEE_RECIPIENT();
  const rareToken = await feeDistributor.RARE_TOKEN();
  const conversionEnabled = await feeDistributor.conversionEnabled();

  console.log(`Total Fee BPS: ${totalFeeBPS} (${totalFeeBPS / 100}%)`);
  console.log(`Beneficiary Share BPS: ${beneficiaryShareBPS} (${beneficiaryShareBPS / 100}%)`);
  console.log(`Protocol Recipient: ${protocolRecipient}`);
  console.log(`RARE Token: ${rareToken}`);
  console.log(`Conversion Enabled: ${conversionEnabled}`);
  console.log("");

  // Parse events
  const feeDistributedInRareInterface = new ethers.Interface(FEE_DISTRIBUTOR_ABI);
  
  let foundFeeEvent = false;

  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== FEE_DISTRIBUTOR_ADDRESS.toLowerCase()) {
      continue;
    }

    try {
      const parsed = feeDistributedInRareInterface.parseLog({
        topics: log.topics as string[],
        data: log.data,
      });

      if (parsed?.name === "FeeDistributedInRare") {
        foundFeeEvent = true;
        const liquidToken = parsed.args.liquidToken;
        const beneficiary = parsed.args.beneficiary;
        const rareTotal = parsed.args.rareTotal;
        const rareBeneficiary = parsed.args.rareBeneficiary;
        const rareProtocol = parsed.args.rareProtocol;
        const reason = ethers.toUtf8String(parsed.args.reason).replace(/\0/g, "");

        console.log("=== Fee Distribution Event ===");
        console.log(`Event: FeeDistributedInRare`);
        console.log(`Liquid Token: ${liquidToken}`);
        console.log(`Beneficiary: ${beneficiary}`);
        console.log(`Reason: ${reason}`);
        console.log("");
        console.log("=== Fee Amounts ===");
        console.log(`Total RARE Distributed: ${ethers.formatEther(rareTotal)} RARE`);
        console.log(`Beneficiary Share: ${ethers.formatEther(rareBeneficiary)} RARE`);
        console.log(`Protocol Share: ${ethers.formatEther(rareProtocol)} RARE`);
        console.log("");

        // Verify split
        const expectedBeneficiary = (rareTotal * BigInt(beneficiaryShareBPS)) / 10000n;
        const expectedProtocol = rareTotal - expectedBeneficiary;

        console.log("=== Split Verification ===");
        console.log(`Expected Beneficiary: ${ethers.formatEther(expectedBeneficiary)} RARE`);
        console.log(`Actual Beneficiary: ${ethers.formatEther(rareBeneficiary)} RARE`);
        console.log(`Match: ${rareBeneficiary === expectedBeneficiary ? "✓ YES" : "✗ NO"}`);
        console.log("");
        console.log(`Expected Protocol: ${ethers.formatEther(expectedProtocol)} RARE`);
        console.log(`Actual Protocol: ${ethers.formatEther(rareProtocol)} RARE`);
        console.log(`Match: ${rareProtocol === expectedProtocol ? "✓ YES" : "✗ NO"}`);
        console.log("");

        // Check if total matches
        const totalDistributed = rareBeneficiary + rareProtocol;
        console.log(`Total Distributed: ${ethers.formatEther(totalDistributed)} RARE`);
        console.log(`Total Fee Collected: ${ethers.formatEther(rareTotal)} RARE`);
        console.log(`All Fees Accounted: ${totalDistributed === rareTotal ? "✓ YES" : "✗ NO"}`);
        console.log("");

        // Analyze reason
        console.log("=== Conversion Analysis ===");
        if (reason === "CONVERSION_OFF") {
          console.log(`Conversion skipped: Conversion is disabled or V4 not configured`);
          console.log(`Fallback: RARE distributed directly (no conversion to ETH)`);
        } else if (reason === "CONVERT_FAIL") {
          console.log(`Conversion attempted but failed`);
          console.log(`Fallback: RARE distributed directly`);
        } else if (reason === "NO_KEY") {
          console.log(`Conversion skipped: Pool key not configured`);
          console.log(`Fallback: RARE distributed directly`);
        }
        console.log("");

        // Check token transfers
        const rareTokenInterface = new ethers.Interface([
          "event Transfer(address indexed from, address indexed to, uint256 value)",
        ]);

        console.log("=== Token Transfers ===");
        let beneficiaryTransfer = false;
        let protocolTransfer = false;

        for (const log2 of receipt.logs) {
          if (log2.address.toLowerCase() !== RARE_TOKEN_ADDRESS.toLowerCase()) {
            continue;
          }

          try {
            const transferParsed = rareTokenInterface.parseLog({
              topics: log2.topics as string[],
              data: log2.data,
            });

            if (transferParsed?.name === "Transfer") {
              const from = transferParsed.args.from;
              const to = transferParsed.args.to;
              const value = transferParsed.args.value;

              if (from.toLowerCase() === FEE_DISTRIBUTOR_ADDRESS.toLowerCase()) {
                if (to.toLowerCase() === beneficiary.toLowerCase()) {
                  console.log(`✓ Beneficiary Transfer: ${ethers.formatEther(value)} RARE`);
                  beneficiaryTransfer = true;
                  if (value !== rareBeneficiary) {
                    console.log(`  ⚠ Warning: Transfer amount (${ethers.formatEther(value)}) doesn't match event (${ethers.formatEther(rareBeneficiary)})`);
                  }
                } else if (to.toLowerCase() === protocolRecipient.toLowerCase()) {
                  console.log(`✓ Protocol Transfer: ${ethers.formatEther(value)} RARE`);
                  protocolTransfer = true;
                  if (value !== rareProtocol) {
                    console.log(`  ⚠ Warning: Transfer amount (${ethers.formatEther(value)}) doesn't match event (${ethers.formatEther(rareProtocol)})`);
                  }
                }
              }
            }
          } catch (e) {
            // Not a Transfer event, skip
          }
        }

        if (!beneficiaryTransfer && rareBeneficiary > 0n) {
          console.log(`✗ Missing beneficiary transfer (expected ${ethers.formatEther(rareBeneficiary)} RARE)`);
        }
        if (!protocolTransfer) {
          console.log(`✗ Missing protocol transfer (expected ${ethers.formatEther(rareProtocol)} RARE)`);
        }
        console.log("");

        // Overall assessment
        console.log("=== Overall Assessment ===");
        const allChecks = [
          totalDistributed === rareTotal,
          rareBeneficiary === expectedBeneficiary || rareBeneficiary === 0n,
          rareProtocol === expectedProtocol || rareProtocol === rareTotal,
          beneficiaryTransfer || rareBeneficiary === 0n,
          protocolTransfer,
        ];

        const passedChecks = allChecks.filter(Boolean).length;
        const totalChecks = allChecks.length;

        console.log(`Checks Passed: ${passedChecks}/${totalChecks}`);
        
        if (passedChecks === totalChecks) {
          console.log("✓ Fee distribution worked correctly!");
        } else {
          console.log("⚠ Some issues detected - see details above");
        }

        break;
      } else if (parsed?.name === "FeeConvertedAndDistributed") {
        foundFeeEvent = true;
        console.log("=== Fee Distribution Event ===");
        console.log(`Event: FeeConvertedAndDistributed`);
        console.log(`Liquid Token: ${parsed.args.liquidToken}`);
        console.log(`Beneficiary: ${parsed.args.beneficiary}`);
        console.log(`RARE Converted: ${ethers.formatEther(parsed.args.rareIn)} RARE`);
        console.log(`ETH Received: ${ethers.formatEther(parsed.args.ethOut)} ETH`);
        console.log(`ETH to Beneficiary: ${ethers.formatEther(parsed.args.ethBeneficiary)} ETH`);
        console.log(`ETH to Protocol: ${ethers.formatEther(parsed.args.ethProtocol)} ETH`);
        console.log("");
        console.log("✓ Conversion successful - fees distributed in ETH");
        break;
      }
    } catch (e) {
      // Not a fee event, continue
    }
  }

  if (!foundFeeEvent) {
    console.log("⚠ No fee distribution event found in transaction logs");
    console.log("This might indicate:");
    console.log("  - Transaction didn't trigger fee collection");
    console.log("  - Fee was zero");
    console.log("  - Event was emitted from a different contract");
  }
}

// Main execution
const txHash = process.argv[2] || "0x22aaa42e2a7a3d63a70a0df068c57995cf7c20ec70c055e246aa2d485b7b2db2";

analyzeFeeDistribution(txHash)
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error:", error);
    process.exit(1);
  });
