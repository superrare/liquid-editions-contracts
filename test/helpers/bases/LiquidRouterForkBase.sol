// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {DeployRAREBurner} from "script/deployers/DeployRAREBurner.s.sol";
import {DeployLiquidFactory} from "script/deployers/DeployLiquidFactory.s.sol";
import {DeployLiquidRouter} from "script/deployers/DeployLiquidRouter.s.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";

/// @title LiquidRouter Fork Base
/// @notice Shared fork setup: URL resolution, deploy burner/factory/router. Extend for AnvilFork, LiquidSwapGuard, etc.
abstract contract LiquidRouterForkBase is Test, InitGuardTestHelper {
    NetworkConfig.Config internal config;
    DeployConfig.Config internal deployConfig;

    address public admin;
    address public tokenCreator;
    address public protocolFeeRecipient;
    address public buyer;

    RAREBurner public burner;
    LiquidFactory public factory;
    LiquidRouter public router;

    /// @notice Override to pin fork block (e.g. for auction salt reuse). Return 0 for latest.
    /// @dev Defaults to FORK_BLOCK env var if set; helps RPC caching and avoids rate-limit flakes.
    function _getForkBlock() internal virtual returns (uint256) {
        return vm.envOr("FORK_BLOCK", uint256(0));
    }

    /// @notice Override to add factory config such as pool hooks. Called after base factory setup.
    function _configureFactory() internal virtual {}

    /// @notice Resolve fork URL. Uses FORK_URL only.
    function _getForkUrl() internal view returns (string memory forkUrl) {
        return ForkUrlResolver.requireForkUrl(vm);
    }

    /// @notice Base setUp. Override and call super.setUp() first to get burner/factory/router.
    function setUp() public virtual {
        _deployBurnerFactoryRouter();
    }

    /// @notice Deploy fork, config, accounts, burner, factory, router.
    function _deployBurnerFactoryRouter() internal {
        string memory forkUrl = _getForkUrl();
        uint256 forkBlock = _getForkBlock();
        if (forkBlock != 0) {
            vm.createSelectFork(forkUrl, forkBlock);
        } else {
            vm.createSelectFork(forkUrl);
        }

        config = NetworkConfig.getConfig(block.chainid);
        deployConfig = DeployConfig.getConfig(block.chainid);

        admin = makeAddr("admin");
        tokenCreator = makeAddr("tokenCreator");
        protocolFeeRecipient =
            config.protocolFeeRecipient != address(0) ? config.protocolFeeRecipient : makeAddr("protocolFeeRecipient");
        buyer = makeAddr("buyer");

        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(buyer, 100 ether);
        if (protocolFeeRecipient != address(0)) {
            vm.deal(protocolFeeRecipient, 1 ether);
        }

        deal(config.rareToken, tokenCreator, 1000 ether);

        vm.startPrank(admin);

        address burnerAddr = DeployRAREBurner.deploy(admin, deployConfig.burner, config);
        burner = RAREBurner(payable(burnerAddr));

        // Deploy LiquidInitGuard as default pool hooks (prevents pre-initialization DoS)
        if (deployConfig.factory.poolHooks == address(0)) {
            address initGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
            deployConfig.factory.poolHooks = initGuardAddr;
        }

        // DeployLiquidFactory.deploy sets the multicurve implementation and base token.
        DeployLiquidFactory.DeployResult memory factoryResult =
            DeployLiquidFactory.deploy(admin, deployConfig.factory, config);
        factory = LiquidFactory(factoryResult.factory);

        // Wire init guard to factory
        if (deployConfig.factory.poolHooks != address(0)) {
            try LiquidGuard(deployConfig.factory.poolHooks).factory() returns (address f) {
                if (f == address(0)) {
                    LiquidGuard(deployConfig.factory.poolHooks).setFactory(address(factory));
                }
            } catch {}
        }

        _configureFactory();

        LiquidRegistry liquidRegistry = new LiquidRegistry(admin);
        (address routerAddr,) = DeployLiquidRouter.deploy(admin, config.uniswapUniversalRouter, address(liquidRegistry));
        router = LiquidRouter(payable(routerAddr));
        liquidRegistry.setWriter(address(factory), true);
        factory.setLiquidRegistry(address(liquidRegistry));

        vm.stopPrank();
    }
}
