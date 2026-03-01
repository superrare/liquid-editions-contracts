// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {FeeDistributor} from "liquid-editions/FeeDistributor.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// ============================================
// Mocks
// ============================================

/// @notice Minimal mock PoolManager for FeeDistributor tests.
///         Supports swap, sync, settle, and take.
contract MockPoolManagerForFD {
    struct TakeCall {
        Currency currency;
        address to;
        uint256 amount;
    }
    TakeCall[] public takeCalls;

    BalanceDelta public swapResult;
    uint256 public syncCount;
    uint256 public settleCount;

    // Slot0 mock: sqrtPriceX96 returned for any pool
    uint160 public mockSqrtPrice;

    function setSwapResult(BalanceDelta result) external {
        swapResult = result;
    }

    function setMockSqrtPrice(uint160 sqrtPrice) external {
        mockSqrtPrice = sqrtPrice;
    }

    // StateLibrary.getSlot0 reads slot0 directly from storage on the PoolManager.
    // We expose getSlot0 as an ordinary function for the mock so the test can call it.
    // FeeDistributor uses StateLibrary.getSlot0(poolManager, poolId) which calls
    // poolManager.extsload() under the hood.  We simulate this by implementing
    // extsload() to return our mocked value at any slot.
    function extsload(bytes32) external view returns (bytes32) {
        // Pack sqrtPriceX96 (uint160) into the low 160 bits of the slot — matches V4 slot0 layout
        return bytes32(uint256(mockSqrtPrice));
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory results) {
        results = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            results[i] = bytes32(uint256(mockSqrtPrice));
        }
    }

    function swap(PoolKey memory, IPoolManager.SwapParams memory, bytes calldata)
        external
        view
        returns (BalanceDelta)
    {
        return swapResult;
    }

    function take(Currency currency, address to, uint256 amount) external {
        takeCalls.push(TakeCall({currency: currency, to: to, amount: amount}));
    }

    function sync(Currency) external {
        syncCount++;
    }

    function settle() external payable returns (uint256) {
        settleCount++;
        return 0;
    }

    function takeCallCount() external view returns (uint256) {
        return takeCalls.length;
    }
}

/// @notice Minimal ERC20 mock for RARE token
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    address public lastTransferTo;
    uint256 public lastTransferAmount;
    bool public shouldFailTransfer;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (shouldFailTransfer) return false;
        lastTransferTo = to;
        lastTransferAmount = amount;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // ERC20 transferFrom needed for SafeERC20 in _distributeRare
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function setFailTransfer(bool fail) external {
        shouldFailTransfer = fail;
    }
}

/// @notice Minimal ILiquidRegistry mock
contract MockLiquidRegistry is ILiquidRegistry {
    mapping(address => address) public beneficiary;

    function setBeneficiary(address token, address bene) external override {
        beneficiary[token] = bene;
    }

    function removeBeneficiary(address token) external override {
        delete beneficiary[token];
    }

    function beneficiaryOf(address token) external view override returns (address) {
        return beneficiary[token];
    }

    function isRegistered(address token) external view override returns (bool) {
        return beneficiary[token] != address(0);
    }

    function setWriter(address, bool) external override {}

    function isWriter(address) external pure override returns (bool) {
        return true;
    }
}

// ============================================
// Test contract
// ============================================

