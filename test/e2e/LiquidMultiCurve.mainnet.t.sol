// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidMultiCurve Mainnet E2E Tests
 * @notice Full fork trading: create, buy, sell, verify balances
 * @dev Forks Base mainnet. Uses MockRARE. Requires 250 RARE minimum.
 */

import "forge-std/console.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {ForkTestBase} from "liquid-editions-test/helpers/bases/ForkTestBase.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {LiquidPoolSwapHelper} from "liquid-editions-test/helpers/LiquidPoolSwapHelper.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiquidMultiCurveMainnetTest is ForkTestBase, InitGuardTestHelper {
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    LiquidFactory public factory;
    LiquidMultiCurve public instantImpl;
    LiquidMultiCurve public multiCurveImpl;
    LiquidPoolSwapHelper public swapHelper;
    MockRARE public mockRARE;

    uint256 constant MIN_RARE = 250e18;
    /// @notice Extra RARE for pool bootstrap - real PoolManager deltas can exceed Multicurve estimates
    uint256 constant POOL_RARE = 2000e18;

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
        _setupFork();

        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        mockRARE = new MockRARE();
        mockRARE.mint(tokenCreator, 10_000 ether);
        mockRARE.mint(user1, 10_000 ether);
        mockRARE.mint(user2, 10_000 ether);

        vm.startPrank(admin);
        address initGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        factory = new LiquidFactory(
            admin,
            config.uniswapV4PoolManager,
            -180,
            120000,
            initGuardAddr,
            60,
            MIN_RARE
        );
        LiquidGuard(initGuardAddr).setFactory(address(factory));
                factory.setLiquidRegistry(address(1));
        instantImpl = new LiquidMultiCurve();
        multiCurveImpl = new LiquidMultiCurve();
        factory.setLiquidMultiCurveImplementation(address(instantImpl));
        factory.setLiquidMultiCurveImplementation(address(multiCurveImpl));
        factory.setBaseToken(address(mockRARE));
        swapHelper = new LiquidPoolSwapHelper(IPoolManager(config.uniswapV4PoolManager));
        vm.stopPrank();

        // Create a dummy LiquidMultiCurve token first so multicurve tokens get same address layout as sniper test
        vm.startPrank(tokenCreator);
        mockRARE.approve(address(factory), MIN_RARE);
        factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://dummy",
            "Dummy",
            "DMY",
            MIN_RARE,
            _defaultCurves()
        );
        vm.stopPrank();
    }

    function test_CreateAndTrade() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(tokenCreator);
        mockRARE.approve(address(factory), POOL_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://e2e-test",
            "E2E MultiCurve",
            "E2E",
            POOL_RARE,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));

        uint256 buyAmount = 50e18;
        vm.startPrank(user1);
        mockRARE.approve(address(swapHelper), buyAmount);
        uint256 tokensOut = swapHelper.buy(address(token), buyAmount, user1);
        vm.stopPrank();

        assertGt(tokensOut, 0);
        assertEq(token.balanceOf(user1), tokensOut);

        uint256 sellAmount = tokensOut / 2;
        vm.startPrank(user1);
        token.approve(address(swapHelper), sellAmount);
        uint256 rareOut = swapHelper.sell(address(token), sellAmount, user1);
        vm.stopPrank();

        assertGt(rareOut, 0);
        assertEq(token.balanceOf(user1), tokensOut - sellAmount);
    }

    function test_MultipleSwaps() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(tokenCreator);
        mockRARE.approve(address(factory), POOL_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://multi-swap",
            "Multi Swap",
            "MSW",
            POOL_RARE,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));

        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(user1);
            mockRARE.approve(address(swapHelper), 10e18);
            swapHelper.buy(address(token), 10e18, user1);
            vm.stopPrank();
        }

        assertGt(token.balanceOf(user1), 0);
    }

    function test_SellAfterBuy() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(tokenCreator);
        mockRARE.approve(address(factory), POOL_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://roundtrip",
            "Roundtrip",
            "RND",
            POOL_RARE,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));

        uint256 rareBefore = mockRARE.balanceOf(user1);
        uint256 buyAmount = 25e18;

        vm.startPrank(user1);
        mockRARE.approve(address(swapHelper), buyAmount);
        uint256 tokensBought = swapHelper.buy(address(token), buyAmount, user1);
        token.approve(address(swapHelper), tokensBought);
        uint256 rareFromSell = swapHelper.sell(address(token), tokensBought, user1);
        vm.stopPrank();

        uint256 rareAfter = mockRARE.balanceOf(user1);
        assertTrue(rareAfter < rareBefore, "Round-trip incurs slippage/fees");
        assertGt(rareFromSell, 0);
    }

    /// @notice Full flow: deploy, multiple buys (drive up price), multiple sells, with progress logging
    function test_FullFlowWithLogging() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(tokenCreator);
        mockRARE.approve(address(factory), POOL_RARE);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://full-flow",
            "Full Flow MultiCurve",
            "FFMC",
            POOL_RARE,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));

        uint256[] memory buyAmounts = new uint256[](8);
        buyAmounts[0] = 10e18;
        buyAmounts[1] = 25e18;
        buyAmounts[2] = 50e18;
        buyAmounts[3] = 100e18;
        buyAmounts[4] = 75e18;
        buyAmounts[5] = 30e18;
        buyAmounts[6] = 150e18;
        buyAmounts[7] = 40e18;

        uint256 totalRareSpent = 0;
        uint256 totalTokensBought = 0;

        console.log("=== MultiCurve full flow: buys (drive price up) ===");
        (uint256 priceRarePerToken, ) = token.getCurrentPrice();
        console.log("  Initial price (RARE per token):", _fmtPrice(priceRarePerToken));

        for (uint256 i = 0; i < buyAmounts.length; i++) {
            uint256 rareIn = buyAmounts[i];
            (uint256 priceBefore, ) = token.getCurrentPrice();

            vm.startPrank(user1);
            mockRARE.approve(address(swapHelper), rareIn);
            uint256 tokensOut = swapHelper.buy(address(token), rareIn, user1);
            vm.stopPrank();

            (uint256 priceAfter, ) = token.getCurrentPrice();
            totalRareSpent += rareIn;
            totalTokensBought += tokensOut;

            uint256 effectivePrice = tokensOut > 0 ? (rareIn * 1e18) / tokensOut : 0;
            console.log(
                "  Buy",
                i,
                string.concat(
                    "RARE:",
                    _fmt(rareIn),
                    " tokens:",
                    _fmt(tokensOut),
                    " effPrice:",
                    _fmtPrice(effectivePrice),
                    " priceBefore:",
                    _fmtPrice(priceBefore),
                    " priceAfter:",
                    _fmtPrice(priceAfter)
                )
            );
        }

        console.log("  Total RARE spent:", _fmt(totalRareSpent));
        console.log("  Total tokens bought:", _fmt(totalTokensBought));
        (uint256 priceAfterBuys, ) = token.getCurrentPrice();
        console.log("  Price after all buys (RARE per token):", _fmtPrice(priceAfterBuys));

        console.log("=== Sells ===");
        uint256 sellAmount1 = totalTokensBought / 4;
        uint256 sellAmount2 = totalTokensBought / 4;

        vm.startPrank(user1);
        token.approve(address(swapHelper), sellAmount1);
        uint256 rareOut1 = swapHelper.sell(address(token), sellAmount1, user1);
        vm.stopPrank();
        console.log("  Sell 1 tokens:", _fmt(sellAmount1), "RARE out:", _fmt(rareOut1));

        vm.startPrank(user1);
        token.approve(address(swapHelper), sellAmount2);
        uint256 rareOut2 = swapHelper.sell(address(token), sellAmount2, user1);
        vm.stopPrank();
        console.log("  Sell 2 tokens:", _fmt(sellAmount2), "RARE out:", _fmt(rareOut2));

        (uint256 priceAfterSells, ) = token.getCurrentPrice();
        console.log("  Price after sells (RARE per token):", _fmtPrice(priceAfterSells));

        uint256 rareOutTotal = rareOut1 + rareOut2;
        console.log("  Total RARE from sells:", _fmt(rareOutTotal));
        console.log("  User1 final token balance:", _fmt(token.balanceOf(user1)));
        console.log("  User1 final RARE balance:", _fmt(mockRARE.balanceOf(user1)));

        assertGt(totalTokensBought, 0);
        assertGt(rareOutTotal, 0);
        assertTrue(priceAfterBuys > priceRarePerToken, "Price should rise after buys");
    }

    function _fmt(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e18;
        uint256 frac = (amount % 1e18) / 1e15;
        if (frac == 0) return vm.toString(whole);
        string memory fracStr = vm.toString(frac);
        if (frac < 10) fracStr = string.concat("00", fracStr);
        else if (frac < 100) fracStr = string.concat("0", fracStr);
        return string.concat(vm.toString(whole), ".", fracStr);
    }

    function _fmtPrice(uint256 priceWei) internal pure returns (string memory) {
        if (priceWei == 0) return "0";
        uint256 whole = priceWei / 1e18;
        if (whole > 0) return _fmt(priceWei);
        uint256 frac9 = (priceWei % 1e18) / 1e9;
        if (frac9 == 0) return "0";
        string memory fracStr = vm.toString(frac9);
        if (frac9 < 10) fracStr = string.concat("00000000", fracStr);
        else if (frac9 < 100) fracStr = string.concat("0000000", fracStr);
        else if (frac9 < 1000) fracStr = string.concat("000000", fracStr);
        else if (frac9 < 10000) fracStr = string.concat("00000", fracStr);
        else if (frac9 < 100000) fracStr = string.concat("0000", fracStr);
        else if (frac9 < 1000000) fracStr = string.concat("000", fracStr);
        else if (frac9 < 10000000) fracStr = string.concat("00", fracStr);
        else if (frac9 < 100000000) fracStr = string.concat("0", fracStr);
        return string.concat("0.", fracStr);
    }
}
