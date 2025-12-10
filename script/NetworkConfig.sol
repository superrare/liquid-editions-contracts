// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

library NetworkConfig {
    struct Config {
        address rareToken;
        address rareBurner;
        address weth;
        bytes32 rareEthPoolId;
        address uniswapV4PoolManager;
        address uniswapV4PositionManager;
        address uniswapV4Quoter;
        address uniswapUniversalRouter;
        address liquidFactory;
        address liquidRouter;
    }

    function getConfig(uint256 chainId) internal pure returns (Config memory) {
        if (chainId == 1) {
            // Ethereum Mainnet
            return
                Config({
                    rareToken: 0xba5BDe662c17e2aDFF1075610382B9B691296350,
                    rareBurner: 0x0000000000000000000000000000000000000000,
                    weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                    rareEthPoolId: 0xc5e82ff54924a7232a3e91ca252d505f4e4417afa2b6a8507dfb691182cd0b16,
                    uniswapV4PoolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
                    uniswapV4PositionManager: 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e,
                    uniswapV4Quoter: 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203,
                    uniswapUniversalRouter: 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af,
                    liquidFactory: 0x0000000000000000000000000000000000000000,
                    liquidRouter: 0x0000000000000000000000000000000000000000
                });
        } else if (chainId == 8453) {
            // Base
            return
                Config({
                    rareToken: 0x691077C8e8de54EA84eFd454630439F99bd8C92f,
                    rareBurner: 0x0000000000000000000000000000000000000000,
                    weth: 0x4200000000000000000000000000000000000006,
                    rareEthPoolId: 0x0000000000000000000000000000000000000000000000000000000000000000,
                    uniswapV4PoolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
                    uniswapV4PositionManager: 0x7C5f5A4bBd8fD63184577525326123B519429bDc,
                    uniswapV4Quoter: 0x0d5e0F971ED27FBfF6c2837bf31316121532048D,
                    uniswapUniversalRouter: 0x6fF5693b99212Da76ad316178A184AB56D299b43,
                    liquidFactory: 0x0000000000000000000000000000000000000000,
                    liquidRouter: 0x0000000000000000000000000000000000000000
                });
        } else if (chainId == 84532) {
            // Base-Sepolia
            return
                Config({
                    rareToken: 0x8b21bC8571d11F7AdB705ad8F6f6BD1deb79cE01,
                    rareBurner: 0x978faD411a01DDc9D5eFCBC476dcf32c758Fc604,
                    weth: 0x4200000000000000000000000000000000000006,
                    rareEthPoolId: 0xb05cc8f2a70e36fc8ccff769958d8b1d90980ed38d3a6f48ae89ce9a8d18f69d,
                    uniswapV4PoolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
                    uniswapV4PositionManager: 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80,
                    uniswapV4Quoter: 0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa,
                    uniswapUniversalRouter: 0x95273d871c8156636e114b63797d78D7E1720d81,
                    liquidFactory: 0x405273DB0f7615b25AA9fD4D9b1c9e86aFd6C95D,
                    liquidRouter: 0x0000000000000000000000000000000000000000
                });
        } else if (chainId == 11155111) {
            // Ethereum Sepolia
            return
                Config({
                    rareToken: 0x197FaeF3f59eC80113e773Bb6206a17d183F97CB,
                    rareBurner: 0xD985d8a1946576D43b5175ED73d9336741C17B69,
                    weth: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
                    rareEthPoolId: 0x781d2707a6eb9cd3bdbea356a0ba90f9c5ef274927f5e72b0060bba5abd94f03,
                    uniswapV4PoolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543,
                    uniswapV4PositionManager: 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4,
                    uniswapV4Quoter: 0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227,
                    uniswapUniversalRouter: 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b,
                    liquidFactory: 0x090b455579DE5e3DB03bE0dD32a39fC1bF8F0904,
                    liquidRouter: 0x34a00cd690d892675da7B2Ded1B309EdAB6b6BAe
                });
        }
        revert("NetworkConfig: Unsupported chain ID");
    }
}
