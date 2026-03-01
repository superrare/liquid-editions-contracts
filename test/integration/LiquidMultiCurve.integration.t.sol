// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidMultiCurve Integration Tests
 * @notice Pool creation, swap traversal, router compatibility, LiquidSwapGuard compatibility
 * @dev Forks Base mainnet. Uses real RARE from fork for correct token ordering (isToken0). Requires 250 RARE minimum.
 */

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {ILiquidBase} from "liquid-editions/interfaces/ILiquidBase.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidPoolSwapHelper} from "liquid-editions-test/helpers/LiquidPoolSwapHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {DeployRAREBurner} from "script/deployers/DeployRAREBurner.s.sol";
import {DeployLiquidFactory} from "script/deployers/DeployLiquidFactory.s.sol";
import {DeployLiquidRouter} from "script/deployers/DeployLiquidRouter.s.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";

contract LiquidMultiCurveIntegrationTest is Test, InitGuardTestHelper {
    using StateLibrary for IPoolManager;

    NetworkConfig.Config internal config;
    DeployConfig.Config internal deployConfig;

    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public buyer = makeAddr("buyer");

    RAREBurner public burner;
    LiquidFactory public factory;
    LiquidRouter public router;
    LiquidMultiCurve public multiCurveImpl;
    LiquidPoolSwapHelper public swapHelper;

    uint256 constant MIN_RARE = 250e18;

    function _defaultCurves() internal pure returns (Curve[] memory) {
        DeployConfig.MultiCurveConfig memory cfg =
            DeployConfig.getDefaultMultiCurveConfig();

        Curve[] memory curves = new Curve[](3);
        curves[0] = Curve({
            tickLower: cfg.tripWireTickLower,
            tickUpper: cfg.tripWireTickUpper,
            numPositions: cfg.tripWirePositions,
            shares: cfg.tripWireShares
        });
        curves[1] = Curve({
            tickLower: cfg.distributionTickLower,
            tickUpper: cfg.distributionTickUpper,
            numPositions: cfg.distributionPositions,
            shares: cfg.distributionShares
        });
        curves[2] = Curve({
            tickLower: cfg.steadyStateTickLower,
            tickUpper: cfg.steadyStateTickUpper,
            numPositions: cfg.steadyStatePositions,
            shares: cfg.steadyStateShares
        });
        return curves;
    }

    function setUp() public {
        string memory forkUrl = ForkUrlResolver.requireForkUrl(vm);
        vm.createSelectFork(forkUrl);

        config = NetworkConfig.getConfig(block.chainid);
        deployConfig = DeployConfig.getConfig(block.chainid);

        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(buyer, 100 ether);
        vm.deal(protocolFeeRecipient, 1 ether);

        deal(config.rareToken, tokenCreator, 1000 ether);
        deal(config.rareToken, buyer, 1000 ether);

        vm.startPrank(admin);

        address burnerAddr = DeployRAREBurner.deploy(
            admin,
            deployConfig.burner,
            config
        );
        burner = RAREBurner(payable(burnerAddr));

        if (deployConfig.factory.poolHooks == address(0)) {
            deployConfig.factory.poolHooks = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        }

        DeployLiquidFactory.DeployResult memory factoryResult = DeployLiquidFactory.deploy(
            admin,
            deployConfig.factory,
            config
        );
        factory = LiquidFactory(factoryResult.factory);

        LiquidInitGuard(deployConfig.factory.poolHooks).setFactory(address(factory));

        multiCurveImpl = new LiquidMultiCurve();
        factory.setLiquidMultiCurveImplementation(address(multiCurveImpl));

        LiquidRegistry registry = new LiquidRegistry(admin);
        (address routerAddr, ) = DeployLiquidRouter.deploy(
            admin,
            config.uniswapUniversalRouter,
            address(registry)
        );
        router = LiquidRouter(payable(routerAddr));
        registry.setWriter(address(factory), true);
        factory.setLiquidRegistry(address(registry));

        swapHelper = new LiquidPoolSwapHelper(IPoolManager(config.uniswapV4PoolManager));

        vm.stopPrank();
    }

    function test_PoolCreatedWithMultiplePositions() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(tokenCreator);
        IERC20(config.rareToken).approve(address(factory), MIN_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://integration-test",
            "MultiCurve Test",
            "MCT",
            MIN_RARE,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        PoolId poolId = token.poolId();

        assertTrue(PoolId.unwrap(poolId) != bytes32(0), "Pool should exist");

        IPoolManager pm = IPoolManager(token.poolManager());
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "Pool should be initialized");

        assertEq(token.lpLiquidity(), 0, "Multicurve has lpLiquidity=0");
        assertTrue(token.lpTickLower() < token.lpTickUpper(), "Tick bounds valid");
    }

    function test_SwapThroughMultiplePositions() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(tokenCreator);
        IERC20(config.rareToken).approve(address(factory), MIN_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://swap-test",
            "Swap Test",
            "SWP",
            MIN_RARE,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));

        uint256 buyAmount = 10e18;
        vm.startPrank(buyer);
        IERC20(config.rareToken).approve(address(swapHelper), buyAmount);
        swapHelper.buy(address(token), buyAmount, buyer);
        vm.stopPrank();

        uint256 balance = token.balanceOf(buyer);
        assertGt(balance, 0, "Buyer should receive tokens");
    }

    function test_QuoteBuyMatchesActualBuy() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(tokenCreator);
        IERC20(config.rareToken).approve(address(factory), MIN_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://quote-test",
            "Quote Test",
            "QTE",
            MIN_RARE,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        uint256 rareIn = 5e18;

        (uint256 quotedOut, ) = token.quoteBuy(rareIn);

        vm.startPrank(buyer);
        IERC20(config.rareToken).approve(address(swapHelper), rareIn);
        uint256 actualOut = swapHelper.buy(address(token), rareIn, buyer);
        vm.stopPrank();

        assertApproxEqAbs(quotedOut, actualOut, actualOut / 100 + 1, "Quote should match actual");
    }

    function test_QuoteSellMatchesActualSell() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(tokenCreator);
        IERC20(config.rareToken).approve(address(factory), MIN_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://sell-quote-test",
            "Sell Quote Test",
            "SQT",
            MIN_RARE,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));

        uint256 buyAmount = 10e18;
        vm.startPrank(buyer);
        IERC20(config.rareToken).approve(address(swapHelper), buyAmount);
        swapHelper.buy(address(token), buyAmount, buyer);
        uint256 tokenBalance = token.balanceOf(buyer);
        vm.stopPrank();

        (uint256 quotedRareOut, ) = token.quoteSell(tokenBalance / 2);

        uint256 sellAmount = tokenBalance / 2;
        vm.startPrank(buyer);
        token.approve(address(swapHelper), sellAmount);
        uint256 actualRareOut = swapHelper.sell(address(token), sellAmount, buyer);
        vm.stopPrank();

        assertApproxEqAbs(quotedRareOut, actualRareOut, actualRareOut / 100 + 1, "Sell quote should match");
    }

    function test_FactoryCreatesMultiCurveToken() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(tokenCreator);
        IERC20(config.rareToken).approve(address(factory), MIN_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://factory-test",
            "Factory Test",
            "FCT",
            MIN_RARE,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        (ILiquidBase.LaunchType launchType, , , ) = token.getLaunchState();
        assertTrue(launchType == ILiquidBase.LaunchType.MULTICURVE);
        assertEq(token.tokenCreator(), tokenCreator);
        assertEq(token.balanceOf(tokenCreator), 100_000e18);
    }
}
