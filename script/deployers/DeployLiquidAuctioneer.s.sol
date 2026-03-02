// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {LiquidAuctioneer} from "liquid-editions/LiquidAuctioneer.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";
import {DeployConfig} from "../config/DeployConfig.sol";
import {NetworkConfig} from "../config/NetworkConfig.sol";

/**
 * @title DeployLiquidAuctioneer
 * @notice Library for deploying LiquidAuctioneer (CCA bid/exit/claim/triggerGraduation)
 * @dev Same fee config pattern as LiquidRouter
 */
library DeployLiquidAuctioneer {
    /**
     * @notice Deploy LiquidAuctioneer contract
     * @param owner Owner address
     * @param protocolFeeRecipient Address that receives protocol fee distributions.
     * @param universalRouter Uniswap Universal Router address
     * @param baseToken RARE token address (base token for auctions)
     * @param weth wrapped native token address for preset ETH route
     * @param silent If true, suppress deployment logs (for tests)
     * @return auctioneer Address of the deployed LiquidAuctioneer
     */
    function deploy(
        address owner,
        address protocolFeeRecipient,
        DeployConfig.FeeConfig memory, /* config - unused, fees managed by LiquidGuard */
        address universalRouter,
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
        require(baseToken != address(0), "Base token (RARE) cannot be zero");
        require(weth != address(0), "WETH cannot be zero");

        LiquidRegistry liquidRegistry = new LiquidRegistry(owner);

        LiquidAuctioneer auctioneerContract = new LiquidAuctioneer(
            owner,
            universalRouter,
            protocolFeeRecipient,
            address(liquidRegistry),
            baseToken,
            weth,
            400 // 4% ETH fee for native ETH bids
        );
        auctioneer = address(auctioneerContract);
        if (!silent) {
            console.log("LiquidAuctioneer deployed at:");
            console.logAddress(auctioneer);
        }
        return auctioneer;
    }

    /// @notice Deploy LiquidAuctioneer with pre-deployed registry
    /// @param owner Owner address
    /// @param protocolFeeRecipient Address to receive ETH fees from native ETH bids (use owner if address(0))
    /// @param liquidRegistry LiquidRegistry module address
    /// @param universalRouter Uniswap Universal Router address
    /// @param baseToken RARE token address
    /// @param weth wrapped native token address
    /// @param ethFeeBps Fee in basis points for native ETH bids (e.g. 400 = 4%). Use 0 for no fee.
    /// @param silent suppress logs
    /// @return auctioneer Address of deployed LiquidAuctioneer
    function deployWithModules(
        address owner,
        address protocolFeeRecipient,
        ILiquidRegistry liquidRegistry,
        address universalRouter,
        address baseToken,
        address weth,
        uint16 ethFeeBps,
        bool silent
    ) internal returns (address auctioneer) {
        if (!silent) {
            console.log("=== Deploying LiquidAuctioneer with modules ===");
        }
        require(owner != address(0), "Owner cannot be zero");
        require(
            universalRouter != address(0),
            "Universal Router not configured"
        );
        require(baseToken != address(0), "Base token (RARE) cannot be zero");
        require(weth != address(0), "WETH cannot be zero");
        require(
            address(liquidRegistry) != address(0),
            "LiquidRegistry address cannot be zero"
        );

        LiquidAuctioneer auctioneerContract = new LiquidAuctioneer(
            owner,
            universalRouter,
            protocolFeeRecipient != address(0) ? protocolFeeRecipient : owner,
            address(liquidRegistry),
            baseToken,
            weth,
            ethFeeBps
        );

        auctioneer = address(auctioneerContract);
        if (!silent) {
            console.log("LiquidAuctioneer deployed at:");
            console.logAddress(auctioneer);
        }
        return auctioneer;
    }
}
