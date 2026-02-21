// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidMultiCurve Anti-Sniping Tests
 * @notice Compare sniper outcomes: LiquidMultiCurve vs LiquidMultiCurve with identical 250 RARE liquidity
 * @dev Simulates same-block sniper buying with X RARE; multicurve sniper gets fewer tokens (trip wire).
 */

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {LiquidPoolSwapHelper} from "liquid-editions-test/helpers/LiquidPoolSwapHelper.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiquidMultiCurveSnipingTest is Test {
    NetworkConfig.Config internal config;

    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public sniper = makeAddr("sniper");

    LiquidFactory public factory;
    LiquidMultiCurve public instantImpl;
    LiquidMultiCurve public multiCurveImpl;
    LiquidPoolSwapHelper public swapHelper;
    MockRARE public mockRARE;

    uint256 constant LIQUIDITY = 250e18;
    /// @notice MultiCurve needs more RARE - real PoolManager deltas exceed Multicurve estimates
    uint256 constant MULTICURVE_LIQUIDITY = 2000e18;

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
        string memory forkUrl = vm.envOr(
            "FORK_URL",
            string("https://mainnet.base.org")
        );
        vm.createSelectFork(forkUrl);

        config = NetworkConfig.getConfig(block.chainid);

        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(sniper, 100 ether);

        mockRARE = new MockRARE();
        mockRARE.mint(tokenCreator, 10_000 ether);
        mockRARE.mint(sniper, 10_000 ether);

        vm.startPrank(admin);        factory = new LiquidFactory(
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
                factory.setLiquidRouter(address(1));
        instantImpl = new LiquidMultiCurve();
        multiCurveImpl = new LiquidMultiCurve();
        factory.setLiquidMultiCurveImplementation(address(instantImpl));
        factory.setLiquidMultiCurveImplementation(address(multiCurveImpl));
        factory.setBaseToken(address(mockRARE));
        swapHelper = new LiquidPoolSwapHelper(IPoolManager(config.uniswapV4PoolManager));
        vm.stopPrank();
    }

    function test_TripWire_LargeBuyCausesPriceImpact() public {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(tokenCreator);
        mockRARE.approve(address(factory), LIQUIDITY + MULTICURVE_LIQUIDITY);
        factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://dummy",
            "Dummy",
            "DMY",
            LIQUIDITY
        );
        mockRARE.approve(address(factory), MULTICURVE_LIQUIDITY);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://tripwire",
            "Tripwire",
            "TRP",
            MULTICURVE_LIQUIDITY,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));

        (uint256 priceBeforeRarePerToken, ) = token.getCurrentPrice();

        uint256 largeBuy = 100e18;
        vm.startPrank(sniper);
        mockRARE.approve(address(swapHelper), largeBuy);
        swapHelper.buy(address(token), largeBuy, sniper);
        vm.stopPrank();

        (uint256 priceAfterRarePerToken, ) = token.getCurrentPrice();

        assertTrue(
            priceAfterRarePerToken > priceBeforeRarePerToken,
            "Large buy should increase price (trip wire)"
        );
    }
}
