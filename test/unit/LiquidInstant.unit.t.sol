// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidInstant Unit Tests
 * @notice Tests for LiquidInstant with mock pool manager
 * @dev Uses MockV4PoolManager for unit testing without fork
 */

import "forge-std/Test.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {ILiquidBase} from "liquid-editions/interfaces/ILiquidBase.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {MockV4PoolManager} from "liquid-editions-test/helpers/MockV4PoolManager.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Position} from "doppler/types/Position.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";

contract LiquidInstantUnitTest is Test, InitGuardTestHelper {
    address public admin = makeAddr("admin");
    address public creator = makeAddr("creator");

    MockV4PoolManager public poolManager;
    MockERC20 public baseToken;

    LiquidFactory public factory;
    LiquidInstant public instantImplementation;

    uint256 constant MIN_RARE = 250e18;

    function setUp() public {
        poolManager = new MockV4PoolManager();
        baseToken = new MockERC20();
        address initGuardAddr = _deployInitGuardForTest(address(poolManager), admin);
        factory = new LiquidFactory(
            admin,
            address(poolManager),
            -180,
            120000,
            initGuardAddr,
            60,
            MIN_RARE
        );
        vm.prank(admin);
        LiquidGuard(initGuardAddr).setFactory(address(factory));

        vm.startPrank(admin);
        factory.setLiquidRegistry(address(1));
        instantImplementation = new LiquidInstant();
        factory.setLiquidInstantImplementation(address(instantImplementation));
        factory.setBaseToken(address(baseToken));
        vm.stopPrank();

        baseToken.mint(admin, 10_000 ether);
        baseToken.mint(creator, 10_000 ether);
    }

    // ============================================
    // Shared helper: deploy a token
    // ============================================

    function _deployToken() internal returns (LiquidInstant) {
        vm.startPrank(creator);
        baseToken.approve(address(factory), MIN_RARE);
        address tokenAddr = factory.createLiquidTokenInstant(
            creator, "ipfs://test", "Test Instant", "TI", MIN_RARE
        );
        vm.stopPrank();
        return LiquidInstant(payable(tokenAddr));
    }

    // ============================================
    // Initialize — post-init invariants
    // ============================================

    function test_Initialize_Success() public {
        LiquidInstant token = _deployToken();

        assertEq(token.name(), "Test Instant");
        assertEq(token.symbol(), "TI");
        assertEq(token.initialTokenUri(), "ipfs://test");
        assertEq(token.tokenCreator(), creator);
        assertEq(token.baseToken(), address(baseToken));
        assertEq(token.factory(), address(factory));

        (ILiquidBase.LaunchType launchType, bool poolLive, address auction, address strategy) =
            token.getLaunchState();
        assertEq(uint8(launchType), uint8(ILiquidBase.LaunchType.INSTANT), "launch type must be INSTANT");
        assertTrue(poolLive, "pool should be live immediately");
        assertEq(auction, address(0), "no auction for Instant");
        assertEq(strategy, address(0), "no strategy for Instant");

        // Instant stores a single concentrated position — lpLiquidity is non-zero
        assertGt(token.lpLiquidity(), 0, "lpLiquidity should be non-zero for Instant");
    }

    function test_Initialize_RevertsWhen_InsufficientRARE_FactoryRejectsLow() public {
        // The factory validates _initialRareLiquidity >= minRareLiquidityWei before transferring.
        // Passing an amount below the factory minimum reverts with InvalidAmount at the factory level.
        uint256 tooLittle = MIN_RARE - 1;

        vm.startPrank(creator);
        baseToken.approve(address(factory), tooLittle);
        vm.expectRevert(ILiquidFactory.InvalidAmount.selector);
        factory.createLiquidTokenInstant(
            creator, "ipfs://test", "Test", "TI", tooLittle
        );
        vm.stopPrank();
    }

    function test_Initialize_RevertsWhen_InsufficientRARE_TokenLevel() public {
        // The token-level RARELiquidityTooSmall check fires when the clone has a lower
        // RARE balance than the _minRequiredRareLiquidity argument to initialize().
        // We mint RARE directly to the clone but pass a higher minimum requirement.
        address clone = Clones.clone(address(instantImplementation));

        // Give the clone some RARE but less than we demand as minimum
        uint256 cloneRare = 100e18;
        uint256 requiredRare = 500e18;
        baseToken.mint(clone, cloneRare);

        // Call initialize directly (bypassing factory) to exercise the token-level guard.
        // factory = msg.sender = address(this); the mock factory needs baseToken + poolManager.
        // We use the real factory as the calling context by pranking from it.
        vm.prank(address(factory));
        vm.expectRevert(ILiquid.RARELiquidityTooSmall.selector);
        LiquidInstant(payable(clone)).initialize(
            creator,
            "ipfs://test",
            "Test",
            "TI",
            requiredRare,  // _minRequiredRareLiquidity > cloneRare → revert
            1_000_000e18,
            100_000e18
        );
    }

    function test_Initialize_RevertsWhen_EmptyTokenURI() public {
        vm.startPrank(creator);
        baseToken.approve(address(factory), MIN_RARE);
        vm.expectRevert(ILiquid.InvalidTokenURI.selector);
        factory.createLiquidTokenInstant(
            creator, "", "Test", "TI", MIN_RARE
        );
        vm.stopPrank();
    }

    function test_Initialize_RevertsWhen_ZeroCreator() public {
        vm.startPrank(creator);
        baseToken.approve(address(factory), MIN_RARE);
        vm.expectRevert();
        factory.createLiquidTokenInstant(
            address(0), "ipfs://test", "Test", "TI", MIN_RARE
        );
        vm.stopPrank();
    }

    function test_Initialize_RevertsWhen_CalledTwice() public {
        LiquidInstant token = _deployToken();

        vm.expectRevert();
        token.initialize(
            creator,
            "ipfs://dup",
            "Dup",
            "DUP",
            MIN_RARE,
            1_000_000e18,
            100_000e18
        );
    }

    function test_Initialize_RevertsWhen_ImplementationNotSet() public {
        address newInitGuardAddr = _deployInitGuardForTest(address(poolManager), admin);
        LiquidFactory newFactory = new LiquidFactory(
            admin,
            address(poolManager),
            -180,
            120000,
            newInitGuardAddr,
            60,
            MIN_RARE
        );
        vm.prank(admin);
        LiquidGuard(newInitGuardAddr).setFactory(address(newFactory));
        vm.startPrank(admin);
        newFactory.setLiquidRegistry(address(1));
        newFactory.setBaseToken(address(baseToken));
        vm.stopPrank();
        // Intentionally do NOT call setLiquidInstantImplementation

        vm.startPrank(creator);
        baseToken.mint(creator, MIN_RARE);
        baseToken.approve(address(newFactory), MIN_RARE);
        vm.expectRevert(ILiquidFactory.ImplementationNotSet.selector);
        newFactory.createLiquidTokenInstant(
            creator, "ipfs://test", "Test", "TI", MIN_RARE
        );
        vm.stopPrank();
    }

    // ============================================
    // Supply constants
    // ============================================

    function test_MaxTotalSupply_IsExpected() public {
        LiquidInstant token = _deployToken();
        assertEq(token.maxTotalSupply(), 1_000_000e18, "MAX_TOTAL_SUPPLY should be 1 million tokens");
    }

    function test_CreatorLaunchReward_IsDistributedOnInit() public {
        LiquidInstant token = _deployToken();
        uint256 CREATOR_REWARD = 100_000e18;
        assertEq(token.balanceOf(creator), CREATOR_REWARD, "creator should receive exact launch reward");
    }

    function test_PoolLaunchSupply_IsMaxMinusCreatorReward() public {
        LiquidInstant token = _deployToken();
        assertEq(
            token.poolLaunchSupply(),
            token.maxTotalSupply() - token.creatorLaunchReward(),
            "poolLaunchSupply must equal maxTotalSupply - creatorLaunchReward"
        );
    }

    function test_LpLiquidity_IsNonZero() public {
        LiquidInstant token = _deployToken();
        // Unlike MultiCurve (which distributes across positions and returns 0),
        // Instant holds a single concentrated position with stored lpLiquidity.
        assertGt(token.lpLiquidity(), 0, "lpLiquidity should be non-zero for a single-position Instant pool");
    }

    // ============================================
    // getLaunchState
    // ============================================

    function test_GetLaunchState_LaunchType_IsINSTANT() public {
        LiquidInstant token = _deployToken();
        (ILiquidBase.LaunchType launchType, bool poolLive, address auction, address strategy) =
            token.getLaunchState();
        assertEq(uint8(launchType), uint8(ILiquidBase.LaunchType.INSTANT), "launch type must be INSTANT");
        assertTrue(poolLive, "pool should be live immediately");
        assertEq(auction, address(0), "no auction for Instant");
        assertEq(strategy, address(0), "no strategy for Instant");
    }

    // ============================================
    // Unlock callback access control
    // ============================================

    function test_UnlockCallback_RevertsWhen_CallerNotPoolManager() public {
        LiquidInstant token = _deployToken();
        bytes memory data = abi.encode(uint8(1), abi.encode(uint256(1e18)));

        vm.expectRevert(ILiquid.OnlyPoolManager.selector);
        vm.prank(makeAddr("notPoolManager"));
        IUnlockCallback(address(token)).unlockCallback(data);
    }

    function test_UnlockCallback_RevertsWhen_UnlockNotExpected() public {
        LiquidInstant token = _deployToken();
        address poolManagerAddr = token.poolManager();
        bytes memory data = abi.encode(uint8(1), abi.encode(uint256(1e18)));

        vm.expectRevert(ILiquid.UnexpectedUnlock.selector);
        vm.prank(poolManagerAddr);
        IUnlockCallback(address(token)).unlockCallback(data);
    }

    // ============================================
    // burn() — positive path, access, events
    // ============================================

    function test_Burn_ReducesTotalSupply() public {
        LiquidInstant token = _deployToken();
        uint256 supplyBefore = token.totalSupply();
        uint256 creatorBalance = token.balanceOf(creator);
        assertGt(creatorBalance, 0, "creator should have tokens");

        uint256 burnAmount = 1e18;
        vm.prank(creator);
        token.burn(burnAmount);

        assertEq(token.totalSupply(), supplyBefore - burnAmount, "totalSupply should decrease by burned amount");
        assertEq(token.balanceOf(creator), creatorBalance - burnAmount, "creator balance should decrease");
    }

    function test_Burn_ZeroAmount_Succeeds() public {
        LiquidInstant token = _deployToken();
        uint256 supplyBefore = token.totalSupply();

        vm.prank(creator);
        token.burn(0);

        assertEq(token.totalSupply(), supplyBefore, "supply should not change on zero burn");
    }

    function test_Burn_EmitsLiquidTransfer() public {
        LiquidInstant token = _deployToken();
        uint256 burnAmount = 1e18;

        vm.expectEmit(true, true, false, false);
        emit ILiquid.LiquidTransfer(creator, address(0), burnAmount, 0, 0, 0);

        vm.prank(creator);
        token.burn(burnAmount);
    }

    function test_Burn_RevertsWhen_InsufficientBalance() public {
        LiquidInstant token = _deployToken();
        uint256 creatorBalance = token.balanceOf(creator);

        vm.prank(creator);
        vm.expectRevert();
        token.burn(creatorBalance + 1);
    }

    // ============================================
    // setRenderContract() — access control, events
    // ============================================

    function test_SetRenderContract_ByCreator_Succeeds() public {
        LiquidInstant token = _deployToken();
        address renderAddr = makeAddr("renderContract");

        vm.prank(creator);
        token.setRenderContract(renderAddr);

        assertEq(token.renderContract(), renderAddr, "render contract should be set");
    }

    function test_SetRenderContract_EmitsRenderContractSet() public {
        LiquidInstant token = _deployToken();
        address renderAddr = makeAddr("renderContractEvent");

        vm.expectEmit(true, false, false, false);
        emit ILiquid.RenderContractSet(renderAddr);

        vm.prank(creator);
        token.setRenderContract(renderAddr);
    }

    function test_SetRenderContract_ByZeroAddress_ClearsRenderContract() public {
        LiquidInstant token = _deployToken();
        address renderAddr = makeAddr("renderContractClear");

        vm.prank(creator);
        token.setRenderContract(renderAddr);
        assertEq(token.renderContract(), renderAddr);

        vm.prank(creator);
        token.setRenderContract(address(0));
        assertEq(token.renderContract(), address(0), "render contract should be cleared");
    }

    function test_SetRenderContract_RevertsForNonCreator() public {
        LiquidInstant token = _deployToken();
        address notCreator = makeAddr("notCreator");

        vm.prank(notCreator);
        vm.expectRevert(ILiquid.NotTokenCreator.selector);
        token.setRenderContract(makeAddr("someRender"));
    }

    // ============================================
    // tokenURI() — fallback to initialTokenUri
    // ============================================

    function test_TokenURI_ReturnsInitialTokenUri_WhenNoRenderContract() public {
        LiquidInstant token = _deployToken();
        assertEq(token.tokenURI(), "ipfs://test", "should return initialTokenUri when no render contract");
    }

    // ============================================
    // Transfer — emits LiquidTransfer with exact values
    // ============================================

    function test_Transfer_EmitsLiquidTransfer_WithExactValues() public {
        LiquidInstant token = _deployToken();
        address recipient = makeAddr("recipient");
        uint256 transferAmount = 1000e18;

        uint256 creatorBalBefore = token.balanceOf(creator);
        uint256 recipientBalBefore = token.balanceOf(recipient);
        uint256 supplyBefore = token.totalSupply();

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
        token.transfer(recipient, transferAmount);
    }

    // ============================================
    // migrateLiquidity() — access control + Instant-specific constraints
    // ============================================

    function test_MigrateLiquidity_RevertsForNonMigrationExecutor() public {
        LiquidInstant token = _deployToken();
        address notExecutor = makeAddr("notExecutor");

        PoolKey memory newKey;
        Position[] memory positions = new Position[](1);

        vm.prank(notExecutor);
        vm.expectRevert(ILiquid.OnlyMigrationExecutor.selector);
        token.migrateLiquidity(newKey, 0, positions, notExecutor, 0, 0);
    }

    function test_MigrateLiquidity_RevertsWhen_InvalidPositionCount_Zero() public {
        LiquidInstant token = _deployToken();
        address executor = makeAddr("executor");

        vm.prank(admin);
        factory.setMigrationExecutor(executor);

        PoolKey memory newKey;
        Position[] memory positions = new Position[](0);

        vm.prank(executor);
        vm.expectRevert(ILiquid.InvalidPositionCount.selector);
        token.migrateLiquidity(newKey, 0, positions, executor, 0, 0);
    }

    function test_MigrateLiquidity_RevertsWhen_InvalidPositionCount_TooMany() public {
        LiquidInstant token = _deployToken();
        address executor = makeAddr("executor");

        vm.prank(admin);
        factory.setMigrationExecutor(executor);

        PoolKey memory newKey;
        Position[] memory positions = new Position[](2);

        vm.prank(executor);
        vm.expectRevert(ILiquid.InvalidPositionCount.selector);
        token.migrateLiquidity(newKey, 0, positions, executor, 0, 0);
    }

    function test_MigrateLiquidity_RevertsWhen_NonZeroSalt() public {
        LiquidInstant token = _deployToken();
        address executor = makeAddr("executor");

        vm.prank(admin);
        factory.setMigrationExecutor(executor);

        PoolKey memory newKey;
        Position[] memory positions = new Position[](1);
        positions[0] = Position({
            tickLower: -180,
            tickUpper: 120000,
            liquidity: 1e18,
            salt: bytes32(uint256(1)) // non-zero salt
        });

        vm.prank(executor);
        vm.expectRevert(ILiquid.NonZeroSalt.selector);
        token.migrateLiquidity(newKey, 0, positions, executor, 0, 0);
    }

    // ============================================
    // Implementation setter (factory admin)
    // ============================================

    function test_SetLiquidInstantImplementation() public {
        LiquidInstant newImpl = new LiquidInstant();
        vm.prank(admin);
        factory.setLiquidInstantImplementation(address(newImpl));
        assertEq(factory.liquidInstantImplementation(), address(newImpl));
    }

    function test_RevertWhen_NonAdmin_SetLiquidInstantImplementation() public {
        LiquidInstant newImpl = new LiquidInstant();
        vm.prank(creator);
        vm.expectRevert();
        factory.setLiquidInstantImplementation(address(newImpl));
    }

    function test_RevertWhen_SetLiquidInstantImplementation_Zero() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setLiquidInstantImplementation(address(0));
    }
}
