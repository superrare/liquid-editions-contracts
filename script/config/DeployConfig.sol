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
        int24 lpTickLower;
        int24 lpTickUpper;
        /// @notice Pool hooks address. When useSwapGuard is true, resolved from liquidSwapGuard (NetworkConfig or deployment).
        address poolHooks;
        /// @notice When true, use LiquidSwapGuard for Instant/MultiCurve/Graduated pools (restricts swaps to LiquidRouter).
        bool useSwapGuard;
        int24 poolTickSpacing;
        uint16 internalMaxSlippageBps;
        uint256 minRareLiquidityWei;
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
    /// The three BPS fields must sum to 10,000 (100% of the remainder after beneficiary cut).
    struct FeeConfig {
        uint16 rareBurnFeeBPS;
        uint16 protocolFeeBPS;
        uint16 referrerFeeBPS;
    }

    struct Config {
        BurnerConfig burner;
        FactoryConfig factory;
        FeeConfig fees;
    }

    /**
     * @notice Get deployment configuration for a given chain ID
     * @return Config struct with all deployment parameters
     */
    function getConfig(
        uint256 /* chainId */
    ) internal pure returns (Config memory) {
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
                lpTickLower: -180, // max expensive (after price rises) - multiple of 60
                lpTickUpper: 120000, // starting point (cheap tokens, bonding curve bottom) - multiple of 60
                poolHooks: address(0), // ignored when useSwapGuard is true (resolved from LiquidSwapGuard at deploy time)
                useSwapGuard: true, // use LiquidSwapGuard for Instant/MultiCurve/Graduated
                poolTickSpacing: 60, // Price granularity (ticks must be multiples of this). Common values: 1, 10, 60, 200
                internalMaxSlippageBps: 500, // 5%
                minRareLiquidityWei: 250000000000000000000 // 250 RARE (shared by Instant and MultiCurve)
            }),
            fees: FeeConfig({
                protocolFeeBPS: 10000, // 100% of remainder after creator fee
                rareBurnFeeBPS: 0, // 0% of remainder after creator fee
                referrerFeeBPS: 0 // 0% of remainder after creator fee
            })
        });

        // Chain-specific overrides can be added here
        // Example:
        // if (chainId == 1) {
        //     config.burner.poolFee = 3000;
        //     config.factory.lpTickLower = -180;
        // }

        return config;
    }

    /// @notice Get default multicurve configuration (250 RARE anchor, calibrated to current market ~0.154 RARE/LIQUID)
    /// Current market: 100K RARE → 650K LIQUID ≈ tick -18,720
    /// Trip wire: -27,000 to -18,720 (covers approach to current price)
    /// Distribution: -18,720 to -9,000 (current to ~7x)
    /// Steady: -9,000 to 60,000 (7x to ~400x, ~$500K FDV ceiling)
    function getDefaultMultiCurveConfig()
        internal
        pure
        returns (MultiCurveConfig memory)
    {
        return
            MultiCurveConfig({
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
                steadyStateShares: 0.50e18
            });
    }
}
