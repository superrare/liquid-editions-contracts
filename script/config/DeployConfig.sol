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
        address poolHooks;
        int24 poolTickSpacing;
        uint16 internalMaxSlippageBps;
        uint256 minRareLiquidityWei;
    }

    struct RouterConfig {
        uint16 rareBurnFeeBPS;
        uint16 protocolFeeBPS;
        uint16 referrerFeeBPS;
    }

    struct Config {
        BurnerConfig burner;
        FactoryConfig factory;
        RouterConfig router;
    }

    /**
     * @notice Get deployment configuration for a given chain ID
     * @param chainId Chain ID to get config for
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
                lpTickLower: -180, // max expensive (after price rises) - multiple of 60
                lpTickUpper: 120000, // starting point (cheap tokens, bonding curve bottom) - multiple of 60
                poolHooks: address(0), // no hooks
                poolTickSpacing: 60, // Price granularity (ticks must be multiples of this). Common values: 1, 10, 60, 200
                internalMaxSlippageBps: 500, // 5%
                minRareLiquidityWei: 1000000000000000000 // 1 $RARE
            }),
            router: RouterConfig({
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
}
