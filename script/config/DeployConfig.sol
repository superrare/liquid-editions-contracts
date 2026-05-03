// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title DeployConfig
 * @notice Centralized deployment configuration for all contracts
 * @dev Provides per-chain deployment parameters with sensible defaults
 */
library DeployConfig {
    struct BurnerConfig {
        bool tryOnDeposit;
        uint24 poolFee;
        int24 tickSpacing;
        address hooks;
        address burnAddress;
        uint16 maxSlippageBPS;
        bool enabled;
    }

    struct FactoryConfig {
        /// @notice Pool hooks address. When useSwapGuard or useLiquidGuard is true, resolved from the guard at deploy time.
        address poolHooks;
        /// @notice When true, use LiquidSwapGuard for Liquid pools (restricts swaps to LiquidRouter).
        bool useSwapGuard;
        /// @notice When true, use LiquidGuard (hook-level fee skimming) instead of LiquidSwapGuard.
        bool useLiquidGuard;
        int24 poolTickSpacing;
        /// @notice Total token supply minted for each new token at launch (default 1_000_000e18).
        uint256 maxTotalSupplyWei;
        /// @notice Tokens transferred to creator at launch (default 100_000e18; 0 = no carve-out).
        uint256 creatorLaunchRewardWei;
    }

    /// @notice Default multicurve configuration (250 RARE anchor, ~$500K FDV ceiling)
    struct MultiCurveConfig {
        int24 tripWireTickLower; // -81_840
        int24 tripWireTickUpper; // -63_840
        uint16 tripWirePositions; // 2
        uint256 tripWireShares; // 0.10e18
        int24 distributionTickLower; // -63_840
        int24 distributionTickUpper; // -36_840
        uint16 distributionPositions; // 3
        uint256 distributionShares; // 0.40e18
        int24 steadyStateTickLower; // -36_840
        int24 steadyStateTickUpper; // 32_220
        uint16 steadyStatePositions; // 5
        uint256 steadyStateShares; // 0.50e18
    }

    /// @notice Fee distribution config shared by LiquidRouter and LiquidAuctioneer.
    /// totalFeeBPS is the full gross fee on ETH side (e.g., 400 = 4%).
    struct FeeConfig {
        uint16 totalFeeBPS;
    }

    enum AuctionRouteKind {
        NONE,
        V4_SINGLE,
        V3_PATH,
        V2_PATH
    }

    struct AuctionRouteConfig {
        AuctionRouteKind kind;
        uint24 v4Fee;
        int24 v4TickSpacing;
        address v4Hooks;
        bytes v3Path;
        address[] v2Path;
    }

    struct AuctioneerRoutesConfig {
        AuctionRouteConfig ethToRare;
        AuctionRouteConfig usdcToRare;
        AuctionRouteConfig rareToRare;
    }

    struct Config {
        BurnerConfig burner;
        FactoryConfig factory;
        FeeConfig fees;
        AuctioneerRoutesConfig auctioneerRoutes;
    }

    /**
     * @notice Get deployment configuration for a given chain ID
     * @return Config struct with all deployment parameters
     */
    function getConfig(uint256 chainId) internal pure returns (Config memory) {
        // Default configuration (applies to all chains unless overridden)
        Config memory config = Config({
            burner: BurnerConfig({
                tryOnDeposit: true,
                poolFee: 3000, // 0.3%
                tickSpacing: 60,
                hooks: address(0),
                burnAddress: 0x000000000000000000000000000000000000dEaD,
                maxSlippageBPS: 300, // 3%
                enabled: true
            }),
            factory: FactoryConfig({
                poolHooks: address(0), // ignored when useSwapGuard/useLiquidGuard is true (resolved from guard at deploy time)
                useSwapGuard: false, // legacy: use LiquidSwapGuard (restricts swaps to LiquidRouter)
                useLiquidGuard: true, // use LiquidGuard (hook-level fee skimming, no caller restrictions)
                poolTickSpacing: 60, // Price granularity (ticks must be multiples of this). Common values: 1, 10, 60, 200
                maxTotalSupplyWei: 1_000_000e18, // 1M tokens minted per edition
                creatorLaunchRewardWei: 0 // tokens sent to creator at launch
            }),
            fees: FeeConfig({
                totalFeeBPS: 125 // 1.25% gross fees
            }),
            auctioneerRoutes: AuctioneerRoutesConfig({
                ethToRare: AuctionRouteConfig({
                    kind: AuctionRouteKind.V4_SINGLE,
                    v4Fee: 3000,
                    v4TickSpacing: 60,
                    v4Hooks: address(0),
                    v3Path: bytes(""),
                    v2Path: new address[](0)
                }),
                usdcToRare: AuctionRouteConfig({
                    kind: AuctionRouteKind.NONE,
                    v4Fee: 0,
                    v4TickSpacing: 0,
                    v4Hooks: address(0),
                    v3Path: bytes(""),
                    v2Path: new address[](0)
                }),
                // Keep disabled by default; RARE input can be supported later via direct-path logic.
                rareToRare: AuctionRouteConfig({
                    kind: AuctionRouteKind.NONE,
                    v4Fee: 0,
                    v4TickSpacing: 0,
                    v4Hooks: address(0),
                    v3Path: bytes(""),
                    v2Path: new address[](0)
                })
            })
        });

        if (chainId == 1) {
            config.auctioneerRoutes.usdcToRare.kind = AuctionRouteKind.V3_PATH;
        } else if (chainId == 8453) {
            config.auctioneerRoutes.usdcToRare.kind = AuctionRouteKind.V3_PATH;
        } else if (chainId == 84532) {
            config.auctioneerRoutes.usdcToRare.kind = AuctionRouteKind.V3_PATH;
        } else if (chainId == 11155111) {
            config.auctioneerRoutes.usdcToRare.kind = AuctionRouteKind.V3_PATH;
        }

        return config;
    }

    /// @notice Get default multicurve configuration (250 RARE anchor, calibrated to current market ~0.154 RARE/LIQUID)
    /// Current market: 100K RARE → 650K LIQUID ≈ tick -18,720
    /// Trip wire: -27,000 to -18,720 (covers approach to current price)
    /// Distribution: -18,720 to -9,000 (current to ~7x)
    /// Steady: -9,000 to 60,000 (7x to ~400x, ~$500K FDV ceiling)
    function getDefaultMultiCurveConfig() internal pure returns (MultiCurveConfig memory) {
        return MultiCurveConfig({
            tripWireTickLower: -27000,
            tripWireTickUpper: 0,
            tripWirePositions: 2,
            tripWireShares: 0.1e18,
            distributionTickLower: 0,
            distributionTickUpper: 28440,
            distributionPositions: 3,
            distributionShares: 0.4e18,
            steadyStateTickLower: 28440,
            steadyStateTickUpper: 60000,
            steadyStatePositions: 5,
            steadyStateShares: 0.5e18
        });
    }
}
