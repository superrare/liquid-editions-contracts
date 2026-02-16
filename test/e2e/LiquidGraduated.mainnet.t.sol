// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidGraduated Mainnet Fork Tests
 * @notice Create with mock CCA, graduate against real Uniswap V4 PoolManager, assert post-graduation state
 */

import "forge-std/Test.sol";
import {LiquidGraduated} from "liquid-editions/LiquidGraduated.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {IDistributionStrategy} from "continuous-clearing-auction/interfaces/external/IDistributionStrategy.sol";
import {IDistributionContract} from "continuous-clearing-auction/interfaces/external/IDistributionContract.sol";
import {AuctionParameters} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {ILBPStrategy} from "liquid-editions/interfaces/ILBPStrategy.sol";
import {MigratorParameters} from "liquid-editions/types/MigratorParameters.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract MockCCAFactoryFork is IDistributionStrategy {
    address public rareToken;

    constructor(address _rare) {
        rareToken = _rare;
    }

    function initializeDistribution(
        address token,
        uint256,
        bytes calldata,
        bytes32
    ) external override returns (IDistributionContract) {
        MockAuctionFork a = new MockAuctionFork(rareToken);
        a.setToken(token);
        return IDistributionContract(address(a));
    }
}

contract MockAuctionFork is IDistributionContract {
    address public rareToken;
    address public token;

    constructor(address _rare) {
        rareToken = _rare;
    }

    function setToken(address _token) external {
        token = _token;
    }

    function onTokensReceived() external override {}

    function sweepCurrency() external {
        uint256 bal = IERC20(rareToken).balanceOf(address(this));
        if (bal > 0) IERC20(rareToken).transfer(msg.sender, bal);
    }

    function sweepUnsoldTokens() external {
        if (token != address(0)) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) IERC20(token).transfer(msg.sender, bal);
        }
    }

    function clearingPrice() external pure returns (uint256) {
        return 79228162514264337593543950336;
    }
}

contract LiquidGraduatedMainnetForkTest is Test {
    NetworkConfig.Config internal config;
    address admin = makeAddr("admin");
    address creator = makeAddr("creator");
    address migrator = makeAddr("migrator");

    LiquidFactory public factory;
    LiquidGraduated public implementation;
    LiquidGraduated public graduated;
    MockRARE public rare;
    MockCCAFactoryFork public mockCcaFactory;

    uint256 constant AUCTION_SUPPLY = 900_000e18;

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

        mockCcaFactory = new MockCCAFactoryFork(address(rare));

        vm.startPrank(admin);
        factory = new LiquidFactory(
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
        factory.setBaseToken(address(rare));
        implementation = new LiquidGraduated();
        factory.setLiquidGraduatedImplementation(address(implementation));
        factory.setCcaFactory(address(mockCcaFactory));
        // Set canonical LBP strategy factory (required)
        MockLBPStrategyFactoryFork mockStrategyFactory = new MockLBPStrategyFactoryFork(
                config.uniswapV4PoolManager
            );
        factory.setLbpStrategyFactory(address(mockStrategyFactory));
        // Use poolManager as positionManager if not set in config (for testing)
        address posManager = config.uniswapV4PositionManager != address(0)
            ? config.uniswapV4PositionManager
            : config.uniswapV4PoolManager;
        factory.setPositionManager(posManager);
        factory.setProtocolFeeRecipient(creator);
        vm.stopPrank();
    }

    function test_CreateAndGraduate_RealPoolManager() public {
        AuctionParameters memory params = AuctionParameters({
            currency: address(rare),
            tokensRecipient: address(0),
            fundsRecipient: address(0),
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 100),
            claimBlock: uint64(block.number + 101),
            tickSpacing: 1e18,
            validationHook: address(0),
            floorPrice: 1e18,
            requiredCurrencyRaised: 0,
            auctionStepsData: abi.encodePacked(uint24(1e7 / 100), uint40(100))
        });
        (address token, address auction) = factory.createLiquidTokenWithAuction(
            creator,
            "https://example.com/1",
            "Fork Grad",
            "FGRAD",
            migrator,
            AUCTION_SUPPLY,
            abi.encode(params),
            bytes32(0)
        );
        graduated = LiquidGraduated(payable(token));

        assertFalse(graduated.isGraduated());
        assertEq(graduated.auctionAddress(), auction);

        uint256 rareAmount = 10e18;
        rare.transfer(auction, rareAmount);
        ILBPStrategy(graduated.strategy()).migrate();

        // Mock uses hooks=address(0) (PoolManager rejects non-registered hooks). LiquidGraduated
        // computes poolId with hooks=strategy. Sync poolId to the pool actually created.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(
                address(rare) < address(graduated)
                    ? address(rare)
                    : address(graduated)
            ),
            currency1: Currency.wrap(
                address(rare) < address(graduated)
                    ? address(graduated)
                    : address(rare)
            ),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.prank(address(factory));
        graduated.setPoolId(key.toId());

        assertTrue(graduated.isGraduated());
        (uint256 rarePerToken, ) = graduated.getCurrentPrice();
        assertTrue(rarePerToken > 0);
    }
}

contract MockLBPStrategyFactoryFork is IDistributionStrategy {
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
        (
            MigratorParameters memory migratorParams,
            bytes memory auctionParams
        ) = abi.decode(configData, (MigratorParameters, bytes));
        abi.decode(auctionParams, (AuctionParameters));
        address currency = migratorParams.currency;
        if (currency == address(0)) {
            currency = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        }
        MockLBPStrategyFork strategy = new MockLBPStrategyFork(
            token,
            poolManager,
            currency
        );
        return IDistributionContract(address(strategy));
    }
}

contract MockLBPStrategyFork is IDistributionContract, ILBPStrategy {
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
            MockAuctionFork mockAuction = new MockAuctionFork(currency);
            mockAuction.setToken(token);
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

    function migrate() external override(ILBPStrategy) {
        if (auction != address(0)) {
            MockAuctionFork(auction).sweepCurrency();
            IPoolManager pm = IPoolManager(poolManager);
            // Real PoolManager rejects non-registered hooks; use address(0) for mock
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(currency < token ? currency : token),
                currency1: Currency.wrap(currency < token ? token : currency),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
            pm.initialize(key, 79228162514264337593543950336);
        }
    }
}
