// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

library NetworkConfig {
    /// @notice Liquid system contract addresses (grouped to reduce struct size for stack depth)
    struct LiquidAddresses {
        address factory;
        address router;
        /// @notice LiquidAuctioneer for CCA bid/exit/claim/triggerGraduation; address(0) if not deployed
        address auctioneer;
        /// @notice LiquidSwapGuard hook for Instant/MultiCurve/Graduated pools; restricts swaps to LiquidRouter
        address swapGuard;
        /// @notice LiquidInitGuard hook (init-only protection); default poolHooks when swapGuard is not used
        address initGuard;
        /// @notice LiquidGuard hook (hook-level RARE fee skimming, no caller restrictions)
        address liquidGuard;
        /// @notice Shared FeeDistributor module used by LiquidGuard
        address feeDistributor;
        /// @notice Shared LiquidRegistry module used by router and auctioneer
        address liquidRegistry;
    }

    struct Config {
        address rareToken;
        /// @notice Canonical USDC token for this chain (address(0) if unavailable)
        address usdc;
        address rareBurner;
        address weth;
        bytes32 rareEthPoolId;
        address uniswapV4PoolManager;
        address uniswapV4PositionManager;
        address uniswapV4Quoter;
        address uniswapUniversalRouter;
        /// @notice CCA factory (Continuous Clearing Auction); address(0) if not deployed on chain
        address ccaFactory;
        /// @notice FullRangeLBPStrategyFactory address. Use Uniswap's official deployment per chain
        ///         (https://docs.uniswap.org/contracts/liquidity-launchpad/Deployments) or deploy own for Base Sepolia.
        ///         Required for CCA path.
        address lbpStrategyFactory;
        /// @notice Protocol fee recipient (LP position recipient at migration)
        address protocolFeeRecipient;
        /// @notice Liquid system contracts (factory, router, auctioneer, swapGuard)
        LiquidAddresses liquid;
    }

    function getConfig(uint256 chainId) internal pure returns (Config memory) {
        if (chainId == 1) {
            // Ethereum Mainnet
            return
                Config({
                    rareToken: 0xba5BDe662c17e2aDFF1075610382B9B691296350,
                    usdc: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
                    rareBurner: address(0), // not yet deployed
                    weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                    rareEthPoolId: 0xc5e82ff54924a7232a3e91ca252d505f4e4417afa2b6a8507dfb691182cd0b16,
                    uniswapV4PoolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
                    uniswapV4PositionManager: 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e,
                    uniswapV4Quoter: 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203,
                    uniswapUniversalRouter: 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af,
                    ccaFactory: 0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5,
                    lbpStrategyFactory: 0x65aF3B62EE79763c704f04238080fBADD005B332,
                    protocolFeeRecipient: 0xBa68422A154e459f7b4992a95Ad358d412b6bd1d, // change this before actual mainnet deployment
                    liquid: LiquidAddresses({
                        factory: address(0), // not yet deployed
                        router: address(0), // not yet deployed
                        auctioneer: address(0), // not yet deployed
                        swapGuard: address(0), // not yet deployed
                        initGuard: address(0), // not yet deployed
                        liquidGuard: address(0), // not yet deployed
                        feeDistributor: address(0), // not yet deployed
                        liquidRegistry: address(0) // not yet deployed
                    })
                });
        } else if (chainId == 8453) {
            // Base
            return
                Config({
                    rareToken: 0x691077C8e8de54EA84eFd454630439F99bd8C92f,
                    usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
                    rareBurner: address(0),
                    weth: 0x4200000000000000000000000000000000000006,
                    rareEthPoolId: 0x0000000000000000000000000000000000000000000000000000000000000000,
                    uniswapV4PoolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
                    uniswapV4PositionManager: 0x7C5f5A4bBd8fD63184577525326123B519429bDc,
                    uniswapV4Quoter: 0x0d5e0F971ED27FBfF6c2837bf31316121532048D,
                    uniswapUniversalRouter: 0x6fF5693b99212Da76ad316178A184AB56D299b43,
                    ccaFactory: address(0), // need to add this before actual mainnet deployment
                    lbpStrategyFactory: 0x39E5eB34dD2c8082Ee1e556351ae660F33B04252,
                    protocolFeeRecipient: address(0), // need to know what this is before actual mainnet deployment
                    liquid: LiquidAddresses({
                        factory: address(0),
                        router: address(0),
                        auctioneer: address(0),
                        swapGuard: address(0),
                        initGuard: address(0),
                        liquidGuard: address(0),
                        feeDistributor: address(0),
                        liquidRegistry: address(0)
                    })
                });
        } else if (chainId == 84532) {
            // Base-Sepolia
            return
                Config({
                    rareToken: 0x8b21bC8571d11F7AdB705ad8F6f6BD1deb79cE01,
                    usdc: 0x036CbD53842c5426634e7929541eC2318f3dCF7e,
                    rareBurner: 0x978faD411a01DDc9D5eFCBC476dcf32c758Fc604,
                    weth: 0x4200000000000000000000000000000000000006,
                    rareEthPoolId: 0xb05cc8f2a70e36fc8ccff769958d8b1d90980ed38d3a6f48ae89ce9a8d18f69d,
                    uniswapV4PoolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
                    uniswapV4PositionManager: 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80,
                    uniswapV4Quoter: 0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa,
                    uniswapUniversalRouter: 0x95273d871c8156636e114b63797d78D7E1720d81,
                    ccaFactory: address(0), // need to add this before actual mainnet deployment
                    lbpStrategyFactory: address(0), // need to add this before actual mainnet deployment
                    protocolFeeRecipient: 0xBa68422A154e459f7b4992a95Ad358d412b6bd1d,
                    liquid: LiquidAddresses({
                        factory: 0xc265a84Dc7EeC0fc15f5F91B61C6C094e7De7116,
                        router: 0x137A81F1C8cC11B69179F8Bf6ACb7e53D7DBC50F,
                        auctioneer: address(0),
                        swapGuard: address(0),
                        initGuard: address(0),
                        liquidGuard: address(0),
                        feeDistributor: address(0),
                        liquidRegistry: address(0)
                    })
                });
        } else if (chainId == 11155111) {
            // Ethereum Sepolia
            return
                Config({
                    rareToken: 0x197FaeF3f59eC80113e773Bb6206a17d183F97CB,
                    usdc: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,
                    rareBurner: 0xD985d8a1946576D43b5175ED73d9336741C17B69,
                    weth: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
                    rareEthPoolId: 0x781d2707a6eb9cd3bdbea356a0ba90f9c5ef274927f5e72b0060bba5abd94f03,
                    uniswapV4PoolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543,
                    uniswapV4PositionManager: 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4,
                    uniswapV4Quoter: 0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227,
                    uniswapUniversalRouter: 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b,
                    ccaFactory: 0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5,
                    lbpStrategyFactory: 0x89Dd5691e53Ea95d19ED2AbdEdCf4cBbE50da1ff,
                    protocolFeeRecipient: 0xBa68422A154e459f7b4992a95Ad358d412b6bd1d,
                    liquid: LiquidAddresses({
                        factory: 0x074598D92570915940aFC6662E9268FAa21533E4,
                        router: 0x5428da796D33dFb99d1E2EFB095028302edFA636,
                        auctioneer: 0x67a5b1Bc2c4834206dA31844C172572F05099D87,
                        swapGuard: 0x69E682bde73c1906CCcE0B0aA0587D63B4C4E080,
                        initGuard: address(0),
                        liquidGuard: 0x36F5Ab31b001c8F2AC5eE76Ccf5AfE887503a0Cc,
                        feeDistributor: 0x93e73F99f37b8a195D5E318cc7Bcb1B3a08bDe96,
                        liquidRegistry: 0xD395973ebb3AEB36d18d376312046d2A8d8D8926
                    })
                });
        }
        revert("NetworkConfig: Unsupported chain ID");
    }
}
