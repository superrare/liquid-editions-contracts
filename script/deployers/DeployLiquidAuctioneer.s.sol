// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidAuctioneer} from "liquid-editions/LiquidAuctioneer.sol";
import {DeployConfig} from "../config/DeployConfig.sol";
import {NetworkConfig} from "../config/NetworkConfig.sol";

/**
 * @title DeployLiquidAuctioneer
 * @notice Library for deploying LiquidAuctioneer (CCA bid/exit/claim/triggerGraduation)
 * @dev Same fee config pattern as LiquidRouter; uses LiquidFeeLib
 */
library DeployLiquidAuctioneer {
    /**
     * @notice Deploy LiquidAuctioneer contract
     * @param owner Owner address
     * @param protocolFeeRecipient Address to receive protocol fees
     * @param config Fee distribution config (shared with router)
     * @param universalRouter Uniswap Universal Router address
     * @param rareBurner Address of the RAREBurner contract
     * @param baseToken RARE token address (base token for auctions)
     * @param weth wrapped native token address for preset ETH route
     * @param silent If true, suppress deployment logs (for tests)
     * @return auctioneer Address of the deployed LiquidAuctioneer
     */
    function deploy(
        address owner,
        address protocolFeeRecipient,
        DeployConfig.FeeConfig memory config,
        address universalRouter,
        address rareBurner,
        address baseToken,
        address weth,
        bool silent
    ) internal returns (address auctioneer) {
        if (!silent) {
            console.log("=== Deploying LiquidAuctioneer ===");
        }
        require(owner != address(0), "Owner cannot be zero");
        require(
            universalRouter != address(0),
            "Universal Router not configured"
        );
        require(
            protocolFeeRecipient != address(0),
            "Protocol fee recipient cannot be zero"
        );
        require(rareBurner != address(0), "RAREBurner cannot be zero");
        require(baseToken != address(0), "Base token (RARE) cannot be zero");
        require(weth != address(0), "WETH cannot be zero");

        LiquidAuctioneer auctioneerContract = new LiquidAuctioneer(
            owner,
            universalRouter,
            protocolFeeRecipient,
            rareBurner,
            baseToken,
            weth,
            config.rareBurnFeeBPS,
            config.protocolFeeBPS,
            config.referrerFeeBPS
        );
        auctioneer = address(auctioneerContract);
        if (!silent) {
            console.log("LiquidAuctioneer deployed at:");
            console.logAddress(auctioneer);
        }
        return auctioneer;
    }
}
