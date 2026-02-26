// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidMultiCurve Data Surface Tests
 * @notice ILiquid parity: compare getCurrentPrice, getMarketState, quoteBuy, quoteSell with LiquidMultiCurve
 * @dev Creates LiquidMultiCurve and LiquidMultiCurve with same RARE liquidity (250 each), verifies identical interface.
 */

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {ILiquidBase} from "liquid-editions/interfaces/ILiquidBase.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";

contract LiquidMultiCurveDatasurfaceTest is Test, InitGuardTestHelper {
    NetworkConfig.Config internal config;

    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");

    LiquidFactory public factory;
    LiquidMultiCurve public instantImpl;
    LiquidMultiCurve public multiCurveImpl;
    MockRARE public mockRARE;

    LiquidMultiCurve public instantToken;
    LiquidMultiCurve public multiCurveToken;

    uint256 constant LIQUIDITY = 250e18;

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

        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);

        mockRARE = new MockRARE();
        mockRARE.mint(tokenCreator, 10_000 ether);

        vm.startPrank(admin);
        address initGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        factory = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager,
            -180,
            120000,
            config.uniswapV4Quoter,
            initGuardAddr,
            60,
            300,
            LIQUIDITY
        );
        LiquidInitGuard(initGuardAddr).setFactory(address(factory));
        factory.setLiquidRegistry(address(1));
        instantImpl = new LiquidMultiCurve();
        multiCurveImpl = new LiquidMultiCurve();
        factory.setLiquidMultiCurveImplementation(address(instantImpl));
        factory.setLiquidMultiCurveImplementation(address(multiCurveImpl));
        factory.setBaseToken(address(mockRARE));
        vm.stopPrank();

        vm.startPrank(tokenCreator);
        mockRARE.approve(address(factory), LIQUIDITY * 2);

        Curve[] memory instantCurves = new Curve[](1);
        instantCurves[0] = Curve({
            tickLower: factory.lpTickLower(),
            tickUpper: factory.lpTickUpper(),
            numPositions: 1,
            shares: 1e18
        });

        instantToken = LiquidMultiCurve(
            payable(
                factory.createLiquidTokenMultiCurve(
                    tokenCreator,
                    "ipfs://instant",
                    "Instant",
                    "INST",
                    LIQUIDITY,
                    instantCurves
                )
            )
        );

        Curve[] memory curves = _defaultCurves();
        multiCurveToken = LiquidMultiCurve(
            payable(
                factory.createLiquidTokenMultiCurve(
                    tokenCreator,
                    "ipfs://multicurve",
                    "MultiCurve",
                    "MCRV",
                    LIQUIDITY,
                    curves
                )
            )
        );

        vm.stopPrank();
    }

    function test_GetLaunchState_ReturnsCorrectEnum() public view {
        (ILiquidBase.LaunchType instantType, , , ) = instantToken.getLaunchState();
        (ILiquidBase.LaunchType multiType, , , ) = multiCurveToken.getLaunchState();

        assertTrue(instantType == ILiquidBase.LaunchType.MULTICURVE);
        assertTrue(multiType == ILiquidBase.LaunchType.MULTICURVE);
    }

    function test_GetCurrentPrice_NonZero() public view {
        (uint256 instantRarePerToken, ) = instantToken.getCurrentPrice();
        (uint256 multiRarePerToken, ) = multiCurveToken.getCurrentPrice();

        assertTrue(instantRarePerToken > 0, "Instant price positive");
        assertTrue(multiRarePerToken > 0, "MultiCurve price positive");
    }

    function test_GetMarketState_NonZero() public view {
        (
            uint256 instantRarePerToken,
            ,
            uint160 instantSqrtPrice,
            ,
            ,
            uint256 instantSupply
        ) = instantToken.getMarketState();

        (
            uint256 multiRarePerToken,
            ,
            uint160 multiSqrtPrice,
            ,
            ,
            uint256 multiSupply
        ) = multiCurveToken.getMarketState();

        assertTrue(instantRarePerToken > 0 && multiRarePerToken > 0);
        assertTrue(instantSqrtPrice > 0 && multiSqrtPrice > 0);
        assertEq(instantSupply, 1_000_000e18);
        assertEq(multiSupply, 1_000_000e18);
    }

    function test_QuoteBuy_ReturnsPositive() public {
        uint256 rareIn = 10e18;
        (uint256 instantOut, ) = instantToken.quoteBuy(rareIn);
        (uint256 multiOut, ) = multiCurveToken.quoteBuy(rareIn);

        assertTrue(instantOut > 0, "Instant quote positive");
        assertTrue(multiOut > 0, "MultiCurve quote positive");
    }

    function test_QuoteSell_ReturnsPositive() public {
        uint256 tokenAmount = 1000e18;
        (uint256 instantRareOut, ) = instantToken.quoteSell(tokenAmount);
        (uint256 multiRareOut, ) = multiCurveToken.quoteSell(tokenAmount);

        assertTrue(instantRareOut > 0, "Instant sell quote positive");
        assertTrue(multiRareOut > 0, "MultiCurve sell quote positive");
    }

    function test_IdenticalILiquidInterface() public view {
        assertEq(instantToken.MAX_TOTAL_SUPPLY(), multiCurveToken.MAX_TOTAL_SUPPLY());
        assertEq(instantToken.totalSupply(), multiCurveToken.totalSupply());
        assertEq(instantToken.tokenCreator(), multiCurveToken.tokenCreator());
        assertEq(instantToken.baseToken(), multiCurveToken.baseToken());
    }
}
