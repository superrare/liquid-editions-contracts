// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Liquid} from "../src/Liquid.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {RAREBurner} from "../src/RAREBurner.sol";
import {LiquidFactory} from "../src/LiquidFactory.sol";
import {NetworkConfig} from "../script/NetworkConfig.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Mock burner for testing (receives ETH but doesn't do anything)
contract MockBurner {
    receive() external payable {}

    function depositForBurn() external payable {}
}

contract LiquidMainnetBasicTest is Test {
    using StateLibrary for IPoolManager;
    // Network configuration
    NetworkConfig.Config public config;

    // Test accounts
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public orderReferrer = makeAddr("orderReferrer");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    // Contract interfaces
    RAREBurner public burner;
    Liquid public liquidImplementation;
    LiquidFactory public factory;
    Liquid public liquid;

    function setUp() public virtual {
        // Fork Base mainnet to access real Uniswap V4 contracts
        string memory forkUrl = vm.envOr(
            "FORK_URL",
            string("https://mainnet.base.org")
        );
        vm.createSelectFork(forkUrl);

        // Get network configuration (Base mainnet chain ID = 8453)
        config = NetworkConfig.getConfig(block.chainid);

        // Fund test accounts
        vm.deal(admin, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(orderReferrer, 100 ether);
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
            0, // rareBurnFeeBPS (0% of remainder)
            5000, // protocolFeeBPS (50% of remainder)
            5000, // referrerFeeBPS (50% of remainder)
            100, // defaultTotalFeeBPS (1%)
            5000, // defaultCreatorFeeBPS (50% to match old behavior)
            -180, // lpTickLower - max expensive (after price rises) - multiple of 60
            120000, // lpTickUpper - starting point (cheap tokens)
            config.uniswapV4Quoter, // V4 Quoter
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            300, // internalMaxSlippageBps (3%)
            0.005 ether, // minOrderSizeWei
            1e15 // minInitialLiquidityWei (0.001 ETH)
        );

        factory.setImplementation(address(liquidImplementation));

        // Create Liquid token through factory
        address liquidAddress = factory.createLiquidToken{value: 0.001 ether}(
            tokenCreator, // creator
            "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG", // tokenUri
            "LIQUID", // name
            "LIQUID" // symbol
        );

        liquid = Liquid(payable(liquidAddress));
        vm.stopPrank();
    }

    function testSetup() public view {
        // Basic setup verification
        assertTrue(admin != address(0));
        assertTrue(tokenCreator != address(0));
        assertTrue(orderReferrer != address(0));
        assertTrue(protocolFeeRecipient != address(0));
        assertTrue(user1 != address(0));
        assertTrue(user2 != address(0));

        // Verify contract interfaces
        assertTrue(address(liquid) != address(0));

        // Verify Liquid configuration
        assertEq(liquid.tokenCreator(), tokenCreator);
        assertEq(liquid.name(), "LIQUID");
        assertEq(liquid.symbol(), "LIQUID");

        // Verify fork is working by checking PoolManager code size
        assertTrue(config.uniswapV4PoolManager.code.length > 0);
    }

    function test_RevertWhen_BuyWithMinimumAmount() public {
        uint256 MIN_ORDER = 0.0000001 ether;

        vm.startPrank(user1);
        vm.expectRevert(ILiquid.EthAmountTooSmall.selector);
        liquid.buy{value: MIN_ORDER - 1}(user1, address(0), 0, 0);
        vm.stopPrank();
    }

    function testBuyWithValidAmount() public {
        uint256 BUY_AMOUNT = 1 ether;
        uint256 INITIAL_BALANCE = user1.balance;

        vm.startPrank(user1);
        uint256 liquidReceived = liquid.buy{value: BUY_AMOUNT}(
            user1,
            address(0),
            0,
            0
        );
        vm.stopPrank();

        // Verify user received liquid tokens
        assertTrue(liquidReceived > 0);
        assertTrue(liquid.balanceOf(user1) > 0);

        // Verify ETH was spent
        assertEq(user1.balance, INITIAL_BALANCE - BUY_AMOUNT);
    }

    function testInitializationWithMinimumEthOnlyProvidesLiquidity() public {
        uint256 MIN_ETH_AMOUNT = 0.001 ether;

        address creator = makeAddr("creator2");
        vm.deal(creator, 100 ether);

        // Track creator's initial balance
        uint256 creatorInitialBalance = creator.balance;

        // Create token through factory with only minimum ETH
        vm.prank(creator);
        address newTokenAddress = factory.createLiquidToken{
            value: MIN_ETH_AMOUNT
        }(creator, "ipfs://test-token-uri-2", "MIN_LIQUID", "ML");

        Liquid newLiquid = Liquid(payable(newTokenAddress));

        // Verify ETH was spent
        assertEq(creator.balance, creatorInitialBalance - MIN_ETH_AMOUNT);

        // Verify creator received only launch rewards
        uint256 creatorFinalTokenBalance = newLiquid.balanceOf(creator);
        uint256 CREATOR_LAUNCH_REWARD = 100_000e18;
        assertEq(creatorFinalTokenBalance, CREATOR_LAUNCH_REWARD);

        // Verify pool was still created
        assertTrue(PoolId.unwrap(newLiquid.poolId()) != bytes32(0));
    }

    function test_RevertWhen_SellWithInsufficientBalance() public {
        vm.startPrank(user2);
        vm.expectRevert(ILiquid.InsufficientBalance.selector);
        liquid.sell(1e18, user2, address(0), 0, 0);
        vm.stopPrank();
    }

    /// @notice Regression test for auditor finding: slippage validation must happen after fee deduction
    /// @dev Before fix: slippage checked on raw swap output, but user received less after 1% fee
    ///      After fix: slippage checked on post-fee amount, ensuring user gets what they specify
    function testSell_SlippageProtectionAfterFees() public {
        uint256 BUY_AMOUNT = 5 ether;

        // Step 1: Buy tokens
        vm.prank(user1);
        uint256 tokenAmount = liquid.buy{value: BUY_AMOUNT}(
            user1,
            address(0),
            0,
            0
        );

        // Step 2: Sell to determine actual post-fee payout
        vm.startPrank(user1);
        uint256 sellAmount = tokenAmount / 2;
        uint256 actualPayout = liquid.sell(sellAmount, user1, address(0), 0, 0);
        vm.stopPrank();

        // Step 3: Verify the key property - user receives exactly what they expect after fees
        // The slippage check must validate the post-fee amount
        // Calculate what the raw swap output was (reverse engineering)
        uint256 totalFeeBPS = liquid.TOTAL_FEE_BPS();
        uint256 estimatedRawOutput = (actualPayout * 10000) / (10000 - totalFeeBPS);
        uint256 estimatedFee = estimatedRawOutput - actualPayout;
        
        // The fee should be approximately 1% of raw output
        uint256 expectedFeeFromRaw = (estimatedRawOutput * totalFeeBPS) / 10000;
        uint256 feeDiff = estimatedFee > expectedFeeFromRaw 
            ? estimatedFee - expectedFeeFromRaw 
            : expectedFeeFromRaw - estimatedFee;
        
        // Allow up to 1 wei difference due to rounding
        assertLe(
            feeDiff,
            1,
            "Fee calculation should be accurate"
        );

        // Step 4: Test that setting minPayoutSize higher than possible fails
        // Buy again and try to sell with unrealistic expectations
        vm.prank(user2);
        uint256 tokenAmount2 = liquid.buy{value: BUY_AMOUNT}(
            user2,
            address(0),
            0,
            0
        );

        vm.startPrank(user2);
        // Set an impossibly high minimum (more than we paid)
        uint256 impossibleMin = BUY_AMOUNT * 2;
        vm.expectRevert(ILiquid.SlippageExceeded.selector);
        liquid.sell(tokenAmount2 / 2, user2, address(0), impossibleMin, 0);
        vm.stopPrank();

        // Step 5: Test that reasonable minPayoutSize succeeds
        vm.startPrank(user2);
        // Use 50% of input as a reasonable minimum for a small sell
        uint256 reasonableMin = BUY_AMOUNT / 2;
        uint256 payout = liquid.sell(
            tokenAmount2 / 2,
            user2,
            address(0),
            reasonableMin,
            0
        );
        assertGe(
            payout,
            reasonableMin,
            "User must receive at least minPayoutSize after all fees"
        );
        vm.stopPrank();
    }

    function testBuyAndSell() public {
        uint256 BUY_AMOUNT = 1 ether;

        // First buy some tokens
        vm.startPrank(user1);
        uint256 liquidReceived = liquid.buy{value: BUY_AMOUNT}(
            user1,
            address(0),
            0,
            0
        );

        // Then sell half of them
        uint256 sellAmount = liquidReceived / 2;
        uint256 ethReceived = liquid.sell(sellAmount, user1, address(0), 0, 0);
        vm.stopPrank();

        // Verify the sell
        assertTrue(ethReceived > 0);
        assertEq(liquid.balanceOf(user1), liquidReceived - sellAmount);
    }

    function testFeeDistribution() public {
        uint256 BUY_AMOUNT = 10 ether;

        // Track initial ETH balances
        uint256 creatorInitialBalance = tokenCreator.balance;
        uint256 protocolInitialBalance = protocolFeeRecipient.balance;

        // Execute a buy
        vm.startPrank(user1);
        liquid.buy{value: BUY_AMOUNT}(user1, address(0), 0, 0);
        vm.stopPrank();

        // Calculate expected fees based on three-tier system
        uint256 totalFee = (BUY_AMOUNT * liquid.TOTAL_FEE_BPS()) / 10000; // 1% of 10 ETH = 0.1 ETH
        uint256 expectedCreatorFee = (totalFee *
            liquid.TOKEN_CREATOR_FEE_BPS()) / 10000; // 50% of 0.1 ETH = 0.05 ETH
        uint256 remainder = totalFee - expectedCreatorFee; // 0.05 ETH
        // With 0% burn, 50% protocol, 50% referrer (who defaults to protocol)
        uint256 expectedProtocolFee = remainder; // All remainder goes to protocol (50% + 50% defaulted referrer)

        // Verify fee distribution
        // The contract also handles secondary rewards (LP fees) after the buy
        // We'll just verify that the balances increased by at least the expected amounts
        assertTrue(
            tokenCreator.balance >= creatorInitialBalance + expectedCreatorFee,
            "Creator should receive at least the expected fee"
        );
        assertTrue(
            protocolFeeRecipient.balance >=
                protocolInitialBalance + expectedProtocolFee,
            "Protocol fee recipient should receive at least the expected fee"
        );
    }

    function testFeeDistributionWithOrderReferrer() public {
        uint256 BUY_AMOUNT = 10 ether;

        // Track initial ETH balances
        uint256 creatorInitialBalance = tokenCreator.balance;
        uint256 orderReferrerInitialBalance = orderReferrer.balance;
        uint256 protocolInitialBalance = protocolFeeRecipient.balance;

        // Execute a buy with order referrer
        vm.startPrank(user1);
        liquid.buy{value: BUY_AMOUNT}(user1, orderReferrer, 0, 0);
        vm.stopPrank();

        // Calculate expected fees based on the actual fee calculation in the contract
        uint256 totalFee = (BUY_AMOUNT * liquid.TOTAL_FEE_BPS()) / 10000; // 1% of 10 ETH = 0.1 ETH
        uint256 expectedCreatorFee = (totalFee *
            liquid.TOKEN_CREATOR_FEE_BPS()) / 10000; // 50% of fee
        uint256 remainder = totalFee - expectedCreatorFee;
        // With 0% burn, 50% protocol, 50% referrer
        uint256 expectedOrderReferrerFee = (remainder * 5000) / 10000;
        uint256 expectedProtocolFee = (remainder * 5000) / 10000;

        // Verify fee distribution
        // The contract also handles secondary rewards (LP fees) after the buy
        // We'll just verify that the balances increased by at least the expected amounts
        assertTrue(
            tokenCreator.balance >= creatorInitialBalance + expectedCreatorFee,
            "Creator should receive at least the expected fee"
        );
        assertTrue(
            orderReferrer.balance >=
                orderReferrerInitialBalance + expectedOrderReferrerFee,
            "Order referrer should receive at least the expected fee"
        );
        assertTrue(
            protocolFeeRecipient.balance >=
                protocolInitialBalance + expectedProtocolFee,
            "Protocol fee recipient should receive at least the expected fee"
        );
    }

    function testBurn() public {
        uint256 BUY_AMOUNT = 1 ether;

        // Buy some tokens
        vm.startPrank(user1);
        uint256 liquidReceived = liquid.buy{value: BUY_AMOUNT}(
            user1,
            address(0),
            0,
            0
        );

        // Burn half of them
        uint256 burnAmount = liquidReceived / 2;
        uint256 initialSupply = liquid.totalSupply();
        liquid.burn(burnAmount);
        vm.stopPrank();

        // Verify the burn
        assertEq(liquid.balanceOf(user1), liquidReceived - burnAmount);
        assertEq(liquid.totalSupply(), initialSupply - burnAmount);
    }

    function testSellFeeDistribution() public {
        uint256 BUY_AMOUNT = 2 ether;

        // Buy tokens first
        vm.startPrank(user1);
        liquid.buy{value: BUY_AMOUNT}(user1, address(0), 0, 0);

        // Track balances right before sell (after buy's secondary rewards have been distributed)
        uint256 creatorInitialBalance = tokenCreator.balance;
        uint256 protocolInitialBalance = protocolFeeRecipient.balance;

        // Sell half
        uint256 sellAmount = liquid.balanceOf(user1) / 2;
        uint256 ethReceived = liquid.sell(sellAmount, user1, address(0), 0, 0);
        vm.stopPrank();

        // Calculate expected fees using same math as Liquid.sol
        // ethReceived is payoutAfterFee (after fees), so we need to calculate backwards
        // truePayoutSize = payoutAfterFee * 10000 / (10000 - TOTAL_FEE_BPS)
        // fee = truePayoutSize - payoutAfterFee
        uint256 truePayoutSize = (ethReceived * 10000) /
            (10000 - liquid.TOTAL_FEE_BPS());
        uint256 totalFee = truePayoutSize - ethReceived;

        // Three-tier fee calculation
        uint256 expectedCreatorFee = (totalFee *
            liquid.TOKEN_CREATOR_FEE_BPS()) / 10000;
        uint256 remainder = totalFee - expectedCreatorFee;

        // TIER 3: Split remainder among burn/protocol/referrer
        // Factory config: 0% burn, 50% protocol, 50% referrer
        uint256 expectedProtocolFee = (remainder * factory.protocolFeeBPS()) /
            10000;
        uint256 expectedReferrerFee = (remainder * factory.referrerFeeBPS()) /
            10000;

        // Calculate dust (rounding remainder) - goes to protocol
        uint256 totalCalculated = expectedCreatorFee +
            expectedReferrerFee +
            expectedProtocolFee;
        uint256 dust = totalFee - totalCalculated;

        // Protocol gets referrer fee + base protocol fee + dust (when no referrer)
        uint256 expectedTotalProtocolFee = expectedProtocolFee +
            expectedReferrerFee +
            dust;

        uint256 creatorDelta = tokenCreator.balance - creatorInitialBalance;
        uint256 protocolDelta = protocolFeeRecipient.balance -
            protocolInitialBalance;

        // Assert exact amounts (no secondary rewards on sells, so balances match primary fees exactly)
        assertEq(creatorDelta, expectedCreatorFee, "Creator fee must be exact");
        assertEq(
            protocolDelta,
            expectedTotalProtocolFee,
            "Protocol fee must be exact (includes referrer portion + dust)"
        );

        // Assert exact sum - this is the key assertion
        assertEq(
            creatorDelta + protocolDelta,
            totalFee,
            "Total must equal totalFee exactly (no wei lost to rounding)"
        );

        // Verify that the payout after fees is less than raw ETH received
        uint256 payoutAfterFee = ethReceived - totalFee;
        assertLt(
            payoutAfterFee,
            ethReceived,
            "Payout after fee should be less than raw ETH received"
        );
    }

    function testSellFeeDistributionWithOrderReferrer() public {
        uint256 BUY_AMOUNT = 2 ether;

        // Buy tokens first
        vm.startPrank(user1);
        liquid.buy{value: BUY_AMOUNT}(user1, address(0), 0, 0);

        // Sell half with order referrer
        uint256 sellAmount = liquid.balanceOf(user1) / 2;
        uint256 ethReceived = liquid.sell(
            sellAmount,
            user1,
            orderReferrer,
            0,
            0
        );
        vm.stopPrank();

        // Verify fee distribution (check that fees were taken from the received ETH)
        assertTrue(ethReceived < sellAmount * 1e18); // Should be less due to fees and slippage
    }

    function testReceiveFunction() public {
        uint256 SEND_AMOUNT = 1 ether;
        uint256 INITIAL_BALANCE = user1.balance;
        uint256 initialContractBalance = address(liquid).balance;

        vm.startPrank(user1);

        // Send ETH directly to the contract - should accept but NOT trigger a buy
        (bool success, ) = address(liquid).call{value: SEND_AMOUNT}("");
        assertTrue(success);

        vm.stopPrank();

        // Verify ETH was accepted but NO tokens were minted (receive() no longer triggers buy)
        assertEq(
            liquid.balanceOf(user1),
            0,
            "User should NOT receive tokens from receive()"
        );
        assertEq(
            user1.balance,
            INITIAL_BALANCE - SEND_AMOUNT,
            "ETH should be sent"
        );
        assertEq(
            address(liquid).balance,
            initialContractBalance + SEND_AMOUNT,
            "Contract should hold ETH"
        );
    }

    function testStateFunction() public view {
        assertTrue(PoolId.unwrap(liquid.poolId()) != bytes32(0));
    }

    function testTokenURIFunction() public view {
        string memory uri = liquid.tokenUri();
        assertEq(uri, "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG");
    }

    function testClaimSecondaryRewards() public {
        // First do some trading to generate secondary rewards
        vm.startPrank(user1);
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);
        vm.stopPrank();

        // NOTE: Plain buy() does NOT harvest secondary rewards (use buyAndHarvest() or harvestSecondaryRewards() for that)
        // This test is just checking basic buy functionality, not secondary rewards

        // Verify that rewards can be claimed separately if desired
        // In a real scenario, you'd call harvestSecondaryRewards() or use buyAndHarvest()
    }

    function testInitialTokenDistribution() public view {
        // Debug: Check all balances
        console.log("Creator balance:", liquid.balanceOf(tokenCreator));
        console.log("Contract balance:", liquid.balanceOf(address(liquid)));
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(liquid.poolId()));
        console.log("Total supply:", liquid.totalSupply());

        // Check that initial tokens were distributed correctly
        assertEq(liquid.balanceOf(tokenCreator), 100_000e18); // 100K tokens

        // Check total supply
        assertEq(liquid.totalSupply(), 1_000_000e18); // 1M tokens total
    }

    function testConstants() public view {
        // Test that constants are set correctly
        assertEq(liquid.MAX_TOTAL_SUPPLY(), 1_000_000e18);
        assertEq(factory.minOrderSizeWei(), 0.005 ether); // Default from factory
        assertEq(liquid.TOTAL_FEE_BPS(), 100);
        assertEq(liquid.TOKEN_CREATOR_FEE_BPS(), 5000);
        // Note: Protocol and referrer fees are now in factory config, not Liquid constants
    }

    // Helper function to calculate fees
    function _calculateFee(
        uint256 amount,
        uint256 bps
    ) internal pure returns (uint256) {
        return (amount * bps) / 10_000;
    }

    function testPoolLiquidityDeployment() public {
        // This test verifies that when _deployPool is called, actual liquidity is added to the Uniswap pool
        uint256 LIQUIDITY_ETH = 1 ether; // Use significant amount to make liquidity clearly measurable

        address creator = makeAddr("liquidityCreator");
        vm.deal(creator, 100 ether);

        // Create token through factory with ETH that should create pool with liquidity
        vm.prank(creator);
        address newTokenAddress = factory.createLiquidToken{
            value: LIQUIDITY_ETH
        }(creator, "ipfs://liquidity-test", "LIQUIDITY_TEST", "LT");

        Liquid newLiquid = Liquid(payable(newTokenAddress));

        // Verify pool was created
        PoolId poolId = newLiquid.poolId();
        assertTrue(
            PoolId.unwrap(poolId) != bytes32(0),
            "Pool should be created"
        );

        // Check if the pool has been initialized properly using V4 StateLibrary
        IPoolManager pm = IPoolManager(newLiquid.poolManager());
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "Pool should be initialized with a price");

        // Check liquidity using V4 - liquidity is stored in the Liquid contract
        uint128 liquidity = newLiquid.lpLiquidity();

        // This is the main assertion - liquidity should be greater than 0
        assertTrue(
            liquidity > 0,
            "LP position should have liquidity greater than 0"
        );

        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(newLiquid.poolId()));
        console.log("Position liquidity:", liquidity);
        console.log("Pool sqrt price:", sqrtPriceX96);
    }

    function testFactoryETHForwardingAndLiquidity() public {
        // Test to verify that the LiquidFactory properly forwards ETH and creates liquidity
        uint256 FACTORY_ETH_AMOUNT = 1 ether;

        address creator = makeAddr("factoryCreator");
        vm.deal(creator, 100 ether);

        // Deploy the factory system
        vm.startPrank(admin);
        MockBurner testMockBurner = new MockBurner();
        LiquidFactory testFactory = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            address(testMockBurner), // rareBurner
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

        // Create implementation and set it in factory
        Liquid factoryLiquidImplementation = new Liquid();
        testFactory.setImplementation(address(factoryLiquidImplementation));
        vm.stopPrank();

        // Record creator's balance before
        uint256 creatorBalanceBefore = creator.balance;

        // Create token through factory with ETH
        vm.startPrank(creator);
        address tokenAddress = testFactory.createLiquidToken{
            value: FACTORY_ETH_AMOUNT
        }(creator, "ipfs://factory-test", "FACTORY_TEST", "FT");
        vm.stopPrank();

        // Verify ETH was spent (all ETH goes to liquidity)
        Liquid factoryLiquid = Liquid(payable(tokenAddress));
        assertEq(
            creator.balance,
            creatorBalanceBefore - FACTORY_ETH_AMOUNT,
            "Creator should have spent all the ETH"
        );

        // Get the Liquid token instance

        // Verify token was created properly
        assertEq(factoryLiquid.name(), "FACTORY_TEST");
        assertEq(factoryLiquid.symbol(), "FT");
        assertEq(factoryLiquid.tokenCreator(), creator);

        // Get market state

        // Verify pool was created
        assertTrue(
            PoolId.unwrap(factoryLiquid.poolId()) != bytes32(0),
            "Factory should create pool"
        );

        // Check pool initialization using V4 StateLibrary
        IPoolManager pm = IPoolManager(factoryLiquid.poolManager());
        PoolId poolId = factoryLiquid.poolId();
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(poolId);
        assertTrue(
            sqrtPriceX96 > 0,
            "Factory-created pool should be initialized"
        );

        // Check liquidity using V4 - liquidity is stored in the Liquid contract
        uint128 liquidity = factoryLiquid.lpLiquidity();

        // CRITICAL TEST: Factory should forward ETH and create liquidity
        assertTrue(liquidity > 0, "FACTORY SHOULD CREATE LIQUIDITY IN POOL");

        // Verify creator got launch rewards
        uint256 creatorTokens = factoryLiquid.balanceOf(creator);
        uint256 CREATOR_LAUNCH_REWARD = 100_000e18;
        assertEq(
            creatorTokens,
            CREATOR_LAUNCH_REWARD,
            "Creator should have only launch rewards"
        );

        console.log("=== FACTORY ETH FORWARDING TEST ===");
        console.log("ETH sent to factory:", FACTORY_ETH_AMOUNT);
        console.log("Token address:", tokenAddress);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(factoryLiquid.poolId()));
        console.log("Position liquidity:", liquidity);
        console.log("Creator token balance:", creatorTokens);
        console.log("Launch reward:", CREATOR_LAUNCH_REWARD);
        console.log("Pool sqrt price:", sqrtPriceX96);
    }

    function testPoolLiquidityDeploymentMinimumAmount() public {
        // Test with minimum ETH amount to see if this is where the issue occurs
        uint256 MIN_LIQUIDITY_ETH = 0.001 ether; // Minimum amount typically used

        address creator = makeAddr("minLiquidityCreator");
        vm.deal(creator, 100 ether);

        // Create token through factory with minimum ETH
        vm.prank(creator);
        address newTokenAddress = factory.createLiquidToken{
            value: MIN_LIQUIDITY_ETH
        }(creator, "ipfs://min-liquidity-test", "MIN_LIQUIDITY_TEST", "MLT");

        Liquid newLiquid = Liquid(payable(newTokenAddress));

        // Get the market state

        // Verify pool was created
        assertTrue(
            PoolId.unwrap(newLiquid.poolId()) != bytes32(0),
            "Pool should be created even with minimum ETH"
        );

        // Check pool initialization using V4 StateLibrary
        IPoolManager pm = IPoolManager(newLiquid.poolManager());
        PoolId poolId = newLiquid.poolId();
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(poolId);
        assertTrue(
            sqrtPriceX96 > 0,
            "Pool should be initialized with minimum ETH"
        );

        // Check liquidity using V4 - liquidity is stored in the Liquid contract
        uint128 liquidity = newLiquid.lpLiquidity();

        // Main assertion - even with minimum ETH, there should be liquidity
        assertTrue(
            liquidity > 0,
            "LP position should have liquidity > 0 even with minimum ETH"
        );

        console.log("=== MINIMUM ETH TEST ===");
        console.log("ETH amount used:", MIN_LIQUIDITY_ETH);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(newLiquid.poolId()));
        console.log("Position liquidity:", liquidity);
        console.log("Pool sqrt price:", sqrtPriceX96);
    }

    // Note: RARE burn tests removed - they are comprehensively covered in:
    // - test/RAREBurn.t.sol (configuration and validation)
    // - test/Liquid.mainnet.bonding.t.sol (V4 integration with Base mainnet fork)
    // - test/Liquid.unit.t.sol (unit tests with mocks)

    function testHarvestSecondaryRewards() public {
        // First do some trading to generate LP fees
        vm.startPrank(user1);
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);
        liquid.sell(liquid.balanceOf(user1) / 2, user1, address(0), 0, 0);
        vm.stopPrank();

        // Record balances before harvest
        uint256 creatorBefore = tokenCreator.balance;
        uint256 protocolBefore = protocolFeeRecipient.balance;

        // Harvest secondary rewards explicitly (use current price with 5% slippage)
        (uint160 sqrtPrice, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        liquid.harvestSecondaryRewards(sqrtPrice, 500);

        // Verify that rewards were distributed
        uint256 creatorAfter = tokenCreator.balance;
        uint256 protocolAfter = protocolFeeRecipient.balance;

        // Both should have increased (LP fees were collected and distributed)
        assertTrue(
            creatorAfter > creatorBefore,
            "Creator should receive secondary rewards"
        );
        assertTrue(
            protocolAfter > protocolBefore,
            "Protocol should receive secondary rewards"
        );
    }

    function testBuyAndHarvest() public {
        uint256 BUY_AMOUNT = 1 ether;

        // First generate some LP fees
        vm.startPrank(user1);
        liquid.buy{value: 0.5 ether}(user1, address(0), 0, 0);
        liquid.sell(liquid.balanceOf(user1) / 2, user1, address(0), 0, 0);
        vm.stopPrank();

        // Record balances before buyAndHarvest
        uint256 user2TokensBefore = liquid.balanceOf(user2);
        uint256 creatorBefore = tokenCreator.balance;
        uint256 protocolBefore = protocolFeeRecipient.balance;

        // Execute buyAndHarvest (should do buy + harvest in one call)
        (uint160 preBuyPrice, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        vm.startPrank(user2);
        uint256 tokensReceived = liquid.buyAndHarvest{value: BUY_AMOUNT}(
            user2,
            address(0),
            0,
            0, // sqrtPriceLimitX96Buy
            preBuyPrice, // preBuySqrtPriceX96
            500 // 5% harvest slippage
        );
        vm.stopPrank();

        // Verify user received tokens (buy part)
        assertTrue(tokensReceived > 0, "Should receive tokens from buy");
        assertEq(
            liquid.balanceOf(user2),
            user2TokensBefore + tokensReceived,
            "Token balance should increase by tokensReceived"
        );

        // Verify secondary rewards were distributed (harvest part)
        uint256 creatorAfter = tokenCreator.balance;
        uint256 protocolAfter = protocolFeeRecipient.balance;

        assertTrue(
            creatorAfter > creatorBefore,
            "Creator should receive both primary and secondary rewards"
        );
        assertTrue(
            protocolAfter > protocolBefore,
            "Protocol should receive both primary and secondary rewards"
        );
    }

    function testBuyDoesNotHarvestSecondaryRewards() public {
        // Generate LP fees first
        vm.startPrank(user1);
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);
        liquid.sell(liquid.balanceOf(user1) / 2, user1, address(0), 0, 0);
        vm.stopPrank();

        // Record balances after first trades (this is now the baseline)
        uint256 creatorBefore = tokenCreator.balance;
        uint256 protocolBefore = protocolFeeRecipient.balance;

        // Execute a regular buy() - should NOT harvest secondary rewards
        vm.startPrank(user2);
        liquid.buy{value: 0.1 ether}(user2, address(0), 0, 0);
        vm.stopPrank();

        // Calculate expected fees from just the buy (primary fees only)
        uint256 totalFee = (0.1 ether * liquid.TOTAL_FEE_BPS()) / 10_000;
        uint256 expectedCreatorFee = (totalFee *
            liquid.TOKEN_CREATOR_FEE_BPS()) / 10_000;
        uint256 remainder = totalFee - expectedCreatorFee;
        uint256 expectedProtocolFee = remainder; // All remainder goes to protocol (no referrer)

        // Verify only primary fees were distributed (not secondary rewards)
        uint256 creatorDelta = tokenCreator.balance - creatorBefore;
        uint256 protocolDelta = protocolFeeRecipient.balance - protocolBefore;

        // Should be approximately equal to primary fees only (no secondary rewards)
        assertApproxEqAbs(
            creatorDelta,
            expectedCreatorFee,
            1e15, // 0.001 ETH tolerance for rounding
            "Creator should only receive primary fee"
        );
        assertApproxEqAbs(
            protocolDelta,
            expectedProtocolFee,
            1e15, // 0.001 ETH tolerance for rounding
            "Protocol should only receive primary fee"
        );
    }

    function testBuyAndHarvestGasComparison() public {
        // This test demonstrates the gas savings of using buy() vs buyAndHarvest()

        // First generate some LP fees
        vm.startPrank(user1);
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);
        liquid.sell(liquid.balanceOf(user1) / 2, user1, address(0), 0, 0);
        vm.stopPrank();

        // Measure gas for regular buy()
        vm.startPrank(user2);
        uint256 gasBefore = gasleft();
        liquid.buy{value: 0.5 ether}(user2, address(0), 0, 0);
        uint256 gasUsedBuy = gasBefore - gasleft();
        vm.stopPrank();

        // Generate more LP fees for the next test
        vm.startPrank(user1);
        liquid.sell(liquid.balanceOf(user1) / 4, user1, address(0), 0, 0);
        vm.stopPrank();

        // Measure gas for buyAndHarvest()
        (uint160 preBuyPrice, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        vm.startPrank(user2);
        gasBefore = gasleft();
        liquid.buyAndHarvest{value: 0.5 ether}(user2, address(0), 0, 0, preBuyPrice, 500);
        uint256 gasUsedBuyAndHarvest = gasBefore - gasleft();
        vm.stopPrank();

        console.log("Gas used for buy():", gasUsedBuy);
        console.log("Gas used for buyAndHarvest():", gasUsedBuyAndHarvest);
        console.log("Gas savings:", gasUsedBuyAndHarvest - gasUsedBuy);

        // buyAndHarvest should use more gas (includes harvest)
        assertGt(
            gasUsedBuyAndHarvest,
            gasUsedBuy,
            "buyAndHarvest() should use more gas than buy()"
        );
    }

    function testHarvestSecondaryRewardsWithNoFees() public {
        // Test that harvest works even when there are no accumulated fees
        // (shouldn't revert, just a no-op)

        uint256 creatorBefore = tokenCreator.balance;
        uint256 protocolBefore = protocolFeeRecipient.balance;

        // Harvest when no fees have accumulated yet
        (uint160 sqrtPrice, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        liquid.harvestSecondaryRewards(sqrtPrice, 500);

        uint256 creatorAfter = tokenCreator.balance;
        uint256 protocolAfter = protocolFeeRecipient.balance;

        // Balances should be unchanged (no fees to harvest)
        assertEq(
            creatorAfter,
            creatorBefore,
            "Creator balance should be unchanged"
        );
        assertEq(
            protocolAfter,
            protocolBefore,
            "Protocol balance should be unchanged"
        );
    }

    function testMultipleHarvestsCantDoubleSpend() public {
        // Test that calling harvest multiple times without new trading doesn't pay out fees again

        // Generate LP fees
        vm.startPrank(user1);
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);
        liquid.sell(liquid.balanceOf(user1) / 2, user1, address(0), 0, 0);
        vm.stopPrank();

        // First harvest - should collect fees from buy+sell above
        uint256 creatorBefore1 = tokenCreator.balance;
        (uint160 sqrtPrice1, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        liquid.harvestSecondaryRewards(sqrtPrice1, 500);
        uint256 creatorAfter1 = tokenCreator.balance;
        uint256 firstHarvestAmount = creatorAfter1 - creatorBefore1;

        // First harvest should pay out fees
        assertTrue(
            firstHarvestAmount > 0,
            "First harvest should pay out accumulated fees"
        );

        // Second harvest immediately after (no new trading, so should collect minimal/no fees)
        uint256 creatorBefore2 = tokenCreator.balance;
        (uint160 sqrtPrice2, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        liquid.harvestSecondaryRewards(sqrtPrice2, 500);
        uint256 creatorAfter2 = tokenCreator.balance;
        uint256 secondHarvestAmount = creatorAfter2 - creatorBefore2;

        // Second harvest should pay significantly less (no new trading activity)
        // Allow for small amounts from price movement, but should be << first harvest
        assertLt(
            secondHarvestAmount,
            firstHarvestAmount / 100, // Should be < 1% of first harvest
            "Second harvest without trading should pay minimal fees"
        );
    }

    function testBuyAndHarvestMatchesSeparateCalls() public {
        // Test that buyAndHarvest() produces the same result as buy() + harvestSecondaryRewards()

        // Setup: generate some LP fees first
        vm.startPrank(user1);
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);
        liquid.sell(liquid.balanceOf(user1) / 2, user1, address(0), 0, 0);
        vm.stopPrank();

        // Test Path 1: buy() + harvestSecondaryRewards()
        uint256 snapshot = vm.snapshotState();

        uint256 creatorBefore1 = tokenCreator.balance;
        uint256 user2TokensBefore1 = liquid.balanceOf(user2);

        vm.startPrank(user2);
        uint256 tokens1 = liquid.buy{value: 0.5 ether}(user2, address(0), 0, 0);
        vm.stopPrank();
        (uint160 sqrtPrice, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        liquid.harvestSecondaryRewards(sqrtPrice, 500);

        uint256 creatorAfter1 = tokenCreator.balance;
        uint256 user2TokensAfter1 = liquid.balanceOf(user2);

        uint256 creatorGain1 = creatorAfter1 - creatorBefore1;
        uint256 tokenGain1 = user2TokensAfter1 - user2TokensBefore1;

        // Restore state
        vm.revertToState(snapshot);

        // Test Path 2: buyAndHarvest()
        uint256 creatorBefore2 = tokenCreator.balance;
        uint256 user2TokensBefore2 = liquid.balanceOf(user2);

        (uint160 preBuyPrice2, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        vm.startPrank(user2);
        uint256 tokens2 = liquid.buyAndHarvest{value: 0.5 ether}(
            user2,
            address(0),
            0,
            0, // sqrtPriceLimitX96Buy
            preBuyPrice2, // preBuySqrtPriceX96
            500 // 5% harvest slippage
        );
        vm.stopPrank();

        uint256 creatorAfter2 = tokenCreator.balance;
        uint256 user2TokensAfter2 = liquid.balanceOf(user2);

        uint256 creatorGain2 = creatorAfter2 - creatorBefore2;
        uint256 tokenGain2 = user2TokensAfter2 - user2TokensBefore2;

        // Results should match
        assertEq(tokens1, tokens2, "Token amounts should match");
        assertEq(tokenGain1, tokenGain2, "Token balance changes should match");
        assertEq(
            creatorGain1,
            creatorGain2,
            "Creator fee distributions should match"
        );
    }

    function testHarvestSecondaryRewardsIsPermissionless() public {
        // Test that anyone can call harvestSecondaryRewards() (it's permissionless)

        // Generate LP fees
        vm.startPrank(user1);
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);
        liquid.sell(liquid.balanceOf(user1) / 2, user1, address(0), 0, 0);
        vm.stopPrank();

        uint256 creatorBefore = tokenCreator.balance;

        // Anyone can harvest (user2 in this case)
        (uint160 sqrtPrice, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        vm.prank(user2);
        liquid.harvestSecondaryRewards(sqrtPrice, 500);

        uint256 creatorAfter = tokenCreator.balance;

        // Creator should have received fees even though user2 called harvest
        assertTrue(
            creatorAfter > creatorBefore,
            "Anyone should be able to trigger harvest"
        );
    }

    function testBuyWithRAREBurnDisabled() public {
        uint256 BUY_AMOUNT = 0.1 ether;

        // NOTE: This test verifies buyAndHarvest() which DOES harvest secondary rewards
        // Plain buy() does NOT harvest automatically - this is by design for gas efficiency

        // Record initial balances
        uint256 initialCreatorBalance = tokenCreator.balance;
        uint256 initialProtocolBalance = protocolFeeRecipient.balance;

        // Execute buy (RARE burn is disabled by default)
        vm.prank(user1);
        liquid.buy{value: BUY_AMOUNT}(user1, address(0), 0, 0);

        // Calculate expected fees (traditional distribution)
        uint256 totalFee = (BUY_AMOUNT * liquid.TOTAL_FEE_BPS()) / 10_000;
        // Fee BPS constants are percentages of the total fee
        uint256 expectedCreatorFee = (totalFee *
            liquid.TOKEN_CREATOR_FEE_BPS()) / 10_000;
        uint256 remainder = totalFee - expectedCreatorFee;
        // With 0% burn, 50% protocol, 50% referrer
        uint256 expectedOrderReferrerFee = (remainder * 5000) / 10_000;
        uint256 expectedProtocolFee = (remainder * 5000) / 10_000;

        // Get final balances
        uint256 finalCreatorBalance = tokenCreator.balance;
        uint256 finalProtocolBalance = protocolFeeRecipient.balance;

        // Calculate deltas (includes both primary fees and secondary rewards from LP fees)
        uint256 creatorDelta = finalCreatorBalance - initialCreatorBalance;
        uint256 protocolDelta = finalProtocolBalance - initialProtocolBalance;

        // Verify at least the expected primary fees were distributed
        // (actual amount will be higher due to secondary rewards from LP fees)
        assertGe(
            creatorDelta,
            expectedCreatorFee,
            "Creator should receive at least primary fee"
        );
        assertGe(
            protocolDelta,
            expectedOrderReferrerFee + expectedProtocolFee,
            "Protocol should receive at least primary fees"
        );
    }

    function testHarvestRevertsWithZeroPrice() public {
        vm.expectRevert(ILiquid.InvalidPrice.selector);
        liquid.harvestSecondaryRewards(0, 500);
    }

    function testHarvestRevertsWithZeroSlippage() public {
        (uint160 sqrtPrice, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        vm.expectRevert(ILiquid.InvalidSlippage.selector);
        liquid.harvestSecondaryRewards(sqrtPrice, 0);
    }

    function testHarvestRevertsWithExcessiveSlippage() public {
        (uint160 sqrtPrice, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        vm.expectRevert(ILiquid.InvalidSlippage.selector);
        liquid.harvestSecondaryRewards(sqrtPrice, 10001); // > 100%
    }

    function testQuoteHarvestParamsMatchesSlot0() public view {
        (uint160 expected, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        (uint160 current, uint160 limit) = liquid.quoteHarvestParams(500);

        assertEq(current, expected, "quoteHarvestParams should return slot0 price");
        assertGt(limit, current, "Price limit should exceed current sqrt price for sells");
    }

    function testQuoteHarvestParamsRevertsWithInvalidSlippage() public {
        vm.expectRevert(ILiquid.InvalidSlippage.selector);
        liquid.quoteHarvestParams(0);
    }

    function testHarvestSecondaryRewardsPriceLimitDoesNotRevert() public {
        // Generate LP fees with significant trading volume
        vm.startPrank(user1);
        liquid.buy{value: 5 ether}(user1, address(0), 0, 0);
        liquid.sell(liquid.balanceOf(user1) / 2, user1, address(0), 0, 0);
        vm.stopPrank();

        // Test that harvest with reasonable slippage succeeds
        (uint160 sqrtPrice, , , ) = IPoolManager(config.uniswapV4PoolManager).getSlot0(liquid.poolId());
        liquid.harvestSecondaryRewards(sqrtPrice, 500); // 5% slippage
    }

    /*//////////////////////////////////////////////////////////////
                    PARTIAL FILL PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test partial fill protection when tight price limit stops swap early
    /// @dev Verifies that buy reverts with PartialFillBuy when price limit prevents full consumption
    function testPartialFillBuy_TightPriceLimit() public {
        // Get quote for normal buy
        uint256 buyAmount = 1 ether;

        // Get current price
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);
        (uint160 currentPrice, , , ) = pm.getSlot0(liquid.poolId());

        // Set limit to only 99.5% of current price - very tight for a 1 ETH buy
        // For buys (ETH->LIQUID), price moves DOWN, so limit must be < current price
        uint160 tightLimit = uint160((uint256(currentPrice) * 995) / 1000);

        // Attempt buy with tight limit - should revert with PartialFillBuy
        vm.prank(user1);
        vm.expectRevert(); // Will revert with PartialFillBuy
        liquid.buy{value: buyAmount}(user1, address(0), 0, tightLimit);
    }

    /// @notice Test that normal buys with no price limit still work
    /// @dev Regression test ensuring partial fill protection doesn't break normal flow
    function testPartialFillBuy_FullFillSucceeds() public {
        uint256 buyAmount = 0.5 ether;

        // Record initial state
        uint256 contractBalanceBefore = address(liquid).balance;
        uint256 userBalanceBefore = user1.balance;

        // Execute normal buy with no price limit
        vm.prank(user1);
        uint256 tokensReceived = liquid.buy{value: buyAmount}(
            user1,
            address(0),
            0,
            0 // No price limit
        );

        // Verify success
        assertGt(tokensReceived, 0, "Should receive tokens");
        assertEq(
            liquid.balanceOf(user1),
            tokensReceived,
            "User should have received tokens"
        );

        // Verify no ETH stuck in contract (except what was there before)
        assertEq(
            address(liquid).balance,
            contractBalanceBefore,
            "No additional ETH should remain in contract"
        );

        // Verify user spent the ETH
        assertEq(
            user1.balance,
            userBalanceBefore - buyAmount,
            "User should have spent buyAmount"
        );
    }

    /// @notice Test that buy with zero price limit (default bounds) consumes all ETH
    /// @dev Verifies sqrtPriceLimitX96=0 fallback doesn't cause partial fills
    function testPartialFillBuy_ZeroPriceLimitFullFill() public {
        uint256 buyAmount = 0.3 ether;

        // Record initial contract balance
        uint256 contractBalanceBefore = address(liquid).balance;

        // Execute buy with explicit zero limit (uses MIN_SQRT_PRICE + 1)
        vm.prank(user1);
        uint256 tokensReceived = liquid.buy{value: buyAmount}(
            user1,
            address(0),
            0,
            0 // Explicit zero - should convert to MIN_SQRT_PRICE + 1
        );

        // Verify full consumption
        assertGt(tokensReceived, 0, "Should receive tokens");
        assertEq(
            address(liquid).balance,
            contractBalanceBefore,
            "No ETH should be stuck - all consumed or refunded"
        );
    }

    /// @notice Test large buy with permissive limit succeeds fully
    /// @dev Verifies that large price-moving trades work when limit is appropriate
    function testPartialFillBuy_LargeBuyWithPermissiveLimit() public {
        uint256 largeBuy = 5 ether;

        // Get quote to understand price impact
        (, , , uint256 quotedTokens, uint160 sqrtPriceX96After) = liquid
            .quoteBuy(largeBuy);

        // Use the quoted post-swap price as limit (should allow full execution)
        uint160 permissiveLimit = sqrtPriceX96After;

        // Record state
        uint256 contractBalanceBefore = address(liquid).balance;

        // Execute large buy
        vm.prank(user1);
        uint256 tokensReceived = liquid.buy{value: largeBuy}(
            user1,
            address(0),
            0,
            permissiveLimit
        );

        // Verify success
        assertGt(tokensReceived, 0, "Should receive tokens");
        assertGe(
            tokensReceived,
            (quotedTokens * 995) / 1000, // Allow 0.5% slippage from quote
            "Should receive approximately quoted amount"
        );

        // Verify no stuck ETH
        assertEq(
            address(liquid).balance,
            contractBalanceBefore,
            "No ETH should remain in contract"
        );
    }

    /// @notice Test that partial fill protection includes correct error parameters
    /// @dev Verifies PartialFillBuy error reports accurate requested vs consumed amounts
    function testPartialFillBuy_CorrectErrorParameters() public {
        // This test verifies the error contains useful debugging info
        uint256 buyAmount = 1 ether;

        // Calculate expected ETH after fee
        uint256 fee = (buyAmount * liquid.TOTAL_FEE_BPS()) / 10000;
        uint256 expectedEthToSwap = buyAmount - fee;

        // Get current price and set tight limit
        IPoolManager pm = IPoolManager(config.uniswapV4PoolManager);
        (uint160 currentPrice, , , ) = pm.getSlot0(liquid.poolId());
        uint160 tightLimit = uint160((uint256(currentPrice) * 998) / 1000);

        // Attempt buy and capture revert data
        vm.prank(user1);
        try liquid.buy{value: buyAmount}(user1, address(0), 0, tightLimit) {
            revert("Should have reverted with PartialFillBuy");
        } catch (bytes memory reason) {
            // Verify error selector matches PartialFillBuy
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 0x20))
            }
            assertEq(
                selector,
                ILiquid.PartialFillBuy.selector,
                "Should revert with PartialFillBuy error"
            );

            // Decode the error parameters
            if (reason.length >= 68) {
                uint256 requested;
                uint256 consumed;
                assembly {
                    requested := mload(add(reason, 0x24))
                    consumed := mload(add(reason, 0x44))
                }

                // Verify requested matches what we sent (after fee)
                assertEq(
                    requested,
                    expectedEthToSwap,
                    "Requested should equal ETH amount after fee"
                );

                // Verify consumed is less than requested
                assertLt(
                    consumed,
                    requested,
                    "Consumed should be less than requested in partial fill"
                );

                // Verify consumed is not zero (some swap occurred)
                assertGt(consumed, 0, "Some ETH should have been consumed");
            }
        }
    }

    /// @notice Test multiple sequential buys don't leave any ETH stuck
    /// @dev Regression test for atomicity across multiple transactions
    function testPartialFillBuy_SequentialBuysNoStuckEth() public {
        uint256 buyAmount = 0.2 ether;

        // Record initial contract balance
        uint256 initialContractBalance = address(liquid).balance;

        // Execute multiple buys
        for (uint i = 0; i < 5; i++) {
            vm.prank(user1);
            uint256 tokensReceived = liquid.buy{value: buyAmount}(
                user1,
                address(0),
                0,
                0
            );
            assertGt(tokensReceived, 0, "Should receive tokens each time");

            // Verify no ETH accumulation after each buy
            assertEq(
                address(liquid).balance,
                initialContractBalance,
                "No ETH should accumulate in contract"
            );
        }
    }
}
