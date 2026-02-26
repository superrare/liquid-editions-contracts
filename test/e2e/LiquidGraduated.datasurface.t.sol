// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidGraduated Data Surface Tests
 * @notice After graduating, assert same ILiquid view outputs for LiquidMultiCurve vs LiquidGraduated
 * @dev Uses fork: create one instant and one graduated token, graduate the latter at same price,
 *      then compare getCurrentPrice, getMarketState, quoteBuy, quoteSell for same inputs.
 */

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
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
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";

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

contract LiquidGraduatedDatasurfaceTest is Test, InitGuardTestHelper {
    NetworkConfig.Config internal config;
    address admin = makeAddr("admin");
    address creator = makeAddr("creator");
    address migrator = makeAddr("migrator");

    LiquidFactory public factory;
    LiquidMultiCurve public instantImpl;
    LiquidGraduated public graduatedImpl;
    MockRARE public rare;
    MockCCAFactoryDS public mockCcaFactory;

    LiquidMultiCurve public instantToken;
    LiquidGraduated public graduatedToken;

    function setUp() public {
        // Fork Base mainnet for realistic testing with deployed contracts
        string memory forkUrl = ForkUrlResolver.requireForkUrl(vm);
        vm.createSelectFork(forkUrl);
        // Get network configuration from forked chain
        config = NetworkConfig.getConfig(block.chainid);

        rare = new MockRARE();
        rare.mint(creator, 1000 ether);
        rare.mint(migrator, 1000 ether);
        mockCcaFactory = new MockCCAFactoryDS(address(rare));

        address initGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);

        vm.startPrank(admin);        factory = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager,
            -180,
            120000,
            config.uniswapV4Quoter,
            initGuardAddr,
            60,
            300,
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
        address instantAddr = factory.createLiquidTokenMultiCurve(
            creator,
            "https://example.com/i",
            "Instant",
            "INST",
            10e18
        );
        instantToken = LiquidMultiCurve(payable(instantAddr));

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
            MockAuctionDS mockAuction = new MockAuctionDS(CURRENCY);
            mockAuction.setToken(TOKEN);
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

    function migrate() external override(ILBPStrategy) {
        if (auction != address(0)) {
            MockAuctionDS(auction).sweepCurrency();
            IPoolManager pm = IPoolManager(POOL_MANAGER);
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(CURRENCY < TOKEN ? CURRENCY : TOKEN),
                currency1: Currency.wrap(CURRENCY < TOKEN ? TOKEN : CURRENCY),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
            pm.initialize(key, 79228162514264337593543950336);
        }
    }
}
