// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";

/**
 * @title ReadNetworkConfig
 * @notice Read-only script that prints addresses from `NetworkConfig.sol` for the current target chain.
 *
 * Environment Variables:
 * - CHAIN_ID: Target chain ID (defaults to block.chainid)
 * - MACHINE_OUTPUT: If set to true, prints only key=value lines suitable for sourcing.
 *
 * Usage:
 *   forge script script/ReadNetworkConfig.s.sol:ReadNetworkConfig --rpc-url $RPC_URL
 *
 *   # Export-friendly output:
 *   MACHINE_OUTPUT=true forge script script/ReadNetworkConfig.s.sol:ReadNetworkConfig --rpc-url $RPC_URL > /tmp/nc.env
 */
contract ReadNetworkConfig is Script {
    function run() external view {
        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _chainId) {
            chainId = _chainId;
        } catch {
            chainId = block.chainid;
        }

        NetworkConfig.Config memory cfg = NetworkConfig.getConfig(chainId);
        bool machineOutput;
        try vm.envBool("MACHINE_OUTPUT") returns (bool _machineOutput) {
            machineOutput = _machineOutput;
        } catch {
            machineOutput = false;
        }

        if (machineOutput) {
            _printMachineOutput(chainId, cfg);
        } else {
            _printHumanReadable(chainId, cfg);
        }
    }

    function _printMachineOutput(uint256 chainId, NetworkConfig.Config memory cfg) internal pure {
        console.log(string.concat("CHAIN_ID=", vm.toString(chainId)));
        console.log(string.concat("RARE_TOKEN=", vm.toString(cfg.rareToken)));
        console.log(string.concat("USDC=", vm.toString(cfg.usdc)));
        console.log(string.concat("WETH=", vm.toString(cfg.weth)));
        console.log(string.concat("RARE_BURNER=", vm.toString(cfg.rareBurner)));
        console.log(string.concat("UNISWAP_V4_POOL_MANAGER=", vm.toString(cfg.uniswapV4PoolManager)));
        console.log(string.concat("UNISWAP_V4_POSITION_MANAGER=", vm.toString(cfg.uniswapV4PositionManager)));
        console.log(string.concat("UNISWAP_V4_QUOTER=", vm.toString(cfg.uniswapV4Quoter)));
        console.log(string.concat("UNISWAP_UNIVERSAL_ROUTER=", vm.toString(cfg.uniswapUniversalRouter)));
        console.log(string.concat("CCA_FACTORY=", vm.toString(cfg.ccaFactory)));
        console.log(string.concat("LBP_STRATEGY_FACTORY=", vm.toString(cfg.lbpStrategyFactory)));
        console.log(string.concat("PROTOCOL_FEE_RECIPIENT=", vm.toString(cfg.protocolFeeRecipient)));
        console.log(string.concat("RARE_ETH_POOL_ID=", vm.toString(cfg.rareEthPoolId)));
        console.log(string.concat("FACTORY=", vm.toString(cfg.liquid.factory)));
        console.log(string.concat("ROUTER=", vm.toString(cfg.liquid.router)));
        console.log(string.concat("AUCTIONEER=", vm.toString(cfg.liquid.auctioneer)));
        console.log(string.concat("SWAP_GUARD=", vm.toString(cfg.liquid.swapGuard)));
        console.log(string.concat("INIT_GUARD=", vm.toString(cfg.liquid.initGuard)));
        console.log(string.concat("GUARD=", vm.toString(cfg.liquid.liquidGuard)));
        console.log(string.concat("LIQUID_GUARD=", vm.toString(cfg.liquid.liquidGuard)));
        console.log(string.concat("FEE_DISTRIBUTOR=", vm.toString(cfg.liquid.feeDistributor)));
        console.log(string.concat("LIQUID_REGISTRY=", vm.toString(cfg.liquid.liquidRegistry)));
        console.log(string.concat("MIG_EXEC=", vm.toString(cfg.liquid.migrationExecutor)));
        console.log(string.concat("MIGRATION_EXECUTOR=", vm.toString(cfg.liquid.migrationExecutor)));
    }

    function _printHumanReadable(uint256 chainId, NetworkConfig.Config memory cfg) internal pure {
        console.log("=== NetworkConfig Snapshot ===");
        console.log("Chain ID:", chainId);
        console.log("");
        console.log("Core assets");
        console.log("  rareToken:", cfg.rareToken);
        console.log("  usdc:", cfg.usdc);
        console.log("  weth:", cfg.weth);
        console.log("  rareBurner:", cfg.rareBurner);
        console.log("");
        console.log("V4 Infrastructure");
        console.log("  uniswapV4PoolManager:", cfg.uniswapV4PoolManager);
        console.log("  uniswapV4PositionManager:", cfg.uniswapV4PositionManager);
        console.log("  uniswapV4Quoter:", cfg.uniswapV4Quoter);
        console.log("  uniswapUniversalRouter:", cfg.uniswapUniversalRouter);
        console.log("");
        console.log("Auction / launch infrastructure");
        console.log("  ccaFactory:", cfg.ccaFactory);
        console.log("  lbpStrategyFactory:", cfg.lbpStrategyFactory);
        console.log("  protocolFeeRecipient:", cfg.protocolFeeRecipient);
        console.log("  rareEthPoolId:");
        console.logBytes32(cfg.rareEthPoolId);
        console.log("");
        console.log("Deployed/liquid contracts");
        console.log("  factory:", cfg.liquid.factory);
        console.log("  router:", cfg.liquid.router);
        console.log("  auctioneer:", cfg.liquid.auctioneer);
        console.log("  swapGuard:", cfg.liquid.swapGuard);
        console.log("  initGuard:", cfg.liquid.initGuard);
        console.log("  liquidGuard:", cfg.liquid.liquidGuard);
        console.log("  feeDistributor:", cfg.liquid.feeDistributor);
        console.log("  liquidRegistry:", cfg.liquid.liquidRegistry);
        console.log("  migrationExecutor:", cfg.liquid.migrationExecutor);
    }
}
