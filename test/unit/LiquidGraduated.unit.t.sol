// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidGraduated} from "liquid-editions/LiquidGraduated.sol";
import {ILiquidGraduated} from "liquid-editions/interfaces/ILiquidGraduated.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IDistributionStrategy} from "continuous-clearing-auction/interfaces/external/IDistributionStrategy.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {IDistributionContract} from "continuous-clearing-auction/interfaces/external/IDistributionContract.sol";
import {AuctionParameters} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {ILBPStrategy} from "liquid-editions/interfaces/ILBPStrategy.sol";
import {MigratorParameters} from "liquid-editions/types/MigratorParameters.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @title LiquidGraduated Unit Tests
/// @notice Tests for initialize(), strategy.migrate(), getAuctionState() with mock pool manager
contract LiquidGraduatedUnitTest is Test {
    address admin = makeAddr("admin");
    address creator = makeAddr("creator");
    address migrator = makeAddr("migrator");

    LiquidFactory public factory;
    LiquidGraduated public implementation;
    LiquidGraduated public graduated;
    MockRARE public rare;
    MockCCAFactory public mockCcaFactory;
    MockV4PoolManager public mockPoolManager;

    uint256 constant AUCTION_SUPPLY = 900_000e18;

    function setUp() public {
        rare = new MockRARE();
        rare.mint(creator, 1000 ether);
        rare.mint(migrator, 1000 ether);

        mockPoolManager = new MockV4PoolManager();
        mockCcaFactory = new MockCCAFactory(address(rare));
        factory = new LiquidFactory(
            admin,
            makeAddr("weth"),
            address(mockPoolManager),
            -180,
            120000,
            makeAddr("v4Quoter"),
            address(0),
            60,
            300,
            1e15
        );

        vm.startPrank(admin);
        factory.setLiquidRegistry(address(1));
        factory.setBaseToken(address(rare));
        implementation = new LiquidGraduated();
        factory.setLiquidGraduatedImplementation(address(implementation));
        factory.setCcaFactory(address(mockCcaFactory));
        // Set canonical LBP strategy factory (required)
        MockLBPStrategyFactory mockStrategyFactory = new MockLBPStrategyFactory(
            address(mockPoolManager)
        );
        factory.setLbpStrategyFactory(address(mockStrategyFactory));
        factory.setPositionManager(makeAddr("positionManager"));
        factory.setProtocolFeeRecipient(makeAddr("protocolFeeRecipient"));
        vm.stopPrank();
    }

    function test_InitializeViaFactory() public {
        AuctionParameters memory params = _defaultAuctionParams();
        (address token, address auction) = factory.createLiquidTokenWithAuction(
            creator,
            "https://example.com/1",
            "Graduated Token",
            "GRAD",
            migrator,
            AUCTION_SUPPLY,
            abi.encode(params),
            bytes32(0)
        );

        graduated = LiquidGraduated(payable(token));

        assertEq(graduated.auctionAddress(), auction);
        assertTrue(graduated.strategy() != address(0));
        assertFalse(graduated.isGraduated());
        assertEq(graduated.balanceOf(creator), 100_000e18);
        assertEq(graduated.totalSupply(), 1_000_000e18);

        (address a, bool grad, address s) = graduated.getAuctionState();
        assertEq(a, auction);
        assertEq(grad, false);
        assertEq(s, graduated.strategy());
    }

    function test_Migrate_Success() public {
        _createGraduatedToken();
        rare.transfer(graduated.auctionAddress(), 10e18);
        ILBPStrategy(graduated.strategy()).migrate();

        assertTrue(graduated.isGraduated());
        assertEq(graduated.baseToken(), address(rare));
    }

    function test_Migrate_WhenAlreadyGraduated_NoRevert() public {
        _createGraduatedToken();
        rare.transfer(graduated.auctionAddress(), 10e18);
        ILBPStrategy(graduated.strategy()).migrate();
        assertTrue(graduated.isGraduated());
        ILBPStrategy(graduated.strategy()).migrate();
        assertTrue(graduated.isGraduated());
    }

    function test_GraduateMarket_Success() public {
        _createGraduatedToken();
        rare.transfer(graduated.auctionAddress(), 10e18);
        ILBPStrategy(graduated.strategy()).migrate();

        assertTrue(graduated.isGraduated());
        assertEq(graduated.baseToken(), address(rare));
    }

    function test_GetCurrentPrice_RevertWhenNotGraduated() public {
        _createGraduatedToken();
        vm.expectRevert(ILiquid.PoolNotInitialized.selector);
        graduated.getCurrentPrice();
    }

    function _defaultAuctionParams()
        internal
        view
        returns (AuctionParameters memory)
    {
        return
            AuctionParameters({
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
                auctionStepsData: abi.encodePacked(
                    uint24(1e7 / 100),
                    uint40(100)
                )
            });
    }

    function _createGraduatedToken() internal {
        (address token, ) = factory.createLiquidTokenWithAuction(
            creator,
            "https://example.com/1",
            "G",
            "G",
            migrator,
            AUCTION_SUPPLY,
            abi.encode(_defaultAuctionParams()),
            bytes32(0)
        );
        graduated = LiquidGraduated(payable(token));
    }
}

