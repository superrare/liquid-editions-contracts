// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidGraduated Shared Behavior Tests
 * @notice Runs the parameterized LiquidTokenBehaviorBase suite against LiquidGraduated.
 * @dev Uses fork URL from FORK_URL. Graduates the token in _deployToken() so pool-live tests pass.
 *      Also includes a pre-graduation variant where pool-live tests are skipped.
 */

import {LiquidTokenBehaviorBase} from "liquid-editions-test/helpers/bases/LiquidTokenBehaviorBase.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
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
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";

// ---- Mocks (matching LiquidGraduated.datasurface.t.sol pattern) ----

contract MockCCAFactoryGradBhv is IDistributionStrategy {
    address public rareToken;

    constructor(address _rare) {
        rareToken = _rare;
    }

    function initializeDistribution(address token, uint256, bytes calldata, bytes32)
        external
        override
        returns (IDistributionContract)
    {
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

    function initializeDistribution(address token, uint256, bytes calldata configData, bytes32)
        external
        override
        returns (IDistributionContract)
    {
        (MigratorParameters memory migratorParams, bytes memory auctionParams) =
            abi.decode(configData, (MigratorParameters, bytes));
        abi.decode(auctionParams, (AuctionParameters));
        address currency = migratorParams.currency;
        if (currency == address(0)) {
            currency = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        }
        MockLBPStrategyGradBhv strategy = new MockLBPStrategyGradBhv(token, poolManager, currency);
        return IDistributionContract(address(strategy));
    }
}

contract MockLBPStrategyGradBhv is IDistributionContract, ILBPStrategy {
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

    function onTokensReceived() external override(IDistributionContract, ILBPStrategy) {
        if (auction == address(0)) {
            MockAuctionGradBhv mockAuction = new MockAuctionGradBhv(CURRENCY);
            mockAuction.setToken(TOKEN);
            auction = address(mockAuction);
            IERC20(TOKEN).transfer(auction, IERC20(TOKEN).balanceOf(address(this)));
            IDistributionContract(auction).onTokensReceived();
        }
    }

    function initializer() external view override(ILBPStrategy) returns (address) {
        return auction;
    }

    function migrate() external override(ILBPStrategy) {
        if (auction != address(0)) {
            MockAuctionGradBhv(auction).sweepCurrency();
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

// ---- Post-graduation behavior test ----

contract LiquidGraduatedBehaviorTest is LiquidTokenBehaviorBase {
    NetworkConfig.Config internal config;
    MockCCAFactoryGradBhv public mockCcaFactory;
    LiquidGraduated public graduatedToken;

    string constant TOKEN_NAME = "GraduatedBehavior";
    string constant TOKEN_SYMBOL = "GBHV";
    string constant TOKEN_URI = "ipfs://graduated-behavior";

    function _deployFactory() internal override returns (LiquidFactory, MockRARE) {
        string memory forkUrl = ForkUrlResolver.requireForkUrl(vm);
        vm.createSelectFork(forkUrl);
        config = NetworkConfig.getConfig(block.chainid);

        MockRARE rare = new MockRARE();
        rare.mint(tokenCreator, 10_000 ether);
        mockCcaFactory = new MockCCAFactoryGradBhv(address(rare));

        vm.startPrank(admin);
        LiquidFactory f = new LiquidFactory(admin, config.uniswapV4PoolManager, address(0), 60);
        f.setLiquidRegistry(address(1));
        f.setBaseToken(address(rare));
        vm.stopPrank();

        return (f, rare);
    }

    function _deployToken() internal override returns (ILiquid) {
        vm.skip(true);
        return ILiquid(address(0));
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

    function _deployFactory() internal override returns (LiquidFactory, MockRARE) {
        string memory forkUrl = ForkUrlResolver.requireForkUrl(vm);
        vm.createSelectFork(forkUrl);
        config = NetworkConfig.getConfig(block.chainid);

        MockRARE rare = new MockRARE();
        rare.mint(tokenCreator, 10_000 ether);
        mockCcaFactory = new MockCCAFactoryGradBhv(address(rare));

        vm.startPrank(admin);
        LiquidFactory f = new LiquidFactory(admin, config.uniswapV4PoolManager, address(0), 60);
        f.setLiquidRegistry(address(1));
        f.setBaseToken(address(rare));
        vm.stopPrank();

        return (f, rare);
    }

    function _deployToken() internal override returns (ILiquid) {
        vm.skip(true);
        return ILiquid(address(0));
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
