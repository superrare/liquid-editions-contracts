// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Liquid} from "../src/Liquid.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";

contract TestBuySell is Script {
    function run() external {
        // Contract address on Base Sepolia (will be updated after token creation)
        address tokenAddress = 0xa6F63d816bc5aEc5dea0418b8CDa649ceA21FBc3;

        // Amount to buy (0.005 ETH)
        uint256 ethToBuy = 0.005 ether;

        // Load environment variables
        uint256 userPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address user = vm.addr(userPrivateKey);

        console.log(
            "=== Testing quoteBuy() -> buy() -> quoteSell() -> sell() Flow ==="
        );
        console.log("Token address:", tokenAddress);
        console.log("User address:", user);
        console.log("ETH to buy:", ethToBuy);
        console.log("");

        // Get contract instance
        Liquid token = Liquid(payable(tokenAddress));

        // Check user's ETH balance
        uint256 ethBalanceBefore = user.balance;
        console.log("User ETH balance:", ethBalanceBefore);

        if (ethBalanceBefore < ethToBuy) {
            console.log("ERROR: Insufficient ETH balance!");
            console.log("Required:", ethToBuy);
            console.log("Available:", ethBalanceBefore);
            return;
        }

        // ============================================
        // PART 1: BUY FLOW
        // ============================================

        // Step 1: Get buy quote (simulated, no broadcast needed)
        console.log("=== Step 1: Calling quoteBuy() (simulated) ===");
        (
            uint256 buyFeeBps,
            uint256 buyEthFee,
            uint256 buyEthIn,
            uint256 buyTokenOut,
            uint160 buySqrtPriceX96After
        ) = token.quoteBuy(ethToBuy);

        console.log("Buy Quote Results:");
        console.log("  Fee BPS:", buyFeeBps);
        console.log("  ETH Fee:", buyEthFee);
        console.log("  ETH In (after fee):", buyEthIn);
        console.log("  Token Out:", buyTokenOut);
        console.log("  Sqrt Price After:", buySqrtPriceX96After);
        console.log("");

        // Step 2: Execute buy (broadcast this transaction)
        vm.startBroadcast(userPrivateKey);
        console.log("=== Step 2: Calling buy() ===");
        uint256 tokenBalanceBeforeBuy = token.balanceOf(user);
        uint256 ethBalanceBeforeBuy = user.balance;

        // Use 95% of quoted amount as minOrderSize for slippage protection (5% tolerance)
        uint256 minOrderSize = (buyTokenOut * 95) / 100;
        console.log("Min order size (95% of quote):", minOrderSize);
        console.log("sqrtPriceLimitX96 (from quote):", buySqrtPriceX96After);

        // Execute buy - recipient is the user, no referrer
        uint256 tokensReceived = token.buy{value: ethToBuy}(
            user, // recipient
            address(0), // orderReferrer
            minOrderSize, // minOrderSize
            buySqrtPriceX96After // sqrtPriceLimitX96 from quote
        );

        uint256 tokenBalanceAfterBuy = token.balanceOf(user);
        uint256 ethBalanceAfterBuy = user.balance;

        console.log("Buy Results:");
        console.log("  Tokens Received (return value):", tokensReceived);
        console.log("  ETH Balance Before:", ethBalanceBeforeBuy);
        console.log("  ETH Balance After:", ethBalanceAfterBuy);
        console.log("  ETH Spent:", ethBalanceBeforeBuy - ethBalanceAfterBuy);
        console.log("  Token Balance Before:", tokenBalanceBeforeBuy);
        console.log("  Token Balance After:", tokenBalanceAfterBuy);
        console.log(
            "  Tokens Received (balance change):",
            tokenBalanceAfterBuy - tokenBalanceBeforeBuy
        );
        console.log("");

        // Step 3: Compare buy quote vs actual
        console.log("=== Step 3: Buy Quote vs Actual Comparison ===");
        console.log("Quoted Token Out:", buyTokenOut);
        console.log("Actual Tokens Received:", tokensReceived);

        if (tokensReceived >= buyTokenOut) {
            console.log("Actual >= Quote (good!)");
            console.log("Difference:", tokensReceived - buyTokenOut);
        } else {
            uint256 difference = buyTokenOut - tokensReceived;
            uint256 slippageBps = (difference * 10000) / buyTokenOut;
            console.log("Actual < Quote");
            console.log("Difference:", difference);
            console.log("Slippage (BPS):", slippageBps);
        }
        console.log("");

        vm.stopBroadcast();

        // ============================================
        // PART 2: SELL FLOW
        // ============================================

        // Use the actual tokens received from the buy
        uint256 tokensToSell = tokensReceived;

        // Step 4: Get sell quote (simulated, no broadcast needed)
        console.log("=== Step 4: Calling quoteSell() (simulated) ===");
        (
            uint256 sellFeeBps,
            uint256 sellEthFee,
            uint256 sellTokenIn,
            uint256 sellEthOut,
            uint160 sellSqrtPriceX96After
        ) = token.quoteSell(tokensToSell);

        console.log("Sell Quote Results:");
        console.log("  Fee BPS:", sellFeeBps);
        console.log("  ETH Fee:", sellEthFee);
        console.log("  Token In:", sellTokenIn);
        console.log("  ETH Out (after fee):", sellEthOut);
        console.log("  Sqrt Price After:", sellSqrtPriceX96After);
        console.log("");

        // Step 5: Execute sell (broadcast this transaction)
        vm.startBroadcast(userPrivateKey);
        console.log("=== Step 5: Calling sell() ===");
        uint256 ethBalanceBeforeSell = user.balance;
        uint256 tokenBalanceBeforeSell = token.balanceOf(user);

        // Use 95% of quoted amount as minPayoutSize for slippage protection (5% tolerance)
        uint256 minPayoutSize = (sellEthOut * 95) / 100;
        console.log("Min payout size (95% of quote):", minPayoutSize);

        // Execute sell - recipient is the user, no referrer
        console.log("sqrtPriceLimitX96 (from quote):", sellSqrtPriceX96After);
        uint256 ethReceived = token.sell(
            tokensToSell,
            user, // recipient
            address(0), // orderReferrer
            minPayoutSize, // minPayoutSize
            sellSqrtPriceX96After // sqrtPriceLimitX96 from quote
        );

        uint256 ethBalanceAfterSell = user.balance;
        uint256 tokenBalanceAfterSell = token.balanceOf(user);

        console.log("Sell Results:");
        console.log("  ETH Received (return value):", ethReceived);
        console.log("  ETH Balance Before:", ethBalanceBeforeSell);
        console.log("  ETH Balance After:", ethBalanceAfterSell);
        console.log(
            "  ETH Balance Change:",
            ethBalanceAfterSell - ethBalanceBeforeSell
        );
        console.log("  Token Balance Before:", tokenBalanceBeforeSell);
        console.log("  Token Balance After:", tokenBalanceAfterSell);
        console.log(
            "  Tokens Sold:",
            tokenBalanceBeforeSell - tokenBalanceAfterSell
        );
        console.log("");

        // Step 6: Compare sell quote vs actual
        console.log("=== Step 6: Sell Quote vs Actual Comparison ===");
        console.log("Quoted ETH Out:", sellEthOut);
        console.log("Actual ETH Received:", ethReceived);

        if (ethReceived >= sellEthOut) {
            console.log("Actual >= Quote (good!)");
            console.log("Difference:", ethReceived - sellEthOut);
        } else {
            uint256 difference = sellEthOut - ethReceived;
            uint256 slippageBps = (difference * 10000) / sellEthOut;
            console.log("Actual < Quote");
            console.log("Difference:", difference);
            console.log("Slippage (BPS):", slippageBps);
        }
        console.log("");

        // ============================================
        // SUMMARY
        // ============================================

        console.log("=== Round Trip Summary ===");
        console.log(
            "ETH Spent (buy):",
            ethBalanceBeforeBuy - ethBalanceAfterBuy
        );
        console.log("ETH Received (sell):", ethReceived);
        uint256 netLoss = (ethBalanceBeforeBuy - ethBalanceAfterBuy) -
            ethReceived;
        console.log("Net Loss:", netLoss);
        if (netLoss > 0) {
            uint256 lossBps = (netLoss * 10000) /
                (ethBalanceBeforeBuy - ethBalanceAfterBuy);
            console.log("Loss Percentage (BPS):", lossBps);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Test Complete ===");
    }
}
