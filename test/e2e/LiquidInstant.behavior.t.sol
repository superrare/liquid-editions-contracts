// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidInstant Shared Behavior Tests
 * @notice Runs the parameterized LiquidTokenBehaviorBase suite against LiquidInstant.
 * @dev Uses Base mainnet fork.
 */

import {LiquidTokenBehaviorBase} from "liquid-editions-test/helpers/bases/LiquidTokenBehaviorBase.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiquidInstantBehaviorTest is LiquidTokenBehaviorBase {
    NetworkConfig.Config internal config;

    string constant TOKEN_NAME = "InstantBehavior";
    string constant TOKEN_SYMBOL = "IBHV";
    string constant TOKEN_URI = "ipfs://instant-behavior";
    uint256 constant LIQUIDITY = 1e15;

    function _deployFactory()
        internal
        override
        returns (LiquidFactory, MockRARE)
    {
        string memory forkUrl = vm.envOr(
            "FORK_URL",
            string("https://mainnet.base.org")
        );
        vm.createSelectFork(forkUrl);
        config = NetworkConfig.getConfig(block.chainid);

        MockRARE rare = new MockRARE();
        rare.mint(tokenCreator, 10_000 ether);

        vm.startPrank(admin);
        LiquidFactory f = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager,
            -180,
            120000,
            config.uniswapV4Quoter,
            address(0),
            60,
            300,
            LIQUIDITY
        );
        LiquidInstant impl = new LiquidInstant();
        f.setImplementation(address(impl));
        f.setBaseToken(address(rare));
        vm.stopPrank();

        return (f, rare);
    }

    function _deployToken() internal override returns (ILiquid) {
        vm.startPrank(tokenCreator);
        mockRARE.approve(address(factory), LIQUIDITY);
        address tokenAddr = factory.createLiquidToken(
            tokenCreator,
            TOKEN_URI,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            LIQUIDITY
        );
        vm.stopPrank();
        return ILiquid(tokenAddr);
    }

    function _poolLive() internal pure override returns (bool) {
        return true;
    }

    function _tokenName() internal pure override returns (string memory) {
        return TOKEN_NAME;
    }

    function _tokenSymbol() internal pure override returns (string memory) {
        return TOKEN_SYMBOL;
    }

    function _tokenUri() internal pure override returns (string memory) {
        return TOKEN_URI;
    }
}
