// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {MockBurner} from "liquid-editions-test/helpers/MockBurner.sol";
import {LiquidPoolSwapHelper} from "liquid-editions-test/helpers/LiquidPoolSwapHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";

contract LiquidInstantBaseMainnetTest is Test, InitGuardTestHelper {
    using StateLibrary for IPoolManager;
    // Network configuration
    NetworkConfig.Config internal config;

    // Helper function to compute correct PoolId from parameters
    function _computePoolId(address rareToken, uint24 fee, int24 tickSpacing, address hooks)
        internal
        pure
        returns (bytes32)
    {
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
    LiquidMultiCurve public liquidImplementation;
    LiquidFactory public factory;
    MockRARE public mockRARE;
    LiquidPoolSwapHelper public swapHelper;

    function _defaultSingleCurve() internal pure returns (Curve[] memory) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({tickLower: -180, tickUpper: 120000, numPositions: 1, shares: 1e18});
        return curves;
    }

    function setUp() public {
        // Fork Base mainnet for contract address verification
        string memory forkUrl = ForkUrlResolver.requireForkUrl(vm);
        vm.createSelectFork(forkUrl);

        // Get network configuration (Base mainnet chain ID = 8453)
        config = NetworkConfig.getConfig(block.chainid);

        // Fund test accounts
        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(protocolFeeRecipient, 100 ether);

        // Deploy MockRARE and fund accounts
        mockRARE = new MockRARE();
        mockRARE.mint(admin, 10_000_000 ether);
        mockRARE.mint(tokenCreator, 10_000_000 ether);

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

        liquidImplementation = new LiquidMultiCurve();
        address initGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        factory = new LiquidFactory(admin, config.uniswapV4PoolManager, initGuardAddr, 60);
        LiquidGuard(initGuardAddr).setFactory(address(factory));

        factory.setLiquidRegistry(address(1));

        // Set the implementation in the factory
        factory.setLiquidMultiCurveImplementation(address(liquidImplementation));

        // Set base token (RARE) in factory
        factory.setBaseToken(address(mockRARE));

        swapHelper = new LiquidPoolSwapHelper(IPoolManager(config.uniswapV4PoolManager));

        vm.stopPrank();
    }

    function testBaseMainnetContractAddresses() public view {
        // Verify all Base mainnet contract addresses exist and have code
        console.log("=== BASE MAINNET CONTRACT VERIFICATION ===");
        console.log("WETH address:", config.weth);
        console.log("WETH code size:", config.weth.code.length);
        assertTrue(config.weth.code.length > 0, "WETH should have code");
    }

    function testBaseMainnetFactoryRARELiquidityCreation() public {
        // Test to verify that the LiquidFactory properly uses RARE tokens to create initial liquidity on Base mainnet
        uint256 FACTORY_ETH_AMOUNT = 1 ether;

        address creator = makeAddr("baseCreator");
        vm.deal(creator, 100 ether);

        // Mint RARE tokens to creator
        mockRARE.mint(creator, 1000 ether);

        // Record creator's RARE balance before
        uint256 creatorRareBalanceBefore = mockRARE.balanceOf(creator);

        // Create token through factory with RARE
        vm.startPrank(creator);
        IERC20(mockRARE).approve(address(factory), FACTORY_ETH_AMOUNT);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            creator, "ipfs://base-test", "BASE_TEST", "BT", FACTORY_ETH_AMOUNT, _defaultSingleCurve()
        );
        vm.stopPrank();

        // Verify RARE was spent (all RARE goes to liquidity)
        LiquidMultiCurve baseLiquid = LiquidMultiCurve(payable(tokenAddress));
        assertEq(
            mockRARE.balanceOf(creator),
            creatorRareBalanceBefore - FACTORY_ETH_AMOUNT,
            "Creator should have spent all the RARE"
        );

        // Get the LiquidMultiCurve token instance

        // Verify token was created properly
        assertEq(baseLiquid.name(), "BASE_TEST");
        assertEq(baseLiquid.symbol(), "BT");
        assertEq(baseLiquid.tokenCreator(), creator);

        // Verify pool was created
        assertTrue(PoolId.unwrap(baseLiquid.poolId()) != bytes32(0), "Base mainnet factory should create pool");

        // Check pool initialization using V4 StateLibrary
        IPoolManager pm = IPoolManager(baseLiquid.poolManager());
        PoolId poolId = baseLiquid.poolId();
        (uint160 sqrtPriceX96,,,) = pm.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "Base mainnet pool should be initialized");

        // Check liquidity via multicurve position count (liquidity is split across ranges)
        uint256 positions = baseLiquid.storedPositionsLength();
        uint128 liquidity = pm.getLiquidity(poolId);

        // CRITICAL TEST: Check that liquidity exists
        assertTrue(positions > 0 || liquidity > 0, "Base mainnet LP position should have liquidity > 0");

        console.log("Pool positions:", positions);
        console.log("Pool's liquidity:", liquidity);

        // Verify creator got launch rewards
        uint256 creatorTokens = baseLiquid.balanceOf(creator);
        uint256 CREATOR_LAUNCH_REWARD = 100_000e18;
        assertEq(creatorTokens, CREATOR_LAUNCH_REWARD, "Creator should have only launch rewards");

        console.log("=== BASE MAINNET FACTORY RARE LIQUIDITY CREATION TEST ===");
        console.log("RARE sent to factory:", FACTORY_ETH_AMOUNT);
        console.log("Token address:", tokenAddress);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(baseLiquid.poolId()));
        console.log("Pool liquidity:", liquidity);
        console.log("Creator token balance:", creatorTokens);
        console.log("Launch reward:", CREATOR_LAUNCH_REWARD);
        console.log("Pool sqrt price:", sqrtPriceX96);
    }

    function testBaseMainnetMinimumETHLiquidity() public {
        // Test with minimum ETH amount on Base mainnet
        uint256 MIN_ETH_AMOUNT = 0.001 ether;

        address creator = makeAddr("baseMinCreator");
        vm.deal(creator, 100 ether);

        // Mint RARE tokens to creator
        mockRARE.mint(creator, 1000 ether);

        // Create token with minimum RARE
        vm.startPrank(creator);
        IERC20(mockRARE).approve(address(factory), MIN_ETH_AMOUNT);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            creator, "ipfs://base-min-test", "BASE_MIN", "BM", MIN_ETH_AMOUNT, _defaultSingleCurve()
        );
        vm.stopPrank();

        // Get the LiquidMultiCurve token instance
        LiquidMultiCurve baseLiquid = LiquidMultiCurve(payable(tokenAddress));

        // Verify pool was created
        assertTrue(
            PoolId.unwrap(baseLiquid.poolId()) != bytes32(0), "Base mainnet should create pool with minimum RARE"
        );

        // Check pool initialization using V4 StateLibrary
        IPoolManager pm = IPoolManager(baseLiquid.poolManager());
        PoolId poolId = baseLiquid.poolId();
        (uint160 sqrtPriceX96,,,) = pm.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "Base mainnet pool should be initialized with minimum RARE");

        // Check liquidity via multicurve position count (liquidity is split across ranges)
        uint256 positions = baseLiquid.storedPositionsLength();
        uint128 liquidity = pm.getLiquidity(poolId);

        // Main assertion - even with minimum RARE on Base mainnet, there should be liquidity
        assertTrue(
            positions > 0 || liquidity > 0, "Base mainnet LP position should have liquidity > 0 even with minimum RARE"
        );

        console.log("=== BASE MAINNET MINIMUM ETH TEST ===");
        console.log("ETH amount used:", MIN_ETH_AMOUNT);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(baseLiquid.poolId()));
        console.log("Pool liquidity:", liquidity);
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
        bytes32 poolId = _computePoolId(config.rareToken, poolFee, tickSpacing, hooks);

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
        address rareToken = testBurner.RARE_TOKEN();
        address v4PoolManager = testBurner.V4_POOL_MANAGER();
        address v4Hooks = testBurner.V4_HOOKS();
        address storedBurnAddress = testBurner.burnAddress();
        bytes32 v4PoolId = testBurner.V4_POOL_ID();
        uint24 v4PoolFee = testBurner.V4_POOL_FEE();
        int24 v4TickSpacing = testBurner.V4_TICK_SPACING();
        uint16 maxSlippageBPS = testBurner.maxSlippageBPS();
        bool enabled = testBurner.enabled();

        assertEq(rareToken, config.rareToken, "RARE token address should match");
        assertTrue(enabled, "RARE burn should be enabled");
        assertEq(maxSlippageBPS, 0, "Max slippage should be 0% (no quoter)");
        assertEq(v4PoolManager, config.uniswapV4PoolManager, "V4 PoolManager should match");
        // Note: v4PoolId will be the COMPUTED value, not necessarily the hardcoded constant
        bytes32 expectedPoolId = _computePoolId(config.rareToken, 3000, 60, address(0));
        assertEq(v4PoolId, expectedPoolId, "V4 pool ID should match computed value");
        assertEq(v4PoolFee, 3000, "Pool fee should be 0.3%");
        assertEq(v4TickSpacing, 60, "Tick spacing should be 60");
        assertEq(v4Hooks, address(0), "No hooks should be configured");
        assertEq(storedBurnAddress, 0x000000000000000000000000000000000000dEaD, "Burn address should be 0xdEaD");

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
        console.log("IMPORTANT: If the V4 pool uses NATIVE ETH instead of WETH:");
        console.log("- V4 represents native ETH as Currency.wrap(address(0))");
        console.log("- Our implementation uses WETH:", config.weth);
        console.log("- This could cause PoolNotInitialized if pool expects native ETH");
    }

    function testBaseMainnetTokenWithRAREBurn() public {
        console.log("=== BASE MAINNET TOKEN WITH RARE BURN TEST ===");

        // Create a token FIRST (before enabling RARE burn) to ensure initialization succeeds
        address creator = makeAddr("baseRARECreator");
        vm.deal(creator, 100 ether);

        // Mint RARE tokens to creator
        mockRARE.mint(creator, 1000 ether);

        vm.startPrank(creator);
        IERC20(mockRARE).approve(address(factory), 1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            creator, "ipfs://base-rare-test", "BASE_RARE", "BR", 1 ether, _defaultSingleCurve()
        );
        vm.stopPrank();

        LiquidMultiCurve baseLiquid = LiquidMultiCurve(payable(tokenAddress));

        // Verify token was created successfully
        assertEq(baseLiquid.tokenCreator(), creator);
        assertTrue(PoolId.unwrap(baseLiquid.poolId()) != bytes32(0));

        console.log("Token created:", tokenAddress);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(baseLiquid.poolId()));
        console.log("Token creator:", creator);

        // Configure RARE burn (separate from token - used by LiquidRouter)
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);

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

        // Token created with RARE burn config; trading now via LiquidRouter
        (uint256 quoteOut,) = baseLiquid.quoteBuy(0.5 ether);
        assertGt(quoteOut, 0, "Quote should work for created token");
    }

    // ============================================
    // QUOTER TESTS
    // ============================================

    function testQuoteBuyBasic() public {
        // Create a token with initial liquidity
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address token = factory.createLiquidTokenMultiCurve(
            tokenCreator, "ipfs://test", "Test Token", "TEST", 0.1 ether, _defaultSingleCurve()
        );
        vm.stopPrank();

        LiquidMultiCurve liquid = LiquidMultiCurve(payable(token));

        // Pass gross ETH amount (function handles fee calculation internally)
        uint256 buyAmount = 1 ether;

        // Get quote - now takes gross ETH and returns fee details
        (uint256 liquidOut, uint160 sqrtPriceX96After) = liquid.quoteBuy(buyAmount);

        console.log("=== Quote Buy Test ===");
        console.log("RARE in:", buyAmount);
        console.log("Tokens out (quoted):", liquidOut);
        console.log("Sqrt price after:", sqrtPriceX96After);

        // Verify quote is reasonable
        assertGt(liquidOut, 0, "Quote should return non-zero tokens");
        assertGt(sqrtPriceX96After, 0, "Sqrt price should be non-zero");
    }

    function testQuoteBuyMatchesActualTrade() public {
        // Create a token with initial liquidity
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator, "ipfs://test", "Test Token", "TEST", 0.1 ether, _defaultSingleCurve()
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));

        uint256 rareIn = 1 ether;
        (uint256 quotedOut,) = token.quoteBuy(rareIn);

        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(swapHelper), rareIn);
        uint256 actualOut = swapHelper.buy(tokenAddr, rareIn, tokenCreator);
        vm.stopPrank();

        uint256 tolerance = (actualOut / 100) + 1;
        assertApproxEqAbs(quotedOut, actualOut, tolerance, "Quote buy should match actual trade within tolerance");
    }

    function testQuoteSellMatchesActualTrade() public {
        // Create a token and buy some tokens
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator, "ipfs://test", "Test Token", "TEST", 0.1 ether, _defaultSingleCurve()
        );
        vm.stopPrank();

        uint256 buyAmount = 10 ether;
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(swapHelper), buyAmount);
        uint256 tokenAmount = swapHelper.buy(tokenAddr, buyAmount, tokenCreator);
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        uint256 sellAmount = tokenAmount / 2;

        (uint256 quotedRareOut,) = token.quoteSell(sellAmount);

        vm.startPrank(tokenCreator);
        token.approve(address(swapHelper), sellAmount);
        uint256 actualRareOut = swapHelper.sell(tokenAddr, sellAmount, tokenCreator);
        vm.stopPrank();

        uint256 tolerance = (actualRareOut / 100) + 1;
        assertApproxEqAbs(
            quotedRareOut, actualRareOut, tolerance, "Quote sell should match actual trade within tolerance"
        );
    }

    function testQuoteBuyAccuracyAfterConfigUpdate() public {
        // Create a token
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        factory.createLiquidTokenMultiCurve(
            tokenCreator, "ipfs://test", "Test Token", "TEST", 0.1 ether, _defaultSingleCurve()
        );
        vm.stopPrank();

        //     "Difference:",
        //     actualPayout > quotedPayout
        //         ? actualPayout - quotedPayout
        //         : quotedPayout - actualPayout
        // );

        // Allow small difference due to LP fees and pool state changes
        // uint256 tolerance = quotedPayout / 100; // 1% tolerance
        // assertApproxEqAbs(
        //     actualPayout,
        //     quotedPayout,
        //     tolerance,
        //     "Actual payout should match quote within tolerance"
        // );
    }

    function testQuoteWithDifferentAmounts() public {
        // Create a token
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address token = factory.createLiquidTokenMultiCurve(
            tokenCreator, "ipfs://test", "Test Token", "TEST", 0.1 ether, _defaultSingleCurve()
        );
        vm.stopPrank();

        LiquidMultiCurve liquid = LiquidMultiCurve(payable(token));

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

            // Returns: (liquidOut, sqrtPriceX96After)
            (uint256 tokensOut,) = liquid.quoteBuy(buyAmount);

            console.log("ETH in (gross):", buyAmount, "Tokens out:", tokensOut);
            assertGt(tokensOut, 0, "Quote should return tokens");
        }
    }

    function testQuotePriceImpact() public {
        // Create a token
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address token = factory.createLiquidTokenMultiCurve(
            tokenCreator, "ipfs://test", "Test Token", "TEST", 0.1 ether, _defaultSingleCurve()
        );
        vm.stopPrank();

        LiquidMultiCurve liquid = LiquidMultiCurve(payable(token));

        // Get quote for small amount (gross ETH)
        uint256 smallAmount = 0.01 ether;
        // Returns: (liquidOut, sqrtPriceX96After)
        (uint256 smallTokensOut,) = liquid.quoteBuy(smallAmount);

        // Get quote for large amount (gross RARE)
        uint256 largeAmount = 5 ether;
        (uint256 largeTokensOut,) = liquid.quoteBuy(largeAmount);

        console.log("=== Price Impact Analysis ===");
        console.log("Small buy (0.01 ETH):", smallTokensOut, "tokens");
        console.log("Large buy (5 ETH):", largeTokensOut, "tokens");

        // Calculate effective price per token (in wei) using ETH after fee
        // Calculate effective prices (RARE per token)
        uint256 smallPrice = (smallAmount * 1e18) / smallTokensOut;
        uint256 largePrice = (largeAmount * 1e18) / largeTokensOut;

        console.log("Small buy price per token:", smallPrice, "wei");
        console.log("Large buy price per token:", largePrice, "wei");
        console.log("Price impact:", ((largePrice - smallPrice) * 100) / smallPrice, "%");

        // Larger buys should have worse price (higher price per token)
        assertGt(largePrice, smallPrice, "Larger buys should have price impact");
    }

    function testQuoteRevertWithZeroAmount() public {
        // Create a token
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address token = factory.createLiquidTokenMultiCurve(
            tokenCreator, "ipfs://test", "Test Token", "TEST", 0.1 ether, _defaultSingleCurve()
        );
        vm.stopPrank();

        LiquidMultiCurve liquid = LiquidMultiCurve(payable(token));

        // Quoter should handle zero amount gracefully or revert
        // This tests the quoter's behavior, not our wrapper
        vm.expectRevert(); // Uniswap quoter typically reverts on zero
        liquid.quoteBuy(0);
    }
}
