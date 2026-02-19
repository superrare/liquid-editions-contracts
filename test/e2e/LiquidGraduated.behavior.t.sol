// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidGraduated Shared Behavior Tests
 * @notice Runs the parameterized LiquidTokenBehaviorBase suite against LiquidGraduated.
 * @dev Uses Sepolia fork. Graduates the token in _deployToken() so pool-live tests pass.
 *      Also includes a pre-graduation variant where pool-live tests are skipped.
 */

import {LiquidTokenBehaviorBase} from "liquid-editions-test/helpers/bases/LiquidTokenBehaviorBase.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {LiquidGraduated} from "liquid-editions/LiquidGraduated.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {ILBPStrategy} from "liquid-editions/interfaces/ILBPStrategy.sol";
import {MigratorParameters} from "liquid-editions/types/MigratorParameters.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {IDistributionStrategy} from "continuous-clearing-auction/interfaces/external/IDistributionStrategy.sol";
import {IDistributionContract} from "continuous-clearing-auction/interfaces/external/IDistributionContract.sol";
import {AuctionParameters} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

// ---- Mocks (matching LiquidGraduated.datasurface.t.sol pattern) ----

contract MockCCAFactoryGradBhv is IDistributionStrategy {
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
        MockAuctionGradBhv auction = new MockAuctionGradBhv(rareToken);
        auction.setToken(token);
        return IDistributionContract(address(auction));
    }
}

contract MockAuctionGradBhv is IDistributionContract {
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
        return 79228162514264337593543950336; // 1:1 sqrtPriceX96
    }
}

contract MockLBPStrategyFactoryGradBhv is IDistributionStrategy {
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
        MockLBPStrategyGradBhv strategy = new MockLBPStrategyGradBhv(
            token,
            poolManager,
            currency
        );
        return IDistributionContract(address(strategy));
    }
}

contract MockLBPStrategyGradBhv is IDistributionContract, ILBPStrategy {
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
            MockAuctionGradBhv mockAuction = new MockAuctionGradBhv(currency);
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
            MockAuctionGradBhv(auction).sweepCurrency();
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

// ---- Post-graduation behavior test ----

contract LiquidGraduatedBehaviorTest is LiquidTokenBehaviorBase {
    NetworkConfig.Config internal config;
    MockCCAFactoryGradBhv public mockCcaFactory;
    LiquidGraduated public graduatedToken;

    string constant TOKEN_NAME = "GraduatedBehavior";
    string constant TOKEN_SYMBOL = "GBHV";
    string constant TOKEN_URI = "ipfs://graduated-behavior";

    function _deployFactory()
        internal
        override
        returns (LiquidFactory, MockRARE)
    {
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
        config = NetworkConfig.getConfig(block.chainid);

        MockRARE rare = new MockRARE();
        rare.mint(tokenCreator, 10_000 ether);
        mockCcaFactory = new MockCCAFactoryGradBhv(address(rare));

        vm.startPrank(admin);
        LiquidFactory f = new LiquidFactory(
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
        f.setLiquidRouter(address(1));
        f.setBaseToken(address(rare));
        LiquidGraduated gradImpl = new LiquidGraduated();
        f.setLiquidGraduatedImplementation(address(gradImpl));
        f.setCcaFactory(address(mockCcaFactory));
        MockLBPStrategyFactoryGradBhv stratFactory = new MockLBPStrategyFactoryGradBhv(
                config.uniswapV4PoolManager
            );
        f.setLbpStrategyFactory(address(stratFactory));
        f.setPositionManager(config.uniswapV4PositionManager);
        f.setProtocolFeeRecipient(tokenCreator);
        vm.stopPrank();

        return (f, rare);
    }

    function _deployToken() internal override returns (ILiquid) {
        address migrator = makeAddr("migrator");

        vm.startPrank(tokenCreator);
        mockRARE.approve(address(factory), 20e18);

        AuctionParameters memory params = AuctionParameters({
            currency: address(mockRARE),
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
            tokenCreator,
            TOKEN_URI,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            migrator,
            900_000e18,
            abi.encode(params),
            bytes32(0)
        );
        vm.stopPrank();

        graduatedToken = LiquidGraduated(payable(gradAddr));

        // Fund auction and graduate
        mockRARE.transfer(graduatedToken.auctionAddress(), 10e18);
        ILBPStrategy(graduatedToken.strategy()).migrate();

        // Sync poolId (mock uses hooks=address(0))
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(
                address(mockRARE) < address(graduatedToken)
                    ? address(mockRARE)
                    : address(graduatedToken)
            ),
            currency1: Currency.wrap(
                address(mockRARE) < address(graduatedToken)
                    ? address(graduatedToken)
                    : address(mockRARE)
            ),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.prank(address(factory));
        graduatedToken.setPoolId(key.toId());

        return ILiquid(gradAddr);
    }

    function _poolLive() internal pure override returns (bool) {
        return true;
    }

    /// @dev Quotes require swapping via the stored poolKey whose hooks = strategyAddr.
    ///      The mock can't initialize a V4 pool with that key because the clone address
    ///      lacks valid V4 hook flag bits, so quote tests are skipped.
    function _quotesSupported() internal pure override returns (bool) {
        return false;
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

// ---- Pre-graduation behavior test (pool not live, data-surface tests skipped) ----

contract LiquidGraduatedPreGradBehaviorTest is LiquidTokenBehaviorBase {
    NetworkConfig.Config internal config;
    MockCCAFactoryGradBhv public mockCcaFactory;

    string constant TOKEN_NAME = "GradPreGrad";
    string constant TOKEN_SYMBOL = "GPRE";
    string constant TOKEN_URI = "ipfs://graduated-pregrad";

    function _deployFactory()
        internal
        override
        returns (LiquidFactory, MockRARE)
    {
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
        config = NetworkConfig.getConfig(block.chainid);

        MockRARE rare = new MockRARE();
        rare.mint(tokenCreator, 10_000 ether);
        mockCcaFactory = new MockCCAFactoryGradBhv(address(rare));

        vm.startPrank(admin);
        LiquidFactory f = new LiquidFactory(
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
        f.setLiquidRouter(address(1));
        f.setBaseToken(address(rare));
        LiquidGraduated gradImpl = new LiquidGraduated();
        f.setLiquidGraduatedImplementation(address(gradImpl));
        f.setCcaFactory(address(mockCcaFactory));
        MockLBPStrategyFactoryGradBhv stratFactory = new MockLBPStrategyFactoryGradBhv(
                config.uniswapV4PoolManager
            );
        f.setLbpStrategyFactory(address(stratFactory));
        f.setPositionManager(config.uniswapV4PositionManager);
        f.setProtocolFeeRecipient(tokenCreator);
        vm.stopPrank();

        return (f, rare);
    }

    function _deployToken() internal override returns (ILiquid) {
        address migrator = makeAddr("migrator");

        vm.startPrank(tokenCreator);
        mockRARE.approve(address(factory), 20e18);

        AuctionParameters memory params = AuctionParameters({
            currency: address(mockRARE),
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
            tokenCreator,
            TOKEN_URI,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            migrator,
            900_000e18,
            abi.encode(params),
            bytes32(0)
        );
        vm.stopPrank();

        // Do NOT graduate — leave pool not initialized
        return ILiquid(gradAddr);
    }

    function _poolLive() internal pure override returns (bool) {
        return false;
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
