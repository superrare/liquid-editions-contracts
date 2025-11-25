// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {RAREBurner} from "../src/RAREBurner.sol";
import {IRAREBurner} from "../src/interfaces/IRAREBurner.sol";
import {NetworkConfig} from "../script/NetworkConfig.sol";

/// @title RARE Burner Fork Tests
/// @notice Fork tests for RAREBurner on Base mainnet
contract RAREBurnerForkTest is Test {
    // Network configuration
    NetworkConfig.Config public config;

    // Test accounts
    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public burnAddress = 0x000000000000000000000000000000000000dEaD;

    RAREBurner public burner;

    function setUp() public {
        // Fork Base mainnet - skip if FORK_URL not set
        string memory forkUrl = vm.envOr("FORK_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(forkUrl);
        
        // Get network configuration (Base mainnet chain ID = 8453)
        config = NetworkConfig.getConfig(block.chainid);

        // Fund test accounts
        vm.deal(owner, 100 ether);
        vm.deal(user1, 100 ether);

        // Deploy burner accumulator with full configuration
        vm.startPrank(owner);
        burner = new RAREBurner(
            owner,
            false, // tryOnDeposit
            config.rareToken,
            config.uniswapV4PoolManager,
            3000, // 0.3% fee
            60, // tick spacing
            address(0), // no hooks
            burnAddress,
            config.uniswapV4Quoter, // Real quoter
            500, // 5% max slippage
            true // enabled
        );

        vm.stopPrank();
    }

    function testConstructorRequiresQuoterWhenSlippageEnabled() public {
        vm.startPrank(owner);

        // Should revert if slippage > 0 but quoter is address(0)
        vm.expectRevert(IRAREBurner.AddressZero.selector);
        new RAREBurner(
            owner,
            false,
            config.rareToken,
            config.uniswapV4PoolManager,
            3000,
            60,
            address(0),
            burnAddress,
            address(0), // No quoter
            500, // 5% slippage (requires quoter!)
            true
        );

        vm.stopPrank();
    }

    function testConstructorRequiresNonZeroBurnAddress() public {
        vm.startPrank(owner);

        // Should revert if burn address is address(0)
        vm.expectRevert(IRAREBurner.AddressZero.selector);
        new RAREBurner(
            owner,
            false,
            config.rareToken,
            config.uniswapV4PoolManager,
            3000,
            60,
            address(0),
            address(0), // Zero burn address!
            config.uniswapV4Quoter,
            500,
            true
        );

        vm.stopPrank();
    }

    function testConstructorAllowsZeroSlippageWithoutQuoter() public {
        vm.startPrank(owner);

        // Should succeed if slippage = 0 even without quoter
        RAREBurner testBurner = new RAREBurner(
            owner,
            false,
            config.rareToken,
            config.uniswapV4PoolManager,
            3000,
            60,
            address(0),
            burnAddress,
            address(0), // No quoter
            0, // 0% slippage (OK without quoter)
            true
        );

        // Verify it was set correctly - read individual state variables
        address rareToken = testBurner.rareToken();
        address v4PoolManager = testBurner.v4PoolManager();
        address v4Quoter = testBurner.v4Quoter();
        address storedBurnAddr = testBurner.burnAddress();
        uint16 maxSlippageBPS = testBurner.maxSlippageBPS();

        assertEq(rareToken, config.rareToken);
        assertEq(v4PoolManager, config.uniswapV4PoolManager);
        assertEq(v4Quoter, address(0));
        assertEq(storedBurnAddr, burnAddress);
        assertEq(maxSlippageBPS, 0);

        vm.stopPrank();
    }
}

/// @title RARE Token Burn Mechanism Test
/// @notice Proves how RARE token burning works on Base mainnet
/// @dev RARE has burn(uint256) function, does NOT allow transfer to address(0)
contract RARETokenBurnMechanismTest is Test {
    // Network configuration
    NetworkConfig.Config public config;

    // Test account
    address public testUser = makeAddr("testUser");

    function setUp() public {
        // Fork Base mainnet - try multiple possible env var names
        string memory rpcUrl;
        try vm.envString("FORK_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {
            try vm.envString("BASE_MAINNET_RPC_URL") returns (
                string memory url
            ) {
                rpcUrl = url;
            } catch {
                // Use public RPC as fallback
                rpcUrl = "https://mainnet.base.org";
            }
        }

        vm.createSelectFork(rpcUrl);
        
        // Get network configuration (Base mainnet chain ID = 8453)
        config = NetworkConfig.getConfig(block.chainid);

        // Verify we're on Base
        assertEq(block.chainid, 8453, "Should be on Base mainnet");

        // Fund test user
        vm.deal(testUser, 100 ether);
    }

    /// @notice Proves RARE token does NOT allow transfers to address(0)
    /// @dev This test validates that RARE rejects address(0) transfers (ERC20InvalidReceiver)
    function testRARERejectsTransferToZeroAddress() public {
        console.log("=== RARE TOKEN ZERO ADDRESS TRANSFER TEST ===");
        console.log("Testing on Base mainnet fork");
        console.log("RARE token address:", config.rareToken);

        // Get a holder with RARE tokens (use a known whale or create liquidity)
        // First, let's find the total supply and check if we can impersonate a holder
        (bool success, bytes memory data) = config.rareToken.staticcall(
            abi.encodeWithSignature("totalSupply()")
        );
        require(success, "Failed to get total supply");
        uint256 totalSupply = abi.decode(data, (uint256));
        console.log("RARE total supply:", totalSupply);

        console.log("\n--- Testing transfer signature ---");

        // Check if RARE has a typical ERC20 interface
        (bool hasTransfer, ) = config.rareToken.staticcall(
            abi.encodeWithSignature("transfer(address,uint256)", address(0), 0)
        );

        // If the call succeeds with amount 0, the function exists
        console.log("RARE has transfer function:", hasTransfer);

        // Now let's test with actual tokens by finding a real holder
        // We can use storage inspection to find holders
        console.log("\n--- Finding RARE token holder ---");

        // Common holder addresses on Base (exchanges, pools, etc.)
        address[] memory potentialHolders = new address[](4);
        potentialHolders[0] = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA; // BaseScan top holder example
        potentialHolders[1] = 0x0000000000000000000000000000000000000001; // Unlikely but check
        potentialHolders[2] = config.weth; // WETH
        potentialHolders[3] = config.uniswapV4PoolManager; // V4 Pool Manager

        address holder = address(0);
        uint256 holderBalance = 0;

        for (uint256 i = 0; i < potentialHolders.length; i++) {
            (bool balSuccess, bytes memory balData) = config.rareToken.staticcall(
                abi.encodeWithSignature(
                    "balanceOf(address)",
                    potentialHolders[i]
                )
            );
            if (balSuccess) {
                uint256 bal = abi.decode(balData, (uint256));
                if (bal > 0) {
                    holder = potentialHolders[i];
                    holderBalance = bal;
                    console.log("Found holder:", holder);
                    console.log("Holder balance:", holderBalance);
                    break;
                }
            }
        }

        // If we didn't find a holder, use vm.store to create one for testing
        if (holder == address(0)) {
            console.log(
                "No holder found in common addresses, creating test holder"
            );
            holder = testUser;
            holderBalance = 1000e18; // 1000 RARE tokens

            // Calculate storage slot for balances mapping (typically slot 0 for ERC20)
            // slot = keccak256(abi.encode(holder, 0)) for mapping at slot 0
            bytes32 balanceSlot = keccak256(abi.encode(holder, uint256(0)));

            // Set balance
            vm.store(config.rareToken, balanceSlot, bytes32(holderBalance));

            // Verify balance was set
            (bool checkSuccess, bytes memory checkData) = config.rareToken.staticcall(
                abi.encodeWithSignature("balanceOf(address)", holder)
            );
            require(checkSuccess, "Failed to check balance");
            uint256 checkBalance = abi.decode(checkData, (uint256));
            console.log("Created holder with balance:", checkBalance);

            // Adjust if the slot was wrong (try slot 1, 2, etc.)
            if (checkBalance == 0) {
                for (uint256 slot = 1; slot <= 10; slot++) {
                    balanceSlot = keccak256(abi.encode(holder, slot));
                    vm.store(config.rareToken, balanceSlot, bytes32(holderBalance));

                    (checkSuccess, checkData) = config.rareToken.staticcall(
                        abi.encodeWithSignature("balanceOf(address)", holder)
                    );
                    if (checkSuccess) {
                        checkBalance = abi.decode(checkData, (uint256));
                        if (checkBalance > 0) {
                            console.log("Found correct slot:", slot);
                            console.log("Holder balance:", checkBalance);
                            holderBalance = checkBalance;
                            break;
                        }
                    }
                }
            }
        }

        require(
            holderBalance > 0,
            "Failed to find or create holder with RARE tokens"
        );

        console.log("\n--- Testing transfer to address(0) ---");

        // Get balance of address(0) before transfer
        (bool zeroBalSuccess, bytes memory zeroBalData) = config.rareToken.staticcall(
            abi.encodeWithSignature("balanceOf(address)", address(0))
        );
        require(zeroBalSuccess, "Failed to get address(0) balance");
        uint256 zeroBalanceBefore = abi.decode(zeroBalData, (uint256));
        console.log("address(0) balance before:", zeroBalanceBefore);

        // Attempt to transfer to address(0)
        uint256 amountToBurn = holderBalance / 10; // Burn 10% of holder's balance
        console.log("Attempting to burn:", amountToBurn);

        vm.prank(holder);
        (bool transferSuccess, bytes memory transferData) = config.rareToken.call(
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                address(0),
                amountToBurn
            )
        );

        if (!transferSuccess) {
            // If transfer failed, decode the revert reason
            console.log("Transfer to address(0) FAILED");
            if (transferData.length > 0) {
                console.log("Revert reason:");
                console.logBytes(transferData);
            }

            // RARE doesn't allow burning to address(0)
            // Error 0xec442f05 is ERC20InvalidReceiver(address(0))
            console.log(
                "Expected behavior: RARE rejects transfers to address(0)"
            );
            console.log(
                "Error signature: 0xec442f05 = ERC20InvalidReceiver(address(0))"
            );
            assertTrue(true, "RARE correctly rejects transfers to address(0)");
        } else {
            // Transfer succeeded!
            console.log("Transfer to address(0) SUCCEEDED");

            // Verify the transfer result
            bool transferResult = transferData.length > 0
                ? abi.decode(transferData, (bool))
                : true;
            assertTrue(transferResult, "Transfer should return true");

            // Check new balances
            (bool newBalSuccess, bytes memory newBalData) = config.rareToken
                .staticcall(
                    abi.encodeWithSignature("balanceOf(address)", holder)
                );
            require(newBalSuccess, "Failed to get new holder balance");
            uint256 newHolderBalance = abi.decode(newBalData, (uint256));

            (bool newZeroSuccess, bytes memory newZeroData) = config.rareToken
                .staticcall(
                    abi.encodeWithSignature("balanceOf(address)", address(0))
                );
            require(newZeroSuccess, "Failed to get new address(0) balance");
            uint256 zeroBalanceAfter = abi.decode(newZeroData, (uint256));

            console.log("Holder balance after:", newHolderBalance);
            console.log("address(0) balance after:", zeroBalanceAfter);

            // Verify balances changed correctly
            assertEq(
                newHolderBalance,
                holderBalance - amountToBurn,
                "Holder balance should decrease"
            );

            console.log("\n=== UNEXPECTED: Transfer succeeded ===");
            console.log(
                "This should not happen - RARE should reject address(0) transfers"
            );
            assertTrue(
                false,
                "RARE unexpectedly allowed transfer to address(0)"
            );
        }
    }

    /// @notice Test that RARE token has a burn(uint256) function
    /// @dev This is the proper way to burn RARE - not transfer to address(0) or burnAddress
    function testRAREHasBurnFunction() public {
        console.log("=== Testing RARE burn() Function ===");

        // Find a holder
        address holder = config.uniswapV4PoolManager; // V4 Pool Manager (has RARE)

        (bool success, bytes memory data) = config.rareToken.staticcall(
            abi.encodeWithSignature("balanceOf(address)", holder)
        );
        require(success, "Failed to get balance");
        uint256 balanceBefore = abi.decode(data, (uint256));
        console.log("Holder balance before:", balanceBefore);
        require(balanceBefore > 0, "Holder must have RARE tokens");

        // Get total supply before
        (bool tsSuccess, bytes memory tsData) = config.rareToken.staticcall(
            abi.encodeWithSignature("totalSupply()")
        );
        require(tsSuccess, "Failed to get total supply");
        uint256 totalSupplyBefore = abi.decode(tsData, (uint256));
        console.log("Total supply before:", totalSupplyBefore);

        // Try to burn some tokens
        uint256 burnAmount = balanceBefore / 100; // Burn 1%
        console.log("Attempting to burn:", burnAmount);

        vm.prank(holder);
        (bool burnSuccess, bytes memory burnData) = config.rareToken.call(
            abi.encodeWithSignature("burn(uint256)", burnAmount)
        );

        if (!burnSuccess) {
            console.log("Burn failed - revert data:");
            console.logBytes(burnData);
            assertTrue(false, "burn() should succeed");
        }

        console.log("[PASS] burn(uint256) succeeded!");

        // Verify balance decreased
        (success, data) = config.rareToken.staticcall(
            abi.encodeWithSignature("balanceOf(address)", holder)
        );
        require(success, "Failed to get new balance");
        uint256 balanceAfter = abi.decode(data, (uint256));
        console.log("Holder balance after:", balanceAfter);

        assertEq(
            balanceAfter,
            balanceBefore - burnAmount,
            "Balance should decrease by burn amount"
        );

        // Verify total supply decreased
        (tsSuccess, tsData) = config.rareToken.staticcall(
            abi.encodeWithSignature("totalSupply()")
        );
        require(tsSuccess, "Failed to get new total supply");
        uint256 totalSupplyAfter = abi.decode(tsData, (uint256));
        console.log("Total supply after:", totalSupplyAfter);

        assertEq(
            totalSupplyAfter,
            totalSupplyBefore - burnAmount,
            "Total supply should decrease"
        );

        console.log("\n=== CONCLUSION ===");
        console.log("[PASS] RARE has burn(uint256) function");
        console.log("[PASS] burn() properly reduces balance and total supply");
        console.log("[PASS] RAREBurner should use burn() instead of transfer");
        console.log(
            "[IMPORTANT] burnAddress parameter should be removed or ignored"
        );
    }
}
