// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Liquid} from "../src/Liquid.sol";
import {LiquidFactory} from "../src/LiquidFactory.sol";
import {RAREBurner} from "../src/RAREBurner.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {NetworkConfig} from "../script/NetworkConfig.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title Liquid Quote → Trade Pattern Tests
/// @notice Comprehensive tests for quoteBuy() → buy() and quoteSell() → sell() patterns
/// @dev Tests that quotes accurately predict actual trade outcomes including slippage protection
contract LiquidQuoteTradeTest is Test {
    // Network configuration
    NetworkConfig.Config public config;

    // Test accounts
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public referrer = makeAddr("referrer");

    // Contracts
    LiquidFactory public factory;
    Liquid public liquidImpl;
    Liquid public token;
    RAREBurner public burner;

    // LP tick range - production configuration
    // Note: price = LIQUID/ETH. High tick = many tokens per ETH = cheap (bonding curve bottom)
    // As users buy, tick moves DOWN = tokens get more expensive
    int24 constant LP_TICK_LOWER = -180; // Max expensive (after price rises) - multiple of 60
    int24 constant LP_TICK_UPPER = 120000; // Starting point - cheap tokens - multiple of 60

    // Constants for assertions
    uint256 constant TOTAL_FEE_BPS = 100; // 1%
    uint256 constant TOLERANCE_BPS = 50; // 0.5% tolerance for slippage

    function setUp() public {
        // Fork Base mainnet for realistic testing
        string memory forkUrl = vm.envOr(
            "FORK_URL",
            string("https://mainnet.base.org")
        );
        vm.createSelectFork(forkUrl);

        // Get network configuration
        config = NetworkConfig.getConfig(block.chainid);

        // Fund test accounts
        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(protocolFeeRecipient, 1 ether);
        vm.deal(referrer, 1 ether);

        // Deploy contracts
        vm.startPrank(admin);

        liquidImpl = new Liquid();

        burner = new RAREBurner(
            admin,
            false, // tryOnDeposit
            config.rareToken, // Use real RARE token but disabled
            config.uniswapV4PoolManager,
            3000, // 0.3% fee
            60, // tick spacing
            address(0), // no hooks
            0x000000000000000000000000000000000000dEaD, // burn address
            address(0), // no quoter initially
            0, // 0% slippage
            false // disabled initially
        );

        factory = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            address(burner),
            0, // rareBurnFeeBPS
            5000, // protocolFeeBPS
            5000, // referrerFeeBPS
            100, // defaultTotalFeeBPS (1%)
            2500, // defaultCreatorFeeBPS (25%)
            LP_TICK_LOWER,
            LP_TICK_UPPER,
            config.uniswapV4Quoter, // Use wrapper instead of raw quoter
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            300, // internalMaxSlippageBps (3%)
            0.005 ether, // minOrderSizeWei
            1e15 // minInitialLiquidityWei (0.001 ETH)
        );

        factory.setImplementation(address(liquidImpl));

        vm.stopPrank();

        // Create a token with production initial liquidity: 0.001 ETH + 900K tokens
        // Starting at tickUpper (cheap tokens), minimal ETH is sufficient
        vm.prank(tokenCreator);
        address tokenAddr = factory.createLiquidToken{value: 0.001 ether}(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST"
        );
        token = Liquid(payable(tokenAddr));

        // Verify quoter is configured
        address quoterAddr = factory.v4Quoter();
        require(
            quoterAddr != address(0),
            "Quoter must be configured for quote tests"
        );
        require(
            quoterAddr == config.uniswapV4Quoter,
            "Quoter should be raw V4 quoter"
        );

        // Verify pool is initialized
        require(
            PoolId.unwrap(token.poolId()) != bytes32(0),
            "Pool must be initialized for quote tests"
        );

        console.log("=== QUOTE TEST SETUP ===");
        console.log("Quoter address:", quoterAddr);
        console.log(
            "Pool initialized:",
            PoolId.unwrap(token.poolId()) != bytes32(0)
        );
        console.log("Token address:", address(token));

        // Perform initial buy swaps to add liquidity to the pool (mimics real usage)
        // This adds ETH to the pool and allows sell operations to work properly
        // Using small 0.1 ETH buys since we're starting at bottom of bonding curve
        console.log("=== INITIAL BUYS TO ADD LIQUIDITY ===");

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);

        // Multiple small buys to gradually build liquidity
        for (uint i = 0; i < 10; i++) {
            vm.prank(user1);
            token.buy{value: 0.1 ether}(user1, address(0), 0, 0);
        }
        console.log("User1 bought 10x with 0.1 ETH each (1 ETH total)");

        for (uint i = 0; i < 10; i++) {
            vm.prank(user2);
            token.buy{value: 0.1 ether}(user2, address(0), 0, 0);
        }
        console.log("User2 bought 10x with 0.1 ETH each (1 ETH total)");

        console.log("Total ETH added to pool via buys: 2 ETH");
        console.log("Pool now has ~2.001 ETH for testing");
    }

    // ============================================
    // BASIC QUOTE → BUY TESTS
    // ============================================

    /// @notice Test that quoteBuy accurately predicts buy outcome
    /// @dev Uses 0 for protection parameters to test pure quote accuracy without slippage protection
    function test_QuoteBuy_BasicAccuracy() public {
        uint256 ethAmount = 1 ether;

        // Get quote
        (
            uint256 feeBps,
            uint256 ethFee,
            uint256 ethIn,
            uint256 tokenOut,
            uint160 sqrtPriceX96After
        ) = token.quoteBuy(ethAmount);

        // Verify quote structure
        assertEq(feeBps, TOTAL_FEE_BPS, "Fee BPS should match");
        assertEq(
            ethFee,
            (ethAmount * TOTAL_FEE_BPS) / 10_000,
            "Fee calculation should match"
        );
        assertEq(
            ethIn,
            ethAmount - ethFee,
            "ETH in should be amount minus fee"
        );
        assertGt(tokenOut, 0, "Should quote positive token amount");
        assertGt(sqrtPriceX96After, 0, "Should return post-swap price");

        // Execute actual buy WITHOUT protection (testing pure quote accuracy)
        uint256 balanceBefore = token.balanceOf(user1);
        vm.prank(user1);
        uint256 actualTokensReceived = token.buy{value: ethAmount}(
            user1,
            address(0),
            0, // minOrderSize = 0 (no protection - testing quote accuracy)
            0 // sqrtPriceLimitX96 = 0 (no limit - testing quote accuracy)
        );

        uint256 balanceAfter = token.balanceOf(user1);
        uint256 tokensReceived = balanceAfter - balanceBefore;

        // Verify quote matches actual within tolerance
        assertEq(
            actualTokensReceived,
            tokensReceived,
            "Return value should match balance change"
        );
        assertApproxEqRel(
            tokensReceived,
            tokenOut,
            (TOLERANCE_BPS * 1e18) / 10_000, // Convert BPS to 18 decimal
            "Actual tokens should match quote within tolerance"
        );

        console.log("=== QUOTE -> BUY ACCURACY ===");
        console.log("Quoted tokens:", tokenOut);
        console.log("Actual tokens:", tokensReceived);
        console.log(
            "Difference:",
            tokenOut > tokensReceived
                ? tokenOut - tokensReceived
                : tokensReceived - tokenOut
        );
    }

    /// @notice Test quoteBuy → buy with user-specified minOrderSize protection
    function test_QuoteBuy_WithMinOrderSize() public {
        uint256 ethAmount = 1 ether;

        // Get quote
        (, , , uint256 tokenOut, ) = token.quoteBuy(ethAmount);

        // Execute buy with minOrderSize = 95% of quoted (allowing 5% slippage)
        uint256 minOrderSize = (tokenOut * 95) / 100;

        vm.prank(user1);
        uint256 tokensReceived = token.buy{value: ethAmount}(
            user1,
            address(0),
            minOrderSize,
            0
        );

        // Should succeed and receive at least minOrderSize
        assertGe(
            tokensReceived,
            minOrderSize,
            "Should receive at least minOrderSize"
        );

        console.log("=== QUOTE -> BUY WITH MIN ORDER SIZE ===");
        console.log("Quoted:", tokenOut);
        console.log("Min required:", minOrderSize);
        console.log("Actual received:", tokensReceived);
    }

    /// @notice Test that buy reverts when minOrderSize is too high based on quote
    function test_QuoteBuy_RevertsWhenMinOrderSizeTooHigh() public {
        uint256 ethAmount = 1 ether;

        // Get quote
        (, , , uint256 tokenOut, ) = token.quoteBuy(ethAmount);

        // Set unrealistic minOrderSize (110% of quoted)
        uint256 minOrderSize = (tokenOut * 110) / 100;

        // Should revert due to slippage
        vm.prank(user1);
        vm.expectRevert(); // Uniswap will revert with "Too little received"
        token.buy{value: ethAmount}(user1, address(0), minOrderSize, 0);

        console.log("=== QUOTE -> BUY REVERT TEST ===");
        console.log("Quoted:", tokenOut);
        console.log("Unrealistic min:", minOrderSize);
    }

    /// @notice Test quoteBuy -> buy with sqrtPriceLimitX96
    function test_QuoteBuy_WithSqrtPriceLimit() public {
        uint256 ethAmount = 0.5 ether;

        // Get quote to see post-swap price
        (, , , , uint160 sqrtPriceX96After) = token.quoteBuy(ethAmount);

        // Use the provided post-swap price directly as sqrtPriceLimit
        uint160 limitFromQuote = sqrtPriceX96After;

        vm.prank(user1);
        uint256 tokensReceived = token.buy{value: ethAmount}(
            user1,
            address(0),
            0,
            limitFromQuote
        );

        // Should succeed
        assertGt(tokensReceived, 0, "Should receive tokens");

        console.log("=== QUOTE -> BUY WITH PRICE LIMIT ===");
        console.log("Quoted price after:", sqrtPriceX96After);
        console.log("Price limit:", limitFromQuote);
        console.log("Tokens received:", tokensReceived);
    }

    /// @notice Returned sqrtPriceX96After should be immediately reusable as sqrtPriceLimit
    function test_QuoteBuy_LimitMatchesQuote() public {
        uint256 ethAmount = 0.75 ether;

        (, , , uint256 tokenOut, uint160 sqrtPriceX96After) = token.quoteBuy(
            ethAmount
        );

        uint256 minOrderSize = (tokenOut * 90) / 100; // 10% slippage allowance

        vm.prank(user1);
        uint256 tokensReceived = token.buy{value: ethAmount}(
            user1,
            address(0),
            minOrderSize,
            sqrtPriceX96After
        );

        assertGe(
            tokensReceived,
            minOrderSize,
            "Buy should respect quote limit"
        );
    }

    // ============================================
    // BASIC QUOTE -> SELL TESTS
    // ============================================

    /// @notice Test that quoteSell accurately predicts sell outcome
    /// @dev Uses 0 for protection parameters to test pure quote accuracy without slippage protection
    function test_QuoteSell_BasicAccuracy() public {
        // First buy some tokens (setup trade, protection not needed)
        vm.prank(user1);
        token.buy{value: 2 ether}(user1, address(0), 0, 0);

        uint256 tokenBalance = token.balanceOf(user1);
        uint256 tokenAmount = tokenBalance / 2; // Sell half

        // Get quote
        (
            uint256 feeBps,
            uint256 ethFee,
            uint256 tokenIn,
            uint256 ethOut,
            uint160 sqrtPriceX96After
        ) = token.quoteSell(tokenAmount);

        // Verify quote structure
        assertEq(feeBps, TOTAL_FEE_BPS, "Fee BPS should match");
        assertEq(tokenIn, tokenAmount, "Token in should match input");
        assertGt(ethOut, 0, "Should quote positive ETH amount");
        assertGt(ethFee, 0, "Should have positive fee");
        assertGt(sqrtPriceX96After, 0, "Should return post-swap price");

        // Execute actual sell - send to a separate recipient to avoid gas cost issues
        address recipient = makeAddr("recipient");
        uint256 ethBalanceBefore = recipient.balance;

        vm.prank(user1);
        uint256 ethReceived = token.sell(
            tokenAmount,
            recipient, // Send to separate address
            address(0),
            0, // minPayoutSize = 0 (no protection - testing quote accuracy)
            0 // sqrtPriceLimitX96 = 0 (no limit - testing quote accuracy)
        );

        uint256 ethBalanceAfter = recipient.balance;
        uint256 ethReceivedByUser = ethBalanceAfter - ethBalanceBefore;

        // Verify return value matches balance change
        assertEq(
            ethReceived,
            ethReceivedByUser,
            "Return value should match balance change"
        );

        // Verify quote matches actual within tolerance
        assertApproxEqRel(
            ethReceived,
            ethOut,
            (TOLERANCE_BPS * 1e18) / 10_000,
            "Actual ETH should match quote within tolerance"
        );

        console.log("=== QUOTE -> SELL ACCURACY ===");
        console.log("Quoted ETH:", ethOut);
        console.log("Actual ETH:", ethReceived);
        console.log("Quoted fee:", ethFee);
        console.log(
            "Difference:",
            ethOut > ethReceived ? ethOut - ethReceived : ethReceived - ethOut
        );
    }

    /// @notice Test quoteSell -> sell with user-specified minPayoutSize protection
    function test_QuoteSell_WithMinPayoutSize() public {
        // Buy tokens first
        vm.prank(user1);
        token.buy{value: 2 ether}(user1, address(0), 0, 0);

        uint256 tokenAmount = token.balanceOf(user1) / 2;

        // Get quote
        (, , , uint256 ethOut, ) = token.quoteSell(tokenAmount);

        // Execute sell with minPayoutSize = 95% of quoted (allowing 5% slippage)
        uint256 minPayoutSize = (ethOut * 95) / 100;

        vm.prank(user1);
        uint256 ethReceived = token.sell(
            tokenAmount,
            user1,
            address(0),
            minPayoutSize,
            0
        );

        // Should succeed and receive at least minPayoutSize
        assertGe(
            ethReceived,
            minPayoutSize,
            "Should receive at least minPayoutSize"
        );

        console.log("=== QUOTE -> SELL WITH MIN PAYOUT SIZE ===");
        console.log("Quoted:", ethOut);
        console.log("Min required:", minPayoutSize);
        console.log("Actual received:", ethReceived);
    }

    /// @notice Returned sqrtPriceX96After should be immediately reusable as sell sqrtPriceLimit
    function test_QuoteSell_LimitMatchesQuote() public {
        vm.prank(user1);
        token.buy{value: 2 ether}(user1, address(0), 0, 0);

        uint256 tokenAmount = token.balanceOf(user1) / 3;

        (, , , uint256 ethOut, uint160 sqrtPriceX96After) = token.quoteSell(
            tokenAmount
        );

        uint256 minPayoutSize = (ethOut * 90) / 100;

        vm.prank(user1);
        uint256 ethReceived = token.sell(
            tokenAmount,
            user1,
            address(0),
            minPayoutSize,
            sqrtPriceX96After
        );

        assertGe(ethReceived, minPayoutSize, "Sell should respect quote limit");
    }

    /// @notice Test that sell reverts when minPayoutSize is too high based on quote
    function test_QuoteSell_RevertsWhenMinPayoutSizeTooHigh() public {
        // Buy tokens first
        vm.prank(user1);
        token.buy{value: 2 ether}(user1, address(0), 0, 0);

        uint256 tokenAmount = token.balanceOf(user1) / 2;

        // Get quote
        (, , , uint256 ethOut, ) = token.quoteSell(tokenAmount);

        // Set unrealistic minPayoutSize (110% of quoted)
        uint256 minPayoutSize = (ethOut * 110) / 100;

        // Should revert due to slippage
        vm.prank(user1);
        vm.expectRevert(); // Uniswap will revert with "Too little received"
        token.sell(tokenAmount, user1, address(0), minPayoutSize, 0);

        console.log("=== QUOTE -> SELL REVERT TEST ===");
        console.log("Quoted:", ethOut);
        console.log("Unrealistic min:", minPayoutSize);
    }

    // ============================================
    // FUZZ TESTS (INVARIANT STYLE)
    // ============================================

    /// @notice Sample-based test: quoteBuy predicts buy outcome within tolerance
    function testQuoteBuyAccuracySamples() public {
        uint256[6] memory ethSamples = [
            uint256(0.005 ether),
            0.05 ether,
            0.5 ether,
            1 ether,
            5 ether,
            10 ether
        ];

        uint256 baseSnapshot = vm.snapshotState();

        for (uint256 i = 0; i < ethSamples.length; i++) {
            vm.revertToState(baseSnapshot);
            _assertQuoteBuyAccuracy(ethSamples[i]);
        }

        vm.revertToState(baseSnapshot);
    }

    /// @notice Sample-based test: quoteSell predicts sell outcome within tolerance
    function testQuoteSellAccuracySamples() public {
        uint256[7] memory sellPercents = [uint256(1), 5, 10, 25, 50, 75, 90];

        uint256 baseSnapshot = vm.snapshotState();

        for (uint256 i = 0; i < sellPercents.length; i++) {
            vm.revertToState(baseSnapshot);
            _assertQuoteSellAccuracy(sellPercents[i]);
        }

        vm.revertToState(baseSnapshot);
    }

    /// @notice Sample-based test: minOrderSize protection enforced on buy quotes
    function testQuoteBuyMinOrderSizeProtectionSamples() public {
        uint256[4] memory ethSamples = [
            uint256(0.005 ether),
            0.1 ether,
            1 ether,
            5 ether
        ];
        uint256[4] memory slippageSamples = [uint256(1), 5, 10, 20];

        uint256 baseSnapshot = vm.snapshotState();

        for (uint256 i = 0; i < ethSamples.length; i++) {
            for (uint256 j = 0; j < slippageSamples.length; j++) {
                vm.revertToState(baseSnapshot);
                _assertQuoteBuyMinOrderProtection(
                    ethSamples[i],
                    slippageSamples[j]
                );
            }
        }

        vm.revertToState(baseSnapshot);
    }

    /// @notice Sample-based test: minPayoutSize protection enforced on sell quotes
    function testQuoteSellMinPayoutSizeProtectionSamples() public {
        uint256[5] memory sellPercents = [uint256(1), 5, 10, 25, 50];
        uint256[4] memory slippageSamples = [uint256(1), 5, 10, 20];

        uint256 baseSnapshot = vm.snapshotState();

        for (uint256 i = 0; i < sellPercents.length; i++) {
            for (uint256 j = 0; j < slippageSamples.length; j++) {
                vm.revertToState(baseSnapshot);
                _assertQuoteSellMinPayoutProtection(
                    sellPercents[i],
                    slippageSamples[j]
                );
            }
        }

        vm.revertToState(baseSnapshot);
    }

    // ============================================
    // MULTI-TRADE SEQUENCE TESTS
    // ============================================

    /// @notice Test quote accuracy across multiple sequential buys
    function test_QuoteBuy_SequentialAccuracy() public {
        uint256[5] memory buyAmounts;
        buyAmounts[0] = 0.1 ether;
        buyAmounts[1] = 0.5 ether;
        buyAmounts[2] = 1 ether;
        buyAmounts[3] = 0.2 ether;
        buyAmounts[4] = 0.8 ether;

        console.log("=== SEQUENTIAL BUY ACCURACY ===");

        for (uint i = 0; i < buyAmounts.length; i++) {
            uint256 ethAmount = buyAmounts[i];
            vm.deal(user2, ethAmount);

            // Get quote
            (, , , uint256 tokenOut, ) = token.quoteBuy(ethAmount);

            // Execute buy
            vm.prank(user2);
            uint256 tokensReceived = token.buy{value: ethAmount}(
                user2,
                address(0),
                0,
                0
            );

            // Verify accuracy
            assertApproxEqRel(
                tokensReceived,
                tokenOut,
                (TOLERANCE_BPS * 1e18) / 10_000,
                "Sequential buy quote should be accurate"
            );

            console.log("Buy", i + 1, "ETH:", ethAmount);
            console.log("  Quoted:", tokenOut);
            console.log("  Actual:", tokensReceived);
        }
    }

    /// @notice Test quote accuracy across multiple sequential sells
    function test_QuoteSell_SequentialAccuracy() public {
        // Buy a large amount first
        vm.deal(user1, 15 ether);
        vm.prank(user1);
        token.buy{value: 10 ether}(user1, address(0), 0, 0);

        uint256 initialBalance = token.balanceOf(user1);

        // Sell in 5 chunks
        uint256[5] memory sellPercents;
        sellPercents[0] = 10;
        sellPercents[1] = 15;
        sellPercents[2] = 20;
        sellPercents[3] = 25;
        sellPercents[4] = 30; // Percentages of remaining

        console.log("=== SEQUENTIAL SELL ACCURACY ===");
        console.log("Initial balance:", initialBalance);

        for (uint i = 0; i < sellPercents.length; i++) {
            uint256 currentBalance = token.balanceOf(user1);
            uint256 tokenAmount = (currentBalance * sellPercents[i]) / 100;

            // Get quote
            (, , , uint256 ethOut, ) = token.quoteSell(tokenAmount);

            // Execute sell
            vm.prank(user1);
            uint256 ethReceived = token.sell(
                tokenAmount,
                user1,
                address(0),
                0,
                0
            );

            // Verify accuracy
            assertApproxEqRel(
                ethReceived,
                ethOut,
                (TOLERANCE_BPS * 1e18) / 10_000,
                "Sequential sell quote should be accurate"
            );

            console.log("Sell", i + 1, "Tokens:", tokenAmount);
            console.log("  Quoted ETH:", ethOut);
            console.log("  Actual ETH:", ethReceived);
        }
    }

    /// @notice Test quote -> trade with alternating buy/sell
    function test_Quote_AlternatingBuySell() public {
        console.log("=== ALTERNATING BUY/SELL QUOTES ===");

        // Buy 1
        uint256 buy1 = 1 ether;
        (, , , uint256 quotedTokens1, ) = token.quoteBuy(buy1);
        vm.prank(user1);
        uint256 actualTokens1 = token.buy{value: buy1}(user1, address(0), 0, 0);
        assertApproxEqRel(
            actualTokens1,
            quotedTokens1,
            (TOLERANCE_BPS * 1e18) / 10_000,
            "Buy 1"
        );

        // Sell 1
        uint256 sell1 = actualTokens1 / 2;
        (, , , uint256 quotedEth1, ) = token.quoteSell(sell1);
        vm.prank(user1);
        uint256 actualEth1 = token.sell(sell1, user1, address(0), 0, 0);
        assertApproxEqRel(
            actualEth1,
            quotedEth1,
            (TOLERANCE_BPS * 1e18) / 10_000,
            "Sell 1"
        );

        // Buy 2
        uint256 buy2 = 0.5 ether;
        vm.deal(user1, buy2);
        (, , , uint256 quotedTokens2, ) = token.quoteBuy(buy2);
        vm.prank(user1);
        uint256 actualTokens2 = token.buy{value: buy2}(user1, address(0), 0, 0);
        assertApproxEqRel(
            actualTokens2,
            quotedTokens2,
            (TOLERANCE_BPS * 1e18) / 10_000,
            "Buy 2"
        );

        // Sell 2
        uint256 sell2 = token.balanceOf(user1) / 3;
        (, , , uint256 quotedEth2, ) = token.quoteSell(sell2);
        vm.prank(user1);
        uint256 actualEth2 = token.sell(sell2, user1, address(0), 0, 0);
        assertApproxEqRel(
            actualEth2,
            quotedEth2,
            (TOLERANCE_BPS * 1e18) / 10_000,
            "Sell 2"
        );

        console.log("All alternating trades matched quotes within tolerance");
    }

    // ============================================
    // EDGE CASES
    // ============================================

    /// @notice Test quote at minimum order size
    function test_QuoteBuy_MinimumOrderSize() public {
        uint256 minOrderSize = factory.minOrderSizeWei();

        // Get quote for minimum
        (, , , uint256 tokenOut, ) = token.quoteBuy(minOrderSize);
        assertGt(tokenOut, 0, "Should quote positive tokens at minimum");

        // Execute buy
        vm.prank(user1);
        uint256 tokensReceived = token.buy{value: minOrderSize}(
            user1,
            address(0),
            0,
            0
        );

        assertApproxEqRel(
            tokensReceived,
            tokenOut,
            (TOLERANCE_BPS * 1e18) / 10_000,
            "Minimum order should match quote"
        );
    }

    /// @notice Test quote with very large amounts (bonding curve stress test)
    function test_QuoteBuy_LargeAmount() public {
        uint256 largeAmount = 50 ether;
        vm.deal(user1, largeAmount);

        // Get quote
        (, , , uint256 tokenOut, ) = token.quoteBuy(largeAmount);
        assertGt(tokenOut, 0, "Should quote positive tokens for large amount");

        // Execute buy
        vm.prank(user1);
        uint256 tokensReceived = token.buy{value: largeAmount}(
            user1,
            address(0),
            0,
            0
        );

        // Allow slightly higher tolerance for large amounts due to slippage
        assertApproxEqRel(
            tokensReceived,
            tokenOut,
            (TOLERANCE_BPS * 2 * 1e18) / 10_000, // 2x tolerance for large trades
            "Large order should match quote within tolerance"
        );
    }

    /// @notice Test that quote matches actual even with referrer (fees distributed differently)
    function test_QuoteBuy_WithReferrer() public {
        uint256 ethAmount = 1 ether;

        // Get quote (doesn't consider referrer)
        (, , , uint256 tokenOut, ) = token.quoteBuy(ethAmount);

        // Execute buy with referrer
        vm.prank(user1);
        uint256 tokensReceived = token.buy{value: ethAmount}(
            user1,
            referrer, // Include referrer
            0,
            0
        );

        // Quote should still match (referrer only affects fee distribution, not swap)
        assertApproxEqRel(
            tokensReceived,
            tokenOut,
            (TOLERANCE_BPS * 1e18) / 10_000,
            "Quote should match even with referrer"
        );
    }

    /// @notice Test quoteSell after LP fees have accumulated
    function test_QuoteSell_AfterLPFeeAccumulation() public {
        // Generate multiple trades to accumulate LP fees
        for (uint i = 0; i < 5; i++) {
            vm.prank(user2);
            token.buy{value: 0.5 ether}(user2, address(0), 0, 0);
        }

        // Buy tokens for user1
        vm.prank(user1);
        token.buy{value: 2 ether}(user1, address(0), 0, 0);

        uint256 tokenAmount = token.balanceOf(user1) / 2;

        // Get quote after LP fees accumulated
        (, , , uint256 ethOut, ) = token.quoteSell(tokenAmount);

        // Execute sell
        vm.prank(user1);
        uint256 ethReceived = token.sell(tokenAmount, user1, address(0), 0, 0);

        // Should still match within tolerance
        assertApproxEqRel(
            ethReceived,
            ethOut,
            (TOLERANCE_BPS * 1e18) / 10_000,
            "Quote should be accurate even after LP fee accumulation"
        );
    }

    // ============================================
    // MULTI-USER INVARIANT TESTS
    // ============================================

    /// @notice Invariant: Multiple users getting quotes and trading simultaneously
    function test_Invariant_MultiUserQuoteAccuracy() public {
        address[3] memory users;
        users[0] = user1;
        users[1] = user2;
        users[2] = makeAddr("user3");

        console.log("=== MULTI-USER QUOTE ACCURACY ===");

        for (uint i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 ethAmount = (i + 1) * 0.5 ether;
            vm.deal(user, ethAmount);

            // Each user gets a quote
            (, , , uint256 tokenOut, ) = token.quoteBuy(ethAmount);

            // Each user executes buy
            vm.prank(user);
            uint256 tokensReceived = token.buy{value: ethAmount}(
                user,
                address(0),
                0,
                0
            );

            // INVARIANT: Each quote is accurate for each user
            assertApproxEqRel(
                tokensReceived,
                tokenOut,
                (TOLERANCE_BPS * 1e18) / 10_000,
                "Multi-user: quote should match"
            );

            console.log("User quoted:", tokenOut);
            console.log("User received:", tokensReceived);
        }
    }

    /// @notice Sample-based invariant: quote remains accurate across pool states
    function testQuoteAccuracyAcrossPoolStatesSamples() public {
        uint256[5] memory initialBuys = [
            uint256(0.1 ether),
            0.5 ether,
            1 ether,
            2 ether,
            10 ether
        ];
        uint256[5] memory testBuys = [
            uint256(0.01 ether),
            0.05 ether,
            0.1 ether,
            0.5 ether,
            1 ether
        ];

        uint256 baseSnapshot = vm.snapshotState();

        for (uint256 i = 0; i < initialBuys.length; i++) {
            for (uint256 j = 0; j < testBuys.length; j++) {
                vm.revertToState(baseSnapshot);
                _assertQuoteAccuracyAcrossPoolStates(
                    initialBuys[i],
                    testBuys[j]
                );
            }
        }

        vm.revertToState(baseSnapshot);
    }

    function _assertQuoteBuyAccuracy(uint256 ethAmount) internal {
        vm.deal(user1, ethAmount);

        (, , , uint256 tokenOut, ) = token.quoteBuy(ethAmount);
        assertGt(tokenOut, 0, "Quote should return positive tokens");

        vm.prank(user1);
        uint256 tokensReceived = token.buy{value: ethAmount}(
            user1,
            address(0),
            0,
            0
        );

        assertApproxEqRel(
            tokensReceived,
            tokenOut,
            (TOLERANCE_BPS * 1e18) / 10_000,
            "Quote buy accuracy should stay within tolerance"
        );
    }

    function _assertQuoteSellAccuracy(uint256 sellPercent) internal {
        vm.prank(user1);
        token.buy{value: 5 ether}(user1, address(0), 0, 0);

        uint256 tokenBalance = token.balanceOf(user1);
        uint256 tokenAmount = (tokenBalance * sellPercent) / 100;
        require(tokenAmount > 0, "Token amount must be positive");

        (, , , uint256 ethOut, ) = token.quoteSell(tokenAmount);
        assertGt(ethOut, 0, "Quote should return positive ETH");

        vm.prank(user1);
        uint256 ethReceived = token.sell(tokenAmount, user1, address(0), 0, 0);

        assertApproxEqRel(
            ethReceived,
            ethOut,
            (TOLERANCE_BPS * 1e18) / 10_000,
            "Quote sell accuracy should stay within tolerance"
        );
    }

    function _assertQuoteBuyMinOrderProtection(
        uint256 ethAmount,
        uint256 tolerancePercent
    ) internal {
        vm.deal(user1, ethAmount);

        (, , , uint256 tokenOut, ) = token.quoteBuy(ethAmount);
        uint256 minOrderSize = (tokenOut * (100 - tolerancePercent)) / 100;

        vm.prank(user1);
        uint256 tokensReceived = token.buy{value: ethAmount}(
            user1,
            address(0),
            minOrderSize,
            0
        );

        assertGe(
            tokensReceived,
            minOrderSize,
            "Buy slippage protection should hold"
        );
    }

    function _assertQuoteSellMinPayoutProtection(
        uint256 sellPercent,
        uint256 tolerancePercent
    ) internal {
        vm.prank(user1);
        token.buy{value: 5 ether}(user1, address(0), 0, 0);

        uint256 tokenBalance = token.balanceOf(user1);
        uint256 tokenAmount = (tokenBalance * sellPercent) / 100;
        require(tokenAmount > 0, "Token amount must be positive");

        (, , , uint256 ethOut, ) = token.quoteSell(tokenAmount);
        uint256 minPayoutSize = (ethOut * (100 - tolerancePercent)) / 100;

        vm.prank(user1);
        uint256 ethReceived = token.sell(
            tokenAmount,
            user1,
            address(0),
            minPayoutSize,
            0
        );

        assertGe(
            ethReceived,
            minPayoutSize,
            "Sell slippage protection should hold"
        );
    }

    function _assertQuoteAccuracyAcrossPoolStates(
        uint256 initialBuy,
        uint256 testBuy
    ) internal {
        vm.deal(user2, initialBuy);
        vm.prank(user2);
        token.buy{value: initialBuy}(user2, address(0), 0, 0);

        vm.deal(user1, testBuy);
        (, , , uint256 tokenOut, ) = token.quoteBuy(testBuy);

        vm.prank(user1);
        uint256 tokensReceived = token.buy{value: testBuy}(
            user1,
            address(0),
            0,
            0
        );

        assertApproxEqRel(
            tokensReceived,
            tokenOut,
            (TOLERANCE_BPS * 1e18) / 10_000,
            "Quotes should remain accurate after pool state changes"
        );
    }

    // ============================================
    // ERROR HANDLING TESTS
    // ============================================

    /// @notice Test that quoteBuy reverts with zero amount
    function test_QuoteBuy_RevertsOnZero() public {
        vm.expectRevert();
        token.quoteBuy(0);
    }

    /// @notice Test that quoteSell reverts with zero amount
    function test_QuoteSell_RevertsOnZero() public {
        vm.expectRevert();
        token.quoteSell(0);
    }

    /// @notice Test that quoteSell reverts when user has insufficient balance
    function test_QuoteSell_RevertsOnInsufficientBalance() public {
        uint256 tokenAmount = 1000000 ether; // Way more than supply

        // Quote may succeed (it's just a simulation)
        // But actual sell will fail
        vm.prank(user1);
        vm.expectRevert(); // Will revert on transfer
        token.sell(tokenAmount, user1, address(0), 0, 0);
    }

    // ============================================
    // PRICE MANIPULATION & SLIPPAGE TESTS
    // ============================================

    /// @notice Test buy with minOrderSize protection when price moves favorably (within tolerance)
    /// @dev Simulates favorable price movement by having another user buy first
    function test_Buy_MinOrderSize_PriceMovesWithinTolerance() public {
        uint256 buyAmount = 1 ether;

        // Another user buys first, moving price
        vm.prank(user2);
        token.buy{value: 0.1 ether}(user2, address(0), 0, 0);

        // NOW get quote for user1's buy (after price moved)
        (, , , uint256 quotedTokens, ) = token.quoteBuy(buyAmount);

        // Set minOrderSize with 5% slippage tolerance (expect 95% of NEW quote)
        uint256 minOrderSize = (quotedTokens * 95) / 100;

        // User1's buy should succeed (quote is fresh)
        vm.prank(user1);
        uint256 tokensReceived = token.buy{value: buyAmount}(
            user1,
            address(0),
            minOrderSize,
            0
        );

        // Should receive at least minOrderSize
        assertGe(
            tokensReceived,
            minOrderSize,
            "Should receive at least minOrderSize"
        );

        console.log("=== BUY WITH FAVORABLE PRICE MOVEMENT ===");
        console.log("Quoted tokens (after price moved):", quotedTokens);
        console.log("Min order size (95%):", minOrderSize);
        console.log("Actual received:", tokensReceived);
        console.log("Trade succeeded with fresh quote");
    }

    /// @notice Test buy with minOrderSize protection when price moves unfavorably (beyond tolerance)
    /// @dev Simulates unfavorable price movement by having another user buy a large amount
    function test_Buy_MinOrderSize_PriceMovesBeyondTolerance() public {
        uint256 buyAmount = 0.5 ether;

        // Get quote for user1's intended buy
        (, , , uint256 quotedTokens, ) = token.quoteBuy(buyAmount);

        // Set minOrderSize with tight 2% slippage tolerance
        uint256 minOrderSize = (quotedTokens * 98) / 100;

        // Another user makes a LARGE buy, significantly moving the price
        vm.prank(user2);
        token.buy{value: 5 ether}(user2, address(0), 0, 0); // Large trade moves price

        // User1's buy should fail - price moved too much
        vm.prank(user1);
        vm.expectRevert(); // Uniswap reverts with "Too little received"
        token.buy{value: buyAmount}(user1, address(0), minOrderSize, 0);

        console.log("=== BUY WITH UNFAVORABLE PRICE MOVEMENT ===");
        console.log("Quoted tokens:", quotedTokens);
        console.log("Min order size (98%):", minOrderSize);
        console.log("Large trade moved price - protection prevented bad trade");
    }

    /// @notice Test sell with minPayoutSize protection when price moves within tolerance
    /// @dev Simulates favorable price movement by having another user sell first
    function test_Sell_MinPayoutSize_PriceMovesWithinTolerance() public {
        // Setup: Both users buy tokens
        vm.prank(user1);
        token.buy{value: 3 ether}(user1, address(0), 0, 0);

        vm.prank(user2);
        token.buy{value: 2 ether}(user2, address(0), 0, 0);

        // User2 sells a small amount first, moving price slightly
        uint256 user2SellAmount = token.balanceOf(user2) / 10;
        vm.prank(user2);
        token.sell(user2SellAmount, user2, address(0), 0, 0);

        // NOW get quote for user1's sell (after price moved)
        uint256 sellAmount = token.balanceOf(user1) / 3; // Sell 1/3 of balance
        (, , , uint256 quotedEth, ) = token.quoteSell(sellAmount);

        // Set minPayoutSize with 5% slippage tolerance
        uint256 minPayoutSize = (quotedEth * 95) / 100;

        // User1's sell should succeed (quote is fresh)
        address recipient = makeAddr("sellRecipient1");
        vm.prank(user1);
        uint256 ethReceived = token.sell(
            sellAmount,
            recipient,
            address(0),
            minPayoutSize,
            0
        );

        // Should receive at least minPayoutSize
        assertGe(
            ethReceived,
            minPayoutSize,
            "Should receive at least minPayoutSize"
        );

        console.log("=== SELL WITH FAVORABLE PRICE MOVEMENT ===");
        console.log("Quoted ETH (after price moved):", quotedEth);
        console.log("Min payout (95%):", minPayoutSize);
        console.log("Actual received:", ethReceived);
        console.log("Trade succeeded with fresh quote");
    }

    /// @notice Test sell with minPayoutSize protection when price moves beyond tolerance
    /// @dev Simulates unfavorable price movement by having another user sell a large amount
    function test_Sell_MinPayoutSize_PriceMovesBeyondTolerance() public {
        // Setup: Both users buy tokens
        vm.prank(user1);
        token.buy{value: 3 ether}(user1, address(0), 0, 0);

        vm.prank(user2);
        token.buy{value: 5 ether}(user2, address(0), 0, 0);

        // Get quote BEFORE price moves
        uint256 sellAmount = token.balanceOf(user1) / 3;
        (, , , uint256 quotedEth, ) = token.quoteSell(sellAmount);

        // Set minPayoutSize with tight 2% slippage tolerance based on OLD quote
        uint256 minPayoutSize = (quotedEth * 98) / 100;

        // User2 makes a LARGE sell, significantly moving the price down
        uint256 user2SellAmount = (token.balanceOf(user2) * 70) / 100;
        vm.prank(user2);
        token.sell(user2SellAmount, user2, address(0), 0, 0); // Large sell crashes price

        // User1's sell should fail - price moved too much, can't meet old minPayoutSize
        address recipient = makeAddr("sellRecipient2");
        vm.prank(user1);
        vm.expectRevert(); // Uniswap reverts with "Too little received"
        token.sell(sellAmount, recipient, address(0), minPayoutSize, 0);

        console.log("=== SELL WITH UNFAVORABLE PRICE MOVEMENT ===");
        console.log("Quoted ETH (before price moved):", quotedEth);
        console.log("Min payout (98%):", minPayoutSize);
        console.log("Large trade moved price - protection prevented bad trade");
    }

    /// @notice Test sqrtPriceLimitX96 on buy when another user moves the price within limit
    function test_Buy_SqrtPriceLimit_WithinLimit() public {
        uint256 buyAmount = 0.5 ether;

        // Get quote to see expected post-swap price
        (, , , uint256 quotedTokens, uint160 sqrtPriceX96After) = token
            .quoteBuy(buyAmount);

        // Set a permissive price limit (allow 10% price decrease for buys)
        // Buy operations move price DOWN (LIQUID/ETH ratio decreases)
        uint160 priceLimit = uint160((uint256(sqrtPriceX96After) * 90) / 100);

        // Another user buys, moving price up slightly
        vm.prank(user2);
        token.buy{value: 0.2 ether}(user2, address(0), 0, 0);

        // User1's buy should succeed - price is within limit
        vm.prank(user1);
        uint256 tokensReceived = token.buy{value: buyAmount}(
            user1,
            address(0),
            0,
            priceLimit
        );

        assertGt(tokensReceived, 0, "Should receive tokens");

        console.log("=== BUY WITH PRICE LIMIT - WITHIN ===");
        console.log("Quoted tokens:", quotedTokens);
        console.log("Price limit:", priceLimit);
        console.log("Tokens received:", tokensReceived);
        console.log("Trade succeeded - price within limit");
    }

    /// @notice Test sqrtPriceLimitX96 on buy when another user moves price beyond limit
    function test_Buy_SqrtPriceLimit_BeyondLimit() public {
        uint256 buyAmount = 0.5 ether;

        // Get quote to see expected post-swap price
        (, , , , uint160 sqrtPriceX96After) = token.quoteBuy(buyAmount);

        // Set a TIGHT price limit (only allow 2% price decrease for buys)
        // Buy operations move price DOWN
        uint160 tightPriceLimit = uint160(
            (uint256(sqrtPriceX96After) * 98) / 100
        );

        // Another user makes a LARGE buy, moving price significantly
        vm.prank(user2);
        token.buy{value: 3 ether}(user2, address(0), 0, 0); // Large buy moves price

        // User1's buy should fail - price moved beyond limit
        vm.prank(user1);
        vm.expectRevert(); // Uniswap reverts due to price limit
        token.buy{value: buyAmount}(user1, address(0), 0, tightPriceLimit);

        console.log("=== BUY WITH PRICE LIMIT - BEYOND ===");
        console.log("Tight price limit:", tightPriceLimit);
        console.log("Large trade moved price beyond limit - protection worked");
    }

    /// @notice Test sqrtPriceLimitX96 on sell when price moves within limit
    function test_Sell_SqrtPriceLimit_WithinLimit() public {
        // Setup: Both users buy tokens
        vm.prank(user1);
        token.buy{value: 3 ether}(user1, address(0), 0, 0);

        vm.prank(user2);
        token.buy{value: 2 ether}(user2, address(0), 0, 0);

        // User2 sells a small amount first, moving price down slightly
        uint256 user2SellAmount = token.balanceOf(user2) / 10;
        vm.prank(user2);
        token.sell(user2SellAmount, user2, address(0), 0, 0);

        // Get quote AFTER price moved
        uint256 sellAmount = token.balanceOf(user1) / 3;
        (, , , uint256 quotedEth, uint160 sqrtPriceX96After) = token.quoteSell(
            sellAmount
        );

        // Set a permissive price limit (allow 10% price increase)
        // For sell, price (LIQUID/ETH) goes UP, so we set a higher limit
        uint160 priceLimit = uint160((uint256(sqrtPriceX96After) * 110) / 100);

        // User1's sell should succeed - price is within limit
        address recipient = makeAddr("sellRecipient3");
        vm.prank(user1);
        uint256 ethReceived = token.sell(
            sellAmount,
            recipient,
            address(0),
            0,
            priceLimit
        );

        assertGt(ethReceived, 0, "Should receive ETH");

        console.log("=== SELL WITH PRICE LIMIT - WITHIN ===");
        console.log("Quoted ETH (after price moved):", quotedEth);
        console.log("Price limit:", priceLimit);
        console.log("ETH received:", ethReceived);
        console.log("Trade succeeded - price within limit");
    }

    /// @notice Test sqrtPriceLimitX96 on sell when price moves beyond limit
    function test_Sell_SqrtPriceLimit_BeyondLimit() public {
        // Setup: Both users buy tokens
        vm.deal(user1, 5 ether);
        vm.prank(user1);
        token.buy{value: 2 ether}(user1, address(0), 0, 0);

        vm.deal(user2, 15 ether);
        vm.prank(user2);
        token.buy{value: 10 ether}(user2, address(0), 0, 0);

        // Get initial pool price
        (, , , , uint160 initialSqrtPrice) = token.quoteSell(1e18);

        // User2 makes a MASSIVE sell first, crashing the price dramatically
        uint256 user2SellAmount = (token.balanceOf(user2) * 90) / 100;
        vm.prank(user2);
        token.sell(user2SellAmount, user2, address(0), 0, 0);

        // Now try to sell with a price limit ABOVE the current crashed price
        // This simulates refusing to sell at the crashed price
        uint256 sellAmount = token.balanceOf(user1) / 3;

        // Set price limit at 95% of ORIGINAL price (before crash)
        // Since price crashed, this is now ABOVE current price, so sell will fail
        uint160 priceFloor = uint160((uint256(initialSqrtPrice) * 95) / 100);

        address recipient = makeAddr("sellRecipient4");
        vm.prank(user1);
        vm.expectRevert(); // Uniswap reverts - can't achieve the higher price floor
        token.sell(sellAmount, recipient, address(0), 0, priceFloor);

        console.log("=== SELL WITH PRICE LIMIT - BEYOND ===");
        console.log("Price floor (95% of original):", priceFloor);
        console.log("Price crashed below floor - protection worked");
    }

    /// @notice Combined test: Both minOrderSize AND sqrtPriceLimit protection on buy
    function test_Buy_CombinedProtection_WithinBothLimits() public {
        uint256 buyAmount = 1 ether;

        // Another user makes a small buy first (minimal price impact)
        vm.prank(user2);
        token.buy{value: 0.1 ether}(user2, address(0), 0, 0);

        // Get quote AFTER price moved
        (, , , uint256 quotedTokens, uint160 sqrtPriceX96After) = token
            .quoteBuy(buyAmount);

        // Set both protections with generous tolerances to ensure success
        uint256 minOrderSize = (quotedTokens * 90) / 100; // 10% slippage tolerance
        // For buy, price goes DOWN, so set limit 15% lower
        uint160 priceLimit = uint160((uint256(sqrtPriceX96After) * 85) / 100); // 15% price change tolerance

        // User1's buy should succeed - within both limits
        vm.prank(user1);
        uint256 tokensReceived = token.buy{value: buyAmount}(
            user1,
            address(0),
            minOrderSize,
            priceLimit
        );

        assertGe(tokensReceived, minOrderSize, "Should meet minOrderSize");

        console.log("=== BUY WITH COMBINED PROTECTION - SUCCESS ===");
        console.log("Min order size:", minOrderSize);
        console.log("Price limit:", priceLimit);
        console.log("Tokens received:", tokensReceived);
        console.log("Both protections satisfied");
    }

    /// @notice Combined test: Both minPayoutSize AND sqrtPriceLimit protection on sell
    function test_Sell_CombinedProtection_WithinBothLimits() public {
        // Setup: Both users buy tokens
        vm.prank(user1);
        token.buy{value: 3 ether}(user1, address(0), 0, 0);

        vm.prank(user2);
        token.buy{value: 2 ether}(user2, address(0), 0, 0);

        // User2 sells a small amount first
        uint256 user2SellAmount = token.balanceOf(user2) / 10;
        vm.prank(user2);
        token.sell(user2SellAmount, user2, address(0), 0, 0);

        // Get quote AFTER price moved
        uint256 sellAmount = token.balanceOf(user1) / 3;
        (, , , uint256 quotedEth, uint160 sqrtPriceX96After) = token.quoteSell(
            sellAmount
        );

        // Set both protections with reasonable tolerances
        uint256 minPayoutSize = (quotedEth * 80) / 100; // 20% slippage (wider for low liquidity bonding curve)
        // For sell, price goes UP, so set limit 25% higher
        uint160 priceLimit = uint160((uint256(sqrtPriceX96After) * 125) / 100); // 25% price change

        // User1's sell should succeed - within both limits
        address recipient = makeAddr("sellRecipient5");
        vm.prank(user1);
        uint256 ethReceived = token.sell(
            sellAmount,
            recipient,
            address(0),
            minPayoutSize,
            priceLimit
        );

        assertGe(ethReceived, minPayoutSize, "Should meet minPayoutSize");

        console.log("=== SELL WITH COMBINED PROTECTION - SUCCESS ===");
        console.log("Min payout size:", minPayoutSize);
        console.log("Price limit:", priceLimit);
        console.log("ETH received:", ethReceived);
        console.log("Both protections satisfied");
    }

    /*//////////////////////////////////////////////////////////////
                    QUOTER UNAVAILABILITY ERROR TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test quoteBuy behavior when factory quoter is unset (skipped: factory disallows zero quoter)
    function test_QuoteBuy_WorksWhenQuoterUnset() public {
        vm.skip(true);

        // Create factory with no quoter
        vm.startPrank(admin);
        LiquidFactory noQuoterFactory = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager,
            address(burner),
            0, // rareBurnFeeBPS
            5000, // protocolFeeBPS
            5000, // referrerFeeBPS
            100, // defaultTotalFeeBPS
            2500, // defaultCreatorFeeBPS
            LP_TICK_LOWER,
            LP_TICK_UPPER,
            address(0), // No quoter
            address(0), // poolHooks
            60, // poolTickSpacing
            300, // internalMaxSlippageBps
            0.005 ether, // minOrderSizeWei
            1e15 // minInitialLiquidityWei
        );
        noQuoterFactory.setImplementation(address(liquidImpl));
        vm.stopPrank();

        // Create token with no quoter
        vm.prank(tokenCreator);
        address tokenAddr = noQuoterFactory.createLiquidToken{value: 1 ether}(
            tokenCreator,
            "ipfs://noquoter",
            "NOQUOTE",
            "NQT"
        );
        Liquid noQuoterToken = Liquid(payable(tokenAddr));

        // Try to quote buy - should revert with QuoterUnavailable
        vm.expectRevert(ILiquid.QuoterUnavailable.selector);
        noQuoterToken.quoteBuy(1 ether);
    }

    /// @notice Test quoteSell behavior when factory quoter is unset (skipped: factory disallows zero quoter)
    function test_QuoteSell_WorksWhenQuoterUnset() public {
        vm.skip(true);

        // Create factory with no quoter
        vm.startPrank(admin);
        LiquidFactory noQuoterFactory = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager,
            address(burner),
            0,
            5000,
            5000,
            100,
            2500,
            LP_TICK_LOWER,
            LP_TICK_UPPER,
            address(0), // No quoter
            address(0),
            60,
            300,
            0.005 ether,
            1e15
        );
        noQuoterFactory.setImplementation(address(liquidImpl));
        vm.stopPrank();

        // Create token with no quoter
        vm.prank(tokenCreator);
        address tokenAddr = noQuoterFactory.createLiquidToken{value: 1 ether}(
            tokenCreator,
            "ipfs://noquoter2",
            "NOQUOTE2",
            "NQT2"
        );
        Liquid noQuoterToken = Liquid(payable(tokenAddr));

        // First buy some tokens (buy doesn't require quoter for execution)
        vm.prank(user1);
        noQuoterToken.buy{value: 1 ether}(user1, address(0), 0, 0);

        // Try to quote sell - should revert with QuoterUnavailable
        vm.expectRevert(ILiquid.QuoterUnavailable.selector);
        noQuoterToken.quoteSell(1000e18);
    }

    /// @notice Test getCurrentPrice() handles extreme price scenarios without reverting
    /// @dev Reproduces bug where creator dumps 100k tokens into minimal ETH causing overflow
    ///      Fixed by using FullMath.mulDiv instead of naive multiplication
    function test_GetCurrentPrice_ExtremeScenario() public {
        // Capture initial price
        (uint256 ethPerTokenBefore, uint256 tokenPerEthBefore) = token
            .getCurrentPrice();
        assertGt(ethPerTokenBefore, 0, "Initial price should be non-zero");
        assertGt(tokenPerEthBefore, 0, "Initial price should be non-zero");

        // Creator dumps 90,000 tokens into the pool (extreme sell)
        // This creates an extremely skewed price: tons of LIQUID, minimal ETH
        // NOTE: We can't dump all 100k because the pool has limited ETH
        vm.startPrank(tokenCreator);
        uint256 creatorBalance = token.balanceOf(tokenCreator);
        assertEq(creatorBalance, 100_000e18, "Creator should have 100k tokens");

        // Sell 90k tokens in batches to avoid complete draining
        // This will create extreme price without reverting the swap
        uint256 sellAmount = 90_000e18;
        token.sell(
            sellAmount,
            tokenCreator,
            address(0),
            0, // No minimum (allow extreme slippage)
            0 // No price limit
        );
        vm.stopPrank();

        // At this point, price is extremely skewed
        // Before fix: getCurrentPrice() would revert with overflow
        // After fix: Should return valid (possibly extreme) values

        // This should NOT revert (main test)
        (uint256 ethPerTokenAfter, uint256 tokenPerEthAfter) = token
            .getCurrentPrice();

        // Verify price moved in expected direction (tokens became cheaper)
        // ethPerToken should decrease (less ETH per token)
        // tokenPerEth should increase (more tokens per ETH)
        assertLt(
            ethPerTokenAfter,
            ethPerTokenBefore,
            "Tokens should be cheaper after dump"
        );
        assertGt(
            tokenPerEthAfter,
            tokenPerEthBefore,
            "Should get more tokens per ETH after dump"
        );

        // Verify values are reasonable (not completely broken)
        // After extreme dump, tokens should be very cheap but not zero
        assertGt(ethPerTokenAfter, 0, "Price should still be non-zero");
        assertGt(tokenPerEthAfter, 0, "Price should still be non-zero");

        // The ratio should be consistent (within numerical precision)
        // ethPerToken * tokenPerEth ≈ 1e36 (1e18 * 1e18)
        uint256 product = (ethPerTokenAfter * tokenPerEthAfter) / 1e18;
        assertGt(product, 1e17, "Price ratio should be reasonable (>0.1e18)");
        assertLt(product, 1e19, "Price ratio should be reasonable (<10e18)");
    }

    /// @notice Test that trades still work when quoter is unset (quotes fail, trades succeed)
    /// @dev Verifies system degrades gracefully - quotes unavailable but trades still execute
    function test_TradesWorkWithoutQuoter() public {
        // SKIPPED: V4 requires quoter to be set at factory construction
        // Quoter is mandatory for V4 pools, so this test is no longer applicable
        vm.skip(true);

        // Create factory with no quoter
        vm.startPrank(admin);
        LiquidFactory noQuoterFactory = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager,
            address(burner),
            0,
            5000,
            5000,
            100,
            2500,
            LP_TICK_LOWER,
            LP_TICK_UPPER,
            address(0), // No quoter
            address(0),
            60,
            300,
            0.005 ether,
            1e15
        );
        noQuoterFactory.setImplementation(address(liquidImpl));
        vm.stopPrank();

        // Create token with no quoter
        vm.prank(tokenCreator);
        address tokenAddr = noQuoterFactory.createLiquidToken{value: 1 ether}(
            tokenCreator,
            "ipfs://noquoter3",
            "NOQUOTE3",
            "NQT3"
        );
        Liquid noQuoterToken = Liquid(payable(tokenAddr));

        // Buy should work without quoter
        vm.prank(user1);
        uint256 tokensReceived = noQuoterToken.buy{value: 1 ether}(
            user1,
            address(0),
            0,
            0
        );
        assertGt(tokensReceived, 0, "Buy should work without quoter");

        // Sell should also work without quoter
        vm.startPrank(user1);
        noQuoterToken.approve(address(noQuoterToken), tokensReceived / 2);
        uint256 ethReceived = noQuoterToken.sell(
            tokensReceived / 2,
            user1,
            address(0),
            0,
            0
        );
        vm.stopPrank();

        assertGt(ethReceived, 0, "Sell should work without quoter");
    }
}
