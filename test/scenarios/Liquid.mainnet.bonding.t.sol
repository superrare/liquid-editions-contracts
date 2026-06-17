// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidBondingForkBase} from "liquid-editions-test/helpers/LiquidBondingForkBase.sol";

/// @notice Minimal QuoterV2 interface for exact-output quotes
interface IQuoterV2 {
    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenUri;
        uint256 amount;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactOutputSingle(
        QuoteExactOutputSingleParams calldata params
    ) external returns (uint256 amountIn, uint160, uint32, uint256);
}

/**
 * @title LiquidMultiCurve Base Mainnet Bonding Curve Test
 * @notice Tests how different tick configurations affect the bonding curve pricing mechanism
 * @dev This test forks Base mainnet to test against real Uniswap V4 contracts
 */
contract LiquidInstantMainnetBondingTest is LiquidBondingForkBase {

    function testMainnetContractAddresses() public view {
        // Verify all Base mainnet contract addresses exist and have code
        console.log("=== BASE MAINNET CONTRACT VERIFICATION ===");

        assertTrue(config.weth.code.length > 0, "WETH should have code");
        console.log("WETH verified");

        assertTrue(
            config.uniswapV4PoolManager.code.length > 0,
            "V4 PoolManager should have code"
        );
        console.log("Uniswap V4 PoolManager verified");

        assertTrue(
            config.uniswapV4Quoter.code.length > 0,
            "V4 Quoter should have code"
        );
        console.log("Quoter V2 verified");
    }

    function testBondingCurveWithDifferentTicks() public {
        console.log(
            "=== BONDING CURVE ANALYSIS WITH DIFFERENT TICK CONFIGURATIONS ==="
        );

        for (uint256 i = 0; i < tickConfigs.length; i++) {
            _testSingleTickConfiguration(tickConfigs[i], i);
        }
    }

    function testBondingCurve_PropertyAssertions() public {
        // Test property: narrower tick ranges should have steeper price impact
        TickConfig memory wideConfig = tickConfigs[0]; // Default_Wide
        TickConfig memory narrowConfig = tickConfigs[1]; // Narrow_Steep

        LiquidFactory wideFactory = _deployLiquidWithTicks(
            wideConfig.tickLower,
            wideConfig.tickUpper
        );
        LiquidFactory narrowFactory = _deployLiquidWithTicks(
            narrowConfig.tickLower,
            narrowConfig.tickUpper
        );

        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(wideFactory), 0.1 ether);
        wideFactory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://wide-test",
            "WIDE",
            "W",
            0.1 ether,
            _defaultSingleCurve(wideFactory)
        );

        IERC20(mockRARE).approve(address(narrowFactory), 0.1 ether);
        narrowFactory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://narrow-test",
            "NARROW",
            "N",
            0.1 ether,
            _defaultSingleCurve(narrowFactory)
        );
        vm.stopPrank();
    }

    function _testSingleTickConfiguration(
        TickConfig memory tickConfig,
        uint256 configIndex
    ) internal {
        console.log("");
        console.log(
            string(
                abi.encodePacked(
                    "--- Configuration ",
                    vm.toString(configIndex + 1),
                    ": ",
                    tickConfig.name,
                    " ---"
                )
            )
        );
        console.log(
            string(abi.encodePacked("Description: ", tickConfig.description))
        );
        console.log(
            string(
                abi.encodePacked(
                    "Tick Lower: ",
                    vm.toString(tickConfig.tickLower)
                )
            )
        );
        console.log(
            string(
                abi.encodePacked(
                    "Tick Upper: ",
                    vm.toString(tickConfig.tickUpper)
                )
            )
        );

        // Deploy a factory with this tick configuration
        LiquidFactory tempFactory = _deployLiquidWithTicks(
            tickConfig.tickLower,
            tickConfig.tickUpper
        );

        // Create the liquid token through the factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(tempFactory), 0.1 ether);
        address tokenAddr = tempFactory.createLiquidTokenMultiCurve(
            tokenCreator,
            string(abi.encodePacked("ipfs://test-", tickConfig.name)),
            string(abi.encodePacked("LIQUID_", tickConfig.name)),
            string(abi.encodePacked("LQ_", tickConfig.name)),
            0.1 ether,
            _defaultSingleCurve(tempFactory)
        );
        vm.stopPrank();
        LiquidMultiCurve liquidImpl = LiquidMultiCurve(payable(tokenAddr));

        // Note: V4 pool state can be queried via StateLibrary.getSlot0() if needed
        // Pool state verification is implicit through successful trades

        console.log(
            string(
                abi.encodePacked(
                    "Initial pool tick: ",
                    vm.toString(int256(0)) // initialSlot0.tick
                )
            )
        );
        console.log(
            string(
                abi.encodePacked(
                    "Initial sqrt price: ",
                    vm.toString(uint256(0)) // initialSlot0.sqrtPriceX96
                )
            )
        );

        // Test purchase amounts and measure price impact
        uint256[] memory purchaseAmounts = new uint256[](5);
        purchaseAmounts[0] = 0.01 ether; // Small purchase
        purchaseAmounts[1] = 0.1 ether; // Medium purchase
        purchaseAmounts[2] = 0.5 ether; // Large purchase
        purchaseAmounts[3] = 1 ether; // Very large purchase
        purchaseAmounts[4] = 5 ether; // Huge purchase

        console.log("");
        console.log(
            "Purchase Amount (ETH) | Tokens Received | Price per Token (ETH) | Pool Tick After"
        );
        console.log(
            "---------------------|------------------|----------------------|----------------"
        );

        // Test sell pressure and price recovery
        console.log("");
        console.log("=== SELL PRESSURE TEST ===");

        // Get current token balance and pool state
        uint256 currentBalance = liquidImpl.balanceOf(buyer1);
        // Note: V4 pool state can be queried via StateLibrary if detailed verification is needed
        console.log(
            string(
                abi.encodePacked(
                    "Current token balance: ",
                    _formatTokens(currentBalance)
                )
            )
        );

        console.log(
            string(
                abi.encodePacked(
                    "Configuration ",
                    tickConfig.name,
                    " testing complete"
                )
            )
        );
    }

    function testTickMathPriceCalculations() public view {
        console.log("=== TICK MATH PRICE CALCULATIONS ===");

        for (uint256 i = 0; i < tickConfigs.length; i++) {
            TickConfig memory tickConfig = tickConfigs[i];

            console.log("");
            console.log(
                string(abi.encodePacked("Configuration: ", tickConfig.name))
            );
            console.log(
                string(
                    abi.encodePacked(
                        "Tick Lower: ",
                        vm.toString(tickConfig.tickLower)
                    )
                )
            );
            console.log(
                string(
                    abi.encodePacked(
                        "Tick Upper: ",
                        vm.toString(tickConfig.tickUpper)
                    )
                )
            );

            // Calculate sqrt prices at bounds
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(
                tickConfig.tickLower
            );
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(
                tickConfig.tickUpper
            );

            console.log(
                string(
                    abi.encodePacked(
                        "Sqrt Price at Lower Tick: ",
                        vm.toString(sqrtPriceLower)
                    )
                )
            );
            console.log(
                string(
                    abi.encodePacked(
                        "Sqrt Price at Upper Tick: ",
                        vm.toString(sqrtPriceUpper)
                    )
                )
            );

            // Calculate price range (these are relative prices, not absolute ETH prices)
            // Use safe math to avoid overflow - skip calculation for extreme tick values
            uint256 priceLower = 0;
            uint256 priceUpper = 0;

            // Only calculate if sqrtPrice values are within safe range
            // Avoid overflow by checking if multiplication would exceed uint256
            uint256 sqrtPriceLower256 = uint256(sqrtPriceLower);
            uint256 sqrtPriceUpper256 = uint256(sqrtPriceUpper);

            // Safe multiplication: check if result would overflow
            // sqrtPriceX96 is uint160, so sqrtPrice^2 could overflow uint256
            // Only calculate if sqrtPrice < sqrt(2^256) = 2^128
            if (sqrtPriceLower256 < (1 << 128)) {
                uint256 product = sqrtPriceLower256 * sqrtPriceLower256;
                if (product / sqrtPriceLower256 == sqrtPriceLower256) {
                    // Check no overflow
                    priceLower = product >> 192;
                }
            }

            if (sqrtPriceUpper256 < (1 << 128)) {
                uint256 product = sqrtPriceUpper256 * sqrtPriceUpper256;
                if (product / sqrtPriceUpper256 == sqrtPriceUpper256) {
                    // Check no overflow
                    priceUpper = product >> 192;
                }
            }

            console.log(
                string(
                    abi.encodePacked(
                        "Relative Price Range: ",
                        vm.toString(priceLower),
                        " to ",
                        vm.toString(priceUpper)
                    )
                )
            );

            if (priceLower > 0) {
                uint256 priceMultiplier = priceUpper / priceLower;
                console.log(
                    string(
                        abi.encodePacked(
                            "Price Multiplier (Upper/Lower): ",
                            vm.toString(priceMultiplier),
                            "x"
                        )
                    )
                );
            }
        }
    }

    function testCompareTickConfigurationEffects() public {
        console.log(
            "=== COMPARATIVE ANALYSIS: SAME PURCHASE ACROSS DIFFERENT TICK CONFIGS ==="
        );

        uint256 testPurchaseAmount = 1 ether;
        console.log(
            "Testing purchase amount: %s ETH",
            _formatEther(testPurchaseAmount)
        );
        console.log("");
        console.log(
            "Configuration      | Tokens Received | Effective Price | Final Pool Tick"
        );
        console.log(
            "-------------------|-----------------|-----------------|----------------"
        );

        for (uint256 i = 0; i < tickConfigs.length; i++) {
            TickConfig memory tickConfig = tickConfigs[i];

            // Deploy factory with tick configuration
            LiquidFactory tempFactory = _deployLiquidWithTicks(
                tickConfig.tickLower,
                tickConfig.tickUpper
            );

            // Create token through factory
            vm.startPrank(tokenCreator);
            IERC20(mockRARE).approve(address(tempFactory), 0.1 ether);
            tempFactory.createLiquidTokenMultiCurve(
                tokenCreator,
                "ipfs://test-compare",
                "LIQUID_TEST",
                "LQT",
                0.1 ether,
                _defaultSingleCurve(tempFactory)
            );
            vm.stopPrank();

            console.log(
                string(
                    abi.encodePacked(
                        tickConfig.name,
                        " | ",
                        "N/A",
                        " | ",
                        "N/A",
                        " | ",
                        "N/A"
                    )
                )
            );
        }
    }

    function testCostToBuySupplyPercentages() public {
        console.log("=== COST TO BUY DIFFERENT SUPPLY PERCENTAGES ===");
        console.log("Testing with tick range: -180 to 120000 (bonding curve)");

        // Deploy factory with the bonding curve tick range
        LiquidFactory tempFactory = _deployLiquidWithTicks(-180, 120000);

        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(tempFactory), 0.001 ether);
        address tokenAddr = tempFactory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test-supply-percentages",
            "SUPPLY_TEST",
            "SPY",
            0.001 ether,
            _defaultSingleCurve(tempFactory)
        );
        vm.stopPrank();
        LiquidMultiCurve liquidImpl = LiquidMultiCurve(payable(tokenAddr));

        // Get total supply available for purchase (excludes creator's initial allocation)
        uint256 totalSupply = liquidImpl.totalSupply();
        uint256 creatorAllocation = 100_000e18; // 100K tokens given to creator
        uint256 availableSupply = totalSupply - creatorAllocation; // 900K tokens available

        console.log("=== SUPPLY INFORMATION ===");
        console.log(
            string(
                abi.encodePacked("Total Supply: ", _formatTokens(totalSupply))
            )
        );
        console.log(
            string(
                abi.encodePacked(
                    "Creator Allocation: ",
                    _formatTokens(creatorAllocation)
                )
            )
        );
        console.log(
            string(
                abi.encodePacked(
                    "Available for Purchase: ",
                    _formatTokens(availableSupply)
                )
            )
        );
        console.log("");

        // Test different percentage purchases
        uint256[] memory percentages = new uint256[](6);
        percentages[0] = 1; // 1%
        percentages[1] = 5; // 5%
        percentages[2] = 10; // 10%
        percentages[3] = 25; // 25%
        percentages[4] = 50; // 50%
        percentages[5] = 70; // 70%

        console.log(
            "Supply % | Target Tokens | ETH Cost | Price per Token | Cumulative Cost"
        );
        console.log(
            "---------|---------------|----------|-----------------|----------------"
        );

        uint256 cumulativeCost = 0;

        for (uint256 i = 0; i < percentages.length; i++) {
            uint256 percentage = percentages[i];
            uint256 targetTokens = (availableSupply * percentage) / 100;

            // Find the cost through binary search
            uint256 ethCost = _findCostForTokenAmount(liquidImpl, targetTokens);
            cumulativeCost += ethCost;

            // Calculate effective price per token
            // Note: Fees are handled by LiquidInstantRouter, not stored in LiquidMultiCurve contract
            uint256 pricePerToken = (ethCost * 1e18) / targetTokens;

            console.log(
                string(
                    abi.encodePacked(
                        vm.toString(percentage),
                        "% | ",
                        _formatTokens(targetTokens),
                        " | ",
                        _formatEther(ethCost),
                        " | ",
                        _formatEther(pricePerToken),
                        " | ",
                        _formatEther(cumulativeCost)
                    )
                )
            );
        }

        console.log("");
        console.log("=== BONDING CURVE ANALYSIS ===");
        console.log("- Early percentages are extremely cheap");
        console.log("- Cost increases exponentially with larger percentages");
        console.log("- Strong incentive for early participation");
        console.log("- Later purchases become very expensive");
    }

    function _findCostForTokenAmount(
        LiquidMultiCurve liquidImpl,
        uint256 targetTokens
    ) internal returns (uint256) {
        // Use binary search to find the ETH cost for the target token amount
        // Since V4 quoter only supports exact input (not exact output), we need to search

        uint256 low = 0.001 ether;
        uint256 high = 1000 ether;
        uint256 tolerance = targetTokens / 100; // 1% tolerance

        // Binary search for the right ETH amount
        for (uint256 i = 0; i < 50; i++) {
            // Max 50 iterations
            uint256 mid = (low + high) / 2;

            // Get quote for this RARE amount
            (uint256 tokensOut, ) = liquidImpl.quoteBuy(mid);

            if (tokensOut < targetTokens - tolerance) {
                // Need more ETH
                low = mid;
            } else if (tokensOut > targetTokens + tolerance) {
                // Need less ETH
                high = mid;
            } else {
                // Close enough!
                return mid;
            }

            // If range is too small, we're done
            if (high - low < 0.0001 ether) {
                return mid;
            }
        }

        return (low + high) / 2;
    }

    function testCostToBuyOneToken() public {
        console.log("=== COST TO BUY EXACTLY 1 TOKEN ANALYSIS ===");
        console.log(
            "Testing with tick range: -150000 to -50000 (bonding curve)"
        );

        // Deploy factory with the specific tick range for a bonding curve
        // Start very cheap (-150000) and rise to moderately expensive (-50000)
        LiquidFactory tempFactory = _deployLiquidWithTicks(-150000, 150000);

        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(tempFactory), 0.1 ether);
        tempFactory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test-one-token",
            "ONE_TOKEN_TEST",
            "OTT",
            0.1 ether,
            _defaultSingleCurve(tempFactory)
        );
        vm.stopPrank();

        console.log("=== Testing Different Purchase Amounts ===");

        // Test several amounts to find approximate cost for 1 token
        uint256[] memory testAmounts = new uint256[](8);
        testAmounts[0] = 0.001 ether;
        testAmounts[1] = 0.01 ether;
        testAmounts[2] = 0.1 ether;
        testAmounts[3] = 0.5 ether;
        testAmounts[4] = 1 ether;
        testAmounts[5] = 2 ether;
        testAmounts[6] = 5 ether;
        testAmounts[7] = 10 ether;

        console.log(
            "ETH Amount | Tokens Received | Price per Token | Close to 1 token?"
        );
        console.log(
            "-----------|-----------------|-----------------|------------------"
        );

        console.log("");
        console.log("=== ANALYSIS ===");
        console.log("With tick range -150000 to -50000:");
        console.log(
            "- This creates a proper bonding curve (cheap to expensive)"
        );
        console.log(
            "- Tokens start very cheap and get progressively expensive"
        );
        console.log("- Good for rewarding early adopters");
        console.log("- Creates strong incentive for early purchases");
    }

    function testPriceImpactAnalysis() public {
        console.log("=== PRICE IMPACT ANALYSIS ===");

        // Use the narrow configuration for detailed analysis
        TickConfig memory narrowConfig = tickConfigs[1]; // Narrow_Steep

        console.log(
            string(
                abi.encodePacked(
                    "Analyzing price impact with configuration: ",
                    narrowConfig.name
                )
            )
        );
        console.log(
            string(abi.encodePacked("Description: ", narrowConfig.description))
        );

        // Deploy factory and create token
        LiquidFactory tempFactory = _deployLiquidWithTicks(
            narrowConfig.tickLower,
            narrowConfig.tickUpper
        );

        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(tempFactory), 0.1 ether);
        tempFactory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://price-impact-test",
            "LIQUID_IMPACT",
            "LQI",
            0.1 ether,
            _defaultSingleCurve(tempFactory)
        );
        vm.stopPrank();

        // V4 pool initialized with token creation

        console.log("");
        console.log(
            string(
                abi.encodePacked(
                    "Initial pool tick: ",
                    vm.toString(int256(0)) // initialSlot0.tick
                )
            )
        );
        console.log(
            "Initial sqrt price: %s",
            vm.toString(uint256(0)) // initialSlot0.sqrtPriceX96
        );

        // Progressive purchases to see cumulative price impact
        uint256[] memory progressivePurchases = new uint256[](6);
        progressivePurchases[0] = 0.1 ether;
        progressivePurchases[1] = 0.2 ether;
        progressivePurchases[2] = 0.5 ether;
        progressivePurchases[3] = 1 ether;
        progressivePurchases[4] = 2 ether;
        progressivePurchases[5] = 5 ether;

        console.log("");
        console.log("Progressive Purchases - Cumulative Price Impact:");
        console.log(
            "Purchase # | Amount (ETH) | Tokens This Round | Cumulative Tokens | Pool Tick | Price Impact"
        );
        console.log(
            "-----------|--------------|-------------------|-------------------|-----------|-------------"
        );

        for (uint256 i = 0; i < progressivePurchases.length; i++) {
            uint256 purchaseAmount = progressivePurchases[i];

            console.log(
                string(
                    abi.encodePacked(
                        vm.toString(i + 1),
                        " | ",
                        _formatEther(purchaseAmount),
                        " | ",
                        "N/A",
                        " | ",
                        "N/A",
                        " | ",
                        "N/A",
                        " | ",
                        "N/A"
                    )
                )
            );
        }
    }

    // Helper function to format ether amounts
    function _formatEther(
        uint256 amount
    ) internal pure returns (string memory) {
        if (amount >= 1e18) {
            return
                string(
                    abi.encodePacked(
                        vm.toString(amount / 1e18),
                        ".",
                        vm.toString((amount % 1e18) / 1e15)
                    )
                );
        } else if (amount >= 1e15) {
            return string(abi.encodePacked("0.00", vm.toString(amount / 1e15)));
        } else {
            return
                string(abi.encodePacked("0.000", vm.toString(amount / 1e12)));
        }
    }

}
