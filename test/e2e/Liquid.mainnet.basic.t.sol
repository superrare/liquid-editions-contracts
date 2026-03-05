// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {MockBurner} from "liquid-editions-test/helpers/MockBurner.sol";
import {MockRAREDeployer} from "liquid-editions-test/helpers/MockRAREDeployer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";

contract LiquidInstantMainnetBasicTest is Test, InitGuardTestHelper {
    using StateLibrary for IPoolManager;
    // Network configuration
    NetworkConfig.Config internal config;

    // Test accounts
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public orderReferrer = makeAddr("orderReferrer");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    // Contract interfaces
    RAREBurner public burner;
    LiquidMultiCurve public liquidImplementation;
    LiquidFactory public factory;
    LiquidMultiCurve public liquid;
    MockRARE public mockRARE;

    function _defaultSingleCurve(LiquidFactory _factory) internal view returns (Curve[] memory) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({
            tickLower: _factory.lpTickLower(),
            tickUpper: _factory.lpTickUpper(),
            numPositions: 1,
            shares: 1e18
        });
        return curves;
    }

    function setUp() public virtual {
        // Fork Base mainnet to access real Uniswap V4 contracts
        string memory forkUrl = ForkUrlResolver.requireForkUrl(vm);
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
        liquidImplementation = new LiquidMultiCurve();
        address initGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        factory = new LiquidFactory(
            admin,
            config.uniswapV4PoolManager, // V4 PoolManager
            -180, // lpTickLower - max expensive (after price rises) - multiple of 60
            120000, // lpTickUpper - starting point (cheap tokens)
            initGuardAddr, // poolHooks
            60, // poolTickSpacing (standard for 0.3% fee tier)
            1e15 // minRareLiquidityWei (0.001 RARE)
        );
        LiquidGuard(initGuardAddr).setFactory(address(factory));

        
        factory.setLiquidRegistry(address(1));

        factory.setLiquidMultiCurveImplementation(address(liquidImplementation));

        // Deploy mock RARE token
        mockRARE = new MockRARE();

        // Set base token (RARE) in factory
        factory.setBaseToken(address(mockRARE));

        // Fund test accounts with RARE tokens
        mockRARE.mint(tokenCreator, 1000 ether);
        mockRARE.mint(user1, 1000 ether);
        mockRARE.mint(user2, 1000 ether);

        // Create LiquidMultiCurve token through factory
        uint256 initialRareLiquidity = 0.001 ether;
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), initialRareLiquidity);
        address liquidAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator, // creator
            "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG", // tokenUri
            "LIQUID", // name
            "LIQUID", // symbol
            initialRareLiquidity,
            _defaultSingleCurve(factory)
        );

        liquid = LiquidMultiCurve(payable(liquidAddress));
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

        // Verify LiquidMultiCurve configuration
        assertEq(liquid.tokenCreator(), tokenCreator);
        assertEq(liquid.name(), "LIQUID");
        assertEq(liquid.symbol(), "LIQUID");

        // Verify fork is working by checking PoolManager code size
        assertTrue(config.uniswapV4PoolManager.code.length > 0);
    }

    function testInitializationWithMinimumRareOnlyProvidesLiquidity() public {
        uint256 MIN_RARE_AMOUNT = 0.001 ether;

        address creator = makeAddr("creator2");
        vm.deal(creator, 100 ether);

        // Use the factory's MockRARE (from setUp) instead of creating a new one
        // Mint RARE tokens to creator
        mockRARE.mint(creator, 1000 ether);

        // Track creator's initial RARE balance
        uint256 creatorInitialRareBalance = mockRARE.balanceOf(creator);

        // Create token through factory with only minimum RARE
        vm.startPrank(creator);
        IERC20(mockRARE).approve(address(factory), MIN_RARE_AMOUNT);
        address newTokenAddress = factory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://test-token-uri-2",
            "MIN_LIQUID",
            "ML",
            MIN_RARE_AMOUNT,
            _defaultSingleCurve(factory)
        );
        vm.stopPrank();

        LiquidMultiCurve newLiquidInstant = LiquidMultiCurve(
            payable(newTokenAddress)
        );

        // Verify RARE was spent
        assertEq(
            mockRARE.balanceOf(creator),
            creatorInitialRareBalance - MIN_RARE_AMOUNT
        );

        // Verify creator received only launch rewards
        uint256 creatorFinalTokenBalance = newLiquidInstant.balanceOf(creator);
        uint256 CREATOR_LAUNCH_REWARD = 100_000e18;
        assertEq(creatorFinalTokenBalance, CREATOR_LAUNCH_REWARD);

        // Verify pool was still created
        assertTrue(PoolId.unwrap(newLiquidInstant.poolId()) != bytes32(0));
    }

    function testReceiveFunction() public {
        uint256 SEND_AMOUNT = 1 ether;
        uint256 INITIAL_BALANCE = user1.balance;

        vm.startPrank(user1);

        // Send ETH directly to the contract
        // LiquidMultiCurve.sol does NOT have a receive() function, so this should REVERT
        // This is expected behavior - ETH should only flow through proper trading functions
        (bool success, ) = address(liquid).call{value: SEND_AMOUNT}("");

        // Verify the call reverted (contract has no receive function)
        assertFalse(
            success,
            "Call should revert - LiquidMultiCurve has no receive() function"
        );

        // Verify user's ETH balance is unchanged (transaction reverted)
        assertEq(
            user1.balance,
            INITIAL_BALANCE,
            "User ETH should be unchanged after reverted call"
        );

        // Verify no tokens were minted
        assertEq(liquid.balanceOf(user1), 0, "User should NOT receive tokens");

        vm.stopPrank();
    }

    function testStateFunction() public view {
        assertTrue(PoolId.unwrap(liquid.poolId()) != bytes32(0));
    }

    function testTokenURIFunction() public view {
        string memory uri = liquid.initialTokenUri();
        assertEq(uri, "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG");
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
        assertEq(liquid.maxTotalSupply(), 1_000_000e18);
        // Note: Fee handling is now done in LiquidRouter, not stored in LiquidMultiCurve contracts
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
        uint256 LIQUIDITY_RARE = 1 ether; // Use significant amount to make liquidity clearly measurable

        address creator = makeAddr("liquidityCreator");
        vm.deal(creator, 100 ether);

        // Fund creator with RARE tokens
        mockRARE.mint(creator, 1000 ether);

        // Create token through factory with RARE that should create pool with liquidity
        vm.startPrank(creator);
        IERC20(mockRARE).approve(address(factory), LIQUIDITY_RARE);
        address newTokenAddress = factory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://liquidity-test",
            "LIQUIDITY_TEST",
            "LT",
            LIQUIDITY_RARE,
            _defaultSingleCurve(factory)
        );
        vm.stopPrank();

        LiquidMultiCurve newLiquidInstant = LiquidMultiCurve(
            payable(newTokenAddress)
        );

        // Verify pool was created
        PoolId poolId = newLiquidInstant.poolId();
        assertTrue(
            PoolId.unwrap(poolId) != bytes32(0),
            "Pool should be created"
        );

        // Check if the pool has been initialized properly using V4 StateLibrary
        IPoolManager pm = IPoolManager(newLiquidInstant.poolManager());
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "Pool should be initialized with a price");

        // Check liquidity using multicurve state (positions may be split across ranges)
        uint256 positions = newLiquidInstant.storedPositionsLength();
        uint128 liquidity = pm.getLiquidity(newLiquidInstant.poolId());

        // This is the main assertion - liquidity should be greater than 0
        assertTrue(
            positions > 0 || liquidity > 0,
            "LP position should have liquidity greater than 0"
        );

        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(newLiquidInstant.poolId()));
        console.log("Pool positions:", positions);
        console.log("Pool liquidity:", liquidity);
        console.log("Pool sqrt price:", sqrtPriceX96);
    }

    function testFactoryRARELiquidityCreation() public {
        // Test to verify that the LiquidFactory properly uses RARE tokens to create initial liquidity
        uint256 FACTORY_ETH_AMOUNT = 1 ether;

        address creator = makeAddr("factoryCreator");
        vm.deal(creator, 100 ether);

        // Deploy the factory system
        vm.startPrank(admin);
        address testInitGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        LiquidFactory testFactory = new LiquidFactory(
            admin,
            config.uniswapV4PoolManager, // V4 PoolManager
            -180, // lpTickLower - max expensive (after price rises) - multiple of 60
            120000, // lpTickUpper - starting point (cheap tokens)
            testInitGuardAddr, // poolHooks
            60, // poolTickSpacing (standard for 0.3% fee tier)
            1e15 // minRareLiquidityWei (0.001 RARE)
        );
        LiquidGuard(testInitGuardAddr).setFactory(address(testFactory));
                testFactory.setLiquidRegistry(address(1));

        // Create implementation and set it in factory
        LiquidMultiCurve factoryLiquidInstantImplementation = new LiquidMultiCurve();
        testFactory.setLiquidMultiCurveImplementation(
            address(factoryLiquidInstantImplementation)
        );

        // Set base token (RARE) in factory
        testFactory.setBaseToken(address(mockRARE));

        vm.stopPrank();

        // Fund creator with RARE tokens
        mockRARE.mint(creator, 1000 ether);

        // Record creator's RARE balance before
        uint256 creatorRareBalanceBefore = mockRARE.balanceOf(creator);

        // Create token through factory with RARE
        vm.startPrank(creator);
        IERC20(mockRARE).approve(address(testFactory), FACTORY_ETH_AMOUNT);
        address tokenAddress = testFactory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://factory-test",
            "FACTORY_TEST",
            "FT",
            FACTORY_ETH_AMOUNT,
            _defaultSingleCurve(testFactory)
        );
        vm.stopPrank();

        // Verify RARE was spent (all RARE goes to liquidity)
        LiquidMultiCurve factoryLiquidInstant = LiquidMultiCurve(
            payable(tokenAddress)
        );
        assertEq(
            mockRARE.balanceOf(creator),
            creatorRareBalanceBefore - FACTORY_ETH_AMOUNT,
            "Creator should have spent all the RARE"
        );

        // Get the LiquidMultiCurve token instance

        // Verify token was created properly
        assertEq(factoryLiquidInstant.name(), "FACTORY_TEST");
        assertEq(factoryLiquidInstant.symbol(), "FT");
        assertEq(factoryLiquidInstant.tokenCreator(), creator);

        // Get market state

        // Verify pool was created
        assertTrue(
            PoolId.unwrap(factoryLiquidInstant.poolId()) != bytes32(0),
            "Factory should create pool"
        );

        // Check pool initialization using V4 StateLibrary
        IPoolManager pm = IPoolManager(factoryLiquidInstant.poolManager());
        PoolId poolId = factoryLiquidInstant.poolId();
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(poolId);
        assertTrue(
            sqrtPriceX96 > 0,
            "Factory-created pool should be initialized"
        );

        // Check actual pool liquidity (positions are split across ranges in multicurve)
        uint256 positions = factoryLiquidInstant.storedPositionsLength();
        uint128 liquidity = pm.getLiquidity(poolId);

        // CRITICAL TEST: Factory should use RARE tokens to create liquidity
        assertTrue(
            positions > 0 || liquidity > 0,
            "FACTORY SHOULD CREATE LIQUIDITY IN POOL"
        );

        // Verify creator got launch rewards
        uint256 creatorTokens = factoryLiquidInstant.balanceOf(creator);
        uint256 CREATOR_LAUNCH_REWARD = 100_000e18;
        assertEq(
            creatorTokens,
            CREATOR_LAUNCH_REWARD,
            "Creator should have only launch rewards"
        );

        console.log("=== FACTORY RARE LIQUIDITY CREATION TEST ===");
        console.log("RARE sent to factory:", FACTORY_ETH_AMOUNT);
        console.log("Token address:", tokenAddress);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(factoryLiquidInstant.poolId()));
        console.log("Pool positions:", positions);
        console.log("Pool liquidity:", liquidity);
        console.log("Creator token balance:", creatorTokens);
        console.log("Launch reward:", CREATOR_LAUNCH_REWARD);
        console.log("Pool sqrt price:", sqrtPriceX96);
    }

    function testPoolLiquidityDeploymentMinimumAmount() public {
        // Test with minimum RARE amount to see if this is where the issue occurs
        uint256 MIN_LIQUIDITY_RARE = 0.001 ether; // Minimum amount typically used

        address creator = makeAddr("minLiquidityCreator");
        vm.deal(creator, 100 ether);

        // Fund creator with RARE tokens
        mockRARE.mint(creator, 1000 ether);

        // Create token through factory with minimum RARE
        vm.startPrank(creator);
        IERC20(mockRARE).approve(address(factory), MIN_LIQUIDITY_RARE);
        address newTokenAddress = factory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://min-liquidity-test",
            "MIN_LIQUIDITY_TEST",
            "MLT",
            MIN_LIQUIDITY_RARE,
            _defaultSingleCurve(factory)
        );
        vm.stopPrank();

        LiquidMultiCurve newLiquidInstant = LiquidMultiCurve(
            payable(newTokenAddress)
        );

        // Get the market state

        // Verify pool was created
        assertTrue(
            PoolId.unwrap(newLiquidInstant.poolId()) != bytes32(0),
            "Pool should be created even with minimum RARE"
        );

        // Check pool initialization using V4 StateLibrary
        IPoolManager pm = IPoolManager(newLiquidInstant.poolManager());
        PoolId poolId = newLiquidInstant.poolId();
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(poolId);
        assertTrue(
            sqrtPriceX96 > 0,
            "Pool should be initialized with minimum RARE"
        );

        // Check actual pool liquidity (positions are split across ranges in multicurve)
        uint256 positions = newLiquidInstant.storedPositionsLength();
        uint128 liquidity = pm.getLiquidity(poolId);

        // Main assertion - even with minimum RARE, there should be liquidity
        assertTrue(
            positions > 0 || liquidity > 0,
            "LP position should have liquidity > 0 even with minimum RARE"
        );

        console.log("=== MINIMUM RARE TEST ===");
        console.log("RARE amount used:", MIN_LIQUIDITY_RARE);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(newLiquidInstant.poolId()));
        console.log("Pool positions:", positions);
        console.log("Pool liquidity:", liquidity);
        console.log("Pool sqrt price:", sqrtPriceX96);
    }

    function testPoolInitializationWithLiquidInstantAsCurrency0() public {
        // This test forces baseTokenIsCurrency0 == false by deploying MockRARE at a high address
        // When LIQUID token address < baseToken address, LIQUID becomes currency0

        uint256 CREATOR_LAUNCH_REWARD = 100_000e18;
        uint256 initialRareLiquidity = 0.1 ether;

        address creator = makeAddr("currency0Creator");
        vm.deal(creator, 100 ether);

        // Deploy MockRARE using the helper deployer with CREATE2
        // This gives us a deterministic address that we can control
        MockRAREDeployer deployer = new MockRAREDeployer();
        bytes32 salt = keccak256(
            "testPoolInitializationWithLiquidInstantAsCurrency0"
        );
        address deployedRARE = deployer.deployMockRARE(salt);

        MockRARE testRARE = MockRARE(deployedRARE);
        testRARE.mint(creator, 1000 ether);

        // Create factory with this RARE token
        vm.startPrank(admin);
        address testInitGuardAddr2 = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        LiquidFactory testFactory = new LiquidFactory(
            admin,
            config.uniswapV4PoolManager,
            -180, // lpTickLower
            120000, // lpTickUpper
            testInitGuardAddr2,
            60,
            1e15
        );
        LiquidGuard(testInitGuardAddr2).setFactory(address(testFactory));
                testFactory.setLiquidRegistry(address(1));
        testFactory.setLiquidMultiCurveImplementation(address(liquidImplementation));
        testFactory.setBaseToken(address(testRARE));
        vm.stopPrank();

        // Create LiquidMultiCurve token
        vm.startPrank(creator);
        IERC20(testRARE).approve(address(testFactory), initialRareLiquidity);
        address liquidAddress = testFactory.createLiquidTokenMultiCurve(
            creator,
            "ipfs://currency0-test",
            "CURRENCY0_TEST",
            "C0",
            initialRareLiquidity,
            _defaultSingleCurve(testFactory)
        );
        vm.stopPrank();

        LiquidMultiCurve testLiquidInstant = LiquidMultiCurve(payable(liquidAddress));

        // Verify address ordering: baseToken should be > liquid token address for baseTokenIsCurrency0 == false
        bool actualOrdering = address(testRARE) < address(testLiquidInstant);

        // If ordering is wrong, try to find a salt that gives us a high address
        if (actualOrdering) {
            address highRARE = address(0);
            uint160 maxAddress = uint160(liquidAddress);

            // Compute CREATE2 addresses without deploying to find a good salt
            bytes memory bytecode = type(MockRARE).creationCode;
            bytes32 bytecodeHash = keccak256(bytecode);
            address deployerAddress = address(deployer);

            // Try multiple salts to find one that gives us a high address
            for (uint256 i = 0; i < 500; i++) {
                bytes32 trySalt = keccak256(
                    abi.encodePacked("highAddress", i, liquidAddress)
                );
                // Manual CREATE2 address computation: keccak256(0xff ++ deployer ++ salt ++ bytecodeHash)[12:]
                address computedAddress;
                assembly {
                    let ptr := mload(0x40)
                    mstore(ptr, 0xff)
                    mstore(add(ptr, 0x20), deployerAddress)
                    mstore(add(ptr, 0x40), trySalt)
                    mstore(add(ptr, 0x60), bytecodeHash)
                    let hash := keccak256(ptr, 0x80)
                    computedAddress := and(
                        hash,
                        0xffffffffffffffffffffffffffffffffffffffff
                    )
                }

                if (uint160(computedAddress) > maxAddress) {
                    maxAddress = uint160(computedAddress);
                    // If we found one higher than liquid address, deploy it
                    if (uint160(computedAddress) > uint160(liquidAddress)) {
                        highRARE = deployer.deployMockRARE(trySalt);
                        break;
                    }
                }
            }

            // If we found a high address, use it
        if (
            highRARE != address(0) &&
            uint160(highRARE) > uint160(liquidAddress)
        ) {
            testRARE = MockRARE(highRARE);
            testRARE.mint(creator, 1000 ether);

            // Recreate factory with high address RARE
            vm.startPrank(admin);
            address testInitGuardAddr3 = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
            testFactory = new LiquidFactory(
                    admin,
                    config.uniswapV4PoolManager,
                    -180,
                    120000,
                    testInitGuardAddr3,
                    60,
                    1e15
                );
            LiquidGuard(testInitGuardAddr3).setFactory(address(testFactory));
                            testFactory.setLiquidRegistry(address(1));
                testFactory.setLiquidMultiCurveImplementation(address(liquidImplementation));
                testFactory.setBaseToken(address(testRARE));
                vm.stopPrank();

                // Recreate LiquidMultiCurve token
                vm.startPrank(creator);
                IERC20(testRARE).approve(
                    address(testFactory),
                    initialRareLiquidity
                );
                liquidAddress = testFactory.createLiquidTokenMultiCurve(
                    creator,
                    "ipfs://currency0-forced",
                    "CURRENCY0_FORCED",
                    "C0F",
                    initialRareLiquidity,
                    _defaultSingleCurve(testFactory)
        );
                vm.stopPrank();

                testLiquidInstant = LiquidMultiCurve(payable(liquidAddress));
                actualOrdering = address(testRARE) < address(testLiquidInstant);
            } else {
                // If we couldn't find a high address, skip this test scenario
                // This is rare but can happen with CREATE2 address distribution
                vm.skip(true);
                return;
            }
        }

        // Verify baseTokenIsCurrency0 == false
        assertFalse(actualOrdering, "baseTokenIsCurrency0 should be false");

        // 1. Verify pool initializes
        PoolId poolId = testLiquidInstant.poolId();
        assertTrue(
            PoolId.unwrap(poolId) != bytes32(0),
            "Pool should be initialized"
        );

        IPoolManager pm = IPoolManager(testLiquidInstant.poolManager());
        (uint160 sqrtPriceX96, int24 currentTick, , ) = pm.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "Pool should have initial price");

        // 2. Verify initial price corresponds to "cheap token" semantics
        // When LIQUID is currency0, ticks are negated: [-120000, 180] instead of [-180, 120000]
        // With optimal price calculation, we start at a price that uses all provided liquidity
        // The price should be within the valid range (not at edges) and still maintain cheap LIQUID semantics
        int24 tickLower = testLiquidInstant.lpTickLower();
        int24 tickUpper = testLiquidInstant.lpTickUpper();

        // Verify multicurve bounds are the stored values from deployment config
        int24 expectedLower = actualOrdering ? int24(-120000) : int24(-180);
        int24 expectedUpper = actualOrdering ? int24(180) : int24(120000);
        assertEq(tickLower, expectedLower, "lpTickLower should match configured bound");
        assertEq(tickUpper, expectedUpper, "lpTickUpper should match configured bound");
        assertEq(tickLower % 60, 0, "lpTickLower must be aligned to tick spacing");
        assertEq(tickUpper % 60, 0, "lpTickUpper must be aligned to tick spacing");

        // Verify tick is within configured bounds for this multicurve launch
        assertGe(
            currentTick,
            tickLower,
            "Price should be within lower bound"
        );
        assertLe(
            currentTick,
            tickUpper,
            "Price should be within upper bound"
        );

        // Verify price interpretation: when LIQUID is currency0, sqrtPriceX96 represents
        // sqrt(RARE/LIQUID). At low tick, this ratio is low, meaning LIQUID is cheap.
        (uint256 rarePerToken, uint256 tokenPerRare) = testLiquidInstant
            .getCurrentPrice();
        // When LIQUID is currency0, rarePerToken should be low (cheap LIQUID)
        assertTrue(
            rarePerToken < 1e18,
            "LIQUID should start cheap (low RARE per token)"
        );

        // 3. Verify launch liquidity uses POOL_LAUNCH_SUPPLY (900K tokens)
        uint256 creatorBalance = testLiquidInstant.balanceOf(creator);

        // Creator should have CREATOR_LAUNCH_REWARD
        assertEq(
            creatorBalance,
            CREATOR_LAUNCH_REWARD,
            "Creator should receive launch reward"
        );

        // Verify total supply
        assertEq(
            testLiquidInstant.totalSupply(),
            1_000_000e18,
            "Total supply should be MAX_TOTAL_SUPPLY"
        );

        // Verify pool has liquidity (which uses POOL_LAUNCH_SUPPLY)
        uint256 positions = testLiquidInstant.storedPositionsLength();
        uint128 liquidity = pm.getLiquidity(poolId);
        assertTrue(
            positions > 0 || liquidity > 0,
            "Pool should have liquidity"
        );

        // Verify that tokens were transferred to the pool
        // The contract negates and swaps the tick range when LIQUID is currency0 to maintain
        // equivalent bonding curve economics regardless of address ordering.
        // This ensures ~900K tokens end up in the pool in both cases.
        uint256 contractBalance = testLiquidInstant.balanceOf(
            address(testLiquidInstant)
        );

        // After initialization: 1M tokens minted, 100K transferred to creator,
        // ~900K should be in pool (contract balance should be very low)
        uint256 POOL_LAUNCH_SUPPLY = 900_000e18;

        // Contract balance should be very low (most tokens in pool)
        // Allow some tolerance for rounding/precision
        assertTrue(
            contractBalance < POOL_LAUNCH_SUPPLY / 10,
            "Most tokens should be in pool, not contract"
        );

        console.log("=== CURRENCY0 ORDERING TEST ===");
        console.log("RARE address:", address(testRARE));
        console.log("LIQUID address:", address(testLiquidInstant));
        console.log("baseTokenIsCurrency0:", actualOrdering);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("Initial tick:", currentTick);
        console.log("Tick lower:", tickLower);
        console.log("Tick upper:", tickUpper);
        console.log("Initial sqrtPriceX96:", sqrtPriceX96);
        console.log("RARE per token:", rarePerToken);
        console.log("Token per RARE:", tokenPerRare);
        console.log("Pool positions:", positions);
        console.log("Pool liquidity:", liquidity);
        console.log("Contract balance:", contractBalance);
        console.log("Creator balance:", creatorBalance);
    }
}
