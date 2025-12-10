// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidRouter} from "../src/LiquidRouter.sol";
import {ILiquidRouter} from "../src/interfaces/ILiquidRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LiquidRouter Sepolia Fork Tests
 * @notice Tests buy and sell functionality against real Sepolia deployment
 * @dev Run with: forge test --match-contract LiquidRouterSepoliaForkTest --fork-url $ETH_SEPOLIA -vvv
 */
contract LiquidRouterSepoliaForkTest is Test {
    // Deployed contract addresses on Sepolia
    address constant LIQUID_ROUTER = 0x34a00cd690d892675da7B2Ded1B309EdAB6b6BAe;
    address constant RARE_TOKEN = 0x197FaeF3f59eC80113e773Bb6206a17d183F97CB;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    
    // Universal Router command codes
    bytes1 constant WRAP_ETH = 0x0b;
    bytes1 constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 constant UNWRAP_WETH = 0x0c;
    
    // Recipient placeholders
    address constant MSG_SENDER = address(1);
    address constant ROUTER_ADDRESS = address(2);

    LiquidRouter public router;
    IERC20 public rareToken;
    
    address public user;

    function setUp() public {
        // Ensure we're on Sepolia fork
        require(block.chainid == 11155111, "Must run on Sepolia fork");
        
        router = LiquidRouter(payable(LIQUID_ROUTER));
        rareToken = IERC20(RARE_TOKEN);
        
        // Create test user with ETH
        user = makeAddr("testUser");
        vm.deal(user, 10 ether);
    }

    /// @notice Test buying RARE with ETH using V3 route
    function testFork_BuyRareWithEth() public {
        uint256 ethAmount = 0.001 ether;
        uint256 ethForSwap = ethAmount * 9700 / 10000; // 97% after 3% fee
        
        // Build route data: WRAP_ETH + V3_SWAP_EXACT_IN
        bytes memory routeData = _encodeBuyRoute(ethForSwap, 0, user);
        
        uint256 rareBalanceBefore = rareToken.balanceOf(user);
        uint256 ethBalanceBefore = user.balance;
        
        vm.prank(user);
        uint256 tokensReceived = router.buy{value: ethAmount}(
            RARE_TOKEN,
            user,                    // recipient
            address(0),              // no referrer
            1,                       // minTokensOut (very low for testing)
            routeData,
            block.timestamp + 1 hours
        );
        
        uint256 rareBalanceAfter = rareToken.balanceOf(user);
        uint256 ethBalanceAfter = user.balance;
        
        // Assertions
        assertGt(tokensReceived, 0, "Should receive tokens");
        assertEq(rareBalanceAfter - rareBalanceBefore, tokensReceived, "Balance should match received");
        assertEq(ethBalanceBefore - ethBalanceAfter, ethAmount, "Should spend exact ETH amount");
        
        console.log("Buy successful:");
        console.log("  ETH spent:", ethAmount);
        console.log("  RARE received:", tokensReceived);
    }

    /// @notice Test selling RARE for ETH using V3 route
    function testFork_SellRareForEth() public {
        // First, buy some RARE to sell
        uint256 ethToBuy = 0.002 ether;
        uint256 ethForSwap = ethToBuy * 9700 / 10000;
        bytes memory buyRouteData = _encodeBuyRoute(ethForSwap, 0, user);
        
        vm.prank(user);
        uint256 tokensBought = router.buy{value: ethToBuy}(
            RARE_TOKEN,
            user,
            address(0),
            1,
            buyRouteData,
            block.timestamp + 1 hours
        );
        
        // Now sell half of what we bought
        uint256 tokensToSell = tokensBought / 2;
        
        // Approve router to spend tokens
        vm.prank(user);
        rareToken.approve(LIQUID_ROUTER, tokensToSell);
        
        // Build sell route data: V3_SWAP_EXACT_IN + UNWRAP_WETH
        bytes memory sellRouteData = _encodeSellRoute(tokensToSell, 0);
        
        uint256 rareBalanceBefore = rareToken.balanceOf(user);
        uint256 ethBalanceBefore = user.balance;
        
        vm.prank(user);
        uint256 ethReceived = router.sell(
            RARE_TOKEN,
            tokensToSell,
            user,                    // recipient
            address(0),              // no referrer
            1,                       // minEthOut (very low for testing)
            sellRouteData,
            block.timestamp + 1 hours
        );
        
        uint256 rareBalanceAfter = rareToken.balanceOf(user);
        uint256 ethBalanceAfter = user.balance;
        
        // Assertions
        assertGt(ethReceived, 0, "Should receive ETH");
        assertEq(rareBalanceBefore - rareBalanceAfter, tokensToSell, "Should sell exact token amount");
        assertEq(ethBalanceAfter - ethBalanceBefore, ethReceived, "ETH balance should increase by received amount");
        
        console.log("Sell successful:");
        console.log("  RARE sold:", tokensToSell);
        console.log("  ETH received:", ethReceived);
    }

    /// @notice Test buy and sell round trip
    function testFork_BuySellRoundTrip() public {
        uint256 initialEth = user.balance;
        uint256 initialRare = rareToken.balanceOf(user);
        
        // Buy
        uint256 ethToBuy = 0.001 ether;
        uint256 ethForSwap = ethToBuy * 9700 / 10000;
        bytes memory buyRouteData = _encodeBuyRoute(ethForSwap, 0, user);
        
        vm.prank(user);
        uint256 tokensBought = router.buy{value: ethToBuy}(
            RARE_TOKEN,
            user,
            address(0),
            1,
            buyRouteData,
            block.timestamp + 1 hours
        );
        
        console.log("Bought RARE:", tokensBought);
        
        // Approve and sell all
        vm.prank(user);
        rareToken.approve(LIQUID_ROUTER, tokensBought);
        
        bytes memory sellRouteData = _encodeSellRoute(tokensBought, 0);
        
        vm.prank(user);
        uint256 ethReceived = router.sell(
            RARE_TOKEN,
            tokensBought,
            user,
            address(0),
            1,
            sellRouteData,
            block.timestamp + 1 hours
        );
        
        console.log("Sold for ETH:", ethReceived);
        
        uint256 finalEth = user.balance;
        uint256 finalRare = rareToken.balanceOf(user);
        
        // After round trip, should have less ETH (fees + slippage) but same RARE
        assertEq(finalRare, initialRare, "RARE balance should be unchanged after round trip");
        assertLt(finalEth, initialEth, "Should have less ETH due to fees");
        
        uint256 totalCost = initialEth - finalEth;
        console.log("Round trip cost (ETH):", totalCost);
        console.log("Cost percentage:", totalCost * 10000 / ethToBuy, "bps");
    }

    /// @notice Test that slippage protection works
    /// @dev The revert happens at Universal Router level (V3TooLittleReceived = 0x39d35496)
    ///      which bubbles up through our contract
    function testFork_BuyRevertsOnSlippage() public {
        uint256 ethAmount = 0.001 ether;
        uint256 ethForSwap = ethAmount * 9700 / 10000;
        
        // Set minTokensOut very high to trigger slippage
        uint256 unreasonableMinOut = 1000000 ether;
        
        bytes memory routeData = _encodeBuyRoute(ethForSwap, unreasonableMinOut, user);
        
        vm.prank(user);
        // Universal Router reverts with V3TooLittleReceived when slippage exceeded
        // The error bubbles up through our contract
        vm.expectRevert(); // Accept any revert
        router.buy{value: ethAmount}(
            RARE_TOKEN,
            user,
            address(0),
            unreasonableMinOut,
            routeData,
            block.timestamp + 1 hours
        );
    }

    // ============================================
    // ROUTE ENCODING HELPERS
    // ============================================

    /// @notice Encode buy route: WRAP_ETH + V3_SWAP_EXACT_IN
    /// @dev Tokens MUST go to MSG_SENDER (LiquidRouter) for proper fee handling
    function _encodeBuyRoute(
        uint256 ethForSwap,
        uint256 minAmountOut,
        address /* recipient - ignored, LiquidRouter handles final transfer */
    ) internal view returns (bytes memory) {
        // Command 1: WRAP_ETH
        bytes memory wrapInput = abi.encode(
            ROUTER_ADDRESS,  // Keep WETH in Universal Router
            ethForSwap       // Amount to wrap
        );
        
        // V3 path: WETH -> RARE (0.3% fee = 3000)
        bytes memory path = abi.encodePacked(
            WETH,
            uint24(3000),
            RARE_TOKEN
        );
        
        // Command 2: V3_SWAP_EXACT_IN
        // CRITICAL: Send to MSG_SENDER (LiquidRouter) not directly to user
        // LiquidRouter checks balance delta and forwards to recipient
        bytes memory swapInput = abi.encode(
            MSG_SENDER,      // Send to LiquidRouter (msg.sender of execute)
            ethForSwap,      // amountIn
            minAmountOut,    // amountOutMin
            path,
            false            // payerIsUser = false (Universal Router has WETH)
        );
        
        // Encode execute call
        bytes memory commands = abi.encodePacked(WRAP_ETH, V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = wrapInput;
        inputs[1] = swapInput;
        
        return abi.encodeWithSignature(
            "execute(bytes,bytes[],uint256)",
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    /// @notice Encode sell route: V3_SWAP_EXACT_IN + UNWRAP_WETH
    function _encodeSellRoute(
        uint256 tokenAmount,
        uint256 minEthOut
    ) internal view returns (bytes memory) {
        // V3 path: RARE -> WETH (0.3% fee = 3000)
        bytes memory path = abi.encodePacked(
            RARE_TOKEN,
            uint24(3000),
            WETH
        );
        
        // Command 1: V3_SWAP_EXACT_IN
        bytes memory swapInput = abi.encode(
            ROUTER_ADDRESS,  // WETH stays in router for unwrap
            tokenAmount,     // amountIn
            minEthOut,       // amountOutMin
            path,
            true             // payerIsUser = true (Permit2 pulls from LiquidRouter)
        );
        
        // Command 2: UNWRAP_WETH
        bytes memory unwrapInput = abi.encode(
            MSG_SENDER,      // Send ETH to LiquidRouter (msg.sender)
            minEthOut        // minimum amount to unwrap
        );
        
        // Encode execute call
        bytes memory commands = abi.encodePacked(V3_SWAP_EXACT_IN, UNWRAP_WETH);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = swapInput;
        inputs[1] = unwrapInput;
        
        return abi.encodeWithSignature(
            "execute(bytes,bytes[],uint256)",
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }
}

