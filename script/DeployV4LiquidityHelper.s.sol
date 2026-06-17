// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {V4LiquidityHelper, IPermit2} from "./V4LiquidityHelper.sol";

contract DeployV4LiquidityHelper is Script {
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint256 chainId = _readUintEnvOr("CHAIN_ID", block.chainid);

        NetworkConfig.Config memory cfg = NetworkConfig.getConfig(chainId);
        require(cfg.uniswapV4PoolManager != address(0), "pool manager not configured");

        vm.startBroadcast(pk);
        V4LiquidityHelper helper = new V4LiquidityHelper(
            IPoolManager(cfg.uniswapV4PoolManager),
            IPermit2(PERMIT2_ADDR),
            deployer
        );
        vm.stopBroadcast();

        console.log("=== V4 Liquidity Helper Deployed ===");
        console.log("Chain ID:");
        console.logUint(chainId);
        console.log("Owner:");
        console.logAddress(deployer);
        console.log("PoolManager:");
        console.logAddress(cfg.uniswapV4PoolManager);
        console.log("Permit2:");
        console.logAddress(PERMIT2_ADDR);
        console.log("Helper:");
        console.logAddress(address(helper));
    }

    function _readUintEnvOr(
        string memory envKey,
        uint256 defaultValue
    ) internal view returns (uint256) {
        try vm.envUint(envKey) returns (uint256 value) {
            return value;
        } catch {
            return defaultValue;
        }
    }
}
