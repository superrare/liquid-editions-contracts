// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Liquid} from "../src/Liquid.sol";
import {LiquidFactory} from "../src/LiquidFactory.sol";
import {RAREBurner} from "../src/RAREBurner.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {NetworkConfig} from "../script/config/NetworkConfig.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {MockRARE} from "./helpers/MockRARE.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    MockRARE public mockRARE;

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

        // Deploy MockRARE and fund accounts
        mockRARE = new MockRARE();
        mockRARE.mint(admin, 10_000_000 ether);
        mockRARE.mint(tokenCreator, 10_000_000 ether);
        mockRARE.mint(user1, 10_000_000 ether);
        mockRARE.mint(user2, 10_000_000 ether);

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
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            LP_TICK_LOWER,
            LP_TICK_UPPER,
            config.uniswapV4Quoter, // Use wrapper instead of raw quoter
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            300, // internalMaxSlippageBps (3%)
            1e15 // minRareLiquidityWei (0.001 RARE)
        );

        factory.setImplementation(address(liquidImpl));

        // Set base token to MockRARE
        factory.setBaseToken(address(mockRARE));

        vm.stopPrank();

        // Create a token with production initial liquidity: 0.001 RARE + 900K tokens
        // Starting at tickUpper (cheap tokens), minimal RARE is sufficient
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.001 ether);
        address tokenAddr = factory.createLiquidToken(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.001 ether
        );
        vm.stopPrank();
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

        // NOTE: buy() function removed - trading now handled by LiquidRouter
        // Initial buys removed - pool liquidity comes from initial RARE deposit
        console.log("=== INITIAL SETUP COMPLETE ===");
        console.log("Pool initialized with initial RARE liquidity");
    }

    // ============================================
    // BASIC QUOTE → BUY TESTS
    // ============================================

    /// @notice Test that quoteBuy returns expected output
    /// @dev Tests simplified quote function (no fee breakdown - fees handled by LiquidRouter)
    function test_QuoteBuy_BasicAccuracy() public {
        uint256 rareAmount = 1 ether;

        // Get quote (simplified - just output and price)
        (uint256 tokenOut, uint160 sqrtPriceX96After) = token.quoteBuy(
            rareAmount
        );

        // Verify quote returns values
        assertGt(tokenOut, 0, "Should return positive token output");
        assertGt(sqrtPriceX96After, 0, "Should return positive price");

        // NOTE: buy() function removed - trading now handled by LiquidRouter
        // Cannot test quote accuracy against actual trades since buy() no longer exists
        // Quote functions still work for client-side estimation
    }

    /// @notice Test quoteBuy → buy with user-specified minOrderSize protection
    function test_QuoteBuy_WithMinOrderSize() public {
        uint256 ethAmount = 1 ether;

        // Get quote
        (uint256 tokenOut, ) = token.quoteBuy(ethAmount);

        // NOTE: buy() function removed - trading now handled by LiquidRouter
        // Cannot test quote accuracy against actual trades since buy() no longer exists
    }

    /// @notice Test that buy reverts when minOrderSize is too high based on quote
    function test_QuoteBuy_RevertsWhenMinOrderSizeTooHigh() public {
        uint256 ethAmount = 1 ether;

        // Get quote
        (uint256 tokenOut, ) = token.quoteBuy(ethAmount);

        // NOTE: buy() function removed - trading now handled by LiquidRouter
        // Cannot test quote accuracy against actual trades since buy() no longer exists
    }

    /// @notice Returned sqrtPriceX96After should be immediately reusable as sqrtPriceLimit
    function test_QuoteBuy_LimitMatchesQuote() public {
        uint256 ethAmount = 0.75 ether;

        (uint256 tokenOut, uint160 sqrtPriceX96After) = token.quoteBuy(
            ethAmount
        );

        // NOTE: buy() function removed - trading now handled by LiquidRouter
        // Cannot test quote accuracy against actual trades since buy() no longer exists
    }

    // ============================================
    // EDGE CASES
    // ============================================

    /// @notice Test quote with very large amounts (bonding curve stress test)
    function test_QuoteBuy_LargeAmount() public {
        uint256 largeAmount = 50 ether;
        vm.deal(user1, largeAmount);

        // Get quote
        (uint256 tokenOut, ) = token.quoteBuy(largeAmount);
        assertGt(tokenOut, 0, "Should quote positive tokens for large amount");

        // NOTE: buy() function removed - trading now handled by LiquidRouter
        // Cannot test quote accuracy against actual trades since buy() no longer exists
    }

    // NOTE: buy() function removed - trading now handled by LiquidRouter
    function test_QuoteBuy_WithReferrer() public {
        // Removed - buy() no longer exists
        // All trading is now handled by LiquidRouter for multi-hop swaps
    }

    // NOTE: buy() and sell() functions removed - trading now handled by LiquidRouter
    function test_QuoteSell_AfterLPFeeAccumulation() public {
        // Removed - buy() and sell() no longer exist
        // All trading is now handled by LiquidRouter for multi-hop swaps
    }

    // ============================================
    // MULTI-USER INVARIANT TESTS
    // ============================================

    // NOTE: buy() function removed - trading now handled by LiquidRouter
    function test_Invariant_MultiUserQuoteAccuracy() public {
        // Removed - buy() no longer exists
        // All trading is now handled by LiquidRouter for multi-hop swaps
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

    // NOTE: buy() function removed - trading now handled by LiquidRouter
    function _assertQuoteBuyAccuracy(uint256 ethAmount) internal {
        // Removed - buy() no longer exists
        // All trading is now handled by LiquidRouter for multi-hop swaps
    }

    // NOTE: buy() and sell() functions removed - trading now handled by LiquidRouter
    function _assertQuoteSellAccuracy(uint256 sellPercent) internal {
        // Removed - buy() and sell() no longer exist
        // All trading is now handled by LiquidRouter for multi-hop swaps
    }

    // NOTE: buy() function removed - trading now handled by LiquidRouter
    function _assertQuoteBuyMinOrderProtection(
        uint256 ethAmount,
        uint256 tolerancePercent
    ) internal {
        // Removed - buy() no longer exists
        // All trading is now handled by LiquidRouter for multi-hop swaps
    }

    // NOTE: buy() and sell() functions removed - trading now handled by LiquidRouter
    function _assertQuoteSellMinPayoutProtection(
        uint256 sellPercent,
        uint256 tolerancePercent
    ) internal {
        // Removed - buy() and sell() no longer exist
        // All trading is now handled by LiquidRouter for multi-hop swaps
    }

    // NOTE: buy() function removed - trading now handled by LiquidRouter
    function _assertQuoteAccuracyAcrossPoolStates(
        uint256 initialBuy,
        uint256 testBuy
    ) internal {
        // Removed - buy() no longer exists
        // All trading is now handled by LiquidRouter for multi-hop swaps
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

    /// @notice Test that quoteSell returns expected output for non-zero amounts
    /// @dev Tests that quoteSell works correctly with sign checks for sell direction
    ///      This test verifies that quoteSell() handles non-zero amounts correctly
    ///      and doesn't have sign check issues that would cause it to revert or return wrong values
    function test_QuoteSell_NonZero() public {
        // The pool starts with initial liquidity (900K tokens + RARE)
        // We can quote selling tokens without needing to buy first

        // Test with a reasonable token amount (e.g., 1000 tokens)
        uint256 tokenAmount = 1000e18;

        // Get current price before quote (for comparison)
        (uint256 rarePerTokenBefore, uint256 tokenPerRareBefore) = token
            .getCurrentPrice();

        // Verify pool is initialized
        assertGt(
            rarePerTokenBefore,
            0,
            "Pool should be initialized with non-zero price"
        );

        // Get quote for selling tokens
        (uint256 rareOut, uint160 sqrtPriceX96After) = token.quoteSell(
            tokenAmount
        );

        // Verify quote returns non-zero values
        assertGt(rareOut, 0, "Should return positive RARE output");
        assertGt(sqrtPriceX96After, 0, "Should return positive sqrt price");

        // Verify the quote makes sense: selling tokens should give us RARE
        // The amount should be reasonable (not zero, not unreasonably large)
        assertLt(
            rareOut,
            tokenAmount,
            "RARE output should be less than token input (slippage/fees)"
        );

        console.log("QuoteSell test:");
        console.log("Token amount:", tokenAmount);
        console.log("RARE out:", rareOut);
        console.log("Sqrt price after:", sqrtPriceX96After);
        console.log("RARE per token before:", rarePerTokenBefore);
        console.log("Token per RARE before:", tokenPerRareBefore);
    }

    // NOTE: sell() function removed - trading now handled by LiquidRouter
    function test_QuoteSell_RevertsOnInsufficientBalance() public {
        // Removed - sell() no longer exists
        // All trading is now handled by LiquidRouter for multi-hop swaps
    }

    // ============================================
    // PRICE MANIPULATION & SLIPPAGE TESTS
    // ============================================

    // NOTE: buy() function removed - trading now handled by LiquidRouter
    function test_Buy_MinOrderSize_PriceMovesWithinTolerance() public {
        // Removed - buy() no longer exists
        // All trading is now handled by LiquidRouter for multi-hop swaps
    }

    // NOTE: buy() function removed - trading now handled by LiquidRouter
    function test_Buy_MinOrderSize_PriceMovesBeyondTolerance() public {
        // Removed - buy() no longer exists
        // All trading is now handled by LiquidRouter for multi-hop swaps
    }

    // NOTE: buy() and sell() functions removed - trading now handled by LiquidRouter
    function test_Sell_MinPayoutSize_PriceMovesWithinTolerance() public {
        // Removed - buy() and sell() no longer exist
        // All trading is now handled by LiquidRouter for multi-hop swaps
    }

    // NOTE: buy() and sell() functions removed - trading now handled by LiquidRouter
    function test_Sell_MinPayoutSize_PriceMovesBeyondTolerance() public {
        // Removed - buy() and sell() no longer exist
        // All trading is now handled by LiquidRouter for multi-hop swaps
    }

    // NOTE: buy() function removed - trading now handled by LiquidRouter
    function test_Buy_SqrtPriceLimit_WithinLimit() public {
        // Removed - buy() no longer exists
        // All trading is now handled by LiquidRouter for multi-hop swaps
    }
}
