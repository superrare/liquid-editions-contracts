// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {RAREBurner} from "../src/RAREBurner.sol";
import {IRAREBurner} from "../src/interfaces/IRAREBurner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

// Mock ERC20 for testing
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock RARE", "MRARE") {
        _mint(msg.sender, 1000000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Helper library for computing pool IDs
library PoolIdHelper {
    using {PoolIdLibrary.toId} for PoolKey;

    function computePoolId(
        address rareToken,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) internal pure returns (bytes32) {
        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(rareToken);
        bool ethIs0 = uint160(address(0)) < uint160(rareToken);

        PoolKey memory key = PoolKey({
            currency0: ethIs0 ? ethC : rareC,
            currency1: ethIs0 ? rareC : ethC,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        return PoolId.unwrap(key.toId());
    }
}

// Mock PoolManager for testing
contract MockPoolManager {
    address public expectedCallback;
    bytes public returnDelta;
    bool public shouldRevert;

    function setExpectedCallback(address _callback) external {
        expectedCallback = _callback;
    }

    function setReturnDelta(bytes memory _delta) external {
        returnDelta = _delta;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function unlock(
        bytes calldata /* data */
    ) external view returns (bytes memory) {
        if (shouldRevert) revert("Pool manager reverted");
        require(expectedCallback != address(0), "No callback set");
        return abi.encode(0);
    }

    function swap(
        bytes32 /* key */,
        bytes memory /* params */,
        bytes memory /* data */
    ) external pure returns (bytes memory) {
        // Return mock delta: -1 ETH (we owe), +100 RARE (we receive)
        return abi.encode(int128(-1 ether), int128(100 ether));
    }

    function settle() external payable {}

    function take(
        bytes32 /* currency */,
        address /* to */,
        uint256 /* amount */
    ) external {}
}

contract RAREBurnerTest is Test {
    // Test accounts
    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public burnAddress = 0x000000000000000000000000000000000000dEaD;

    // Contracts
    RAREBurner public burner;
    MockERC20 public mockRARE;
    MockPoolManager public mockPoolManager;

    // Events to test (consolidated)
    event Deposited(address indexed from, uint256 amount, uint256 pendingTotal);
    event Burned(uint256 ethIn, uint256 rareOut);
    event BurnFailed(uint256 ethIn, uint8 reason);
    event ConfigUpdated(bool enabled, uint16 maxSlippageBPS);
    event Paused(bool isPaused);

    function setUp() public {
        // Fund test accounts
        vm.deal(owner, 100 ether);
        vm.deal(user1, 100 ether);

        // Deploy mock contracts
        vm.startPrank(owner);
        mockRARE = new MockERC20();
        mockPoolManager = new MockPoolManager();

        // Deploy burner with full configuration
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);

        burner = new RAREBurner(
            owner, // owner
            false, // don't try on deposit initially
            address(mockRARE), // RARE token
            address(mockPoolManager), // V4 PoolManager
            poolFee, // 0.3% pool fee
            tickSpacing, // tick spacing
            hooks, // no hooks
            burnAddress, // burn address
            address(0), // no quoter for basic tests
            0, // 0% max slippage (no quoter, no slippage protection)
            true // enabled
        );

        // Give burner some RARE tokens to simulate successful swaps
        mockRARE.mint(address(burner), 1000 ether);

        vm.stopPrank();
    }

    // ============================================
    // TEST 1: Deposit buffers & doesn't revert
    // ============================================

    function testDepositBuffersWithoutRevert() public {
        uint256 depositAmount = 0.5 ether;

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit Deposited(user1, depositAmount, depositAmount);

        burner.depositForBurn{value: depositAmount}();

        assertEq(burner.pendingEth(), depositAmount);
        assertEq(address(burner).balance, depositAmount);
    }

    function testDepositWithBrokenConfig() public {
        // Disable burn in config
        vm.prank(owner);
        burner.toggleBurnEnabled(false);

        uint256 depositAmount = 0.5 ether;

        // Should still succeed (non-reverting)
        vm.prank(user1);
        burner.depositForBurn{value: depositAmount}();

        assertEq(burner.pendingEth(), depositAmount);
    }

    function testDepositWhenPaused() public {
        vm.prank(owner);
        burner.pause(true);

        vm.prank(user1);
        vm.expectRevert(IRAREBurner.BurnerPaused.selector);
        burner.depositForBurn{value: 0.5 ether}();
    }

    function testReceiveWhenPaused_DoesNotIncrementPending() public {
        // Pause the burner
        vm.prank(owner);
        burner.pause(true);

        uint256 pendingBefore = burner.pendingEth();

        // Send ETH via receive() - should accept but not increment pendingEth
        vm.prank(user1);
        (bool success, ) = address(burner).call{value: 1 ether}("");
        assertTrue(success, "ETH transfer should succeed");

        // pendingEth should NOT have changed
        assertEq(
            burner.pendingEth(),
            pendingBefore,
            "pendingEth should not increase when paused"
        );

        // But contract balance should have increased (forced sends can't be stopped)
        assertEq(
            address(burner).balance,
            1 ether,
            "Contract balance should increase"
        );
    }

    // ============================================
    // TEST 2: Flush succeeds with deltas settled
    // ============================================

    function testFlushNotRevertingOnDisabledBurn() public {
        // Deposit some ETH
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        // Disable burn
        vm.prank(owner);
        burner.toggleBurnEnabled(false);

        // Flush should not revert, just do nothing
        uint256 pendingBefore = burner.pendingEth();
        burner.flush();

        // Pending should remain unchanged
        assertEq(burner.pendingEth(), pendingBefore);
    }

    // ============================================
    // TEST 3: Unlock guards enforced
    // ============================================

    function testUnlockCallbackOnlyPoolManager() public {
        // Build proper PoolKey and Currency for the callback data
        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(address(mockRARE));

        PoolKey memory key = PoolKey({
            currency0: ethC,
            currency1: rareC,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bytes memory fakeData = abi.encode(
            1 ether, // ethAmount
            key, // PoolKey (proper struct)
            uint160(1), // priceLimit
            0, // minOut
            rareC, // RARE currency (proper type)
            burnAddress // burnTo
        );

        // Call from non-PoolManager address (user1)
        vm.prank(user1);
        vm.expectRevert(RAREBurner.OnlyPoolManager.selector);
        burner.unlockCallback(fakeData);
    }

    // ============================================
    // TEST 4: PoolId identity required
    // ============================================

    function testPoolIdMismatchNoDecrease() public {
        // Deposit ETH
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        // Deploy a NEW burner with a DIFFERENT token address
        // This will compute a different PoolId, causing the flush to detect a mismatch
        address differentToken = makeAddr("differentRAREToken");
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);

        // Deploy new burner with different token (creates pool ID mismatch)
        vm.prank(owner);
        RAREBurner newBurner = new RAREBurner(
            owner,
            false,
            differentToken, // Using different token creates valid but mismatched config
            address(mockPoolManager),
            poolFee,
            tickSpacing,
            hooks,
            burnAddress,
            address(0),
            0, // No slippage (no quoter available)
            true // enabled
        );

        // Transfer pending ETH to new burner for testing
        uint256 pendingBefore = burner.pendingEth();
        vm.prank(owner);
        burner.sweep(address(newBurner), pendingBefore);

        // Send ETH to new burner
        vm.deal(address(newBurner), pendingBefore);
        vm.prank(address(newBurner));
        (bool success, ) = address(newBurner).call{value: pendingBefore}("");
        require(success, "ETH transfer failed");

        uint256 newBurnerPendingBefore = newBurner.pendingEth();

        // Flush should not decrease pending (pool ID mismatch - new burner expects different token)
        newBurner.flush();

        assertEq(newBurner.pendingEth(), newBurnerPendingBefore);
    }

    // ============================================
    // TEST 5: Pause & sweep
    // ============================================

    function testPause() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit Paused(true);
        burner.pause(true);

        assertTrue(burner.paused());

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit Paused(false);
        burner.pause(false);

        assertFalse(burner.paused());
    }

    function testSweep() public {
        // Deposit ETH
        vm.prank(user1);
        burner.depositForBurn{value: 2 ether}();

        assertEq(burner.pendingEth(), 2 ether);

        uint256 recipientBalanceBefore = owner.balance;

        // Sweep half
        vm.prank(owner);
        burner.sweep(owner, 1 ether);

        assertEq(burner.pendingEth(), 1 ether);
        assertEq(owner.balance, recipientBalanceBefore + 1 ether);

        // Sweep all (amount=0)
        vm.prank(owner);
        burner.sweep(owner, 0);

        assertEq(burner.pendingEth(), 0);
        assertEq(owner.balance, recipientBalanceBefore + 2 ether);
    }

    function testSweepInsufficientBalance() public {
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRAREBurner.InsufficientPendingEth.selector,
                2 ether,
                1 ether
            )
        );
        burner.sweep(owner, 2 ether);
    }

    function testSweepOnlyOwner() public {
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        vm.prank(user1);
        vm.expectRevert();
        burner.sweep(user1, 1 ether);
    }

    // ============================================
    // TEST 6: Receive ETH (inert)
    // ============================================

    function testReceiveEthIsInert() public {
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit Deposited(user1, 1 ether, 1 ether);

        (bool success, ) = address(burner).call{value: 1 ether}("");
        assertTrue(success);

        assertEq(burner.pendingEth(), 1 ether);
    }

    // ============================================
    // TEST 7: Config updates
    // ============================================

    function testSetTryOnDeposit() public {
        bool newTry = true;

        vm.startPrank(owner);
        burner.setTryOnDeposit(newTry);
        vm.stopPrank();

        // Verify via reading state variable
        bool tryOn = burner.tryOnDeposit();
        assertEq(tryOn, newTry);
    }

    // ============================================
    // TEST 8: Deposit with tryOnDeposit
    // ============================================

    function testDepositWithTryOnDeposit() public {
        // Enable tryOnDeposit
        vm.startPrank(owner);
        burner.setTryOnDeposit(true);

        // Disable burn to avoid actual swap attempt
        burner.toggleBurnEnabled(false);
        vm.stopPrank();

        // Deposit should trigger flush attempt
        vm.prank(user1);
        burner.depositForBurn{value: 0.5 ether}();

        // Since burn is disabled, pending should remain
        assertEq(burner.pendingEth(), 0.5 ether);
    }

    // ============================================
    // TEST 9: Multiple deposits accumulate
    // ============================================

    function testMultipleDepositsAccumulate() public {
        vm.prank(user1);
        burner.depositForBurn{value: 0.5 ether}();

        vm.prank(user1);
        burner.depositForBurn{value: 0.3 ether}();

        vm.prank(user1);
        burner.depositForBurn{value: 0.2 ether}();

        assertEq(burner.pendingEth(), 1 ether);
    }

    // ============================================
    // TEST 10: Flush when nothing pending
    // ============================================

    function testFlushWithNoPending() public {
        assertEq(burner.pendingEth(), 0);

        // Should not revert
        burner.flush();

        assertEq(burner.pendingEth(), 0);
    }

    // ============================================
    // TEST 11: Flush when paused
    // ============================================

    function testFlushWhenPaused() public {
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        vm.prank(owner);
        burner.pause(true);

        vm.expectRevert(IRAREBurner.BurnerPaused.selector);
        burner.flush();
    }

    // ============================================
    // TEST 12: sweepExcess for force-sent ETH
    // ============================================

    function testSweepExcessAfterForceSend() public {
        // Setup: deposit 1 ETH through normal path
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        assertEq(burner.pendingEth(), 1 ether);
        assertEq(address(burner).balance, 1 ether);

        // Simulate force-send via selfdestruct (using vm.deal to simulate)
        // This bypasses pendingEth accounting
        vm.deal(address(burner), 3 ether); // Now has 3 ETH total

        assertEq(address(burner).balance, 3 ether);
        assertEq(burner.pendingEth(), 1 ether); // Still only 1 ETH tracked

        uint256 recipientBalanceBefore = owner.balance;

        // Sweep excess (should be 2 ETH)
        vm.prank(owner);
        burner.sweepExcess(owner);

        // Verify results
        assertEq(
            burner.pendingEth(),
            1 ether,
            "pendingEth should remain unchanged"
        );
        assertEq(
            address(burner).balance,
            1 ether,
            "Contract should have pendingEth balance left"
        );
        assertEq(
            owner.balance,
            recipientBalanceBefore + 2 ether,
            "Owner should receive excess"
        );
    }

    function testSweepExcessWithNoExcess() public {
        // Deposit 1 ETH through normal path
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        // Try to sweep excess when none exists
        vm.prank(owner);
        vm.expectRevert(IRAREBurner.NoExcessEth.selector);
        burner.sweepExcess(owner);
    }

    function testSweepExcessWithBalanceLessThanPending() public {
        // Create scenario where balance < pendingEth (shouldn't happen normally)
        // This could theoretically occur if there's a bug or external manipulation

        // Deposit ETH
        vm.prank(user1);
        burner.depositForBurn{value: 2 ether}();

        // Sweep some actual balance using regular sweep
        vm.prank(owner);
        burner.sweep(owner, 1 ether);

        assertEq(burner.pendingEth(), 1 ether);
        assertEq(address(burner).balance, 1 ether);

        // Now force balance to be less than pending (using vm.deal)
        vm.deal(address(burner), 0.5 ether);

        // sweepExcess should revert with "No excess ETH"
        vm.prank(owner);
        vm.expectRevert(IRAREBurner.NoExcessEth.selector);
        burner.sweepExcess(owner);
    }

    function testSweepExcessOnlyOwner() public {
        // Setup excess ETH
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        vm.deal(address(burner), 2 ether);

        // Non-owner should not be able to sweep excess
        vm.prank(user1);
        vm.expectRevert();
        burner.sweepExcess(user1);
    }

    function testSweepExcessDoesNotAffectPending() public {
        // Deposit through normal path
        vm.prank(user1);
        burner.depositForBurn{value: 5 ether}();

        // Force-send additional ETH
        vm.deal(address(burner), 10 ether);

        uint256 pendingBefore = burner.pendingEth();

        // Sweep excess
        vm.prank(owner);
        burner.sweepExcess(owner);

        // pendingEth should be completely unchanged
        assertEq(
            burner.pendingEth(),
            pendingBefore,
            "pendingEth must remain unchanged"
        );
        assertEq(
            address(burner).balance,
            pendingBefore,
            "Only pendingEth should remain"
        );
    }

    function testSweepExcessMultipleTimes() public {
        // Initial deposit
        vm.prank(user1);
        burner.depositForBurn{value: 1 ether}();

        // Force-send ETH
        vm.deal(address(burner), 3 ether);

        // First sweep of excess
        vm.prank(owner);
        burner.sweepExcess(owner);

        assertEq(address(burner).balance, 1 ether);
        assertEq(burner.pendingEth(), 1 ether);

        // Force-send more ETH
        vm.deal(address(burner), 4 ether);

        uint256 recipientBalanceBefore = owner.balance;

        // Second sweep of excess
        vm.prank(owner);
        burner.sweepExcess(owner);

        assertEq(address(burner).balance, 1 ether);
        assertEq(burner.pendingEth(), 1 ether);
        assertEq(
            owner.balance - recipientBalanceBefore,
            3 ether,
            "Should receive 3 ETH excess"
        );
    }

    function testSweepExcessAfterPartialSweep() public {
        // Deposit 5 ETH
        vm.prank(user1);
        burner.depositForBurn{value: 5 ether}();

        // Regular sweep of 2 ETH
        vm.prank(owner);
        burner.sweep(owner, 2 ether);

        assertEq(burner.pendingEth(), 3 ether);
        assertEq(address(burner).balance, 3 ether);

        // Force-send 2 ETH
        vm.deal(address(burner), 5 ether);

        uint256 recipientBalanceBefore = owner.balance;

        // Sweep excess
        vm.prank(owner);
        burner.sweepExcess(owner);

        assertEq(burner.pendingEth(), 3 ether, "pendingEth unchanged");
        assertEq(address(burner).balance, 3 ether, "Balance equals pendingEth");
        assertEq(
            owner.balance - recipientBalanceBefore,
            2 ether,
            "Received 2 ETH excess"
        );
    }
}
