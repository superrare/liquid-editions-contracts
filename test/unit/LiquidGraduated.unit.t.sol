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
import {Position} from "doppler/types/Position.sol";
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

        mockPoolManager = new MockV4PoolManager();
        mockCcaFactory = new MockCCAFactory(address(rare));
        factory = new LiquidFactory(
            admin,
            address(mockPoolManager),
            -180,
            120000,
            address(0),
            60,
            1e15
        );

        vm.startPrank(admin);
        factory.setLiquidRegistry(address(1));
        factory.setBaseToken(address(rare));
        implementation = new LiquidGraduated();
        factory.setLiquidGraduatedImplementation(address(implementation));
        factory.setCcaFactory(address(mockCcaFactory));
        MockLBPStrategyFactory mockStrategyFactory = new MockLBPStrategyFactory(
            address(mockPoolManager)
        );
        factory.setLbpStrategyFactory(address(mockStrategyFactory));
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

    // ============================================
    // burn() — positive path, events, access
    // ============================================

    function test_Burn_ReducesTotalSupply() public {
        _createGraduatedToken();
        uint256 supplyBefore = graduated.totalSupply();
        uint256 creatorBalance = graduated.balanceOf(creator);
        assertGt(creatorBalance, 0, "creator should have tokens");

        uint256 burnAmount = 1e18;
        vm.prank(creator);
        graduated.burn(burnAmount);

        assertEq(graduated.totalSupply(), supplyBefore - burnAmount, "totalSupply should decrease");
        assertEq(graduated.balanceOf(creator), creatorBalance - burnAmount, "creator balance should decrease");
    }

    function test_Burn_ZeroAmount_Succeeds() public {
        _createGraduatedToken();
        uint256 supplyBefore = graduated.totalSupply();

        vm.prank(creator);
        graduated.burn(0);

        assertEq(graduated.totalSupply(), supplyBefore, "supply should not change on zero burn");
    }

    function test_Burn_EmitsLiquidTransfer() public {
        _createGraduatedToken();
        uint256 burnAmount = 1e18;

        vm.expectEmit(true, true, false, false);
        emit ILiquid.LiquidTransfer(creator, address(0), burnAmount, 0, 0, 0);

        vm.prank(creator);
        graduated.burn(burnAmount);
    }

    function test_Burn_RevertsWhen_InsufficientBalance() public {
        _createGraduatedToken();
        uint256 creatorBalance = graduated.balanceOf(creator);

        vm.prank(creator);
        vm.expectRevert();
        graduated.burn(creatorBalance + 1);
    }

    // ============================================
    // setRenderContract() — access control, events
    // ============================================

    function test_SetRenderContract_ByCreator_Succeeds() public {
        _createGraduatedToken();
        address renderAddr = makeAddr("renderContract");

        vm.prank(creator);
        graduated.setRenderContract(renderAddr);

        assertEq(graduated.renderContract(), renderAddr, "render contract should be set");
    }

    function test_SetRenderContract_EmitsRenderContractSet() public {
        _createGraduatedToken();
        address renderAddr = makeAddr("renderContractEvent");

        vm.expectEmit(true, false, false, false);
        emit ILiquid.RenderContractSet(renderAddr);

        vm.prank(creator);
        graduated.setRenderContract(renderAddr);
    }

    function test_SetRenderContract_RevertsForNonCreator() public {
        _createGraduatedToken();
        address notCreator = makeAddr("notCreator");

        vm.prank(notCreator);
        vm.expectRevert(ILiquid.NotTokenCreator.selector);
        graduated.setRenderContract(makeAddr("someRender"));
    }

    // ============================================
    // Supply and distribution constants
    // ============================================

    function test_MaxTotalSupply_IsExpected() public {
        _createGraduatedToken();
        assertEq(graduated.MAX_TOTAL_SUPPLY(), 1_000_000e18, "MAX_TOTAL_SUPPLY should be 1 million tokens");
    }

    function test_CreatorLaunchReward_IsDistributedOnInit() public {
        _createGraduatedToken();
        uint256 CREATOR_REWARD = 100_000e18;
        assertEq(graduated.balanceOf(creator), CREATOR_REWARD, "creator should receive exact launch reward");
    }

    function test_TotalSupply_IsMaxOnInit() public {
        _createGraduatedToken();
        assertEq(graduated.totalSupply(), 1_000_000e18, "total supply should equal MAX at init");
    }

    // ============================================
    // getLaunchState / getAuctionState — correct enum
    // ============================================

    function test_GetAuctionState_NotGraduated() public {
        _createGraduatedToken();
        (address a, bool grad, address s) = graduated.getAuctionState();
        assertEq(a, graduated.auctionAddress(), "auction address mismatch");
        assertFalse(grad, "should not be graduated initially");
        assertEq(s, graduated.strategy(), "strategy address mismatch");
    }

    function test_GetAuctionState_AfterGraduation() public {
        _createGraduatedToken();
        rare.transfer(graduated.auctionAddress(), 10e18);
        ILBPStrategy(graduated.strategy()).migrate();

        (, bool grad, ) = graduated.getAuctionState();
        assertTrue(grad, "should be graduated after migration");
    }

    // ============================================
    // migrateLiquidity() — always reverts in LiquidGraduated (use strategy instead)
    // ============================================

    function test_MigrateLiquidity_AlwaysReverts_UseStrategy() public {
        _createGraduatedToken();

        // LiquidGraduated.migrateLiquidity always reverts regardless of caller —
        // liquidity migration for graduated tokens goes through the strategy contract.
        PoolKey memory newKey;
        Position[] memory positions = new Position[](0);
        vm.prank(makeAddr("anyone"));
        vm.expectRevert("Graduated: use strategy");
        graduated.migrateLiquidity(newKey, 0, positions, makeAddr("anyone"), 0, 0);
    }

    // ============================================
    // tokenURI — fallback behavior
    // ============================================

    function test_TokenURI_ReturnsInitialUri_WhenNoRenderContract() public {
        _createGraduatedToken();
        string memory uri = graduated.tokenURI();
        assertEq(uri, "https://example.com/1", "should return initial token URI");
    }

    function test_Transfer_EmitsLiquidTransfer_WithExactValues() public {
        _createGraduatedToken();
        address recipient = makeAddr("recipient");
        uint256 transferAmount = 1000e18;

        uint256 creatorBalBefore = graduated.balanceOf(creator);
        uint256 recipientBalBefore = graduated.balanceOf(recipient);
        uint256 supplyBefore = graduated.totalSupply();

        vm.expectEmit(true, true, false, true);
        emit ILiquid.LiquidTransfer(
            creator,
            recipient,
            transferAmount,
            creatorBalBefore - transferAmount,
            recipientBalBefore + transferAmount,
            supplyBefore
        );

        vm.prank(creator);
        graduated.transfer(recipient, transferAmount);
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
