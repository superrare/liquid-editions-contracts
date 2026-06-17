// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

library NetworkConfig {
    /// @notice Liquid system contract addresses (grouped to reduce struct size for stack depth)
    struct LiquidAddresses {
        address factory;
        address router;
        /// @notice LiquidAuctioneer for CCA bid/exit/claim/triggerGraduation; address(0) if not deployed
        address auctioneer;
        /// @notice LiquidSwapGuard hook for Liquid pools; restricts swaps to LiquidRouter
        address swapGuard;
        /// @notice LiquidInitGuard hook (init-only protection); default poolHooks when swapGuard is not used
        address initGuard;
        /// @notice LiquidGuard hook (hook-level RARE fee skimming, no caller restrictions)
        address liquidGuard;
        /// @notice Shared FeeDistributor module used by LiquidGuard
        address feeDistributor;
        /// @notice Shared LiquidRegistry module used by router and auctioneer
        address liquidRegistry;
        /// @notice LiquidMigrationExecutor for atomic liquidity migrations
        address migrationExecutor;
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
                    rareBurner: 0x64F366E6d515dA78930B8b37c858c67e357b7B5B,
                    weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                    rareEthPoolId: 0xc5e82ff54924a7232a3e91ca252d505f4e4417afa2b6a8507dfb691182cd0b16,
                    uniswapV4PoolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
                    uniswapV4PositionManager: 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e,
                    uniswapV4Quoter: 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203,
                    uniswapUniversalRouter: 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af,
                    ccaFactory: 0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5,
                    lbpStrategyFactory: 0x65aF3B62EE79763c704f04238080fBADD005B332,
                    protocolFeeRecipient: 0x860a80d33E85e97888F1f0C75c6e5BBD60b48DA9, // change this before actual mainnet deployment
                    liquid: LiquidAddresses({
                        factory: 0x25f993C222fE5e891128a782A5168f1C78629540,
                        router: 0xEBd58EdA8408d9EA409f2c2bE8898BD9738f3583,
                        auctioneer: 0x656b073247d2583994a88300B01Af82dD7d28EFA,
                        swapGuard: address(0), // not yet deployed
                        initGuard: address(0),
                        liquidGuard: 0x8Ff5660951C974f4806F0bEF9A32bcf35d3aE0cC,
                        feeDistributor: 0xCDccF9078540448009d432f87141a76B1C02B774,
                        liquidRegistry: 0x4066052d6AAC25EcFB027fD0C1aD54A597Ce3A31,
                        migrationExecutor: 0xfaDCCe3A08435B06d88AcF736dbE0bE802556306
                    })
                });
        } else if (chainId == 8453) {
            // Base
            return
                Config({
                    rareToken: 0x691077C8e8de54EA84eFd454630439F99bd8C92f,
                    usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
                    rareBurner: 0x8B333c7cE380A7efE110Ea444e81609DBA4b75e5,
                    weth: 0x4200000000000000000000000000000000000006,
                    rareEthPoolId: 0x0000000000000000000000000000000000000000000000000000000000000000,
                    uniswapV4PoolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
                    uniswapV4PositionManager: 0x7C5f5A4bBd8fD63184577525326123B519429bDc,
                    uniswapV4Quoter: 0x0d5e0F971ED27FBfF6c2837bf31316121532048D,
                    uniswapUniversalRouter: 0x6fF5693b99212Da76ad316178A184AB56D299b43,
                    ccaFactory: 0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5,
                    lbpStrategyFactory: 0x39E5eB34dD2c8082Ee1e556351ae660F33B04252,
                    protocolFeeRecipient: 0xD2437c0511906085CbDD06C27e8915d715dC3290,
                    liquid: LiquidAddresses({
                        factory: 0x54016106A92895a38E54cA286216416750e517b1,
                        router: 0x6d078A410ee2AD08cACD8d22b486365433e98b7b,
                        auctioneer: address(0),
                        swapGuard: address(0),
                        initGuard: address(0),
                        liquidGuard: 0xb0E1Ecc884698f88D4e24043469e4B9bCE0a60cc,
                        feeDistributor: 0x16e81cade4Bb1E9Ff8C3e8c4277FE7693Bd272BB,
                        liquidRegistry: 0x539e8261e18C56D801c7549fb29d06c779ef5004,
                        migrationExecutor: 0xCDb9eC7408cfEb126cF93ad70396eBc733f2bfaE
                    })
                });
        } else if (chainId == 84532) {
            // Base-Sepolia
            return
                Config({
                    rareToken: 0x8b21bC8571d11F7AdB705ad8F6f6BD1deb79cE01,
                    usdc: 0x036CbD53842c5426634e7929541eC2318f3dCF7e,
                    rareBurner: 0x9156b06d9849429d5C6D32c815b56004d582e5C8,
                    weth: 0x4200000000000000000000000000000000000006,
                    rareEthPoolId: 0x7e9be56512e7013e608b830dce2aa4e6a63edbb6488482aa4ccfff9a00b0da5b,
                    uniswapV4PoolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
                    uniswapV4PositionManager: 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80,
                    uniswapV4Quoter: 0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa,
                    uniswapUniversalRouter: 0x492E6456D9528771018DeB9E87ef7750EF184104,
                    ccaFactory: 0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5,
                    lbpStrategyFactory: 0xa3A236647c80BCD69CAD561ACf863c29981b6fbC,
                    protocolFeeRecipient: 0xBa68422A154e459f7b4992a95Ad358d412b6bd1d,
                    liquid: LiquidAddresses({
                        factory: 0x912ecC55445d87149d09d83426D0aC41379bB643,
                        router: 0x92438008608949E2C7eCef34c474792bAFe8a971,
                        auctioneer: address(0),
                        swapGuard: address(0),
                        initGuard: address(0),
                        liquidGuard: 0x1c56E7747D67b6731c9EE12b74b4062Efc7020Cc,
                        feeDistributor: 0x3c8cdeF90333F5adA046690f0c37bEc311f0996a,
                        liquidRegistry: 0x5AB6B3f7eBEFDA67cfc4D135718F9E34d58856b9,
                        migrationExecutor: 0xc87f440Acde20726Dc42F862C78A45981De76dF1
                    })
                });
        } else if (chainId == 11155111) {
            // Ethereum Sepolia
            return
                Config({
                    rareToken: 0x197FaeF3f59eC80113e773Bb6206a17d183F97CB,
                    usdc: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,
                    rareBurner: 0x9F9c2FBC75bbea5792250374527D701332DAB4a6,
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
                        factory: 0xb1777091C953fa2aC1fD67f2b3e2f61343F5Ce5e,
                        router: 0x429c3Ee66E7f6CDA12C5BadE4104aF3277aA2305,
                        auctioneer: 0xf0dC12B5A36498C30dE00708253258F7509f1130,
                        swapGuard: address(0),
                        initGuard: address(0),
                        liquidGuard: 0xB32eC4b5eC46fBd8E68a39308b8569538d0620CC,
                        feeDistributor: 0xC5875290E3942BdC2971ACB1af6630563E6cc557,
                        liquidRegistry: 0x979C2FB02B8cF352eBeD15872B76b8bE78B64Ebc,
                        migrationExecutor: 0x4bfE60db98493B146CdfCEFd20f0AAE697C7c80A
                    })
                });
        }
        revert("NetworkConfig: Unsupported chain ID");
    }
}
