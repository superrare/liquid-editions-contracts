// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {DeployLiquidFactory} from "script/deployers/DeployLiquidFactory.s.sol";

contract DeployLiquidFactoryUnitTest is Test {
    function _factoryConfig() internal pure returns (DeployConfig.FactoryConfig memory config) {
        config = DeployConfig.FactoryConfig({
            poolHooks: address(0),
            useSwapGuard: false,
            useLiquidGuard: false,
            poolTickSpacing: 60,
            maxTotalSupplyWei: 0,
            creatorLaunchRewardWei: 100_000e18
        });
    }

    function test_Deploy_DeploysAndRegistersFactoryImplementations() public {
        address rare = makeAddr("rare");
        address usdc = makeAddr("usdc");

        DeployLiquidFactory.DeployResult memory result = DeployLiquidFactory.deploy(
            address(this),
            _factoryConfig(),
            DeployLiquidFactory.NetworkAddresses({
                uniswapV4PoolManager: makeAddr("poolManager"), rareToken: rare, usdc: usdc
            })
        );

        LiquidFactory factory = LiquidFactory(result.factory);

        assertTrue(result.multiCurveImplementation != address(0), "multicurve implementation");
        assertTrue(result.sovereignERC20Implementation != address(0), "sovereign implementation");
        assertTrue(result.sovereignERC20MarketImplementation != address(0), "sovereign market implementation");
        assertTrue(
            result.sovereignERC20MarketRewardsImplementation != address(0), "sovereign market rewards implementation"
        );

        assertEq(factory.liquidMultiCurveImplementation(), result.multiCurveImplementation);
        assertEq(factory.baseToken(), rare);

        (address sovereignImpl, bool sovereignEnabled) = factory.tokenImplementations(factory.KIND_SOVEREIGN_ERC20());
        assertEq(sovereignImpl, result.sovereignERC20Implementation);
        assertTrue(sovereignEnabled);

        (address marketImpl, bool marketEnabled) = factory.tokenImplementations(factory.KIND_SOVEREIGN_ERC20_MARKET());
        assertEq(marketImpl, result.sovereignERC20MarketImplementation);
        assertTrue(marketEnabled);

        (address rewardsImpl, bool rewardsEnabled) =
            factory.tokenImplementations(factory.KIND_SOVEREIGN_ERC20_MARKET_REWARDS());
        assertEq(rewardsImpl, result.sovereignERC20MarketRewardsImplementation);
        assertTrue(rewardsEnabled);

        assertTrue(factory.sovereignRewardTokenAllowed(rare));
        assertTrue(factory.sovereignRewardTokenAllowed(usdc));
        assertTrue(factory.isSovereignRewardTokenAllowed(factory.SELF_REWARD_TOKEN()));
    }
}