contract FeeDistributorUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    FeeDistributor public distributor;
    MockPoolManagerForFD public poolManager;
    MockERC20 public rareToken;
    MockLiquidRegistry public registry;

    address owner             = makeAddr("owner");
    address protocolRecipient = makeAddr("protocolRecipient");
    address beneficiary       = makeAddr("beneficiary");
    address liquidToken       = makeAddr("liquidToken");
    address approvedHook      = makeAddr("approvedHook");
    address unauthorizedCaller = makeAddr("unauthorizedCaller");

    uint16 constant BENEFICIARY_SHARE_BPS = 5000; // 50%

    // A plausible sqrtPriceX96 (~0.0001 ETH per RARE, i.e. 1 RARE ≈ 0.0001 ETH)
    // sqrtPrice = sqrt(0.0001) * 2^96 ≈ 0.01 * 79228162514264337593543950336 ≈ 7.9e26
    uint160 constant MOCK_SQRT_PRICE = 7_922_816_251_426_433_759;

    // The RARE/ETH pool key used throughout tests:
    // currency0 = address(0) (native ETH), currency1 = rareToken
    PoolKey rareEthKey;

    function setUp() public {
        poolManager = new MockPoolManagerForFD();
        rareToken   = new MockERC20();
        registry    = new MockLiquidRegistry();

        distributor = new FeeDistributor(
            owner,
            address(poolManager),
            address(rareToken),
            protocolRecipient,
            BENEFICIARY_SHARE_BPS,
            400 // 4% total fee
        );

        rareEthKey = PoolKey({
            currency0: Currency.wrap(address(0)),       // native ETH
            currency1: Currency.wrap(address(rareToken)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(0))
        });

        registry.setBeneficiary(liquidToken, beneficiary);

        vm.startPrank(owner);
        distributor.setBeneficiaryRegistry(address(registry));
        distributor.setHookApproval(approvedHook, true);
        distributor.setRareEthPoolKey(rareEthKey);
        // Disable slippage bound so mock swap outputs pass without matching the mock sqrtPrice
        distributor.setMaxSlippageBps(10_000);
        vm.stopPrank();

        // Give RARE to distributor (simulating hook's take())
        rareToken.mint(address(distributor), 1000e18);
    }

    // ============================================
    // Helpers
    // ============================================

    /// Make the pool manager send ETH to distributor when take() is called
    function _dealEthToPoolManager(uint256 amount) internal {
        vm.deal(address(poolManager), amount);
    }

    // ============================================
    // Constructor validation
    // ============================================

    function test_constructor_RevertsOnZeroPoolManager() public {
        vm.expectRevert(IFeeDistributor.InvalidAddress.selector);
        new FeeDistributor(owner, address(0), address(rareToken), protocolRecipient, 5000, 400);
    }

    function test_constructor_RevertsOnZeroRareToken() public {
        vm.expectRevert(IFeeDistributor.InvalidAddress.selector);
        new FeeDistributor(owner, address(poolManager), address(0), protocolRecipient, 5000, 400);
    }

    function test_constructor_RevertsOnZeroProtocolRecipient() public {
        vm.expectRevert(IFeeDistributor.InvalidAddress.selector);
        new FeeDistributor(owner, address(poolManager), address(rareToken), address(0), 5000, 400);
    }

    function test_constructor_RevertsOnInvalidBeneficiaryShare() public {
        vm.expectRevert(IFeeDistributor.InvalidBeneficiaryShare.selector);
        new FeeDistributor(owner, address(poolManager), address(rareToken), protocolRecipient, 10_001, 400);
    }

    function test_constructor_DefaultsSet() public {
        FeeDistributor fresh = new FeeDistributor(
            owner, address(poolManager), address(rareToken), protocolRecipient, 5000, 400
        );
        assertEq(fresh.maxSlippageBps(), 100);
        assertTrue(fresh.conversionEnabled());
    }

    // ============================================
    // Access control: onlyHook
    // ============================================

    function test_notifyFee_RevertsForUnauthorizedCaller() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IFeeDistributor.UnauthorizedHook.selector, unauthorizedCaller));
        distributor.notifyFee(liquidToken, 1e18);
    }

    // ============================================
    // notifyFee: zero amount is no-op
    // ============================================

    function test_notifyFee_ZeroAmount_NoOp() public {
        vm.prank(approvedHook);
        distributor.notifyFee(liquidToken, 0);
        assertEq(poolManager.takeCallCount(), 0);
    }

    // ============================================
    // E1: Canonical path — fresh price → conversion succeeds
    // ============================================

    function test_notifyFee_FreshPrice_ConvertsToEth() public {
        poolManager.setMockSqrtPrice(MOCK_SQRT_PRICE);

        uint256 rareAmount = 1e18;
        uint256 ethOut     = 0.0001e18; // plausible ETH output

        // ETH is currency0 (index 0), RARE is token1 — zeroForOne = false (RARE→ETH means !rareIsToken0)
        // rareToken is currency1, so rareIsToken0 = false → ethDelta = amount0 (positive)
        poolManager.setSwapResult(toBalanceDelta(int128(uint128(ethOut)), -int128(uint128(rareAmount))));

        // The pool manager's take() just records calls — fund it with ETH so _sendEth works
        vm.deal(address(distributor), ethOut);

        vm.prank(approvedHook);
        vm.expectEmit(true, true, false, false);
        emit IFeeDistributor.FeeConvertedAndDistributed(
            liquidToken, beneficiary, rareAmount, ethOut, ethOut / 2, ethOut - ethOut / 2
        );
        distributor.notifyFee(liquidToken, rareAmount);

        // No FeeDistributedInRare should be emitted
        // (can't assert absence of an event in Foundry directly, but no RARE transfer to recipients)
        assertEq(rareToken.lastTransferTo(), address(poolManager)); // RARE went to PM settle
    }

    // ============================================
    // E2: Conversion disabled → fallback distributes RARE with split
    // ============================================

    function test_notifyFee_ConversionDisabled_DistributesRare_WithSplit() public {
        vm.prank(owner);
        distributor.setConversionEnabled(false);

        uint256 rareAmount = 1e18;
        uint256 rareBen    = rareAmount / 2;
        uint256 rareProt   = rareAmount - rareBen;

        vm.prank(approvedHook);
        vm.expectEmit(true, true, false, true);
        emit IFeeDistributor.FeeDistributedInRare(
            liquidToken, beneficiary, rareAmount, rareBen, rareProt, "CONVERSION_OFF"
        );
        distributor.notifyFee(liquidToken, rareAmount);

        assertEq(rareToken.balanceOf(beneficiary),       rareBen);
        assertEq(rareToken.balanceOf(protocolRecipient), rareProt);

        // No pool swap happened
        assertEq(poolManager.syncCount(), 0);
    }

    // ============================================
    // E2b: Zero spot price from slot0 → conversion attempted, mock swap returns (0,0) → CONVERT_FAIL
    // ============================================

    function test_notifyFee_ZeroSpotPrice_FallsBackToRare() public {
        // mockSqrtPrice defaults to 0 — conversion attempted but swap returns (0,0) → "NO_ETH_OUT" → CONVERT_FAIL
        uint256 rareAmount = 1e18;

        vm.prank(approvedHook);
        vm.expectEmit(true, true, false, false);
        emit IFeeDistributor.FeeDistributedInRare(
            liquidToken, beneficiary, rareAmount, 0, 0, "CONVERT_FAIL"
        );
        distributor.notifyFee(liquidToken, rareAmount);

        assertEq(poolManager.syncCount(), 0);
    }

    function test_notifyFee_UpdatedBeneficiaryConfig_TracksSettlementAndRecipientShares() public {
        poolManager.setMockSqrtPrice(MOCK_SQRT_PRICE);

        address beneficiaryTwo = makeAddr("beneficiaryTwo");
        uint256 protocolStart = protocolRecipient.balance;
        uint256 beneficiaryStart = beneficiary.balance;
        uint256 beneficiaryTwoStart = beneficiaryTwo.balance;

        // Initial beneficiary configured in setUp()
        uint256 rareAmountA = 1e18;
        uint256 ethOutA = 0.0001e18;
        poolManager.setSwapResult(toBalanceDelta(int128(uint128(ethOutA)), -int128(uint128(rareAmountA))));
        vm.deal(address(distributor), ethOutA);

        vm.prank(approvedHook);
        distributor.notifyFee(liquidToken, rareAmountA);

        uint256 expectedBenA = ethOutA / 2;
        uint256 expectedProtA = ethOutA - expectedBenA;
        assertEq(beneficiary.balance - beneficiaryStart, expectedBenA);
        assertEq(protocolRecipient.balance - protocolStart, expectedProtA);
        assertEq(poolManager.syncCount(), 1);
        assertEq(poolManager.settleCount(), 1);

        // Update beneficiary mid-lineage in registry
        registry.setBeneficiary(liquidToken, beneficiaryTwo);

        uint256 rareAmountB = 2e18;
        uint256 ethOutB = 0.0002e18;
        poolManager.setSwapResult(toBalanceDelta(int128(uint128(ethOutB)), -int128(uint128(rareAmountB))));
        vm.deal(address(distributor), ethOutB);

        vm.prank(approvedHook);
        distributor.notifyFee(liquidToken, rareAmountB);

        uint256 expectedBenB = ethOutB / 2;
        uint256 expectedProtB = ethOutB - expectedBenB;
        assertEq(beneficiary.balance - beneficiaryStart, expectedBenA);
        assertEq(beneficiaryTwo.balance - beneficiaryTwoStart, expectedBenB);
        assertEq(protocolRecipient.balance - protocolStart, expectedProtA + expectedProtB);
        assertEq(poolManager.syncCount(), 2);
        assertEq(poolManager.settleCount(), 2);

        // Remove beneficiary to validate no-beneficiary edge recipient accounting
        registry.removeBeneficiary(liquidToken);

        uint256 rareAmountC = 3e18;
        uint256 ethOutC = 0.0003e18;
        poolManager.setSwapResult(toBalanceDelta(int128(uint128(ethOutC)), -int128(uint128(rareAmountC))));
        vm.deal(address(distributor), ethOutC);

        vm.prank(approvedHook);
        distributor.notifyFee(liquidToken, rareAmountC);

        // All remaining ETH goes to protocol when beneficiary is not set
        assertEq(beneficiary.balance, beneficiaryStart + expectedBenA);
        assertEq(beneficiaryTwo.balance, beneficiaryTwoStart + expectedBenB);
        assertEq(
            protocolRecipient.balance,
            protocolStart + expectedProtA + expectedProtB
        );
        (Currency ethCurrency, address ethTo, uint256 ethAmount) = poolManager.takeCalls(2);
        assertEq(Currency.unwrap(ethCurrency), address(0));
        assertEq(ethTo, protocolRecipient);
        assertEq(ethAmount, ethOutC);
        assertEq(poolManager.syncCount(), 3);
        assertEq(poolManager.settleCount(), 3);
    }

    // ============================================
    // E3: Conversion fails (swap returns 0 ETH) → fallback distributes RARE
    // ============================================

    function test_notifyFee_ConversionFailure_DistributesRare() public {
        poolManager.setMockSqrtPrice(MOCK_SQRT_PRICE);

        // Swap returns zero ETH → _convertAndDistributeEth reverts ("NO_ETH_OUT")
        poolManager.setSwapResult(toBalanceDelta(0, 0));

        uint256 rareAmount = 1e18;

        vm.prank(approvedHook);
        vm.expectEmit(true, true, false, false);
        emit IFeeDistributor.FeeDistributedInRare(
            liquidToken, beneficiary, rareAmount, 0, 0, "CONVERT_FAIL"
        );
        distributor.notifyFee(liquidToken, rareAmount);

        // RARE distributed to beneficiary and protocol
        assertGt(rareToken.balanceOf(beneficiary),       0);
        assertGt(rareToken.balanceOf(protocolRecipient), 0);
        // No PM settlement happened
        assertEq(poolManager.syncCount(), 0);
    }

    // ============================================
    // E3b: Pool key not configured → NO_KEY fallback
    // ============================================

    function test_notifyFee_NoPoolKey_DistributesRare() public {
        // Deploy a fresh distributor with no pool key set
        FeeDistributor fresh = new FeeDistributor(
            owner, address(poolManager), address(rareToken), protocolRecipient, 5000, 400
        );
        rareToken.mint(address(fresh), 1e18);

        address freshHook = makeAddr("freshHook");
        vm.prank(owner);
        fresh.setHookApproval(freshHook, true);

        vm.prank(freshHook);
        vm.expectEmit(true, true, false, false);
        emit IFeeDistributor.FeeDistributedInRare(
            liquidToken, address(0), 1e18, 0, 0, "NO_KEY"
        );
        fresh.notifyFee(liquidToken, 1e18);
    }

    // ============================================
    // conversionEnabled kill-switch
    // ============================================

    function test_notifyFee_ConversionDisabled_DistributesRare() public {
        vm.prank(owner);
        distributor.setConversionEnabled(false);

        uint256 rareAmount = 1e18;

        vm.prank(approvedHook);
        vm.expectEmit(true, true, false, false);
        emit IFeeDistributor.FeeDistributedInRare(
            liquidToken, beneficiary, rareAmount, 0, 0, "CONVERSION_OFF"
        );
        distributor.notifyFee(liquidToken, rareAmount);
    }

    // ============================================
    // Admin: setRareEthPoolKey
    // ============================================

    function test_setRareEthPoolKey_OnlyOwner() public {
        PoolKey memory newKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(rareToken)),
            fee:         500,
            tickSpacing: 10,
            hooks:       IHooks(address(0))
        });
        vm.prank(owner);
        distributor.setRareEthPoolKey(newKey);
    }

    function test_setRareEthPoolKey_RevertsForNonOwner() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert();
        distributor.setRareEthPoolKey(rareEthKey);
    }

    function test_setRareEthPoolKey_RevertsForWrongCurrencies() public {
        address someToken = makeAddr("someToken");
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(someToken),
            currency1: Currency.wrap(address(rareToken)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(0))
        });
        vm.prank(owner);
        vm.expectRevert(IFeeDistributor.InvalidPoolKeyCurrencies.selector);
        distributor.setRareEthPoolKey(badKey);
    }

    // ============================================
    // Admin: setMaxSlippageBps / setConversionEnabled
    // ============================================

    function test_setMaxSlippageBps_OnlyOwner() public {
        vm.prank(owner);
        distributor.setMaxSlippageBps(200);
        assertEq(distributor.maxSlippageBps(), 200);
    }

    function test_setMaxSlippageBps_RevertsAbove10000() public {
        vm.prank(owner);
        vm.expectRevert(IFeeDistributor.InvalidSlippageBps.selector);
        distributor.setMaxSlippageBps(10_001);
    }

    function test_setConversionEnabled_OnlyOwner() public {
        vm.prank(owner);
        distributor.setConversionEnabled(false);
        assertFalse(distributor.conversionEnabled());
    }

    // ============================================
    // Admin: setBeneficiaryShareBPS
    // ============================================

    function test_setBeneficiaryShareBPS_OnlyOwner() public {
        vm.prank(owner);
        distributor.setBeneficiaryShareBPS(7000);
        assertEq(distributor.beneficiaryShareBPS(), 7000);
    }

    function test_setBeneficiaryShareBPS_RevertsInvalid() public {
        vm.prank(owner);
        vm.expectRevert(IFeeDistributor.InvalidBeneficiaryShare.selector);
        distributor.setBeneficiaryShareBPS(10_001);
    }

    // ============================================
    // Admin: setHookApproval / setBeneficiaryRegistry
    // ============================================

    function test_setHookApproval_OnlyOwner() public {
        address newHook = makeAddr("newHook");
        assertFalse(distributor.approvedHooks(newHook));

        vm.prank(owner);
        distributor.setHookApproval(newHook, true);
        assertTrue(distributor.approvedHooks(newHook));

        vm.prank(owner);
        distributor.setHookApproval(newHook, false);
        assertFalse(distributor.approvedHooks(newHook));
    }

    function test_setBeneficiaryRegistry_OnlyOwner() public {
        address newReg = makeAddr("newReg");
        vm.prank(owner);
        distributor.setBeneficiaryRegistry(newReg);
        assertEq(distributor.beneficiaryRegistry(), newReg);
    }

    // ============================================
    // RARE fallback: NoBeneficiary — all to protocol
    // ============================================

    function test_notifyFee_ConversionOff_NoBeneficiary_AllGoesToProtocol() public {
        address noBeneficiaryToken = makeAddr("noBeneficiaryToken");

        vm.prank(owner);
        distributor.setConversionEnabled(false);

        uint256 rareAmount = 1e18;

        vm.prank(approvedHook);
        distributor.notifyFee(noBeneficiaryToken, rareAmount);

        assertEq(rareToken.balanceOf(protocolRecipient), rareAmount);
        assertEq(rareToken.balanceOf(beneficiary),        0);
    }

    // ============================================
    // Legacy stubs
    // ============================================

    function test_totalFeeBPS_ReturnsConstructorValue() public view {
        assertEq(distributor.totalFeeBPS(), 400);
    }

    function test_legacy_protocolFeeRecipient() public view {
        assertEq(distributor.protocolFeeRecipient(), protocolRecipient);
    }

    function test_legacy_quoteFeeBreakdown_ReturnsZeros() public view {
        (uint256 a, uint256 b) = distributor.quoteFeeBreakdown(1e18);
        assertEq(a, 0);
        assertEq(b, 0);
    }

    function test_legacy_distributeFees_ReturnsZeros() public {
        (uint256 a, uint256 b, uint256 c) = distributor.distributeFees(1e18, address(0), address(0));
        assertEq(a, 0);
        assertEq(b, 0);
        assertEq(c, 0);
    }

    // ============================================
    // Event assertions for admin setters
    // ============================================

    function test_setMaxSlippageBps_EmitsMaxSlippageBpsUpdated() public {
        uint16 oldBps = distributor.maxSlippageBps();
        uint16 newBps = 200;

        vm.expectEmit(false, false, false, true);
        emit IFeeDistributor.MaxSlippageBpsUpdated(oldBps, newBps);

        vm.prank(owner);
        distributor.setMaxSlippageBps(newBps);
    }

    function test_setConversionEnabled_EmitsConversionEnabledUpdated() public {
        vm.expectEmit(false, false, false, true);
        emit IFeeDistributor.ConversionEnabledUpdated(false);

        vm.prank(owner);
        distributor.setConversionEnabled(false);
    }

    function test_setBeneficiaryShareBPS_EmitsBeneficiaryShareBpsUpdated() public {
        uint16 oldBps = distributor.beneficiaryShareBPS();
        uint16 newBps = 7000;

        vm.expectEmit(false, false, false, true);
        emit IFeeDistributor.BeneficiaryShareBpsUpdated(oldBps, newBps);

        vm.prank(owner);
        distributor.setBeneficiaryShareBPS(newBps);
    }

    function test_setBeneficiaryRegistry_EmitsBeneficiaryRegistryUpdated() public {
        address oldReg = distributor.beneficiaryRegistry();
        address newReg = makeAddr("newReg");

        vm.expectEmit(true, true, false, false);
        emit IFeeDistributor.BeneficiaryRegistryUpdated(oldReg, newReg);

        vm.prank(owner);
        distributor.setBeneficiaryRegistry(newReg);
    }

    function test_setHookApproval_EmitsHookApprovalUpdated() public {
        address newHook = makeAddr("newHookEvent");

        vm.expectEmit(true, false, false, true);
        emit IFeeDistributor.HookApprovalUpdated(newHook, true);

        vm.prank(owner);
        distributor.setHookApproval(newHook, true);
    }

    function test_setRareEthPoolKey_EmitsRareEthPoolKeyUpdated() public {
        PoolKey memory newKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(rareToken)),
            fee:         500,
            tickSpacing: 10,
            hooks:       IHooks(address(0))
        });

        vm.expectEmit(false, false, false, false); // struct comparison — just check it fires
        emit IFeeDistributor.RareEthPoolKeyUpdated(rareEthKey, newKey);

        vm.prank(owner);
        distributor.setRareEthPoolKey(newKey);
    }

    // ============================================
    // BPS boundary edge cases
    // ============================================

    function test_BeneficiaryShareBPS_Zero_AllGoesToProtocol() public {
        vm.prank(owner);
        distributor.setBeneficiaryShareBPS(0);

        poolManager.setMockSqrtPrice(MOCK_SQRT_PRICE);

        uint256 rareAmount = 1e18;
        uint256 ethOut = 0.0001e18;
        poolManager.setSwapResult(toBalanceDelta(int128(uint128(ethOut)), -int128(uint128(rareAmount))));
        vm.deal(address(distributor), ethOut);

        vm.prank(approvedHook);
        distributor.notifyFee(liquidToken, rareAmount);

        // When benShareBps=0, the contract skips _sendEth and calls pm.take() directly
        // to the protocol fee recipient — verify via the recorded take() call.
        assertGt(poolManager.takeCallCount(), 0, "pm.take() should be called");
        (, address takeTo, uint256 takeAmount) = poolManager.takeCalls(poolManager.takeCallCount() - 1);
        assertEq(takeTo, protocolRecipient, "last take() should go to protocol");
        assertEq(takeAmount, ethOut, "full ETH should be taken for protocol when BPS=0");

        // beneficiary should receive nothing directly
        assertEq(beneficiary.balance, 0, "beneficiary should get nothing when BPS=0");
    }

    function test_BeneficiaryShareBPS_TenThousand_AllGoesToBeneficiary() public {
        vm.prank(owner);
        distributor.setBeneficiaryShareBPS(10_000);

        poolManager.setMockSqrtPrice(MOCK_SQRT_PRICE);

        uint256 rareAmount = 1e18;
        uint256 ethOut = 0.0001e18;
        poolManager.setSwapResult(toBalanceDelta(int128(uint128(ethOut)), -int128(uint128(rareAmount))));
        vm.deal(address(distributor), ethOut);

        uint256 beneficiaryBefore = beneficiary.balance;

        vm.prank(approvedHook);
        distributor.notifyFee(liquidToken, rareAmount);

        // With 10000 BPS: ethBen = ethOut, ethProt = 0
        // Contract calls pm.take(eth, address(this), ethOut) then _sendEth(beneficiary, ethOut)
        assertEq(beneficiary.balance - beneficiaryBefore, ethOut, "all ETH should go to beneficiary when BPS=10000");
        assertEq(protocolRecipient.balance, 0, "protocol should get nothing when BPS=10000");
    }

    function test_BeneficiaryShareBPS_ExactSplit_UsesCorrectMath() public {
        uint16 customBps = 3000;
        vm.prank(owner);
        distributor.setBeneficiaryShareBPS(customBps);

        poolManager.setMockSqrtPrice(MOCK_SQRT_PRICE);

        uint256 rareAmount = 1e18;
        uint256 ethOut = 1e15; // 0.001 ETH — use a value divisible cleanly
        poolManager.setSwapResult(toBalanceDelta(int128(uint128(ethOut)), -int128(uint128(rareAmount))));
        vm.deal(address(distributor), ethOut);

        uint256 beneficiaryBefore = beneficiary.balance;
        uint256 protocolBefore = protocolRecipient.balance;

        vm.prank(approvedHook);
        distributor.notifyFee(liquidToken, rareAmount);

        uint256 expectedBeneficiary = (ethOut * customBps) / 10_000;
        uint256 expectedProtocol    = ethOut - expectedBeneficiary;

        assertEq(beneficiary.balance - beneficiaryBefore, expectedBeneficiary, "wrong beneficiary share");
        assertEq(protocolRecipient.balance - protocolBefore, expectedProtocol, "wrong protocol share");
        assertEq(
            (beneficiary.balance - beneficiaryBefore) + (protocolRecipient.balance - protocolBefore),
            ethOut,
            "shares must sum to total ETH"
        );
    }

    function test_RareDistribution_ExactSplit_UsesCorrectMath() public {
        // Conversion attempted with default sqrtPrice=0, swap returns (0,0) → CONVERT_FAIL → RARE fallback
        uint16 customBps = 3000;
        vm.prank(owner);
        distributor.setBeneficiaryShareBPS(customBps);

        uint256 rareAmount = 1e18;

        vm.prank(approvedHook);
        distributor.notifyFee(liquidToken, rareAmount);

        uint256 expectedBeneficiary = (rareAmount * customBps) / 10_000;
        uint256 expectedProtocol    = rareAmount - expectedBeneficiary;

        assertEq(rareToken.balanceOf(beneficiary),       expectedBeneficiary, "wrong beneficiary RARE");
        assertEq(rareToken.balanceOf(protocolRecipient), expectedProtocol,    "wrong protocol RARE");
    }

    function test_MaxSlippageBps_Zero_AllowsNoSlippage() public {
        poolManager.setMockSqrtPrice(MOCK_SQRT_PRICE);

        vm.prank(owner);
        distributor.setMaxSlippageBps(0);

        uint256 rareAmount = 1e18;
        // Give a deliberately wrong ETH output (slippage exceeded)
        uint256 ethOut = 1; // essentially zero vs expected
        poolManager.setSwapResult(toBalanceDelta(int128(uint128(ethOut)), -int128(uint128(rareAmount))));
        vm.deal(address(distributor), ethOut);

        // Should fall back to RARE distribution (SLIPPAGE_EXCEEDED)
        vm.prank(approvedHook);
        vm.expectEmit(true, true, false, false);
        emit IFeeDistributor.FeeDistributedInRare(liquidToken, beneficiary, rareAmount, 0, 0, "CONVERT_FAIL");
        distributor.notifyFee(liquidToken, rareAmount);
    }

    // ============================================
    // Unauthorized access to admin setters
    // ============================================

    function test_setBeneficiaryRegistry_RevertsForNonOwner() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert();
        distributor.setBeneficiaryRegistry(makeAddr("x"));
    }

    function test_setHookApproval_RevertsForNonOwner() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert();
        distributor.setHookApproval(makeAddr("x"), true);
    }

    function test_setConversionEnabled_RevertsForNonOwner() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert();
        distributor.setConversionEnabled(false);
    }

    function test_setMaxSlippageBps_RevertsForNonOwner() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert();
        distributor.setMaxSlippageBps(200);
    }

    function test_setBeneficiaryShareBPS_RevertsForNonOwner() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert();
        distributor.setBeneficiaryShareBPS(5000);
    }

    // ============================================
    // setBeneficiaryRegistry — address(0) is allowed
    // ============================================

    function test_setBeneficiaryRegistry_AllowsZeroAddress() public {
        vm.prank(owner);
        distributor.setBeneficiaryRegistry(address(0));
        assertEq(distributor.beneficiaryRegistry(), address(0));
    }

    // ============================================
    // Fuzz tests
    // ============================================

    function testFuzz_BeneficiaryShare_SumsToTotal_ETHPath(uint16 shareBps) public {
        // Restrict to shares where _sendEth path is taken (shareBps > 0).
        // When shareBps == 0, the contract routes via pm.take() to the protocol directly
        // and the ETH is not in recipient balances (mock take() doesn't move ETH).
        shareBps = uint16(bound(uint256(shareBps), 1, 10_000));

        vm.prank(owner);
        distributor.setBeneficiaryShareBPS(shareBps);

        poolManager.setMockSqrtPrice(MOCK_SQRT_PRICE);

        uint256 rareAmount = 1e18;
        uint256 ethOut = 0.001e18;
        poolManager.setSwapResult(toBalanceDelta(int128(uint128(ethOut)), -int128(uint128(rareAmount))));
        vm.deal(address(distributor), ethOut);

        uint256 protocolBefore = protocolRecipient.balance;
        uint256 beneficiaryBefore = beneficiary.balance;

        vm.prank(approvedHook);
        distributor.notifyFee(liquidToken, rareAmount);

        uint256 protocolGot    = protocolRecipient.balance - protocolBefore;
        uint256 beneficiaryGot = beneficiary.balance - beneficiaryBefore;

        assertEq(protocolGot + beneficiaryGot, ethOut, "ETH shares must sum to total");

        uint256 expectedBeneficiary = (ethOut * shareBps) / 10_000;
        assertEq(beneficiaryGot, expectedBeneficiary, "beneficiary share must use BPS math");
    }

    function testFuzz_BeneficiaryShare_SumsToTotal_RAREPath(uint16 shareBps) public {
        shareBps = uint16(bound(uint256(shareBps), 0, 10_000));

        vm.prank(owner);
        distributor.setBeneficiaryShareBPS(shareBps);

        // Conversion attempted with default sqrtPrice=0, swap returns (0,0) → CONVERT_FAIL → RARE fallback
        uint256 rareAmount = 2e18;
        rareToken.mint(address(distributor), rareAmount); // top up

        vm.prank(approvedHook);
        distributor.notifyFee(liquidToken, rareAmount);

        uint256 beneficiaryGot = rareToken.balanceOf(beneficiary);
        uint256 protocolGot    = rareToken.balanceOf(protocolRecipient);

        assertEq(beneficiaryGot + protocolGot, rareAmount, "RARE shares must sum to total");

        uint256 expectedBeneficiary = (rareAmount * shareBps) / 10_000;
        assertEq(beneficiaryGot, expectedBeneficiary, "beneficiary RARE share must use BPS math");
    }

    function testFuzz_MaxSlippageBps_ValidRange(uint16 slippageBps) public {
        slippageBps = uint16(bound(uint256(slippageBps), 0, 10_000));

        vm.prank(owner);
        distributor.setMaxSlippageBps(slippageBps);
        assertEq(distributor.maxSlippageBps(), slippageBps, "should store valid slippage BPS");
    }

    function testFuzz_SetBeneficiaryShareBPS_ValidRange(uint16 bps) public {
        bps = uint16(bound(uint256(bps), 0, 10_000));

        vm.prank(owner);
        distributor.setBeneficiaryShareBPS(bps);
        assertEq(distributor.beneficiaryShareBPS(), bps, "should store valid BPS");
    }

    function testFuzz_MaxSlippageBps_RevertsAbove10000(uint16 slippageBps) public {
        slippageBps = uint16(bound(uint256(slippageBps), 10_001, type(uint16).max));

        vm.prank(owner);
        vm.expectRevert(IFeeDistributor.InvalidSlippageBps.selector);
        distributor.setMaxSlippageBps(slippageBps);
    }

    // ============================================
    // ETH fallback: beneficiary rejects ETH → protocol gets all
    // ============================================

    function test_notifyFee_BeneficiaryRejectsEth_RedirectsToProtocol() public {
        EthRejecter rejecter = new EthRejecter();
        registry.setBeneficiary(liquidToken, address(rejecter));

        poolManager.setMockSqrtPrice(MOCK_SQRT_PRICE);

        uint256 rareAmount = 1e18;
        uint256 ethOut     = 0.0001e18;

        poolManager.setSwapResult(toBalanceDelta(int128(uint128(ethOut)), -int128(uint128(rareAmount))));
        vm.deal(address(distributor), ethOut);

        uint256 protocolBefore = protocolRecipient.balance;

        vm.prank(approvedHook);
        distributor.notifyFee(liquidToken, rareAmount);

        // Beneficiary got nothing (rejected ETH)
        assertEq(address(rejecter).balance, 0, "rejecter should have 0 ETH");
        // Protocol got ALL the ETH (both shares)
        assertEq(protocolRecipient.balance - protocolBefore, ethOut, "protocol should get all ETH");
        // No ETH stranded in distributor
        assertEq(address(distributor).balance, 0, "no ETH should be stranded in distributor");
    }

    // ============================================
    // RARE fallback: beneficiary RARE transfer fails → protocol gets all
    // ============================================

    function test_notifyFee_BeneficiaryRareTransferFails_RedirectsToProtocol() public {
        // Deploy a RARE mock with blocklist and a fresh distributor using it
        MockERC20WithBlocklist blockedRare = new MockERC20WithBlocklist();

        FeeDistributor freshDist = new FeeDistributor(
            owner,
            address(poolManager),
            address(blockedRare),
            protocolRecipient,
            BENEFICIARY_SHARE_BPS,
            400
        );

        // Block the beneficiary address on the token
        blockedRare.blockAddress(beneficiary);
        blockedRare.mint(address(freshDist), 1e18);

        MockLiquidRegistry freshReg = new MockLiquidRegistry();
        freshReg.setBeneficiary(liquidToken, beneficiary);

        address freshHook = makeAddr("freshHookBlocked");
        vm.startPrank(owner);
        freshDist.setBeneficiaryRegistry(address(freshReg));
        freshDist.setHookApproval(freshHook, true);
        vm.stopPrank();

        // No pool key set → conversion fails → _distributeRare
        uint256 rareAmount = 1e18;
        uint256 protocolBefore = blockedRare.balanceOf(protocolRecipient);

        vm.prank(freshHook);
        freshDist.notifyFee(liquidToken, rareAmount);

        // Beneficiary got nothing (blocked)
        assertEq(blockedRare.balanceOf(beneficiary), 0, "blocked beneficiary should get 0 RARE");
        // Protocol got ALL the RARE
        assertEq(
            blockedRare.balanceOf(protocolRecipient) - protocolBefore,
            rareAmount,
            "protocol should get all RARE"
        );
    }
}

/// @notice Contract that rejects ETH transfers
contract EthRejecter {
    receive() external payable {
        revert("NO_ETH");
    }
}

/// @notice ERC20 mock that reverts on transfer to a specific address (simulates blocklisted beneficiary)
contract MockERC20WithBlocklist {
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public blocked;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function blockAddress(address addr) external {
        blocked[addr] = true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (blocked[to]) revert("BLOCKED");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (blocked[to]) revert("BLOCKED");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
