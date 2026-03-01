// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidGraduated Sniping / Fair Launch Tests
 * @notice Instant launch: pool is live same-block so a sniper can buy (and dump) in same block.
 *         CCA path: pool is created only after auction ends at graduation; no same-block snipe.
 * @dev This test documents the difference; we assert instant token is tradeable same-block.
 */

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidGraduated} from "liquid-editions/LiquidGraduated.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {IDistributionStrategy} from "continuous-clearing-auction/interfaces/external/IDistributionStrategy.sol";
import {IDistributionContract} from "continuous-clearing-auction/interfaces/external/IDistributionContract.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {AuctionParameters} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {MigratorParameters} from "liquid-editions/types/MigratorParameters.sol";
import {ILBPStrategy} from "liquid-editions/interfaces/ILBPStrategy.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";

contract MockCCAFactorySniping is IDistributionStrategy {
    function initializeDistribution(
        address,
        uint256,
        bytes calldata,
        bytes32
    ) external override returns (IDistributionContract) {
        return IDistributionContract(address(new MockAuctionSniping()));
    }
}

contract MockAuctionSniping is IDistributionContract {
    function onTokensReceived() external override {}
}

contract MockLBPStrategyFactorySniping is IDistributionStrategy {
    address public poolManager;

    constructor(address _poolManager) {
        poolManager = _poolManager;
    }

    function initializeDistribution(
        address token,
        uint256,
        bytes calldata configData,
        bytes32
    ) external override returns (IDistributionContract) {
        (MigratorParameters memory migratorParams, ) = abi.decode(
            configData,
            (MigratorParameters, bytes)
        );
        // AuctionParameters memory params = abi.decode(auctionParams, (AuctionParameters)); // Unused
        address currency = migratorParams.currency;
        if (currency == address(0)) {
            currency = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        }
        MockLBPStrategySniping strategy = new MockLBPStrategySniping(
            token,
            poolManager,
            currency
        );
        return IDistributionContract(address(strategy));
    }
}

contract MockLBPStrategySniping is IDistributionContract, ILBPStrategy {
    address public immutable TOKEN;
    address public immutable POOL_MANAGER;
    address public immutable CURRENCY;
    address public auction;

    constructor(address _token, address _poolManager, address _currency) {
        TOKEN = _token;
        POOL_MANAGER = _poolManager;
        CURRENCY = _currency;
    }

    function token() external view override(ILBPStrategy) returns (address) {
        return TOKEN;
    }

    function onTokensReceived()
        external
        override(IDistributionContract, ILBPStrategy)
    {
        if (auction == address(0)) {
            MockAuctionSniping mockAuction = new MockAuctionSniping();
            auction = address(mockAuction);
            IERC20(TOKEN).transfer(
                auction,
                IERC20(TOKEN).balanceOf(address(this))
            );
            IDistributionContract(auction).onTokensReceived();
        }
    }

    function initializer()
        external
        view
        override(ILBPStrategy)
        returns (address)
    {
        return auction;
    }

    function migrate() external override(ILBPStrategy) {}
}

contract LiquidGraduatedSnipingTest is Test, InitGuardTestHelper {
    NetworkConfig.Config internal config;
    address admin = makeAddr("admin");
    address creator = makeAddr("creator");
    address migrator = makeAddr("migrator");
    address sniper = makeAddr("sniper");

    LiquidFactory public factory;
    LiquidMultiCurve public instantImpl;
    LiquidGraduated public graduatedImpl;
    MockRARE public rare;
    MockCCAFactorySniping public mockCcaFactory;

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

    function setUp() public {
        // Fork Base mainnet for realistic testing with deployed contracts
        string memory forkUrl = ForkUrlResolver.requireForkUrl(vm);
        vm.createSelectFork(forkUrl);
        // Get network configuration from forked chain
        config = NetworkConfig.getConfig(block.chainid);

        rare = new MockRARE();
        rare.mint(creator, 1000 ether);
        rare.mint(migrator, 1000 ether);
        rare.mint(sniper, 1000 ether);
        mockCcaFactory = new MockCCAFactorySniping();

        address initGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);

        vm.startPrank(admin);        factory = new LiquidFactory(
            admin,
            config.uniswapV4PoolManager,
            -180,
            120000,
            initGuardAddr,
            60,
            1e15
        );
        LiquidInitGuard(initGuardAddr).setFactory(address(factory));
                factory.setLiquidRegistry(address(1));
        factory.setBaseToken(address(rare));
        instantImpl = new LiquidMultiCurve();
        graduatedImpl = new LiquidGraduated();
        factory.setLiquidMultiCurveImplementation(address(instantImpl));
        factory.setLiquidGraduatedImplementation(address(graduatedImpl));
        factory.setCcaFactory(address(mockCcaFactory));
        // Set canonical LBP strategy factory (required)
        MockLBPStrategyFactorySniping mockStrategyFactory = new MockLBPStrategyFactorySniping(
                config.uniswapV4PoolManager
            );
        factory.setLbpStrategyFactory(address(mockStrategyFactory));
        factory.setProtocolFeeRecipient(creator);
        vm.stopPrank();
    }

    /// @notice Instant launch: pool exists same-block; sniper can buy in same block as creation
    function test_InstantLaunch_TradeableSameBlock() public {
        vm.startPrank(creator);
        rare.approve(address(factory), 10e18);
        address instantAddr = factory.createLiquidTokenMultiCurve(
            creator,
            "https://example.com/i",
            "Instant",
            "INST",
            10e18,
            _defaultSingleCurve()
        );
        LiquidMultiCurve instantToken = LiquidMultiCurve(payable(instantAddr));
        vm.stopPrank();

        (uint256 rarePerToken, ) = instantToken.getCurrentPrice();
        assertTrue(rarePerToken > 0, "instant pool live same block");
    }

    /// @notice Graduated token: not tradeable until graduateMarket is called (no same-block snipe)
    function test_GraduatedLaunch_NotTradeableUntilGraduation() public {
        AuctionParameters memory params = AuctionParameters({
            currency: address(rare),
            tokensRecipient: creator,
            fundsRecipient: address(0),
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 100),
            claimBlock: uint64(block.number + 101),
            tickSpacing: 1e9,
            validationHook: address(0),
            floorPrice: 1e9,
            requiredCurrencyRaised: 0,
            auctionStepsData: ""
        });
        (address gradAddr, ) = factory.createLiquidTokenWithAuction(
            creator,
            "https://example.com/g",
            "Grad",
            "GRAD",
            migrator,
            900_000e18,
            abi.encode(params),
            bytes32(0)
        );
        LiquidGraduated graduatedToken = LiquidGraduated(payable(gradAddr));

        assertFalse(graduatedToken.isGraduated());
        vm.expectRevert(ILiquid.PoolNotInitialized.selector);
        graduatedToken.getCurrentPrice();
    }
}
