// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {IRAREBurner} from "liquid-editions/interfaces/IRAREBurner.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/interfaces/IV4Quoter.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RARE Burner Unit Tests
/// @notice Unit tests for RARE burn configuration and validation
contract RAREBurnerUnitTest is Test {
    // Network configuration
    NetworkConfig.Config internal config;

    // Test accounts
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public user1 = makeAddr("user1");

    // Contract interfaces
    RAREBurner public burner;
    LiquidMultiCurve public liquidImplementation;

    function setUp() public {
        // Fund test accounts
        vm.deal(admin, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(protocolFeeRecipient, 100 ether);

        // Deploy contracts
        vm.startPrank(admin);
        liquidImplementation = new LiquidMultiCurve();
        vm.stopPrank();
    }

    function testRAREBurnGlobalConfiguration() public {
        // Test RARE burn configuration via constructor
        address mockRAREToken = makeAddr("mockRAREToken");
        uint16 maxSlippage = 0; // 0% (no quoter available for unit test)
        uint24 poolFee = 3000; // 0.3%
        int24 tickSpacing = 60;
        address hooks = address(0);
        address burnAddr = 0x000000000000000000000000000000000000dEaD;

        // CRITICAL: Compute the correct PoolId from parameters
        bytes32 correctPoolId = _computePoolId(
            mockRAREToken,
            poolFee,
            tickSpacing,
            hooks
        );

        // Deploy burner with full configuration
        vm.prank(admin);
        burner = new RAREBurner(
            admin,
            false, // tryOnDeposit
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890), // Mock V4 PoolManager
            poolFee,
            tickSpacing,
            hooks,
            burnAddr,
            address(0), // no quoter
            maxSlippage, // 0% slippage (no quoter available for unit test)
            true // enabled
        );

        // Verify configuration was set - read individual state variables
        address rareToken = burner.RARE_TOKEN();
        address v4PoolManager = burner.V4_POOL_MANAGER();
        address v4Hooks = burner.V4_HOOKS();
        address storedBurnAddr = burner.burnAddress();
        bytes32 v4PoolId = burner.V4_POOL_ID();
        uint24 v4PoolFee = burner.V4_POOL_FEE();
        int24 v4TickSpacing = burner.V4_TICK_SPACING();
        uint16 maxSlippageBPS = burner.maxSlippageBPS();
        bool enabled = burner.enabled();

        assertEq(rareToken, mockRAREToken);
        assertTrue(enabled);
        assertEq(maxSlippageBPS, maxSlippage);
        assertEq(
            v4PoolManager,
            address(0x1234567890123456789012345678901234567890)
        );
        assertEq(v4PoolId, correctPoolId);
        assertEq(v4PoolFee, poolFee);
        assertEq(v4TickSpacing, tickSpacing);
        assertEq(v4Hooks, hooks);
        assertEq(storedBurnAddr, burnAddr);
    }

    function testRAREBurnConfigurationValidation() public {
        address mockRAREToken = makeAddr("mockRAREToken");
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);
        address burnAddr = 0x000000000000000000000000000000000000dEaD;

        // Test maximum slippage validation (should fail at >10%)
        // Note: burner doesn't have a burnFeeBPS limit since fee split is handled upstream
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRAREBurner.SlippageTooHigh.selector,
                1001,
                1000
            )
        );
        new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890),
            poolFee,
            tickSpacing,
            hooks,
            burnAddr,
            address(0), // no quoter
            1001, // maxSlippage > 10%
            true // enabled
        );

        // Test invalid V4 PoolManager (should fail with zero address)
        vm.prank(admin);
        vm.expectRevert(IRAREBurner.AddressZero.selector);
        new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(0),
            poolFee,
            tickSpacing,
            hooks,
            burnAddr,
            address(0), // no quoter
            500, // maxSlippage
            true // enabled
        );

        // Note: burner doesn't validate pool ID at config time, only at burn time
        // This allows flexible configuration but validates before actual swap
    }

    function testPoolConfigValidation_DetectsValidConfig() public {
        // Setup valid pool parameters
        address mockRAREToken = makeAddr("mockRAREToken");
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);
        address burnAddr = 0x000000000000000000000000000000000000dEaD;

        // Deploy with correct parameters
        vm.prank(admin);
        burner = new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890),
            poolFee,
            tickSpacing,
            hooks,
            burnAddr,
            address(0),
            0, // 0% slippage (no quoter available)
            true // enabled
        );

        // Validate configuration
        assertTrue(burner.validatePoolConfig());
    }

    function testPoolIdComputationRegression() public pure {
        // Test that PoolId computation is deterministic and matches expected format
        address mockRAREToken = address(
            0x691077C8e8de54EA84eFd454630439F99bd8C92f
        );
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);

        // Compute pool ID using our helper
        bytes32 poolId1 = _computePoolId(
            mockRAREToken,
            poolFee,
            tickSpacing,
            hooks
        );

        // Compute again to verify determinism
        bytes32 poolId2 = _computePoolId(
            mockRAREToken,
            poolFee,
            tickSpacing,
            hooks
        );

        // Should be identical
        assertEq(poolId1, poolId2, "PoolId computation must be deterministic");

        // Verify it's not zero (regression check for implementation bugs)
        assertTrue(poolId1 != bytes32(0), "PoolId must not be zero");

        // Test with swapped parameters to ensure ordering matters
        address mockRAREToken2 = address(
            0x791077C8E8De54Ea84EFd454630439F99BD8C92f
        );
        bytes32 poolId3 = _computePoolId(
            mockRAREToken2,
            poolFee,
            tickSpacing,
            hooks
        );

        // Different token should produce different pool ID
        assertTrue(
            poolId1 != poolId3,
            "Different tokens must produce different pool IDs"
        );
    }

    function testBurnerIsRAREBurnActive() public {
        // Setup valid pool parameters
        address mockRAREToken = makeAddr("mockRAREToken");
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);
        address burnAddr = 0x000000000000000000000000000000000000dEaD;

        // Deploy with full configuration and enabled
        vm.prank(admin);
        burner = new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890),
            poolFee,
            tickSpacing,
            hooks,
            burnAddr,
            address(0),
            0, // 0% slippage (no quoter available)
            true // enabled
        );

        // Now active
        assertTrue(burner.isRAREBurnActive());

        // Disable
        vm.prank(admin);
        burner.toggleBurnEnabled(false);

        // No longer active
        assertFalse(burner.isRAREBurnActive());
    }

    function testBurnerToggleBurnEnabled() public {
        // Setup valid pool parameters
        address mockRAREToken = makeAddr("mockRAREToken");
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);
        address burnAddr = 0x000000000000000000000000000000000000dEaD;

        // Deploy with full configuration and enabled
        vm.prank(admin);
        burner = new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890),
            poolFee,
            tickSpacing,
            hooks,
            burnAddr,
            address(0),
            0, // 0% slippage (no quoter available)
            true // enabled
        );

        // Initially enabled
        assertTrue(burner.isRAREBurnActive());

        // Toggle off
        vm.prank(admin);
        burner.toggleBurnEnabled(false);
        assertFalse(burner.isRAREBurnActive());

        // Toggle back on
        vm.prank(admin);
        burner.toggleBurnEnabled(true);
        assertTrue(burner.isRAREBurnActive());
    }

    function testBurnerRequiresFullConfiguration() public {
        // Test that constructor requires all parameters
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);
        address burnAddr = 0x000000000000000000000000000000000000dEaD;

        // Should revert if rareToken is address(0)
        vm.prank(admin);
        vm.expectRevert(IRAREBurner.AddressZero.selector);
        new RAREBurner(
            admin,
            false,
            address(0),
            address(0x1234567890123456789012345678901234567890),
            poolFee,
            tickSpacing,
            hooks,
            burnAddr,
            address(0),
            0,
            true
        );
    }

    // Helper function to compute PoolId (matches RAREBurner logic)
    function _computePoolId(
        address rareToken,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) internal pure returns (bytes32) {
        // Import types for V4
        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(rareToken);

        // Determine token ordering
        bool ethIs0 = uint160(address(0)) < uint160(rareToken);

        PoolKey memory key = PoolKey({
            currency0: ethIs0 ? ethC : rareC,
            currency1: ethIs0 ? rareC : ethC,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        return PoolId.unwrap(PoolIdLibrary.toId(key));
    }

    // NOTE: V4 burn functionality is comprehensively tested in:
    // - Liquid.mainnet.invariants.t.sol: testRealisticRAREBurnOnBaseFork()
    // - Liquid.invariants.t.sol: testUnlockCallbackGuard*() tests
    // - RAREBurner.t.sol: testUnlockCallbackOnlyPoolManager()
    // - RAREBurner.mainnet.t.sol: Fork tests for RARE token behavior
}

// ============================================
// Mock Contracts for Testing
// ============================================

/// @title Mock PoolManager that can force failures
contract MockPoolManagerForced {
    bool public shouldFail;
    bool public shouldPartialFill;
    uint256 public partialFillRatio; // e.g., 5000 = 50% fill

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    function setShouldPartialFill(bool _partial, uint256 _ratio) external {
        shouldPartialFill = _partial;
        partialFillRatio = _ratio; // BPS (0-10000)
    }

    event UnlockStarted(address caller);
    event UnlockCallbackReturned();
    
    function unlock(bytes calldata data) external virtual returns (bytes memory) {
        emit UnlockStarted(msg.sender);
        if (shouldFail) {
            revert("MockPoolManager: swap failed");
        }
        // Call unlockCallback - RAREBurner implements IUnlockCallback
        // Use low-level call to see the actual return data/error
        (bool success, bytes memory result) = msg.sender.call(
            abi.encodeWithSelector(IUnlockCallback.unlockCallback.selector, data)
        );
        if (!success) {
            // Re-throw with the actual revert reason
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        emit UnlockCallbackReturned();
        return result;
    }

    function swap(
        PoolKey memory,
        IPoolManager.SwapParams memory params,
        bytes calldata
    ) external payable returns (BalanceDelta) {
        if (shouldFail) {
            revert("MockPoolManager: swap failed");
        }

        // Calculate deltas
        // params.amountSpecified is negative for input (ETH in)
        int256 amountSpecified = params.amountSpecified;
        require(amountSpecified < 0, "amountSpecified must be negative");
        uint256 ethIn = uint256(-amountSpecified);
        uint256 rareOut = ethIn; // 1:1 for simplicity

        // Apply partial fill if enabled
        if (shouldPartialFill) {
            rareOut = (rareOut * partialFillRatio) / 10000;
        }

        // Return BalanceDelta: amount0 = negative ETH (paid), amount1 = positive RARE (received)
        int128 ethDelta = -int128(uint128(ethIn));
        int128 rareDelta = int128(uint128(rareOut));
        return toBalanceDelta(ethDelta, rareDelta);
    }

    function settle() external payable returns (uint256) {
        // Accept ETH and return amount settled
        return msg.value;
    }

    event TakeCalled(address currency, address to, uint256 amount);
    event FallbackCalled(bytes data);
    
    function take(Currency currency, address to, uint256 amount) external virtual {
        emit TakeCalled(Currency.unwrap(currency), to, amount);
        // No-op for base mock; override in MockPoolManagerWithRARE to transfer
    }
    
    fallback() external payable {
        emit FallbackCalled(msg.data);
        revert("MockPoolManagerForced: unknown function");
    }
    
    receive() external payable {}
}

/// @title Mock PoolManager that holds RARE and transfers on take (for happy-path unlock callback)
contract MockPoolManagerWithRARE is MockPoolManagerForced {
    address public rareToken;

    constructor(address _rareToken) {
        rareToken = _rareToken;
    }

    event TakeWithTransfer(address currency, address to, uint256 amount);
    
    function take(Currency currency, address to, uint256 amount) external override {
        emit TakeWithTransfer(Currency.unwrap(currency), to, amount);
        require(
            Currency.unwrap(currency) == rareToken,
            "MockPoolManagerWithRARE: wrong currency"
        );
        IERC20(rareToken).transfer(to, amount);
    }
}

/// @title Mock PoolManager that records unlock context for lifecycle assertions
contract MockPoolManagerWithRAREStateful is MockPoolManagerWithRARE {
    bytes public lastUnlockData;
    uint256 public unlockCallCount;

    constructor(address _rareToken) MockPoolManagerWithRARE(_rareToken) {}

    function unlock(
        bytes calldata data
    ) external override returns (bytes memory) {
        unlockCallCount += 1;
        lastUnlockData = data;

        emit UnlockStarted(msg.sender);
        if (shouldFail) {
            revert("MockPoolManager: swap failed");
        }
        (bool success, bytes memory result) = msg.sender.call(
            abi.encodeWithSelector(IUnlockCallback.unlockCallback.selector, data)
        );
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        emit UnlockCallbackReturned();
        return result;
    }
}

/// @title Mock Quoter that can force failures
contract MockQuoterForced {
    uint256 public mockQuote;
    bool public shouldRevert;
    bool public shouldReturnZero;

    function setMockQuote(uint256 _quote) external {
        mockQuote = _quote;
    }

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function setShouldReturnZero(bool _zero) external {
        shouldReturnZero = _zero;
    }

    function quoteExactInputSingle(
        IV4Quoter.QuoteExactSingleParams memory
    ) external view returns (uint256 amountOut, uint256) {
        if (shouldRevert) {
            revert("MockQuoter: quote failed");
        }
        if (shouldReturnZero) {
            return (0, 0);
        }
        return (mockQuote, 0);
    }
}

/// @title RAREBurner Unit Tests (continued)
contract RAREBurnerUnitTestContinued is RAREBurnerUnitTest {
    // ============================================
    // SECTION: Non-Reverting Guarantee Tests
    // ============================================

    /// @notice Test that depositForBurn() never reverts on quoter failure
    function test_DepositForBurn_NeverReverts_OnQuoterFailure() public {
        address mockRAREToken = makeAddr("mockRAREToken");
        MockQuoterForced mockQuoter = new MockQuoterForced();
        mockQuoter.setShouldRevert(true);

        vm.prank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            false, // tryOnDeposit
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(mockQuoter),
            500, // 5% slippage
            true
        );

        // Deposit should succeed even if quoter fails
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        testBurner.depositForBurn{value: 1 ether}();

        assertEq(testBurner.pendingEth(), 1 ether);
    }

    /// @notice Test that depositForBurn() never reverts on swap failure
    function test_DepositForBurn_NeverReverts_OnSwapFailure() public {
        address mockRAREToken = makeAddr("mockRAREToken");
        MockPoolManagerForced mockPoolManager = new MockPoolManagerForced();
        mockPoolManager.setShouldFail(true);

        vm.prank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            true, // tryOnDeposit - will attempt flush
            mockRAREToken,
            address(mockPoolManager),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(0), // no quoter
            0, // no slippage
            true
        );

        // Deposit should succeed even if swap fails
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        testBurner.depositForBurn{value: 1 ether}();

        assertEq(testBurner.pendingEth(), 1 ether);
    }

    /// @notice Test that depositForBurn() never reverts on pool misconfiguration
    function test_DepositForBurn_NeverReverts_OnPoolMisconfiguration() public {
        address mockRAREToken = makeAddr("mockRAREToken");

        // Create burner with mismatched pool config
        vm.prank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            true, // tryOnDeposit
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(0),
            0,
            true
        );

        // Deposit should succeed even if pool config is wrong
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        testBurner.depositForBurn{value: 1 ether}();

        assertEq(testBurner.pendingEth(), 1 ether);
    }

    /// @notice Test that flush() never reverts on swap failure, emits BurnFailed
    function test_Flush_NeverReverts_OnSwapFailure_EmitsBurnFailed() public {
        address mockRAREToken = makeAddr("mockRAREToken");
        MockPoolManagerForced mockPoolManager = new MockPoolManagerForced();
        mockPoolManager.setShouldFail(true);

        vm.prank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            false, // tryOnDeposit
            mockRAREToken,
            address(mockPoolManager),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(0),
            0,
            true
        );

        // Deposit ETH
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        testBurner.depositForBurn{value: 1 ether}();

        uint256 pendingBefore = testBurner.pendingEth();

        // Flush should not revert, should emit BurnFailed
        vm.expectEmit(true, false, false, true);
        emit IRAREBurner.BurnFailed(1 ether, 0); // FAIL_SWAP = 0

        testBurner.flush();

        // PendingEth should be unchanged
        assertEq(testBurner.pendingEth(), pendingBefore);
    }

    /// @notice Test that flush() never reverts on quoter failure, emits BurnFailed
    function test_Flush_NeverReverts_OnQuoterFailure_EmitsBurnFailed() public {
        address mockRAREToken = makeAddr("mockRAREToken");
        MockQuoterForced mockQuoter = new MockQuoterForced();
        mockQuoter.setShouldRevert(true);

        vm.prank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(mockQuoter),
            500, // 5% slippage
            true
        );

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        testBurner.depositForBurn{value: 1 ether}();

        uint256 pendingBefore = testBurner.pendingEth();

        vm.expectEmit(true, false, false, true);
        emit IRAREBurner.BurnFailed(1 ether, 1); // FAIL_QUOTE = 1

        testBurner.flush();

        assertEq(testBurner.pendingEth(), pendingBefore);
    }

    // ============================================
    // SECTION: Sweep/SweepExcess Correctness Tests
    // ============================================

    /// @notice Test that sweep(0) sweeps exactly pendingEth
    function test_Sweep_ZeroAmount_SweepsExactlyPendingEth() public {
        address mockRAREToken = makeAddr("mockRAREToken");

        vm.prank(admin);
        burner = new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(0),
            0,
            true
        );

        // Deposit ETH
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        assertEq(burner.pendingEth(), 1 ether);

        // Sweep with amount=0 should sweep all pendingEth
        vm.prank(admin);
        burner.sweep(user1, 0);

        assertEq(burner.pendingEth(), 0);
        assertEq(user1.balance, 1 ether);
    }

    /// @notice Test that sweep() reverts when amount exceeds pendingEth
    function test_Sweep_RevertsWhen_AmountExceedsPendingEth() public {
        address mockRAREToken = makeAddr("mockRAREToken");

        vm.prank(admin);
        burner = new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(0),
            0,
            true
        );

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        vm.expectRevert(
            abi.encodeWithSelector(
                IRAREBurner.InsufficientPendingEth.selector,
                2 ether,
                1 ether
            )
        );
        vm.prank(admin);
        burner.sweep(user1, 2 ether);
    }

    // ============================================
    // SECTION: Unlock Callback Happy Path Tests
    // ============================================

    /// @notice Sanity check: MockPoolManagerWithRARE take transfers tokens correctly
    function test_MockPoolManagerWithRARE_TakeTransfersTokens() public {
        MockERC20 mockRARE = new MockERC20();
        mockRARE.mint(address(this), 1000 ether);
        MockPoolManagerWithRARE pm = new MockPoolManagerWithRARE(address(mockRARE));
        mockRARE.transfer(address(pm), 100 ether);

        uint256 balBefore = mockRARE.balanceOf(user1);
        pm.take(Currency.wrap(address(mockRARE)), user1, 1 ether);
        assertEq(mockRARE.balanceOf(user1), balBefore + 1 ether);
    }

    /// @notice Sanity check: take works when recipient is RAREBurner (contract)
    function test_MockPoolManagerWithRARE_TakeToContract() public {
        MockERC20 mockRARE = new MockERC20();
        mockRARE.mint(address(this), 1000 ether);
        MockPoolManagerWithRARE pm = new MockPoolManagerWithRARE(address(mockRARE));
        mockRARE.transfer(address(pm), 100 ether);

        vm.prank(admin);
        burner = new RAREBurner(
            admin,
            false,
            address(mockRARE),
            address(pm),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(0),
            0,
            true
        );

        uint256 balBefore = mockRARE.balanceOf(address(burner));
        // Simulate RAREBurner calling take (as it would during unlockCallback)
        vm.prank(address(burner));
        pm.take(Currency.wrap(address(mockRARE)), address(burner), 1 ether);
        assertEq(mockRARE.balanceOf(address(burner)), balBefore + 1 ether);
    }

    /// @notice Sanity check: toBalanceDelta works for swap deltas
    function test_ToBalanceDelta_WorksForSwapDeltas() public pure {
        int128 ethDelta = -int128(uint128(1 ether));
        int128 rareDelta = int128(uint128(1 ether));
        BalanceDelta delta = toBalanceDelta(ethDelta, rareDelta);
        assertEq(delta.amount0(), ethDelta);
        assertEq(delta.amount1(), rareDelta);
    }

    /// @notice Test unlockCallback happy path - full flush flow
    /// @dev Full flow: depositForBurn -> flush -> unlock -> swap -> settle -> take -> burn.
    function test_UnlockCallback_HappyPath_EmitsBurnedEvent() public {
        MockERC20 mockRARE = new MockERC20();
        mockRARE.mint(address(this), 1000 ether);

        MockPoolManagerWithRARE mockPoolManager = new MockPoolManagerWithRARE(
            address(mockRARE)
        );
        mockRARE.transfer(address(mockPoolManager), 100 ether);

        address burnAddr = 0x000000000000000000000000000000000000dEaD;

        vm.prank(admin);
        burner = new RAREBurner(
            admin,
            false,
            address(mockRARE),
            address(mockPoolManager),
            3000,
            60,
            address(0),
            burnAddr,
            address(0),
            0,
            true
        );

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        uint256 burnAddrBalBefore = mockRARE.balanceOf(burnAddr);
        uint256 burnerBalBefore = mockRARE.balanceOf(address(burner));
        uint256 pmBalBefore = mockRARE.balanceOf(address(mockPoolManager));

        // Debug: log balances before flush
        emit log_named_uint("Pool manager RARE before", pmBalBefore);
        emit log_named_uint("Burner RARE before", burnerBalBefore);
        emit log_named_uint("Burn address RARE before", burnAddrBalBefore);

        burner.flush();

        uint256 burnAddrBalAfter = mockRARE.balanceOf(burnAddr);
        uint256 burnerBalAfter = mockRARE.balanceOf(address(burner));
        uint256 pmBalAfter = mockRARE.balanceOf(address(mockPoolManager));

        // Debug: log balances after flush
        emit log_named_uint("Pool manager RARE after", pmBalAfter);
        emit log_named_uint("Burner RARE after", burnerBalAfter);
        emit log_named_uint("Burn address RARE after", burnAddrBalAfter);
        emit log_named_uint("pendingEth after", burner.pendingEth());

        assertEq(burner.pendingEth(), 0, "pendingEth should be decremented");
        assertEq(
            burnAddrBalAfter,
            burnAddrBalBefore + 1 ether,
            "Burn address should receive RARE"
        );
    }

    /// @notice Verify unlock callback lifecycle:
    /// - invalid callback caller reverts with OnlyPoolManager
    /// - context is one-shot and cleared after successful unlockCallback
    function test_UnlockCallback_ContextLifecycle_OneShotAndCallerGuard() public {
        MockERC20 mockRARE = new MockERC20();
        mockRARE.mint(address(this), 1000 ether);

        MockPoolManagerWithRAREStateful mockPoolManager = new MockPoolManagerWithRAREStateful(
                address(mockRARE)
            );
        mockRARE.transfer(address(mockPoolManager), 100 ether);

        address burnAddr = 0x000000000000000000000000000000000000dEaD;

        vm.prank(admin);
        burner = new RAREBurner(
            admin,
            false,
            address(mockRARE),
            address(mockPoolManager),
            3000,
            60,
            address(0),
            burnAddr,
            address(0),
            0,
            true
        );

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        burner.flush();

        assertEq(
            mockPoolManager.unlockCallCount(),
            1,
            "valid unlock callback should run once"
        );
        assertEq(mockPoolManager.lastUnlockData().length > 0, true);
        assertEq(burner.pendingEth(), 0, "successful burn should clear pendingEth");

        bytes memory callbackData = mockPoolManager.lastUnlockData();

        vm.prank(user1);
        vm.expectRevert(IRAREBurner.OnlyPoolManager.selector);
        burner.unlockCallback(callbackData);

        vm.prank(address(mockPoolManager));
        vm.expectRevert(IRAREBurner.UnexpectedUnlock.selector);
        burner.unlockCallback(callbackData);
    }

    /// @notice Test unlockCallback reverts when context hash mismatch
    function test_UnlockCallback_RevertsWhen_ContextHashMismatch() public {
        address mockRAREToken = makeAddr("mockRAREToken");

        vm.prank(admin);
        burner = new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(0),
            0,
            true
        );

        // Try to call unlockCallback without setting context
        bytes memory data = abi.encode(
            1 ether,
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(mockRAREToken),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            }),
            uint160(0),
            uint256(0),
            Currency.wrap(mockRAREToken),
            address(0x000000000000000000000000000000000000dEaD)
        );

        vm.expectRevert(IRAREBurner.UnexpectedUnlock.selector);
        vm.prank(address(0x1234567890123456789012345678901234567890));
        burner.unlockCallback(data);
    }

    // ============================================
    // SECTION: Partial Fill Accounting Tests
    // ============================================

    // ============================================
    // SECTION: Slippage Enforcement Tests
    // ============================================

    /// @notice Test that flush() emits BurnFailed when slippage exceeded
    function test_Flush_EmitsBurnFailed_WhenSlippageExceeded() public {
        address mockRAREToken = makeAddr("mockRAREToken");
        MockQuoterForced mockQuoter = new MockQuoterForced();
        mockQuoter.setMockQuote(1 ether); // Quote 1 RARE for 1 ETH

        MockPoolManagerForced mockPoolManager = new MockPoolManagerForced();
        // Configure to return less than minOut (slippage exceeded)
        mockPoolManager.setShouldPartialFill(true, 4000); // 40% fill = 60% slippage > 5% max

        vm.prank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(mockPoolManager),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(mockQuoter),
            500, // 5% max slippage
            true
        );

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        testBurner.depositForBurn{value: 1 ether}();

        uint256 pendingBefore = testBurner.pendingEth();

        // Should emit BurnFailed due to slippage
        vm.expectEmit(true, false, false, true);
        emit IRAREBurner.BurnFailed(1 ether, 0); // FAIL_SWAP = 0

        testBurner.flush();

        assertEq(testBurner.pendingEth(), pendingBefore);
    }

    /// @notice Test that flush() emits BurnFailed when quoter returns zero
    function test_Flush_EmitsBurnFailed_WhenQuoterReturnsZero() public {
        address mockRAREToken = makeAddr("mockRAREToken");
        MockQuoterForced mockQuoter = new MockQuoterForced();
        mockQuoter.setShouldReturnZero(true);

        vm.prank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(mockQuoter),
            500,
            true
        );

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        testBurner.depositForBurn{value: 1 ether}();

        uint256 pendingBefore = testBurner.pendingEth();

        vm.expectEmit(true, false, false, true);
        emit IRAREBurner.BurnFailed(1 ether, 1); // FAIL_QUOTE = 1

        testBurner.flush();

        assertEq(testBurner.pendingEth(), pendingBefore);
    }

    /// @notice Test that flush() keeps pendingEth unchanged when slippage exceeded
    function test_Flush_PendingEthUnchanged_WhenSlippageExceeded() public {
        address mockRAREToken = makeAddr("mockRAREToken");
        MockQuoterForced mockQuoter = new MockQuoterForced();
        mockQuoter.setMockQuote(1 ether);

        MockPoolManagerForced mockPoolManager = new MockPoolManagerForced();
        mockPoolManager.setShouldPartialFill(true, 4000); // High slippage

        vm.prank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(mockPoolManager),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(mockQuoter),
            500,
            true
        );

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        testBurner.depositForBurn{value: 1 ether}();

        uint256 pendingBefore = testBurner.pendingEth();
        assertEq(pendingBefore, 1 ether);

        testBurner.flush();

        // PendingEth should be unchanged after slippage failure
        assertEq(testBurner.pendingEth(), pendingBefore);
    }

    /// @notice Test that receive() when paused allows ETH recovery via sweepExcess
    function test_Receive_WhenPaused_ETHCanBeRecoveredViaSweepExcess() public {
        address mockRAREToken = makeAddr("mockRAREToken");

        vm.prank(admin);
        burner = new RAREBurner(
            admin,
            false,
            mockRAREToken,
            address(0x1234567890123456789012345678901234567890),
            3000,
            60,
            address(0),
            0x000000000000000000000000000000000000dEaD,
            address(0),
            0,
            true
        );

        // Pause the burner
        vm.prank(admin);
        burner.pause(true);

        // Send ETH via receive() while paused
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        (bool success, ) = address(burner).call{value: 1 ether}("");
        assertTrue(success, "ETH should be accepted even when paused");

        // pendingEth should not be incremented
        assertEq(burner.pendingEth(), 0);

        // But ETH should be recoverable via sweepExcess
        uint256 balanceBefore = user1.balance;
        vm.prank(admin);
        burner.sweepExcess(user1);

        assertEq(user1.balance, balanceBefore + 1 ether);
    }
}
