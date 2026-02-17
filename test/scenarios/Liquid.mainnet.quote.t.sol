// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {LiquidPoolSwapHelper} from "liquid-editions-test/helpers/LiquidPoolSwapHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LiquidInstant Quote → Trade Pattern Tests
/// @notice Comprehensive tests for quoteBuy() → buy() and quoteSell() → sell() patterns
/// @dev Tests that quotes accurately predict actual trade outcomes including slippage protection
contract LiquidInstantQuoteTradeTest is Test {
    // Network configuration
    NetworkConfig.Config internal config;

    // Test accounts
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public referrer = makeAddr("referrer");

    // Contracts
    LiquidFactory public factory;
    LiquidInstant public liquidImpl;
    LiquidInstant public token;
    RAREBurner public burner;
    MockRARE public mockRARE;
    LiquidPoolSwapHelper public swapHelper;

    // LP tick range - production configuration
    // Note: price = LIQUID/ETH. High tick = many tokens per ETH = cheap (bonding curve bottom)
    // As users buy, tick moves DOWN = tokens get more expensive
    int24 constant LP_TICK_LOWER = -180; // Max expensive (after price rises) - multiple of 60
    int24 constant LP_TICK_UPPER = 120000; // Starting point - cheap tokens - multiple of 60
    uint256 constant INITIAL_LIQUIDITY_RARE = 0.001 ether;
    uint256 constant ORDERING_SWAP_RARE_IN = 1 ether;
    address internal constant ORDERING_BASE_TOKEN_LOW =
        address(0x0000000000000000000000000000000000000100);
    address internal constant ORDERING_BASE_TOKEN_HIGH = address(
        uint160(type(uint160).max)
    );

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

        liquidImpl = new LiquidInstant();

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

        swapHelper = new LiquidPoolSwapHelper(
            IPoolManager(config.uniswapV4PoolManager)
        );

        vm.stopPrank();

        // Create a token with production initial liquidity: 0.001 RARE + 900K tokens
        // Starting at tickUpper (cheap tokens), minimal RARE is sufficient
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), INITIAL_LIQUIDITY_RARE);
        address tokenAddr = factory.createLiquidToken(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            INITIAL_LIQUIDITY_RARE
        );
        vm.stopPrank();
        token = LiquidInstant(payable(tokenAddr));

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

    function _prepareMockBase(address baseAddress) internal returns (MockRARE baseToken) {
        if (baseAddress.code.length == 0) {
            vm.etch(baseAddress, address(mockRARE).code);
        }
        baseToken = MockRARE(baseAddress);
    }

    function _createTokenWithBase(
        MockRARE baseTokenToUse
    ) internal returns (LiquidInstant createdToken) {
        baseTokenToUse.mint(
            tokenCreator,
            INITIAL_LIQUIDITY_RARE + (ORDERING_SWAP_RARE_IN * 2)
        );

        vm.startPrank(admin);
        factory.setBaseToken(address(baseTokenToUse));
        vm.stopPrank();

        vm.startPrank(tokenCreator);
        IERC20(address(baseTokenToUse)).approve(
            address(factory),
            INITIAL_LIQUIDITY_RARE
        );
        address tokenAddress = factory.createLiquidToken(
            tokenCreator,
            "ipfs://ordering-test",
            "Ordering Test",
            "ORDR",
            INITIAL_LIQUIDITY_RARE
        );
        vm.stopPrank();

        createdToken = LiquidInstant(payable(tokenAddress));
        return createdToken;
    }

    function _createTokenWithOrdering(
        bool wantBaseTokenIsCurrency0
    ) internal returns (LiquidInstant createdToken, MockRARE baseToken) {
        address baseAddress = wantBaseTokenIsCurrency0
            ? ORDERING_BASE_TOKEN_LOW
            : ORDERING_BASE_TOKEN_HIGH;

        baseToken = _prepareMockBase(baseAddress);
        createdToken = _createTokenWithBase(baseToken);

        if ((address(baseToken) < address(createdToken)) == wantBaseTokenIsCurrency0) {
            return (createdToken, baseToken);
        }

        revert("FailedToForceOrdering");
    }

    function _assertMarketInversionCorrect(
        LiquidInstant testedToken
    ) internal view {
        (uint256 rarePerTokenPrice, uint256 tokenPerRarePrice) = testedToken
            .getCurrentPrice();
        (
            uint256 rarePerTokenMarket,
            uint256 tokenPerRareMarket,
            uint160 sqrtPriceX96,
            ,
            ,
            uint256 currentSupply
        ) = testedToken.getMarketState();

        assertEq(
            rarePerTokenPrice,
            rarePerTokenMarket,
            "getCurrentPrice/getMarketState rarePerToken mismatch"
        );
        assertEq(
            tokenPerRarePrice,
            tokenPerRareMarket,
            "getCurrentPrice/getMarketState tokenPerRare mismatch"
        );
        assertEq(
            currentSupply,
            testedToken.MAX_TOTAL_SUPPLY(),
            "market state should report max supply"
        );

        assertGt(sqrtPriceX96, 0, "sqrtPriceX96 must be non-zero");

        uint256 priceQ128 = FullMath.mulDiv(
            uint256(sqrtPriceX96),
            uint256(sqrtPriceX96),
            1 << 64
        );
        uint256 denominatorQ128 = 1 << 128;

        bool baseTokenIsCurrency0 = testedToken.baseToken() <
            address(testedToken);
        uint256 expectedRarePerToken;
        uint256 expectedTokenPerRare;

        if (baseTokenIsCurrency0) {
            expectedRarePerToken = FullMath.mulDiv(
                denominatorQ128,
                1e18,
                priceQ128
            );
            expectedTokenPerRare = FullMath.mulDiv(
                priceQ128,
                1e18,
                denominatorQ128
            );
        } else {
            expectedRarePerToken = FullMath.mulDiv(
                priceQ128,
                1e18,
                denominatorQ128
            );
            expectedTokenPerRare = FullMath.mulDiv(
                denominatorQ128,
                1e18,
                priceQ128
            );
        }

        assertEq(
            rarePerTokenPrice,
            expectedRarePerToken,
            "rare/ token inversion mismatch"
        );
        assertEq(
            tokenPerRarePrice,
            expectedTokenPerRare,
            "token per rare inversion mismatch"
        );
    }

    function _assertQuoteMatchesActualForToken(LiquidInstant testedToken) internal {
        uint256 rareIn = ORDERING_SWAP_RARE_IN;
        MockRARE baseToken = MockRARE(testedToken.baseToken());

        uint256 availableBase = baseToken.balanceOf(tokenCreator);
        if (availableBase < rareIn) {
            baseToken.mint(tokenCreator, rareIn - availableBase);
        }

        vm.startPrank(tokenCreator);
        (uint256 quotedOut, ) = testedToken.quoteBuy(rareIn);
        IERC20(testedToken.baseToken()).approve(address(swapHelper), rareIn);
        uint256 actualOut = swapHelper.buy(address(testedToken), rareIn, tokenCreator);
        vm.stopPrank();

        uint256 tolerance = (actualOut / 100) + 1;
        assertApproxEqAbs(
            quotedOut,
            actualOut,
            tolerance,
            "Quote buy should match actual buy within tolerance"
        );

        uint256 sellAmount = actualOut / 2;

        (uint256 quotedRareOut, ) = testedToken.quoteSell(sellAmount);

        vm.startPrank(tokenCreator);
        testedToken.approve(address(swapHelper), sellAmount);
        uint256 actualRareOut = swapHelper.sell(
            address(testedToken),
            sellAmount,
            tokenCreator
        );
        vm.stopPrank();

        tolerance = (actualRareOut / 100) + 1;
        assertApproxEqAbs(
            quotedRareOut,
            actualRareOut,
            tolerance,
            "Quote sell should match actual sell within tolerance"
        );
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
    }

    function test_QuoteBuy_MatchesActualTrade() public {
        uint256 rareAmount = 1 ether;

        (uint256 quotedOut, ) = token.quoteBuy(rareAmount);

        vm.startPrank(user1);
        IERC20(mockRARE).approve(address(swapHelper), rareAmount);
        uint256 actualOut = swapHelper.buy(address(token), rareAmount, user1);
        vm.stopPrank();

        uint256 tolerance = (actualOut / 100) + 1;
        assertApproxEqAbs(
            quotedOut,
            actualOut,
            tolerance,
            "Quote buy should match actual buy within tolerance"
        );
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
    }

    function test_QuoteSell_MatchesActualTrade() public {
        uint256 buyAmount = 10 ether;

        vm.startPrank(user1);
        IERC20(mockRARE).approve(address(swapHelper), buyAmount);
        uint256 tokenAmount = swapHelper.buy(address(token), buyAmount, user1);
        vm.stopPrank();

        uint256 sellAmount = tokenAmount / 2;
        (uint256 quotedRareOut, ) = token.quoteSell(sellAmount);

        vm.startPrank(user1);
        token.approve(address(swapHelper), sellAmount);
        uint256 actualRareOut = swapHelper.sell(
            address(token),
            sellAmount,
            user1
        );
        vm.stopPrank();

        uint256 tolerance = (actualRareOut / 100) + 1;
        assertApproxEqAbs(
            quotedRareOut,
            actualRareOut,
            tolerance,
            "Quote sell should match actual sell within tolerance"
        );
    }

    function test_QuoteOrdering_BaseTokenLessThanToken_QuotesAndMarkets() public {
        (LiquidInstant orderedToken, MockRARE orderedBaseToken) = _createTokenWithOrdering(
            true
        );

        assertTrue(
            address(orderedBaseToken) < address(orderedToken),
            "baseToken should be currency0 for this branch"
        );

        _assertMarketInversionCorrect(orderedToken);
        _assertQuoteMatchesActualForToken(orderedToken);
    }

    function test_QuoteOrdering_BaseTokenGreaterThanToken_QuotesAndMarkets() public {
        (LiquidInstant orderedToken, MockRARE orderedBaseToken) = _createTokenWithOrdering(
            false
        );

        assertTrue(
            address(orderedBaseToken) > address(orderedToken),
            "baseToken should be currency1 for this branch"
        );

        _assertMarketInversionCorrect(orderedToken);
        _assertQuoteMatchesActualForToken(orderedToken);
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

}
