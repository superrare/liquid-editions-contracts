// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidMultiCurve Shared Behavior Tests
 * @notice Runs the parameterized LiquidTokenBehaviorBase suite against LiquidMultiCurve.
 * @dev Uses Base mainnet fork.
 */

import {LiquidTokenBehaviorBase} from "liquid-editions-test/helpers/bases/LiquidTokenBehaviorBase.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {DeployConfig} from "script/config/DeployConfig.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";

contract LiquidMultiCurveBehaviorTest is LiquidTokenBehaviorBase, InitGuardTestHelper {
    NetworkConfig.Config internal config;

    string constant TOKEN_NAME = "MultiCurveBehavior";
    string constant TOKEN_SYMBOL = "MCBHV";
    string constant TOKEN_URI = "ipfs://multicurve-behavior";
    uint256 constant LIQUIDITY = 250e18;

    function _defaultCurves() internal pure returns (Curve[] memory) {
        DeployConfig.MultiCurveConfig memory cfg = DeployConfig.getDefaultMultiCurveConfig();

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

    function _deployFactory() internal override returns (LiquidFactory, MockRARE) {
        string memory forkUrl = ForkUrlResolver.requireForkUrl(vm);
        vm.createSelectFork(forkUrl);
        config = NetworkConfig.getConfig(block.chainid);

        MockRARE rare = new MockRARE();
        rare.mint(tokenCreator, 10_000 ether);

        address initGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        vm.startPrank(admin);
        LiquidFactory f = new LiquidFactory(admin, config.uniswapV4PoolManager, initGuardAddr, 60);
        LiquidGuard(initGuardAddr).setFactory(address(f));
        f.setLiquidRegistry(address(1));
        LiquidMultiCurve impl = new LiquidMultiCurve();
        f.setLiquidMultiCurveImplementation(address(impl));
        f.setBaseToken(address(rare));
        vm.stopPrank();

        return (f, rare);
    }

    function _deployToken() internal override returns (ILiquid) {
        Curve[] memory curves = _defaultCurves();

        vm.startPrank(tokenCreator);
        mockRARE.approve(address(factory), LIQUIDITY);
        address tokenAddr =
            factory.createLiquidTokenMultiCurve(tokenCreator, TOKEN_URI, TOKEN_NAME, TOKEN_SYMBOL, LIQUIDITY, curves);
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
