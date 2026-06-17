// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";

/// @notice Script to replay a transaction and analyze fee distribution
contract ReplayTxFeeAnalysis is Script {
    function run() external {
        uint256 chainId = block.chainid;
        NetworkConfig.Config memory config = NetworkConfig.getConfig(chainId);
        
        // Sepolia chain ID
        require(chainId == 11155111, "Must run on Sepolia");
        
        // Transaction hash to analyze
        bytes32 txHash = 0x22aaa42e2a7a3d63a70a0df068c57995cf7c20ec70c055e246aa2d485b7b2db2;
        
        console.log("=== Fee Distribution Analysis ===");
        console.log("Transaction Hash:", vm.toString(txHash));
        console.log("Chain ID:", chainId);
        console.log("");
        
        // Fork at the transaction block for on-chain reads
        uint256 txBlock = 10349268;
        vm.createSelectFork(vm.rpcUrl("sepolia"), txBlock);
        
        // Decode receipt to get logs
        // We'll manually parse the logs to find FeeDistributor events
        
        // FeeDistributor address on Sepolia
        address feeDistributor = config.liquid.feeDistributor;
        console.log("FeeDistributor Address:", feeDistributor);
        
        IFeeDistributor distributor = IFeeDistributor(feeDistributor);
        
        // Get configuration
        uint16 totalFeeBPS = distributor.totalFeeBPS();
        uint16 beneficiaryShareBPS = distributor.beneficiaryShareBPS();
        address protocolRecipient = distributor.PROTOCOL_FEE_RECIPIENT();
        address rareToken = distributor.RARE_TOKEN();
        address beneficiaryRegistry = distributor.beneficiaryRegistry();
        
        console.log("");
        console.log("=== Fee Distributor Configuration ===");
        console.log("Total Fee BPS:", totalFeeBPS);
        console.log("Beneficiary Share BPS:", beneficiaryShareBPS);
        console.log("Protocol Recipient:", protocolRecipient);
        console.log("RARE Token:", rareToken);
        console.log("Beneficiary Registry:", beneficiaryRegistry);
        console.log("Conversion Enabled:", distributor.conversionEnabled());
        console.log("Max Slippage BPS:", distributor.maxSlippageBps());
        console.log("");
        
        console.log("=== Transaction Analysis ===");
        console.log("Looking for fee distribution events...");
        console.log("");
        
        IERC20 rare = IERC20(rareToken);
        uint256 protocolBalanceBefore = rare.balanceOf(protocolRecipient);
        console.log("Protocol RARE Balance at tx block:", protocolBalanceBefore);
        
        console.log("");
        console.log("=== Analysis Complete ===");
        console.log("Use cast logs to decode events (see docs/FEE_DISTRIBUTION_ANALYSIS.md)");
    }
}
