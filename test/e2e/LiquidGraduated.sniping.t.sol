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
    address public immutable override(ILBPStrategy) token;
    address public immutable poolManager;
    address public immutable currency;
    address public auction;

    constructor(address _token, address _poolManager, address _currency) {
        token = _token;
        poolManager = _poolManager;
        currency = _currency;
    }

    function onTokensReceived()
        external
        override(IDistributionContract, ILBPStrategy)
    {
        if (auction == address(0)) {
            MockAuctionSniping mockAuction = new MockAuctionSniping();
            auction = address(mockAuction);
            IERC20(token).transfer(
                auction,
                IERC20(token).balanceOf(address(this))
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

contract LiquidGraduatedSnipingTest is Test {
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

    function setUp() public {
        // Fork Ethereum Sepolia for realistic testing with deployed contracts
        // Sepolia has all contracts deployed: Factory, Router, RAREBurner, etc.
        // Check ETH_SEPOLIA, SEPOLIA_RPC_URL, FORK_URL, or use default
        string memory forkUrl;
        try vm.envString("ETH_SEPOLIA") returns (string memory url) {
            forkUrl = url;
        } catch {
            try vm.envString("SEPOLIA_RPC_URL") returns (string memory url) {
                forkUrl = url;
            } catch {
                forkUrl = vm.envOr(
                    "FORK_URL",
                    string("https://eth-sepolia.g.alchemy.com/v2/demo")
                );
            }
        }
        vm.createSelectFork(forkUrl);
        // Get network configuration (Ethereum Sepolia chain ID = 11155111)
        config = NetworkConfig.getConfig(block.chainid);

        rare = new MockRARE();
        rare.mint(creator, 1000 ether);
        rare.mint(migrator, 1000 ether);
        rare.mint(sniper, 1000 ether);
        mockCcaFactory = new MockCCAFactorySniping();

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
            1e15
        );
                factory.setLiquidRouter(address(1));
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
        factory.setPositionManager(config.uniswapV4PositionManager);
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
            10e18
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
