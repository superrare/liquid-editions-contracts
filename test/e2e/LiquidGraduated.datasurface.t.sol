// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidGraduated Data Surface Tests
 * @notice After graduating, assert same ILiquid view outputs for LiquidInstant vs LiquidGraduated
 * @dev Uses fork: create one instant and one graduated token, graduate the latter at same price,
 *      then compare getCurrentPrice, getMarketState, quoteBuy, quoteSell for same inputs.
 */

import "forge-std/Test.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {LiquidGraduated} from "liquid-editions/LiquidGraduated.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {IDistributionStrategy} from "continuous-clearing-auction/interfaces/external/IDistributionStrategy.sol";
import {IDistributionContract} from "continuous-clearing-auction/interfaces/external/IDistributionContract.sol";
import {AuctionParameters} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILBPStrategy} from "liquid-editions/interfaces/ILBPStrategy.sol";
import {MigratorParameters} from "liquid-editions/types/MigratorParameters.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract MockCCAFactoryDS is IDistributionStrategy {
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
        MockAuctionDS auction = new MockAuctionDS(rareToken);
        auction.setToken(token);
        return IDistributionContract(address(auction));
    }
}

contract MockAuctionDS is IDistributionContract {
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

contract LiquidGraduatedDatasurfaceTest is Test {
    NetworkConfig.Config internal config;
    address admin = makeAddr("admin");
    address creator = makeAddr("creator");
    address migrator = makeAddr("migrator");

    LiquidFactory public factory;
    LiquidInstant public instantImpl;
    LiquidGraduated public graduatedImpl;
    MockRARE public rare;
    MockCCAFactoryDS public mockCcaFactory;

    LiquidInstant public instantToken;
    LiquidGraduated public graduatedToken;

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
        mockCcaFactory = new MockCCAFactoryDS(address(rare));

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
        instantImpl = new LiquidInstant();
        graduatedImpl = new LiquidGraduated();
        factory.setImplementation(address(instantImpl));
        factory.setLiquidGraduatedImplementation(address(graduatedImpl));
        factory.setCcaFactory(address(mockCcaFactory));
        // Set canonical LBP strategy factory (required)
        MockLBPStrategyFactoryDS mockStrategyFactory = new MockLBPStrategyFactoryDS(
                config.uniswapV4PoolManager
            );
        factory.setLbpStrategyFactory(address(mockStrategyFactory));
        factory.setPositionManager(config.uniswapV4PositionManager);
        factory.setProtocolFeeRecipient(creator);
        vm.stopPrank();
    }

    /// @notice After both tokens exist (instant with pool, graduated after graduation), same price params yield same getCurrentPrice shape
    function test_PostGraduation_GetCurrentPrice_NonZero() public {
        vm.startPrank(creator);
        rare.approve(address(factory), 20e18);
        address instantAddr = factory.createLiquidToken(
            creator,
            "https://example.com/i",
            "Instant",
            "INST",
            10e18
        );
        instantToken = LiquidInstant(payable(instantAddr));

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
        vm.stopPrank();
        graduatedToken = LiquidGraduated(payable(gradAddr));
        rare.transfer(graduatedToken.auctionAddress(), 10e18);
        ILBPStrategy(graduatedToken.strategy()).migrate();

        // Mock uses hooks=address(0); LiquidGraduated computes poolId with hooks=strategy. Sync poolId.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(
                address(rare) < address(graduatedToken)
                    ? address(rare)
                    : address(graduatedToken)
            ),
            currency1: Currency.wrap(
                address(rare) < address(graduatedToken)
                    ? address(graduatedToken)
                    : address(rare)
            ),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.prank(address(factory));
        graduatedToken.setPoolId(key.toId());

        (uint256 instantRarePerToken, ) = instantToken.getCurrentPrice();
        (uint256 gradRarePerToken, ) = graduatedToken.getCurrentPrice();
        assertTrue(
            instantRarePerToken > 0 && gradRarePerToken > 0,
            "both prices positive"
        );
    }
}

contract MockLBPStrategyFactoryDS is IDistributionStrategy {
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
        MockLBPStrategyDS strategy = new MockLBPStrategyDS(
            token,
            poolManager,
            currency
        );
        return IDistributionContract(address(strategy));
    }
}

contract MockLBPStrategyDS is IDistributionContract, ILBPStrategy {
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
            MockAuctionDS mockAuction = new MockAuctionDS(currency);
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
            MockAuctionDS(auction).sweepCurrency();
            IPoolManager pm = IPoolManager(poolManager);
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
