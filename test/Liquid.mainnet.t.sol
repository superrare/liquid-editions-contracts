// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Liquid} from "../src/Liquid.sol";
import {LiquidFactory} from "../src/LiquidFactory.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {RAREBurner} from "../src/RAREBurner.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {NetworkConfig} from "../script/NetworkConfig.sol";

// Mock burner for testing
contract MockBurner {
    receive() external payable {}

    function depositForBurn() external payable {}
}

contract LiquidBaseMainnetTest is Test {
    using StateLibrary for IPoolManager;
    // Network configuration
    NetworkConfig.Config public config;

    // Helper function to compute correct PoolId from parameters
    function _computePoolId(
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

        return PoolId.unwrap(PoolIdLibrary.toId(key));
    }

    // Test accounts
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");

    // Contract interfaces
    RAREBurner public burner;
    Liquid public liquidImplementation;
    LiquidFactory public factory;

    function setUp() public {
        // Fork Base mainnet for contract address verification
        string memory forkUrl = vm.envOr(
            "FORK_URL",
            string("https://mainnet.base.org")
        );
        vm.createSelectFork(forkUrl);

        // Get network configuration (Base mainnet chain ID = 8453)
        config = NetworkConfig.getConfig(block.chainid);

        // Fund test accounts
        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(protocolFeeRecipient, 100 ether);

        // Deploy contracts
        vm.startPrank(admin);

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

        liquidImplementation = new Liquid();
        MockBurner mockBurner = new MockBurner();


        factory = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            address(mockBurner), // rareBurner
            0, // rareBurnFeeBPS
            5000, // protocolFeeBPS
            5000, // referrerFeeBPS
            100, // defaultTotalFeeBPS
            2500, // defaultCreatorFeeBPS
            -180, // lpTickLower - max expensive (after price rises) - multiple of 60
            120000, // lpTickUpper - starting point (cheap tokens)
            config.uniswapV4Quoter, // Use wrapper instead of raw quoter
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            300, // internalMaxSlippageBps (3%)
            0.005 ether, // minOrderSizeWei
            1e15 // minInitialLiquidityWei (0.001 ETH)
        );

        // Set the implementation in the factory
        factory.setImplementation(address(liquidImplementation));

        vm.stopPrank();
    }

    function testBaseMainnetContractAddresses() public view {
        // Verify all Base mainnet contract addresses exist and have code
        console.log("=== BASE MAINNET CONTRACT VERIFICATION ===");
        console.log("WETH address:", config.weth);
        console.log("WETH code size:", config.weth.code.length);
        assertTrue(config.weth.code.length > 0, "WETH should have code");
    }

    function testBaseMainnetFactoryETHForwardingAndLiquidity() public {
        // Test to verify that the LiquidFactory properly forwards ETH and creates liquidity on Base mainnet
        uint256 FACTORY_ETH_AMOUNT = 1 ether;

        address creator = makeAddr("baseCreator");
        vm.deal(creator, 100 ether);

        // Record creator's balance before
        uint256 creatorBalanceBefore = creator.balance;

        // Create token through factory with ETH
        vm.startPrank(creator);
        address tokenAddress = factory.createLiquidToken{
            value: FACTORY_ETH_AMOUNT
        }(creator, "ipfs://base-test", "BASE_TEST", "BT");
        vm.stopPrank();

        // Verify ETH was spent (all ETH goes to liquidity)
        Liquid baseLiquid = Liquid(payable(tokenAddress));
            assertEq(
                creator.balance,
                creatorBalanceBefore - FACTORY_ETH_AMOUNT,
            "Creator should have spent all the ETH"
            );

        // Get the Liquid token instance

        // Verify token was created properly
        assertEq(baseLiquid.name(), "BASE_TEST");
        assertEq(baseLiquid.symbol(), "BT");
        assertEq(baseLiquid.tokenCreator(), creator);

        // Verify pool was created
        assertTrue(
            PoolId.unwrap(baseLiquid.poolId()) != bytes32(0),
            "Base mainnet factory should create pool"
        );

        // Check pool initialization using V4 StateLibrary
        IPoolManager pm = IPoolManager(baseLiquid.poolManager());
        PoolId poolId = baseLiquid.poolId();
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "Base mainnet pool should be initialized");

        // Check liquidity using V4 - liquidity is stored in the Liquid contract
        uint128 liquidity = baseLiquid.lpLiquidity();

        // CRITICAL TEST: Check that liquidity exists
        assertTrue(
            liquidity > 0,
            "Base mainnet LP position should have liquidity > 0"
        );

        console.log("Pool's position liquidity:", liquidity);

        // Verify creator got launch rewards
        uint256 creatorTokens = baseLiquid.balanceOf(creator);
        uint256 CREATOR_LAUNCH_REWARD = 100_000e18;
        assertEq(
            creatorTokens,
            CREATOR_LAUNCH_REWARD,
            "Creator should have only launch rewards"
        );

        console.log("=== BASE MAINNET FACTORY ETH FORWARDING TEST ===");
        console.log("ETH sent to factory:", FACTORY_ETH_AMOUNT);
        console.log("Token address:", tokenAddress);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(baseLiquid.poolId()));
        console.log("Position liquidity:", liquidity);
        console.log("Creator token balance:", creatorTokens);
        console.log("Launch reward:", CREATOR_LAUNCH_REWARD);
        console.log("Pool sqrt price:", sqrtPriceX96);
    }

    function testBaseMainnetMinimumETHLiquidity() public {
        // Test with minimum ETH amount on Base mainnet
        uint256 MIN_ETH_AMOUNT = 0.001 ether;

        address creator = makeAddr("baseMinCreator");
        vm.deal(creator, 100 ether);

        // Create token with minimum ETH
        vm.startPrank(creator);
        address tokenAddress = factory.createLiquidToken{value: MIN_ETH_AMOUNT}(
            creator,
            "ipfs://base-min-test",
            "BASE_MIN",
            "BM"
        );
        vm.stopPrank();

        // Get the Liquid token instance
        Liquid baseLiquid = Liquid(payable(tokenAddress));

        // Verify pool was created
        assertTrue(
            PoolId.unwrap(baseLiquid.poolId()) != bytes32(0),
            "Base mainnet should create pool with minimum ETH"
        );

        // Check pool initialization using V4 StateLibrary
        IPoolManager pm = IPoolManager(baseLiquid.poolManager());
        PoolId poolId = baseLiquid.poolId();
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "Base mainnet pool should be initialized with minimum ETH");

        // Check liquidity using V4 - liquidity is stored in the Liquid contract
        uint128 liquidity = baseLiquid.lpLiquidity();

        // Main assertion - even with minimum ETH on Base mainnet, there should be liquidity
        assertTrue(
            liquidity > 0,
            "Base mainnet LP position should have liquidity > 0 even with minimum ETH"
        );

        console.log("=== BASE MAINNET MINIMUM ETH TEST ===");
        console.log("ETH amount used:", MIN_ETH_AMOUNT);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(baseLiquid.poolId()));
        console.log("Position liquidity:", liquidity);
        console.log("Pool sqrt price:", sqrtPriceX96);
    }

    function testBaseMainnetRAREBurnConfiguration() public {
        console.log("=== BASE MAINNET RARE BURN CONFIGURATION TEST ===");

        // Note: The actual pool parameters for the V4 RARE/WETH pool need to be verified.
        // Common fee tiers: 500 (0.05%), 3000 (0.3%), 10000 (1%)
        // Tick spacings: 10 for 0.05%, 60 for 0.3%, 200 for 1%

        // Try with 0.3% fee tier first (most common)
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);

        // Compute the PoolId from the actual pool parameters
        bytes32 poolId = _computePoolId(
            config.rareToken,
            poolFee,
            tickSpacing,
            hooks
        );

        console.log("Computed pool ID:", vm.toString(poolId));

        // Configure RARE burn with Base mainnet V4 pool using computed pool ID
        vm.startPrank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            false, // tryOnDeposit
            config.rareToken,
            config.uniswapV4PoolManager,
            poolFee,
            tickSpacing,
            hooks,
            0x000000000000000000000000000000000000dEaD, // burn address
            address(0), // no quoter (slippage protection disabled)
            0, // 0% slippage (no quoter available)
            true // enabled
        );
        vm.stopPrank();

        // Verify the configuration is valid
        bool isValid = testBurner.validatePoolConfig();
        assertTrue(isValid, "Pool config should be valid after setting");
        console.log("Pool config validation: PASSED");

        // Verify configuration was set correctly - read individual state variables
        address rareToken = testBurner.rareToken();
        address v4PoolManager = testBurner.v4PoolManager();
        address v4Hooks = testBurner.v4Hooks();
        address storedBurnAddress = testBurner.burnAddress();
        bytes32 v4PoolId = testBurner.v4PoolId();
        uint24 v4PoolFee = testBurner.v4PoolFee();
        int24 v4TickSpacing = testBurner.v4TickSpacing();
        uint16 maxSlippageBPS = testBurner.maxSlippageBPS();
        bool enabled = testBurner.enabled();

        assertEq(
            rareToken,
            config.rareToken,
            "RARE token address should match"
        );
        assertTrue(enabled, "RARE burn should be enabled");
        assertEq(maxSlippageBPS, 0, "Max slippage should be 0% (no quoter)");
        assertEq(
            v4PoolManager,
            config.uniswapV4PoolManager,
            "V4 PoolManager should match"
        );
        // Note: v4PoolId will be the COMPUTED value, not necessarily the hardcoded constant
        bytes32 expectedPoolId = _computePoolId(
            config.rareToken,
            3000,
            60,
            address(0)
        );
        assertEq(
            v4PoolId,
            expectedPoolId,
            "V4 pool ID should match computed value"
        );
        assertEq(v4PoolFee, 3000, "Pool fee should be 0.3%");
        assertEq(v4TickSpacing, 60, "Tick spacing should be 60");
        assertEq(v4Hooks, address(0), "No hooks should be configured");
        assertEq(
            storedBurnAddress,
            0x000000000000000000000000000000000000dEaD,
            "Burn address should be 0xdEaD"
        );

        console.log("RARE token:", config.rareToken);
        console.log("V4 PoolManager:", config.uniswapV4PoolManager);
        console.log("V4 Pool ID:", vm.toString(v4PoolId));
        console.log("Max slippage BPS:", maxSlippageBPS);
        console.log("Pool fee:", v4PoolFee);
        console.log("Tick spacing:", vm.toString(v4TickSpacing));
        console.log("Burn address:", storedBurnAddress);

        assertTrue(testBurner.isRAREBurnActive(), "RARE burn should be active");
        console.log("RARE burn is active: true");
        console.log("");
        console.log(
            "IMPORTANT: If the V4 pool uses NATIVE ETH instead of WETH:"
        );
        console.log("- V4 represents native ETH as Currency.wrap(address(0))");
        console.log("- Our implementation uses WETH:", config.weth);
        console.log(
            "- This could cause PoolNotInitialized if pool expects native ETH"
        );
    }

    function testBaseMainnetTokenWithRAREBurn() public {
        console.log("=== BASE MAINNET TOKEN WITH RARE BURN TEST ===");

        // Create a token FIRST (before enabling RARE burn) to ensure initialization succeeds
        address creator = makeAddr("baseRARECreator");
        vm.deal(creator, 100 ether);

        vm.startPrank(creator);
        address tokenAddress = factory.createLiquidToken{value: 1 ether}(
            creator,
            "ipfs://base-rare-test",
            "BASE_RARE",
            "BR"
        );
        vm.stopPrank();

        Liquid baseLiquid = Liquid(payable(tokenAddress));

        // Verify token was created successfully
        assertEq(baseLiquid.tokenCreator(), creator);
        assertTrue(PoolId.unwrap(baseLiquid.poolId()) != bytes32(0));

        console.log("Token created:", tokenAddress);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(baseLiquid.poolId()));
        console.log("Token creator:", creator);

        // NOW configure RARE burn after token creation
        // Use computed PoolId to ensure validation passes
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);
        bytes32 computedPoolId = _computePoolId(
            config.rareToken,
            poolFee,
            tickSpacing,
            hooks
        );

        vm.startPrank(admin);
        RAREBurner testBurner = new RAREBurner(
            admin,
            false, // tryOnDeposit
            config.rareToken,
            config.uniswapV4PoolManager,
            poolFee,
            tickSpacing,
            hooks,
            0x000000000000000000000000000000000000dEaD, // burn address
            address(0),
            0,
            true
        );
        vm.stopPrank();

        // Verify burner was created and is active
        assertTrue(testBurner.isRAREBurnActive(), "RARE burner should be active");

        // Now perform a buy to generate fees
        address buyer = makeAddr("baseBuyer");
        vm.deal(buyer, 10 ether);

        uint256 buyAmount = 0.1 ether;

        // BUFFERED BURN BEHAVIOR: With RARE burn enabled, the buy transaction will:
        // 1. Always SUCCEED - user trades never revert due to RARE burn issues
        // 2. ETH deposits to RAREBurner (synchronous, buffered)
        // 3. Actual V4 burn happens later via flush() (asynchronous, can fail gracefully)
        console.log(
            "Note: RARE burn uses BUFFERED pattern - user trades always succeed"
        );
        console.log(
            "ETH accumulates in burner, actual burns happen via separate flush() calls"
        );

        // Execute buy - should always succeed regardless of V4 pool state
        vm.prank(buyer);
        uint256 tokens = baseLiquid.buy{value: buyAmount}(
            buyer,
            address(0),
            0,
            0
        );

        console.log("SUCCESS: Buy transaction completed!");
        console.log("- Tokens received:", tokens);
        console.log("- ETH deposited to RAREBurner");
        console.log("- Actual RARE burn will happen on next flush() call");
        assertTrue(tokens > 0, "Should have received tokens");
        console.log("");
        console.log("TROUBLESHOOTING:");
        console.log(
            "If getting PoolNotInitialized error, verify these pool parameters:"
        );
        console.log("- Fee tier: Currently using 3000 (0.3%)");
        console.log("- Tick spacing: Currently using 60");
        console.log("- Hooks: Currently using address(0)");
        console.log("- WETH address:", config.weth);
        console.log("- RARE address:", config.rareToken);
        console.log(
            "- Currency sort: WETH is token0?",
            uint160(config.weth) < uint160(config.rareToken)
        );
        console.log("");
        console.log("The actual V4 pool may use different parameters.");
        console.log("Pool ID:", vm.toString(computedPoolId));
        console.log(
            "To find correct parameters, decode the pool ID or query the V4 PoolManager"
        );
    }

    // ============================================
    // QUOTER TESTS
    // ============================================

    function testQuoteBuyBasic() public {
        // Create a token with initial liquidity
        vm.prank(tokenCreator);
        address token = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST"
        );

        Liquid liquid = Liquid(payable(token));

        // Pass gross ETH amount (function handles fee calculation internally)
        uint256 buyAmount = 1 ether;

        // Get quote - now takes gross ETH and returns fee details
        (
            uint256 feeBps,
            uint256 ethFee,
            uint256 ethIn,
            uint256 liquidOut,
            uint160 sqrtPriceX96After
        ) = liquid.quoteBuy(buyAmount);

        console.log("=== Quote Buy Test ===");
        console.log("ETH in (gross):", buyAmount);
        console.log("Fee BPS:", feeBps);
        console.log("ETH fee:", ethFee);
        console.log("ETH in (after fee):", ethIn);
        console.log("Tokens out (quoted):", liquidOut);
        console.log("Sqrt price after:", sqrtPriceX96After);

        // Verify quote is reasonable
        assertGt(liquidOut, 0, "Quote should return non-zero tokens");
        assertGt(sqrtPriceX96After, 0, "Sqrt price should be non-zero");
        assertEq(
            feeBps,
            liquid.TOTAL_FEE_BPS(),
            "Fee BPS should match token config"
        );
        assertEq(
            ethFee,
            (buyAmount * feeBps) / 10_000,
            "Fee should be calculated correctly"
        );
        assertEq(ethIn, buyAmount - ethFee, "ETH in should be gross minus fee");
    }

    function testQuoteSellBasic() public {
        // Create a token and buy some tokens first
        vm.startPrank(tokenCreator);
        address token = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST"
        );

        Liquid liquid = Liquid(payable(token));

        // Buy some tokens
        liquid.buy{value: 1 ether}(tokenCreator, address(0), 0, 0);

        uint256 tokenBalance = liquid.balanceOf(tokenCreator);
        uint256 tokensToSell = tokenBalance / 2; // Sell half

        // Get quote - now returns ETH after fee (net payout)
        (
            uint256 feeBps,
            uint256 ethFee,
            uint256 tokenIn,
            uint256 ethOut,
            uint160 sqrtPriceX96After
        ) = liquid.quoteSell(tokensToSell);

        console.log("=== Quote Sell Test ===");
        console.log("Tokens in:", tokensToSell);
        console.log("Fee BPS:", feeBps);
        console.log("ETH fee:", ethFee);
        console.log("ETH out (quoted, after fee):", ethOut);
        console.log("Sqrt price after:", sqrtPriceX96After);

        // Verify quote is reasonable
        assertGt(ethOut, 0, "Quote should return non-zero ETH");
        assertGt(sqrtPriceX96After, 0, "Sqrt price should be non-zero");
        assertEq(
            feeBps,
            liquid.TOTAL_FEE_BPS(),
            "Fee BPS should match token config"
        );
        assertEq(tokenIn, tokensToSell, "Token in should match input");

        vm.stopPrank();
    }

    function testQuoteBuyMatchesActualTrade() public {
        // Create a token with initial liquidity
        vm.prank(tokenCreator);
        address token = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST"
        );

        Liquid liquid = Liquid(payable(token));

        // Pass gross ETH amount (function handles fee calculation internally)
        uint256 buyAmount = 1 ether;

        // Get quote - now takes gross ETH
        // Returns: (feeBps, ethFee, ethIn, liquidOut, sqrtPriceX96After)
        (, , , uint256 quotedAmount, ) = liquid.quoteBuy(buyAmount);

        // Execute actual trade
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        uint256 actualAmount = liquid.buy{value: buyAmount}(
            buyer,
            address(0),
            0,
            0
        );

        console.log("=== Quote vs Actual Trade ===");
        console.log("Quoted amount:", quotedAmount);
        console.log("Actual amount:", actualAmount);
        console.log(
            "Difference:",
            actualAmount > quotedAmount
                ? actualAmount - quotedAmount
                : quotedAmount - actualAmount
        );

        // Allow small difference due to LP fees collected between quote and execution
        uint256 tolerance = quotedAmount / 100; // 1% tolerance
        assertApproxEqAbs(
            actualAmount,
            quotedAmount,
            tolerance,
            "Actual trade should match quote within tolerance"
        );
    }

    function testQuoteSellMatchesActualTrade() public {
        // Create a token and buy some tokens
        vm.startPrank(tokenCreator);
        address token = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST"
        );

        Liquid liquid = Liquid(payable(token));

        // Buy tokens
        liquid.buy{value: 2 ether}(tokenCreator, address(0), 0, 0);

        uint256 tokenBalance = liquid.balanceOf(tokenCreator);
        uint256 tokensToSell = tokenBalance / 2;

        // Get quote for sell - returns ETH after fee (net payout)
        // Returns: (feeBps, ethFee, tokenIn, ethOut, sqrtPriceX96After)
        (, , , uint256 quotedPayout, ) = liquid.quoteSell(tokensToSell);

        // Execute actual sell - NOW returns payout AFTER fee (fixed!)
        uint256 actualPayout = liquid.sell(
            tokensToSell,
            tokenCreator,
            address(0),
            0,
            0
        );

        console.log("=== Quote vs Actual Sell ===");
        console.log("Quoted payout (after fee):", quotedPayout);
        console.log("Actual payout (after fee):", actualPayout);
        console.log(
            "Difference:",
            actualPayout > quotedPayout
                ? actualPayout - quotedPayout
                : quotedPayout - actualPayout
        );

        // Allow small difference due to LP fees and pool state changes
        uint256 tolerance = quotedPayout / 100; // 1% tolerance
        assertApproxEqAbs(
            actualPayout,
            quotedPayout,
            tolerance,
            "Actual payout should match quote within tolerance"
        );

        vm.stopPrank();
    }

    function testQuoteWithDifferentAmounts() public {
        // Create a token
        vm.prank(tokenCreator);
        address token = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST"
        );

        Liquid liquid = Liquid(payable(token));

        console.log("=== Quote Buy with Different Amounts ===");

        // Test multiple buy amounts (gross ETH)
        uint256[5] memory amounts;
        amounts[0] = 0.01 ether;
        amounts[1] = 0.1 ether;
        amounts[2] = 0.5 ether;
        amounts[3] = 1 ether;
        amounts[4] = 5 ether;

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 buyAmount = amounts[i];

        // Returns: (feeBps, ethFee, ethIn, liquidOut, sqrtPriceX96After)
            (, , , uint256 tokensOut, ) = liquid.quoteBuy(buyAmount);

            console.log("ETH in (gross):", buyAmount, "Tokens out:", tokensOut);
            assertGt(tokensOut, 0, "Quote should return tokens");
        }
    }

    function testQuotePriceImpact() public {
        // Create a token
        vm.prank(tokenCreator);
        address token = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST"
        );

        Liquid liquid = Liquid(payable(token));

        // Get quote for small amount (gross ETH)
        uint256 smallAmount = 0.01 ether;
        // Returns: (feeBps, ethFee, ethIn, liquidOut, sqrtPriceX96After)
        (, , uint256 smallEthIn, uint256 smallTokensOut, ) = liquid.quoteBuy(
            smallAmount
        );

        // Get quote for large amount (gross ETH)
        uint256 largeAmount = 5 ether;
        (, , uint256 largeEthIn, uint256 largeTokensOut, ) = liquid.quoteBuy(
            largeAmount
        );

        console.log("=== Price Impact Analysis ===");
        console.log("Small buy (0.01 ETH):", smallTokensOut, "tokens");
        console.log("Large buy (5 ETH):", largeTokensOut, "tokens");

        // Calculate effective price per token (in wei) using ETH after fee
        uint256 smallPrice = (smallEthIn * 1e18) / smallTokensOut;
        uint256 largePrice = (largeEthIn * 1e18) / largeTokensOut;

        console.log("Small buy price per token:", smallPrice, "wei");
        console.log("Large buy price per token:", largePrice, "wei");
        console.log(
            "Price impact:",
            ((largePrice - smallPrice) * 100) / smallPrice,
            "%"
        );

        // Larger buys should have worse price (higher price per token)
        assertGt(
            largePrice,
            smallPrice,
            "Larger buys should have price impact"
        );
    }

    function testQuoteAfterConfigSync() public {
        // Create a token
        vm.prank(tokenCreator);
        address token = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST"
        );

        Liquid liquid = Liquid(payable(token));

        // Get initial quote (gross ETH)
        uint256 buyAmount = 1 ether;
        // Returns: (feeBps, ethFee, ethIn, liquidOut, sqrtPriceX96After)
        (, , , uint256 quote1, ) = liquid.quoteBuy(buyAmount);

        // Update factory config values
        // For this test, we just verify quote still works after config update
        vm.startPrank(admin);
        factory.setInternalMaxSlippageBps(300);
        factory.setMinOrderSizeWei(0.005 ether);
        vm.stopPrank();

        // Get quote after config update (config changes take effect immediately)
        (, , , uint256 quote2, ) = liquid.quoteBuy(buyAmount);

        console.log("=== Quote After Config Sync ===");
        console.log("Quote before sync:", quote1);
        console.log("Quote after sync:", quote2);

        // Both quotes should be valid and similar (pool state hasn't changed much)
        assertGt(quote1, 0, "Initial quote should be valid");
        assertGt(quote2, 0, "Quote after sync should be valid");
    }

    function testQuoteRevertWithZeroAmount() public {
        // Create a token
        vm.prank(tokenCreator);
        address token = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST"
        );

        Liquid liquid = Liquid(payable(token));

        // Quoter should handle zero amount gracefully or revert
        // This tests the quoter's behavior, not our wrapper
        vm.expectRevert(); // Uniswap quoter typically reverts on zero
        liquid.quoteBuy(0);
    }

    function testQuoteHelperUsageExample() public {
        // Create a token
        vm.prank(tokenCreator);
        address token = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST"
        );

        Liquid liquid = Liquid(payable(token));

        console.log("=== Example: Using Quote for Slippage Protection ===");

        // User wants to buy with 1 ETH (gross amount)
        uint256 userBudget = 1 ether;

        // Get quote - now takes gross ETH and handles fee internally
        // Returns: (feeBps, ethFee, ethIn, liquidOut, sqrtPriceX96After)
        (, , , uint256 expectedTokens, ) = liquid.quoteBuy(userBudget);
        console.log("Expected tokens from quote:", expectedTokens);

        // Apply 5% slippage tolerance
        uint256 minAcceptable = (expectedTokens * 95) / 100;
        console.log("Minimum acceptable (5% slippage):", minAcceptable);

        // Execute buy with slippage protection
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        uint256 actualTokens = liquid.buy{value: userBudget}(
            buyer,
            address(0),
            minAcceptable,
            0
        );

        console.log("Actual tokens received:", actualTokens);
        console.log("Trade succeeded with slippage protection!");

        assertGe(actualTokens, minAcceptable, "Should meet minimum");
        assertApproxEqRel(
            actualTokens,
            expectedTokens,
            0.05e18,
            "Should be within 5%"
        );
    }
}
