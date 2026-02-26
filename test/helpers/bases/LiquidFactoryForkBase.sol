// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ForkTestBase} from "liquid-editions-test/helpers/bases/ForkTestBase.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";

/// @title Liquid Factory Fork Test Base
/// @notice Shared setup for fork tests: Factory + MockRARE + common accounts
/// @dev Inheritors get factory, mockRARE, multiCurveImpl, and funded admin/tokenCreator/protocolFeeRecipient
abstract contract LiquidFactoryForkBase is ForkTestBase, InitGuardTestHelper {
    // Standard LP tick range
    int24 constant LP_TICK_LOWER = -180;
    int24 constant LP_TICK_UPPER = 120000;

    address public admin;
    address public tokenCreator;
    address public protocolFeeRecipient;

    RAREBurner public burner;
    LiquidFactory public factory;
    LiquidMultiCurve public multiCurveImpl;
    MockRARE public mockRARE;

    /// @notice Override to skip burner deployment (e.g. MEV test doesn't need it)
    function _deployBurner() internal virtual returns (bool) {
        return true;
    }

    /// @notice Deploy factory with standard params. Override to customize.
    function _deployFactory() internal virtual returns (LiquidFactory) {
        address initGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);

        LiquidFactory f = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager,
            LP_TICK_LOWER,
            LP_TICK_UPPER,
            config.uniswapV4Quoter,
            initGuardAddr,
            60, // poolTickSpacing
            300, // internalMaxSlippageBps (3%)
            1e15 // minRareLiquidityWei (0.001 RARE)
        );
        LiquidInitGuard(initGuardAddr).setFactory(address(f));
        f.setLiquidRegistry(address(1));
        f.setLiquidMultiCurveImplementation(address(multiCurveImpl));
        f.setBaseToken(address(mockRARE));
        return f;
    }

    /// @notice Returns a default single-curve config (equivalent to former LiquidMultiCurve)
    function _defaultSingleCurve() internal view returns (Curve[] memory) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({
            tickLower: factory.lpTickLower(),
            tickUpper: factory.lpTickUpper(),
            numPositions: 1,
            shares: 1e18
        });
        return curves;
    }

    /// @notice Full setup. Call from setUp() or override for custom setup.
    function _setupLiquidFactoryFork() internal {
        _setupFork();

        admin = makeAddr("admin");
        tokenCreator = makeAddr("tokenCreator");
        protocolFeeRecipient = config.protocolFeeRecipient != address(0)
            ? config.protocolFeeRecipient
            : makeAddr("protocolFeeRecipient");

        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(protocolFeeRecipient, 1 ether);

        mockRARE = new MockRARE();
        mockRARE.mint(admin, 10_000_000 ether);
        mockRARE.mint(tokenCreator, 10_000_000 ether);

        vm.startPrank(admin);

        multiCurveImpl = new LiquidMultiCurve();

        if (_deployBurner()) {
            burner = new RAREBurner(
                admin,
                false, // tryOnDeposit
                config.rareToken,
                config.uniswapV4PoolManager,
                3000, // 0.3% fee
                60, // tick spacing
                address(0), // no hooks
                0x000000000000000000000000000000000000dEaD, // burn address
                address(0), // no quoter initially
                0, // 0% slippage
                false // disabled initially
            );
        }

        factory = _deployFactory();

        vm.stopPrank();
    }
}
