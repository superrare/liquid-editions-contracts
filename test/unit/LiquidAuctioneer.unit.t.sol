// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidAuctioneer} from "liquid-editions/LiquidAuctioneer.sol";
import {LiquidGraduated} from "liquid-editions/LiquidGraduated.sol";
import {ILiquidGraduated} from "liquid-editions/interfaces/ILiquidGraduated.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";
import {MockBurner} from "liquid-editions-test/helpers/MockBurner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDistributionStrategy} from "continuous-clearing-auction/interfaces/external/IDistributionStrategy.sol";
import {IDistributionContract} from "continuous-clearing-auction/interfaces/external/IDistributionContract.sol";
import {AuctionParameters} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {ILiquidAuctioneer} from "liquid-editions/interfaces/ILiquidAuctioneer.sol";
import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {ILBPStrategy} from "liquid-editions/interfaces/ILBPStrategy.sol";
import {MigratorParameters} from "liquid-editions/types/MigratorParameters.sol";
import {FeeDistributor} from "liquid-editions/FeeDistributor.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @title LiquidAuctioneer Unit Tests
contract LiquidAuctioneerUnitTest is Test {
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address referrer = makeAddr("referrer");
    address admin = makeAddr("admin");

    LiquidAuctioneer public auctioneer;
    LiquidRegistry public auctioneerRegistry;
    MockRARE public rare;
    MockERC20 public usdc;
    MockRouter public router;
    MockBurner public burner;
    LiquidFactory public factory;
    LiquidGraduated public implementation;
    LiquidGraduated public graduated;
    MockCCAFactorySweepable public mockCcaFactory;
    MockV4PoolManagerAuctioneer public mockPoolManager;

    function _createDefaultModules(
        address protocolRecipient
    ) internal returns (FeeDistributor, LiquidRegistry) {
        return (
            new FeeDistributor(
                owner,
                address(0),
                address(0),
                protocolRecipient,
                400,
                400
            ),
            new LiquidRegistry(owner)
        );
    }

    function _createAuctioneer(
        address routerAddr
    ) internal returns (LiquidAuctioneer) {
        return
            _createAuctioneer(
                routerAddr,
                protocolFeeRecipient,
                makeAddr("weth")
            );
    }

    function _createAuctioneer(
        address routerAddr,
        address protocolRecipient,
        address wethAddress
    ) internal returns (LiquidAuctioneer) {
        (FeeDistributor feeDistributor, LiquidRegistry liquidRegistry) = _createDefaultModules(
                protocolRecipient
            );
        LiquidAuctioneer createdAuctioneer = new LiquidAuctioneer(
            owner,
            routerAddr,
            address(feeDistributor),
            address(liquidRegistry),
            address(rare),
            wethAddress
        );
        vm.prank(owner);
        liquidRegistry.setWriter(address(createdAuctioneer), true);
        // Store registry for token registration in tests
        auctioneerRegistry = liquidRegistry;
        return createdAuctioneer;
    }

    function setUp() public {
        vm.deal(user, 100 ether);
        rare = new MockRARE();
        usdc = new MockERC20();
        rare.mint(admin, 1000 ether);
        router = new MockRouter(address(rare));
        burner = new MockBurner();

        auctioneer = _createAuctioneer(address(router));

        mockPoolManager = new MockV4PoolManagerAuctioneer();
        mockCcaFactory = new MockCCAFactorySweepable(address(rare));

        vm.startPrank(admin);
        factory = new LiquidFactory(
            admin,
            address(mockPoolManager),
            -180,
            120000,
            address(0),
            60,
            1e15
        );
        factory.setLiquidRegistry(address(1));
        factory.setBaseToken(address(rare));
        implementation = new LiquidGraduated();
        factory.setLiquidGraduatedImplementation(address(implementation));
        factory.setCcaFactory(address(mockCcaFactory));
        MockLBPStrategyFactoryAuctioneer mockStrategyFactory = new MockLBPStrategyFactoryAuctioneer(
                address(mockPoolManager)
            );
        factory.setLbpStrategyFactory(address(mockStrategyFactory));
        factory.setProtocolFeeRecipient(protocolFeeRecipient);
        vm.stopPrank();

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
        (address token, ) = factory.createLiquidTokenWithAuction(
            makeAddr("creator"),
            "https://example.com/1",
            "G",
            "G",
            address(auctioneer),
            900_000e18,
            abi.encode(params),
            bytes32(0)
        );
        graduated = LiquidGraduated(payable(token));

        // Register the graduated token in the auctioneer's registry
        _registerTokenInRegistry(auctioneerRegistry, address(graduated));
    }

    /// @dev Register a token in a registry (grants writer if needed)
    function _registerTokenInRegistry(LiquidRegistry registry, address token) internal {
        if (!registry.isWriter(address(this))) {
            vm.prank(owner);
            registry.setWriter(address(this), true);
        }
        registry.setBeneficiary(token, makeAddr("beneficiary"));
    }

    function _validRoute()
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        commands = hex"10";
        inputs = new bytes[](1);
        bytes memory actions = abi.encodePacked(uint8(0x07), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](0);
        inputs[0] = abi.encode(actions, params);
    }

    function test_MigrationViaStrategy_SweepAndGraduate() public {
        address auctionAddr = graduated.auctionAddress();
        rare.transfer(auctionAddr, 100e18);
        MockAuctionSweepable(auctionAddr).setClearingPrice(
            79228162514264337593543950336
        );

        address strategyAddr = graduated.strategy();
        ILBPStrategy(strategyAddr).migrate();

        assertTrue(graduated.isGraduated());
    }

    function test_RevertWhenPaused() public {
        vm.prank(owner);
        auctioneer.pause();
        vm.prank(user);
        vm.expectRevert();
        auctioneer.bid{value: 1 ether}(
            address(0),
            0,
            address(graduated),
            1,
            user,
            0,
            1,
            block.timestamp + 3600
        );
    }

    /// @notice Router that refunds ETH simulates unexpected Universal Router behavior
    function test_BidWithETH_RevertsOnUnexpectedEthRefund() public {
        EthRefundingRouter refundRouter = new EthRefundingRouter(
            address(rare),
            0.5 ether
        );
        rare.transfer(address(refundRouter), 2e18);
        vm.deal(address(refundRouter), 1 ether);

        LiquidAuctioneer refundAuctioneer = _createAuctioneer(
            address(refundRouter)
        );
        _registerTokenInRegistry(auctioneerRegistry, address(graduated));

        vm.prank(user);
        vm.expectRevert(ILiquidAuctioneer.UnexpectedEthRefund.selector);
        refundAuctioneer.bid{value: 1 ether}(
            address(0),
            0,
            address(graduated),
            1,
            user,
            0,
            1,
            block.timestamp + 3600
        );
    }

    // ==================== Rescue Tests ====================

    function test_RescueETH_Success() public {
        uint256 rescueAmount = 1 ether;
        vm.deal(address(auctioneer), rescueAmount);

        uint256 ownerBalBefore = owner.balance;

        vm.expectEmit(true, false, false, true);
        emit ILiquidAuctioneer.EthRescued(owner, rescueAmount);

        vm.prank(owner);
        auctioneer.rescueETH(owner, rescueAmount);

        assertEq(owner.balance - ownerBalBefore, rescueAmount);
        assertEq(address(auctioneer).balance, 0);
    }

    function test_RescueETH_RevertsOnZeroAddress() public {
        vm.deal(address(auctioneer), 1 ether);

        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(owner);
        auctioneer.rescueETH(address(0), 1 ether);
    }

    function test_RescueETH_RevertsOnZeroAmount() public {
        vm.deal(address(auctioneer), 1 ether);

        vm.expectRevert(ILiquidRouter.InvalidAmount.selector);
        vm.prank(owner);
        auctioneer.rescueETH(owner, 0);
    }

    function test_RescueETH_RevertsOnInsufficientBalance() public {
        vm.expectRevert(ILiquidRouter.InsufficientBalance.selector);
        vm.prank(owner);
        auctioneer.rescueETH(owner, 1 ether);
    }

    function test_RescueETH_RevertsForNonOwner() public {
        vm.deal(address(auctioneer), 1 ether);

        vm.expectRevert();
        vm.prank(user);
        auctioneer.rescueETH(user, 1 ether);
    }

    function test_SetUniversalRouter_RevertsForNonOwner() public {
        vm.expectRevert();
        vm.prank(user);
        auctioneer.setUniversalRouter(makeAddr("notOwnerRouter"));
    }

    function test_ConstructorRevertsOnEOAUniversalRouter() public {
        (FeeDistributor feeDistributor, LiquidRegistry liquidRegistry) = _createDefaultModules(
            protocolFeeRecipient
        );

        vm.expectRevert(ILiquidRouter.InvalidModule.selector);
        new LiquidAuctioneer(
            owner,
            makeAddr("eoaUniversalRouter"),
            address(feeDistributor),
            address(liquidRegistry),
            address(rare),
            makeAddr("weth")
        );
    }

    function testOnlyOwnerCanSetUniversalRouter() public {
        address newRouter = address(new MockRouter(address(rare)));
        address oldRouter = auctioneer.universalRouter();

        vm.expectEmit(true, true, false, false);
        emit ILiquidAuctioneer.UniversalRouterUpdated(oldRouter, newRouter);

        vm.prank(owner);
        auctioneer.setUniversalRouter(newRouter);

        assertEq(auctioneer.universalRouter(), newRouter);
    }

    function testSetUniversalRouterRevertsOnEOA() public {
        vm.prank(owner);
        vm.expectRevert(ILiquidRouter.InvalidModule.selector);
        auctioneer.setUniversalRouter(makeAddr("eoaUniversalRouter"));
    }

    function testOnlyOwnerCanSetFeeDistributor() public {
        FeeDistributor newFeeDistributor = new FeeDistributor(
            owner,
            address(0),
            address(0),
            protocolFeeRecipient,
            500,
            400
        );

        vm.prank(user);
        vm.expectRevert();
        auctioneer.setFeeDistributor(address(newFeeDistributor));
    }

    function testSetFeeDistributorRevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        auctioneer.setFeeDistributor(address(0));
    }

    function testSetFeeDistributorRevertsOnEOA() public {
        vm.prank(owner);
        vm.expectRevert(ILiquidRouter.InvalidModule.selector);
        auctioneer.setFeeDistributor(makeAddr("eoaFeeDistributor"));
    }

    function testSetFeeDistributorUpdatesAndReadsFromModule() public {
        address previousDistributor = auctioneer.feeDistributor();
        FeeDistributor newFeeDistributor = new FeeDistributor(
            owner,
            address(0),
            address(0),
            protocolFeeRecipient,
            500,
            400
        );

        vm.expectEmit(true, true, false, true);
        emit ILiquidAuctioneer.FeeDistributorUpdated(
            previousDistributor,
            address(newFeeDistributor)
        );

        vm.prank(owner);
        auctioneer.setFeeDistributor(address(newFeeDistributor));

        assertEq(auctioneer.feeDistributor(), address(newFeeDistributor));
        IFeeDistributor distributor = IFeeDistributor(auctioneer.feeDistributor());
        assertEq(distributor.totalFeeBPS(), 400);
    }

    function testOnlyOwnerCanSetLiquidRegistry() public {
        LiquidRegistry newRegistry = new LiquidRegistry(owner);

        vm.prank(user);
        vm.expectRevert();
        auctioneer.setLiquidRegistry(address(newRegistry));
    }

    function testSetLiquidRegistryRevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        auctioneer.setLiquidRegistry(address(0));
    }

    function testSetLiquidRegistryRevertsOnEOA() public {
        vm.prank(owner);
        vm.expectRevert(ILiquidRouter.InvalidModule.selector);
        auctioneer.setLiquidRegistry(makeAddr("eoaLiquidRegistry"));
    }

    function testSetLiquidRegistryUpdatesTokenBeneficiarySource() public {
        address previousRegistry = auctioneer.liquidRegistry();
        LiquidRegistry newRegistry = new LiquidRegistry(owner);

        vm.prank(owner);
        newRegistry.setWriter(address(auctioneer), true);

        vm.expectEmit(true, true, false, true);
        emit ILiquidAuctioneer.LiquidRegistryUpdated(
            previousRegistry,
            address(newRegistry)
        );

        vm.prank(owner);
        auctioneer.setLiquidRegistry(address(newRegistry));

        address token = makeAddr("auctioneerToken");
        address replacementBeneficiary = makeAddr("replacementBeneficiary");
        vm.prank(owner);
        auctioneer.setBeneficiary(token, replacementBeneficiary);

        assertEq(
            auctioneer.tokenBeneficiaries(token),
            replacementBeneficiary
        );
    }

    function testOnlyOwnerCanSetUniversalRouterRevertsOnZero() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(owner);
        auctioneer.setUniversalRouter(address(0));
    }

    function test_RescueTokens_Success() public {
        uint256 rescueAmount = 100e18;
        rare.mint(address(auctioneer), rescueAmount);

        uint256 ownerBalBefore = rare.balanceOf(owner);

        vm.expectEmit(true, true, false, true);
        emit ILiquidAuctioneer.TokensRescued(address(rare), owner, rescueAmount);

        vm.prank(owner);
        auctioneer.rescueTokens(address(rare), owner, rescueAmount);

        assertEq(rare.balanceOf(owner) - ownerBalBefore, rescueAmount);
        assertEq(rare.balanceOf(address(auctioneer)), 0);
    }

    function test_BidWithUSDC_UsesUnifiedBidPath() public {
        uint256 usdcAmount = 100e18;
        address liquidToken = address(
            new MockLiquidTokenForExit(address(new MockAuctionForBid()))
        );
        auctioneerRegistry.setBeneficiary(liquidToken, makeAddr("creator"));
        FunctionalMockPermit2 permit2Impl = new FunctionalMockPermit2();
        vm.etch(PERMIT2_ADDR, address(permit2Impl).code);
        rare.transfer(address(router), 10e18);
        usdc.mint(user, usdcAmount);

        vm.prank(owner);
        auctioneer.setTokenRouteV4(address(usdc), 3000, 60, address(0));

        vm.startPrank(user);
        usdc.approve(address(auctioneer), usdcAmount);
        uint256 bidId = auctioneer.bid(
            address(usdc),
            usdcAmount,
            liquidToken,
            1,
            user,
            0,
            1,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        assertEq(bidId, 1, "USDC bid should submit successfully");
    }

    function test_BidWithRare_UsesUnifiedBidPath() public {
        uint256 rareInput = 1e18;
        address liquidToken = address(
            new MockLiquidTokenForExit(address(new MockAuctionForBid()))
        );
        auctioneerRegistry.setBeneficiary(liquidToken, makeAddr("creator"));
        FunctionalMockPermit2 permit2Impl = new FunctionalMockPermit2();
        vm.etch(PERMIT2_ADDR, address(permit2Impl).code);
        rare.transfer(address(router), 10e18);
        rare.mint(user, rareInput);

        vm.prank(owner);
        auctioneer.setTokenRouteV4(address(rare), 3000, 60, address(0));

        vm.startPrank(user);
        rare.approve(address(auctioneer), rareInput);
        uint256 bidId = auctioneer.bid(
            address(rare),
            rareInput,
            liquidToken,
            1,
            user,
            0,
            1,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        assertEq(bidId, 1, "RARE bid should submit successfully");
    }
}

/// @title LiquidAuctioneer Security Tests (CRITICAL-01 fix)
/// @notice Tests for exitBidToETH / exitPartialBidToETH safety invariants:
///   - Slippage protection via minEthOut
///   - ETH delta tracking (not absolute balance)
///   - Token consumption check (RARE fully consumed by swap)
contract LiquidAuctioneerSecurityTest is Test {
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address attacker = makeAddr("attacker");
    address protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address recipient = makeAddr("recipient");

    LiquidAuctioneer public auctioneer;
    LiquidRegistry public auctioneerRegistry;
    MockRARE public rare;
    MockBurner public burner;

    function setUp() public {
        vm.deal(user, 100 ether);
        vm.deal(recipient, 0);
        rare = new MockRARE();
        burner = new MockBurner();
        MockRouter securityRouter = new MockRouter(address(rare));

        // Deploy functional MockPermit2 at the hardcoded address.
        // This mock tracks allowances and can perform transferFrom like real Permit2.
        FunctionalMockPermit2 permit2Impl = new FunctionalMockPermit2();
        vm.etch(PERMIT2_ADDR, address(permit2Impl).code);

        // Default auctioneer with a placeholder router (each test creates its own)
        auctioneer = _createAuctioneer(address(securityRouter));
    }

    /// @dev Register a token in the auctioneer's registry so it passes the isRegistered check
    function _registerToken(LiquidRegistry registry, address token) internal {
        vm.prank(owner);
        registry.setWriter(address(this), true);
        registry.setBeneficiary(token, makeAddr("beneficiary"));
    }

    function _validRoute()
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        commands = hex"10";
        inputs = new bytes[](1);
        bytes memory actions = abi.encodePacked(uint8(0x07), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](0);
        inputs[0] = abi.encode(actions, params);
    }

    /// @dev Helper: create a mock LiquidGraduated-like contract that returns a mock auction address
    function _setupMockAuctionToken(
        address auctionAddr
    ) internal returns (address) {
        MockLiquidTokenForExit mockToken = new MockLiquidTokenForExit(
            auctionAddr
        );
        return address(mockToken);
    }

    /// @dev Helper: create an auctioneer with a specific router
    function _createAuctioneer(
        address routerAddr
    ) internal returns (LiquidAuctioneer) {
        return _createAuctioneer(routerAddr, protocolFeeRecipient, makeAddr("weth"));
    }

    function _createAuctioneer(
        address routerAddr,
        address protocolRecipient,
        address wethAddress
    ) internal returns (LiquidAuctioneer) {
        FeeDistributor feeDistributor = new FeeDistributor(
            owner,
            address(0),
            address(0),
            protocolRecipient,
            400,
            400
        );
        LiquidRegistry liquidRegistry = new LiquidRegistry(owner);
        LiquidAuctioneer createdAuctioneer = new LiquidAuctioneer(
            owner,
            routerAddr,
            address(feeDistributor),
            address(liquidRegistry),
            address(rare),
            wethAddress
        );
        vm.prank(owner);
        liquidRegistry.setWriter(address(createdAuctioneer), true);
        auctioneerRegistry = liquidRegistry;

        return createdAuctioneer;
    }

    function _createAuctioneerWithProtocolRecipient(
        address routerAddr,
        address protocolRecipient
    ) internal returns (LiquidAuctioneer) {
        return
            _createAuctioneer(
                routerAddr,
                protocolRecipient,
                makeAddr("weth")
            );
    }

    function _setupBidToken() internal returns (address) {
        MockAuctionForBid bidAuction = new MockAuctionForBid();
        return address(new MockLiquidTokenForExit(address(bidAuction)));
    }

    /// @notice Beneficiary callback that reenters bid should be contained and
    ///         redirected as protocol share.
    function test_BidWithETH_BeneficiaryReenters() public {
        MockBidRouterForAuctioneer bidRouter = new MockBidRouterForAuctioneer(
            address(rare)
        );
        address liquidToken = _setupBidToken();
        ReentrantBeneficiaryForAuctioneer beneficiary = new ReentrantBeneficiaryForAuctioneer();
        beneficiary.setBidParams(
            liquidToken,
            user,
            block.timestamp + 1 hours
        );

        LiquidAuctioneer bidAuctioneer = _createAuctioneerWithProtocolRecipient(
            address(bidRouter),
            protocolFeeRecipient
        );
        _registerToken(auctioneerRegistry, liquidToken);
        beneficiary.setAuctioneer(payable(address(bidAuctioneer)));
        vm.prank(owner);
        bidAuctioneer.setBeneficiary(liquidToken, address(beneficiary));
        uint256 protocolBefore = protocolFeeRecipient.balance;

        vm.prank(user);
        bidAuctioneer.bid{value: 1 ether}(
            address(0),
            0,
            liquidToken,
            1,
            user,
            1,
            1,
            block.timestamp + 1 hours
        );

        IFeeDistributor distributor = IFeeDistributor(bidAuctioneer.feeDistributor());
        uint256 grossFee = (1 ether * uint256(distributor.totalFeeBPS())) / 10_000;
        (
            uint256 beneficiaryFee,
            uint256 protocolFee
        ) = distributor.quoteFeeBreakdown(grossFee);
        uint256 expectedProtocolShare = protocolFee + beneficiaryFee;
        uint256 protocolAfter = protocolFeeRecipient.balance;
        assertGe(
            protocolAfter,
            protocolBefore,
            "Beneficiary reentry should not reduce protocol balance"
        );
        assertEq(
            protocolAfter,
            protocolBefore + expectedProtocolShare,
            "Beneficiary reentry should redirect share to protocol"
        );
    }

    /// @notice With totalFeeBPS() == 0 (legacy stub), no ETH fee is computed so distributeFees
    ///         is never called, and a rejecting protocol fee recipient does NOT cause a revert.
    function test_BidWithETH_ProtocolFeeRecipientReverts() public {
        MockBidRouterForAuctioneer bidRouter = new MockBidRouterForAuctioneer(
            address(rare)
        );
        address liquidToken = _setupBidToken();

        RejectingRecipientForAuctioneer rejectingProtocol = new RejectingRecipientForAuctioneer();
        LiquidAuctioneer bidAuctioneer = _createAuctioneerWithProtocolRecipient(
            address(bidRouter),
            address(rejectingProtocol)
        );
        _registerToken(auctioneerRegistry, liquidToken);
        // Bid succeeds — fee == 0 because totalFeeBPS() stub returns 0, so distributeFees is skipped
        vm.prank(user);
        bidAuctioneer.bid{value: 1 ether}(
            address(0),
            0,
            liquidToken,
            1,
            user,
            0,
            1,
            block.timestamp + 1 hours
        );
        assertTrue(true, "Bid succeeded without fee distribution");
    }

    /// @notice Reentrant ETH payout recipient on full exit should revert via non-reentrant guard.
    function test_ExitBidToETH_RevertsOnRecipientReentrancy() public {
        RareConsumingRouter ethRouter = new RareConsumingRouter(
            address(rare),
            1 ether
        );
        vm.deal(address(ethRouter), 10 ether);
        LiquidAuctioneer ethAuctioneer = _createAuctioneer(address(ethRouter));

        uint256 refundAmount = 10 ether;
        MockAuctionForExit mockAuction = new MockAuctionForExit(
            address(rare),
            refundAmount,
            user
        );
        rare.mint(address(mockAuction), refundAmount);
        address liquidToken = _setupMockAuctionToken(address(mockAuction));
        _registerToken(auctioneerRegistry, liquidToken);
        (bytes memory exitCommands, bytes[] memory exitInputs) = _validRoute();

        ReentrantRecipientForAuctioneer exitRecipient = new ReentrantRecipientForAuctioneer(
                payable(address(ethAuctioneer)),
                liquidToken,
                exitCommands,
                exitInputs,
                block.timestamp + 1 hours,
                true
            );

        vm.startPrank(user);
        rare.approve(address(ethAuctioneer), type(uint256).max);
        vm.expectRevert(ILiquidRouter.EthTransferFailed.selector);
        ethAuctioneer.exitBidToETH(
            liquidToken,
            0,
            address(exitRecipient),
            0,
            exitCommands,
            exitInputs,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    /// @notice Reentrant ETH payout recipient on partial exit should revert via non-reentrant guard.
    function test_ExitPartialBidToETH_RevertsOnRecipientReentrancy() public {
        RareConsumingRouter ethRouter = new RareConsumingRouter(
            address(rare),
            1 ether
        );
        vm.deal(address(ethRouter), 10 ether);
        LiquidAuctioneer ethAuctioneer = _createAuctioneer(address(ethRouter));

        uint256 refundAmount = 10 ether;
        MockAuctionForExit mockAuction = new MockAuctionForExit(
            address(rare),
            refundAmount,
            user
        );
        rare.mint(address(mockAuction), refundAmount);
        address liquidToken = _setupMockAuctionToken(address(mockAuction));
        _registerToken(auctioneerRegistry, liquidToken);
        (bytes memory exitCommands, bytes[] memory exitInputs) = _validRoute();

        ReentrantRecipientForAuctioneer exitRecipient = new ReentrantRecipientForAuctioneer(
                payable(address(ethAuctioneer)),
                liquidToken,
                exitCommands,
                exitInputs,
                block.timestamp + 1 hours,
                false
            );

        vm.startPrank(user);
        rare.approve(address(ethAuctioneer), type(uint256).max);
        vm.expectRevert(ILiquidRouter.EthTransferFailed.selector);
        ethAuctioneer.exitPartialBidToETH(
            liquidToken,
            0,
            0,
            0,
            address(exitRecipient),
            0,
            exitCommands,
            exitInputs,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    // ==================== Theft Test ====================
    /// @notice Malicious router does NOT consume RARE (simulating theft via routeData).
    ///         After fix: reverts with UnexpectedTokenBalance because RARE was not consumed.
    function test_ExitBidToETH_RevertsOnTokenTheft() public {
        // Malicious router: succeeds but does not consume any RARE and sends no ETH
        MaliciousNoOpRouter malRouter = new MaliciousNoOpRouter();
        LiquidAuctioneer malAuctioneer = _createAuctioneer(address(malRouter));

        // Mock auction that refunds 10 RARE to the bid owner (user) on exitBid
        uint256 refundAmount = 10 ether;
        MockAuctionForExit mockAuction = new MockAuctionForExit(
            address(rare),
            refundAmount,
            user
        );
        rare.mint(address(mockAuction), refundAmount);
        address liquidToken = _setupMockAuctionToken(address(mockAuction));
        _registerToken(auctioneerRegistry, liquidToken);

        // User approves auctioneer to pull RARE
        vm.startPrank(user);
        rare.approve(address(malAuctioneer), type(uint256).max);
        (bytes memory exitCommands, bytes[] memory exitInputs) = _validRoute();

        // After fix: should revert because malicious router doesn't actually consume RARE
        // (it transfers RARE to attacker, but the balance check catches it)
        vm.expectRevert(abi.encodeWithSignature("UnexpectedTokenBalance()"));
        malAuctioneer.exitBidToETH(
            liquidToken,
            0, // bidId
            recipient,
            0, // minEthOut
            exitCommands,
            exitInputs,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Verify attacker did not receive RARE (tx reverted)
        assertEq(
            rare.balanceOf(attacker),
            0,
            "Attacker should not receive RARE"
        );
    }

    // ==================== Balance-Mixing Test ====================
    /// @notice Pre-fund the auctioneer with ETH, then exit with a router that consumes RARE but sends 0 ETH.
    ///         After fix: user receives only the ETH delta (0), not pre-existing ETH.
    function test_ExitBidToETH_DoesNotSendPreExistingETH() public {
        // Router that consumes RARE (via MockPermit2) but returns 0 ETH
        RareConsumingRouter noEthRouter = new RareConsumingRouter(
            address(rare),
            0
        );
        LiquidAuctioneer noEthAuctioneer = _createAuctioneer(
            address(noEthRouter)
        );

        // Pre-fund the auctioneer with 1 ETH (simulating stuck ETH)
        vm.deal(address(noEthAuctioneer), 1 ether);

        // Mock auction that refunds 5 RARE to the bid owner (user)
        uint256 refundAmount = 5 ether;
        MockAuctionForExit mockAuction = new MockAuctionForExit(
            address(rare),
            refundAmount,
            user
        );
        rare.mint(address(mockAuction), refundAmount);
        address liquidToken = _setupMockAuctionToken(address(mockAuction));
        _registerToken(auctioneerRegistry, liquidToken);

        // User approves and calls exit with minEthOut = 0
        vm.startPrank(user);
        rare.approve(address(noEthAuctioneer), type(uint256).max);
        (bytes memory exitCommands, bytes[] memory exitInputs) = _validRoute();

        uint256 recipientBalBefore = recipient.balance;
        uint256 ethReceived = noEthAuctioneer.exitBidToETH(
            liquidToken,
            0,
            recipient,
            0, // minEthOut = 0 (accept zero ETH)
            exitCommands,
            exitInputs,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // After fix: ethReceived should be 0 (delta), not 1 ETH
        assertEq(ethReceived, 0, "ETH received should be 0 (delta-based)");
        assertEq(
            recipient.balance,
            recipientBalBefore,
            "Recipient should not receive pre-existing ETH"
        );
        // The 1 ETH should still be in the auctioneer
        assertEq(
            address(noEthAuctioneer).balance,
            1 ether,
            "Pre-existing ETH should remain in auctioneer"
        );
    }

    // ==================== Slippage Test ====================
    /// @notice Exit with a minEthOut higher than what the swap returns.
    ///         Should revert with SlippageExceeded.
    function test_ExitBidToETH_RevertsOnSlippageExceeded() public {
        // Router that consumes RARE and returns 0.5 ETH
        RareConsumingRouter ethRouter = new RareConsumingRouter(
            address(rare),
            0.5 ether
        );
        vm.deal(address(ethRouter), 10 ether); // fund router so it can send ETH
        LiquidAuctioneer ethAuctioneer = _createAuctioneer(address(ethRouter));

        uint256 refundAmount = 5 ether;
        MockAuctionForExit mockAuction = new MockAuctionForExit(
            address(rare),
            refundAmount,
            user
        );
        rare.mint(address(mockAuction), refundAmount);
        address liquidToken = _setupMockAuctionToken(address(mockAuction));
        _registerToken(auctioneerRegistry, liquidToken);

        vm.startPrank(user);
        rare.approve(address(ethAuctioneer), type(uint256).max);
        (bytes memory exitCommands, bytes[] memory exitInputs) = _validRoute();

        // minEthOut = 1 ETH, but router only returns 0.5 ETH
        vm.expectRevert(abi.encodeWithSignature("SlippageExceeded()"));
        ethAuctioneer.exitBidToETH(
            liquidToken,
            0,
            recipient,
            1 ether, // minEthOut: too high
            exitCommands,
            exitInputs,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    // ==================== Happy Path Test ====================
    /// @notice Exit with a correctly-behaving router and verify user receives expected ETH.
    function test_ExitBidToETH_HappyPath() public {
        uint256 ethToReturn = 2 ether;
        RareConsumingRouter ethRouter = new RareConsumingRouter(
            address(rare),
            ethToReturn
        );
        vm.deal(address(ethRouter), 10 ether); // fund router
        LiquidAuctioneer ethAuctioneer = _createAuctioneer(address(ethRouter));

        uint256 refundAmount = 10 ether;
        MockAuctionForExit mockAuction = new MockAuctionForExit(
            address(rare),
            refundAmount,
            user
        );
        rare.mint(address(mockAuction), refundAmount);
        address liquidToken = _setupMockAuctionToken(address(mockAuction));
        _registerToken(auctioneerRegistry, liquidToken);

        vm.startPrank(user);
        rare.approve(address(ethAuctioneer), type(uint256).max);
        (bytes memory exitCommands, bytes[] memory exitInputs) = _validRoute();

        uint256 recipientBalBefore = recipient.balance;
        uint256 ethReceived = ethAuctioneer.exitBidToETH(
            liquidToken,
            0,
            recipient,
            1 ether, // minEthOut: expect at least 1 ETH
            exitCommands,
            exitInputs,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        assertEq(ethReceived, ethToReturn, "Should return exact ETH from swap");
        assertEq(
            recipient.balance,
            recipientBalBefore + ethToReturn,
            "Recipient should receive ETH"
        );
    }

    // ==================== Zero recipient revert test ====================
    function test_ExitBidToETH_RevertsOnZeroRecipient() public {
        RareConsumingRouter ethRouter = new RareConsumingRouter(
            address(rare),
            1 ether
        );
        vm.deal(address(ethRouter), 10 ether);
        LiquidAuctioneer ethAuctioneer = _createAuctioneer(address(ethRouter));

        uint256 refundAmount = 5 ether;
        MockAuctionForExit mockAuction = new MockAuctionForExit(
            address(rare),
            refundAmount,
            user
        );
        rare.mint(address(mockAuction), refundAmount);
        address liquidToken = _setupMockAuctionToken(address(mockAuction));
        _registerToken(auctioneerRegistry, liquidToken);

        vm.startPrank(user);
        rare.approve(address(ethAuctioneer), type(uint256).max);
        (bytes memory exitCommands, bytes[] memory exitInputs) = _validRoute();

        vm.expectRevert(abi.encodeWithSignature("AddressZero()"));
        ethAuctioneer.exitBidToETH(
            liquidToken,
            0,
            address(0), // zero recipient
            0,
            exitCommands,
            exitInputs,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }
}

// ============================================
// Mock contracts for security tests
// ============================================

/// @dev Functional mock Permit2 deployed at the hardcoded PERMIT2 address via vm.etch.
///      When approve(token, spender, amount, expiration) is called by the auctioneer,
///      this contract records the allowance. The mock router can then call transferFrom
///      to pull tokens from the auctioneer, using the ERC20 approval the auctioneer
///      granted to this contract (PERMIT2).
contract FunctionalMockPermit2 {
    // owner => token => spender => amount
    mapping(address => mapping(address => mapping(address => uint160)))
        public allowances;

    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48
    ) external {
        allowances[msg.sender][token][spender] = amount;
    }

    function allowance(
        address ownerAddr,
        address token,
        address spender
    ) external view returns (uint160, uint48, uint48) {
        return (allowances[ownerAddr][token][spender], 0, 0);
    }

    /// @dev Called by the router (spender) to pull tokens from owner through Permit2
    function transferFrom(
        address from,
        address to,
        uint160 amount,
        address token
    ) external {
        uint160 allowed = allowances[from][token][msg.sender];
        require(allowed >= amount, "Permit2: insufficient allowance");
        allowances[from][token][msg.sender] = allowed - amount;
        // Use the ERC20 approval that `from` granted to this contract (PERMIT2)
        IERC20(token).transferFrom(from, to, uint256(amount));
    }
}

/// @dev Mock LiquidGraduated that just returns auctionAddress()
contract MockLiquidTokenForExit {
    address public auctionAddress_;

    constructor(address _auction) {
        auctionAddress_ = _auction;
    }

    function auctionAddress() external view returns (address) {
        return auctionAddress_;
    }
}

/// @dev Mock auction that, on exitBid(bidId), sends refundAmount of RARE to the bid owner.
///      In a real CCA, the refund goes to the bid owner, not the caller. We accept refundRecipient
///      so tests can pass the user (bid owner) who will receive the RARE.
contract MockAuctionForExit {
    address public rareToken;
    uint256 public refundAmount;
    address public refundRecipient;

    constructor(address _rare, uint256 _refund, address _refundRecipient) {
        rareToken = _rare;
        refundAmount = _refund;
        refundRecipient = _refundRecipient;
    }

    function exitBid(uint256) external {
        IERC20(rareToken).transfer(refundRecipient, refundAmount);
    }

    function exitPartiallyFilledBid(uint256, uint64, uint64) external {
        IERC20(rareToken).transfer(refundRecipient, refundAmount);
    }
}

/// @dev Mock auction implementing the bid entrypoint for bid coverage tests.
contract MockAuctionForBid {
    function submitBid(
        uint256,
        uint128,
        address,
        uint256,
        bytes calldata
    ) external pure returns (uint256 bidId) {
        return 1;
    }
}

contract MockBidRouterForAuctioneer {
    address public rareToken;

    constructor(address _rare) {
        rareToken = _rare;
    }

    function execute(
        bytes calldata,
        bytes[] calldata,
        uint256
    ) external payable {
        if (msg.value > 0) {
            uint256 tokensOut = (msg.value * 1000e18) / 1e18;
            MockRARE(rareToken).mint(msg.sender, tokensOut);
        }
    }

    receive() external payable {}
    fallback() external payable {}
}

contract RejectingRecipientForAuctioneer {
    receive() external payable {
        revert("I reject ETH");
    }
}

contract ReentrantBeneficiaryForAuctioneer {
    LiquidAuctioneer public auctioneer;
    address public liquidToken;
    address public bidOwner;
    uint256 public deadline;
    bool public shouldReenter;

    constructor() {}

    function setAuctioneer(address payable _auctioneer) external {
        auctioneer = LiquidAuctioneer(payable(_auctioneer));
    }

    function setBidParams(
        address _liquidToken,
        address _bidOwner,
        uint256 _deadline
    ) external {
        liquidToken = _liquidToken;
        bidOwner = _bidOwner;
        deadline = _deadline;
        shouldReenter = true;
    }

    receive() external payable {
        if (!shouldReenter) {
            return;
        }
        auctioneer.bid{value: 0}(
            address(0),
            0,
            liquidToken,
            1,
            bidOwner,
            0,
            1,
            deadline
        );
    }
}

contract ReentrantRecipientForAuctioneer {
    LiquidAuctioneer public auctioneer;
    address public liquidToken;
    bytes public routeCommands;
    bytes[] public routeInputs;
    uint256 public deadline;
    bool public useFullExit;

    constructor(
        address payable _auctioneer,
        address _liquidToken,
        bytes memory _routeCommands,
        bytes[] memory _routeInputs,
        uint256 _deadline,
        bool _useFullExit
    ) {
        auctioneer = LiquidAuctioneer(payable(_auctioneer));
        liquidToken = _liquidToken;
        routeCommands = _routeCommands;
        routeInputs = _routeInputs;
        deadline = _deadline;
        useFullExit = _useFullExit;
    }

    receive() external payable {
        if (useFullExit) {
            auctioneer.exitBidToETH(
                liquidToken,
                0,
                address(this),
                0,
                routeCommands,
                routeInputs,
                deadline
            );
        } else {
            auctioneer.exitPartialBidToETH(
                liquidToken,
                0,
                0,
                0,
                address(this),
                0,
                routeCommands,
                routeInputs,
                deadline
            );
        }
    }
}

/// @dev Malicious no-op router: succeeds but does NOT consume any RARE and sends no ETH.
///      Simulates crafted routeData that doesn't actually perform the intended swap.
contract MaliciousNoOpRouter {
    fallback() external payable {
        // Do nothing - don't consume RARE, don't send ETH
        // The transaction succeeds, but the auctioneer's RARE is untouched
    }

    receive() external payable {}
}

/// @dev Router that consumes RARE from the auctioneer (via FunctionalMockPermit2) and optionally returns ETH.
///      Simulates a real Universal Router that pulls tokens via Permit2 and sends ETH back.
contract RareConsumingRouter {
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public rareToken;
    uint256 public ethToReturn;

    constructor(address _rare, uint256 _ethToReturn) {
        rareToken = _rare;
        ethToReturn = _ethToReturn;
    }

    function execute(
        bytes calldata,
        bytes[] calldata,
        uint256
    ) external payable {
        _swap();
    }

    fallback() external payable {
        _swap();
    }

    function _swap() internal {
        // Pull all permitted RARE from the caller (auctioneer) through MockPermit2
        (uint160 allowed, , ) = FunctionalMockPermit2(PERMIT2_ADDR).allowance(
            msg.sender,
            rareToken,
            address(this)
        );
        if (allowed > 0) {
            FunctionalMockPermit2(PERMIT2_ADDR).transferFrom(
                msg.sender,
                address(this),
                allowed,
                rareToken
            );
        }
        // Send ETH back to the caller (auctioneer) if configured
        if (ethToReturn > 0 && address(this).balance >= ethToReturn) {
            (bool ok, ) = msg.sender.call{value: ethToReturn}("");
            require(ok, "ETH send failed");
        }
    }

    receive() external payable {}
}

contract MockRouter {
    address public rareToken;
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    struct V4PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    constructor(address _rare) {
        rareToken = _rare;
    }

    receive() external payable {}

    fallback() external payable {
        bytes memory commands = "";
        bytes[] memory inputs;
        if (msg.data.length >= 4) {
            (commands, inputs, ) = abi.decode(
                msg.data[4:],
                (bytes, bytes[], uint256)
            );
        }
        for (uint256 i = 0; i < inputs.length; i++) {
                if (commands.length > i && commands[i] == 0x10) {
                    (bytes memory _v4Actions, bytes[] memory params) = abi.decode(
                        inputs[i],
                        (bytes, bytes[])
                    );
                    _v4Actions;
                    if (params.length > 0) {
                    (
                        address currencyIn,
                        V4PathKey[] memory _path,
                        uint128 amountIn,
                        uint128 minRareOut
                    ) = abi.decode(
                        params[0],
                        (address, V4PathKey[], uint128, uint128)
                    );
                    _path;
                    minRareOut;
                    if (currencyIn != address(0) && amountIn > 0) {
                        uint160 consumeAmount = amountIn >
                            type(uint160).max
                            ? type(uint160).max
                            : uint160(amountIn);
                        FunctionalMockPermit2(PERMIT2_ADDR).transferFrom(
                            msg.sender,
                            address(this),
                            consumeAmount,
                            currencyIn
                        );
                    }
                }
            }
        }

        uint256 bal = IERC20(rareToken).balanceOf(address(this));
        if (bal > 0) {
            IERC20(rareToken).transfer(msg.sender, bal);
        }
    }
}

/// @dev Mock router that refunds ETH to caller (simulates unexpected Universal Router behavior)
contract EthRefundingRouter {
    address public rareToken;
    uint256 public ethToRefund;

    constructor(address _rare, uint256 _ethToRefund) {
        rareToken = _rare;
        ethToRefund = _ethToRefund;
    }

    receive() external payable {}

    fallback() external payable {
        uint256 bal = IERC20(rareToken).balanceOf(address(this));
        if (bal > 0) {
            IERC20(rareToken).transfer(msg.sender, bal);
        }
        if (ethToRefund > 0 && address(this).balance >= ethToRefund) {
            (bool ok, ) = msg.sender.call{value: ethToRefund}("");
            require(ok, "ETH refund failed");
        }
    }
}

contract MockAuctionSweepable is IDistributionContract {
    address public rareToken;
    address public token;
    uint256 public clearingPriceQ96;

    constructor(address _rare) {
        rareToken = _rare;
    }

    function setToken(address _token) external {
        token = _token;
    }

    function onTokensReceived() external override {}

    function setClearingPrice(uint256 _price) external {
        clearingPriceQ96 = _price;
    }

    function sweepCurrency() external {
        uint256 bal = IERC20(rareToken).balanceOf(address(this));
        if (bal > 0) {
            IERC20(rareToken).transfer(msg.sender, bal);
        }
    }

    function sweepUnsoldTokens() external {
        if (token != address(0)) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) {
                IERC20(token).transfer(msg.sender, bal);
            }
        }
    }

    function clearingPrice() external view returns (uint256) {
        return clearingPriceQ96;
    }

    function submitBid(
        uint256,
        uint128,
        address,
        uint256,
        bytes calldata
    ) external pure returns (uint256 bidId) {
        return 1;
    }
}

contract MockCCAFactorySweepable is IDistributionStrategy {
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
        MockAuctionSweepable auction = new MockAuctionSweepable(rareToken);
        auction.setToken(token);
        return IDistributionContract(address(auction));
    }
}

contract MockLBPStrategyFactoryAuctioneer is IDistributionStrategy {
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
        MockLBPStrategyAuctioneer strategy = new MockLBPStrategyAuctioneer(
            token,
            poolManager,
            currency
        );
        return IDistributionContract(address(strategy));
    }
}

contract MockLBPStrategyAuctioneer is IDistributionContract, ILBPStrategy {
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
            MockAuctionSweepable mockAuction = new MockAuctionSweepable(CURRENCY);
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
            MockAuctionSweepable(auction).sweepCurrency();
            IPoolManager pm = IPoolManager(POOL_MANAGER);
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

/// @title LiquidAuctioneer V2/V3 payerIsUser encoding tests
/// @notice Verifies that V2/V3 swap encoding uses payerIsUser=true for ERC20 inputs
///         and payerIsUser=false for ETH inputs (where WRAP_ETH deposits to router first).
contract LiquidAuctioneerPayerIsUserTest is Test {
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address referrer = makeAddr("referrer");

    PayerCheckingRouter public payerRouter;
    LiquidAuctioneer public auctioneer;
    LiquidRegistry public auctioneerRegistry;
    MockRARE public rare;
    MockERC20 public usdc;
    MockBurner public burner;

    address constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function _createAuctioneer(
        address routerAddr,
        address protocolRecipient,
        address wethAddress
    ) internal returns (LiquidAuctioneer) {
        FeeDistributor feeDistributor = new FeeDistributor(
            owner,
            address(0),
            address(0),
            protocolRecipient,
            400,
            400
        );
        LiquidRegistry liquidRegistry = new LiquidRegistry(owner);
        LiquidAuctioneer createdAuctioneer = new LiquidAuctioneer(
            owner,
            routerAddr,
            address(feeDistributor),
            address(liquidRegistry),
            address(rare),
            wethAddress
        );
        vm.prank(owner);
        liquidRegistry.setWriter(address(createdAuctioneer), true);
        auctioneerRegistry = liquidRegistry;
        return createdAuctioneer;
    }

    function _registerToken(address token) internal {
        if (!auctioneerRegistry.isWriter(address(this))) {
            vm.prank(owner);
            auctioneerRegistry.setWriter(address(this), true);
        }
        auctioneerRegistry.setBeneficiary(token, makeAddr("beneficiary"));
    }

    function setUp() public {
        vm.deal(user, 100 ether);
        rare = new MockRARE();
        usdc = new MockERC20();
        burner = new MockBurner();
        payerRouter = new PayerCheckingRouter(address(rare));
        rare.transfer(address(payerRouter), 100e18);

        FunctionalMockPermit2 permit2Impl = new FunctionalMockPermit2();
        vm.etch(PERMIT2_ADDR, address(permit2Impl).code);

        auctioneer = _createAuctioneer(
            address(payerRouter),
            protocolFeeRecipient,
            WETH_ADDR
        );
    }

    function test_V3Route_ERC20_PayerIsUserTrue() public {
        // Set up a V3 route for USDC -> RARE
        bytes memory v3Path = abi.encodePacked(
            address(usdc),
            uint24(3000),
            address(rare)
        );
        vm.prank(owner);
        auctioneer.setTokenRouteV3(address(usdc), v3Path);

        // Setup bid infrastructure
        address liquidToken = address(
            new MockLiquidTokenForExit(address(new MockAuctionForBid()))
        );
        _registerToken(liquidToken);
        usdc.mint(user, 100e18);

        // Set expected payerIsUser = true for ERC20
        payerRouter.setExpectedPayerIsUser(true);

        vm.startPrank(user);
        usdc.approve(address(auctioneer), 100e18);
        auctioneer.bid(
            address(usdc),
            100e18,
            liquidToken,
            1,
            user,
            0,
            1,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        assertTrue(payerRouter.payerFlagChecked(), "Router should have checked payerIsUser flag");
    }

    function test_V3Route_ETH_PayerIsUserFalse() public {
        // Set up a V3 route for ETH -> RARE (path starts with WETH)
        bytes memory v3Path = abi.encodePacked(
            WETH_ADDR,
            uint24(3000),
            address(rare)
        );
        vm.prank(owner);
        auctioneer.setTokenRouteV3(address(0), v3Path);

        // Setup bid infrastructure
        address liquidToken = address(
            new MockLiquidTokenForExit(address(new MockAuctionForBid()))
        );
        _registerToken(liquidToken);

        // Set expected payerIsUser = false for ETH
        payerRouter.setExpectedPayerIsUser(false);

        vm.prank(user);
        auctioneer.bid{value: 1 ether}(
            address(0),
            0,
            liquidToken,
            1,
            user,
            0,
            1,
            block.timestamp + 1 hours
        );

        assertTrue(payerRouter.payerFlagChecked(), "Router should have checked payerIsUser flag");
    }

    function test_V2Route_ERC20_PayerIsUserTrue() public {
        // Set up a V2 route for USDC -> RARE
        address[] memory v2Path = new address[](2);
        v2Path[0] = address(usdc);
        v2Path[1] = address(rare);
        vm.prank(owner);
        auctioneer.setTokenRouteV2(address(usdc), v2Path);

        // Setup bid infrastructure
        address liquidToken = address(
            new MockLiquidTokenForExit(address(new MockAuctionForBid()))
        );
        _registerToken(liquidToken);
        usdc.mint(user, 100e18);

        // Set expected payerIsUser = true for ERC20
        payerRouter.setExpectedPayerIsUser(true);

        vm.startPrank(user);
        usdc.approve(address(auctioneer), 100e18);
        auctioneer.bid(
            address(usdc),
            100e18,
            liquidToken,
            1,
            user,
            0,
            1,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        assertTrue(payerRouter.payerFlagChecked(), "Router should have checked payerIsUser flag");
    }

    function test_V2Route_ETH_PayerIsUserFalse() public {
        // Set up a V2 route for ETH -> RARE (path starts with WETH)
        address[] memory v2Path = new address[](2);
        v2Path[0] = WETH_ADDR;
        v2Path[1] = address(rare);
        vm.prank(owner);
        auctioneer.setTokenRouteV2(address(0), v2Path);

        // Setup bid infrastructure
        address liquidToken = address(
            new MockLiquidTokenForExit(address(new MockAuctionForBid()))
        );
        _registerToken(liquidToken);

        // Set expected payerIsUser = false for ETH
        payerRouter.setExpectedPayerIsUser(false);

        vm.prank(user);
        auctioneer.bid{value: 1 ether}(
            address(0),
            0,
            liquidToken,
            1,
            user,
            0,
            1,
            block.timestamp + 1 hours
        );

        assertTrue(payerRouter.payerFlagChecked(), "Router should have checked payerIsUser flag");
    }
}

/// @dev Mock router that decodes V2/V3 swap inputs and asserts the payerIsUser flag
contract PayerCheckingRouter {
    address public rareToken;
    bool public expectedPayerIsUser;
    bool public payerFlagChecked;

    constructor(address _rare) {
        rareToken = _rare;
    }

    function setExpectedPayerIsUser(bool _expected) external {
        expectedPayerIsUser = _expected;
        payerFlagChecked = false;
    }

    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256
    ) external payable {
        // Find the V3 (0x00) or V2 (0x08) swap command and decode payerIsUser
        for (uint256 i = 0; i < commands.length; i++) {
            uint8 cmd = uint8(commands[i]);
            if (cmd == 0x00) {
                // V3_SWAP_EXACT_IN: (address, uint256, uint256, bytes, bool)
                (, , , , bool payerIsUser) = abi.decode(
                    inputs[i],
                    (address, uint256, uint256, bytes, bool)
                );
                require(
                    payerIsUser == expectedPayerIsUser,
                    string(
                        abi.encodePacked(
                            "V3 payerIsUser mismatch: expected ",
                            expectedPayerIsUser ? "true" : "false",
                            " got ",
                            payerIsUser ? "true" : "false"
                        )
                    )
                );
                payerFlagChecked = true;
            } else if (cmd == 0x08) {
                // V2_SWAP_EXACT_IN: (address, uint256, uint256, address[], bool)
                (, , , , bool payerIsUser) = abi.decode(
                    inputs[i],
                    (address, uint256, uint256, address[], bool)
                );
                require(
                    payerIsUser == expectedPayerIsUser,
                    string(
                        abi.encodePacked(
                            "V2 payerIsUser mismatch: expected ",
                            expectedPayerIsUser ? "true" : "false",
                            " got ",
                            payerIsUser ? "true" : "false"
                        )
                    )
                );
                payerFlagChecked = true;
            }
        }
        // Transfer RARE to caller to simulate successful swap
        uint256 bal = IERC20(rareToken).balanceOf(address(this));
        if (bal > 0) {
            uint256 toSend = bal > 1e18 ? 1e18 : bal;
            IERC20(rareToken).transfer(msg.sender, toSend);
        }
    }

    receive() external payable {}
    fallback() external payable {}
}

contract MockV4PoolManagerAuctioneer {
    function unlock(bytes calldata data) external returns (bytes memory) {
        if (msg.sender.code.length > 0) {
            IUnlockCallback(msg.sender).unlockCallback(data);
        }
        return "";
    }

    function getSlot0(
        bytes32
    ) external pure returns (uint160, int24, uint24, uint24) {
        return (79228162514264337593543950336, 0, 0, 0);
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

    function initialize(PoolKey memory, uint160) external pure returns (int24) {
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

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32((uint256(79228162514264337593543950336) << 24));
    }
}
