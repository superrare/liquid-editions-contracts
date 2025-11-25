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
    }

    function getConfig(uint256 chainId) internal pure returns (Config memory) {
        if (chainId == 1) {
            // Mainnet
            return
                Config({
                    rareToken: 0xba5BDe662c17e2aDFF1075610382B9B691296350,
                    rareBurner: 0x0000000000000000000000000000000000000000,
                    weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                    rareEthPoolId: 0x0000000000000000000000000000000000000000000000000000000000000000,
                    uniswapV4PoolManager: 0x0000000000000000000000000000000000000000,
                    uniswapV4PositionManager: 0x0000000000000000000000000000000000000000,
                    uniswapV4Quoter: 0x0000000000000000000000000000000000000000
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
                    uniswapV4Quoter: 0x0d5e0F971ED27FBfF6c2837bf31316121532048D
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
                    uniswapV4Quoter: 0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa
                });
        }
        revert("NetworkConfig: Unsupported chain ID");
    }
}