/// Mock CCA factory: returns a minimal distribution contract address
contract MockCCAFactory is IDistributionStrategy {
    address public rareToken;

    constructor(address _rare) {
        rareToken = _rare;
    }

    function initializeDistribution(
        address token,
        uint256 /* amount */,
        bytes calldata,
        bytes32
    ) external override returns (IDistributionContract distributionContract) {
        MockAuction mock = new MockAuction(rareToken);
        mock.setToken(token);
        return IDistributionContract(address(mock));
    }
}

/// Mock LBP Strategy Factory: returns a mock strategy
contract MockLBPStrategyFactory is IDistributionStrategy {
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
        // Decode configData: (MigratorParameters, bytes) where bytes is auctionParams
        // MigratorParameters is a struct, so we decode it directly
        (MigratorParameters memory migratorParams, ) = // bytes memory auctionParams // Unused
        abi.decode(configData, (MigratorParameters, bytes));
        // AuctionParameters memory params = abi.decode(
        //     auctionParams,
        //     (AuctionParameters)
        // ); // Unused
        // Use currency from migratorParams (should match auction params)
        address currency = migratorParams.currency;
        if (currency == address(0)) {
            // If currency is zero (ETH), use a placeholder address for testing
            currency = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        }

        MockLBPStrategy strategy = new MockLBPStrategy(
            token,
            poolManager,
            currency
        );
        return IDistributionContract(address(strategy));
    }
}

/// Mock LBP Strategy: implements ILBPStrategy interface
contract MockLBPStrategy is IDistributionContract, ILBPStrategy {
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
            // Create mock auction on first call
            MockAuction mockAuction = new MockAuction(CURRENCY);
            mockAuction.setToken(TOKEN);
            auction = address(mockAuction);
            // Transfer tokens to auction
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
            // Sweep currency from auction
            MockAuction(auction).sweepCurrency();
            // Initialize pool via pool manager
            IPoolManager pm = IPoolManager(POOL_MANAGER);
            // Create a simple pool key
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(CURRENCY < TOKEN ? CURRENCY : TOKEN),
                currency1: Currency.wrap(CURRENCY < TOKEN ? TOKEN : CURRENCY),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(this))
            });
            pm.initialize(key, 79228162514264337593543950336);
        }
    }
}

contract MockAuction is IDistributionContract {
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

/// Minimal mock for V4 PoolManager: supports unlock callback (initialize pool + add liquidity)
contract MockV4PoolManager {
    using PoolIdLibrary for PoolKey;

    bytes32 constant POOLS_SLOT = bytes32(uint256(6));
    mapping(bytes32 => bytes32) public slotData;

    function unlock(bytes calldata data) external returns (bytes memory) {
        address callbackContract = msg.sender;
        if (callbackContract.code.length > 0) {
            IUnlockCallback(callbackContract).unlockCallback(data);
        }
        return "";
    }

    function getSlot0(
        bytes32 poolId
    ) external view returns (uint160, int24, uint24, uint24) {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        // slotData is set by initialize; StateLibrary uses extsload(stateSlot)
        if (slotData[stateSlot] != bytes32(0)) {
            return (79228162514264337593543950336, 0, 0, 0);
        }
        return (0, 0, 0, 0);
    }

    function swap(
        PoolKey memory,
        IPoolManager.SwapParams memory,
        bytes memory
    ) external pure returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function modifyLiquidity(
        PoolKey memory,
        IPoolManager.ModifyLiquidityParams memory,
        bytes calldata
    ) external pure returns (BalanceDelta, BalanceDelta) {
        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function initialize(PoolKey memory key, uint160) external returns (int24) {
        PoolId pid = key.toId();
        bytes32 stateSlot = keccak256(
            abi.encodePacked(PoolId.unwrap(pid), POOLS_SLOT)
        );
        slotData[stateSlot] = bytes32(uint256(79228162514264337593543950336));
        return 0;
    }

    function take(Currency, address, uint256) external {}

    function mint(address, uint256 id, uint256 amount) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function burn(address, uint256 id, uint256 amount) external {}

    function donate(
        PoolKey memory,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function sync(Currency) external {}

    function clear(Currency, uint256) external {}

    function settleFor(address) external payable returns (uint256) {
        return 0;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slotData[slot];
    }
}
