// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidFactory Mainnet Tests
 * @notice These tests fork Base mainnet to access real Uniswap V4 contracts
 * @dev Fork is created automatically in setUp()
 * @dev Run with: make test-factory
 */

import "forge-std/Test.sol";
import {LiquidFactory} from "../src/LiquidFactory.sol";
import {Liquid} from "../src/Liquid.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {ILiquidFactory} from "../src/interfaces/ILiquidFactory.sol";
import {RAREBurner} from "../src/RAREBurner.sol";
import {NetworkConfig} from "../script/NetworkConfig.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

// Mock burner for testing
contract MockBurner {
    receive() external payable {}

    function depositForBurn() external payable {}
}

contract LiquidFactoryTest is Test {
    // Test accounts
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    // Network configuration
    NetworkConfig.Config public config;

    // Contract instances
    RAREBurner public burner;
    Liquid public liquidImplementation;
    LiquidFactory public factory;

    function setUp() public {
        // Fork Base mainnet to access Uniswap V4 contracts
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
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

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
            2500, // defaultCreatorFeeBPS (25%)
            -180, // lpTickLower - max expensive (after price rises) - multiple of 60
            120000, // lpTickUpper - starting point (cheap tokens) - multiple of 60
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

    function testSetup() public view {
        // Verify basic setup
        assertTrue(admin != address(0));
        assertTrue(tokenCreator != address(0));
        assertTrue(protocolFeeRecipient != address(0));
        assertTrue(user1 != address(0));
        assertTrue(user2 != address(0));

        // Verify contract addresses
        assertTrue(address(liquidImplementation) != address(0));
        assertTrue(address(factory) != address(0));

        // Verify factory configuration using new config system
        assertEq(factory.protocolFeeRecipient(), protocolFeeRecipient);
        assertEq(factory.weth(), config.weth);
        assertEq(factory.poolManager(), config.uniswapV4PoolManager);
        assertEq(factory.v4Quoter(), config.uniswapV4Quoter);
        assertEq(factory.liquidImplementation(), address(liquidImplementation));
    }

    function testCreateLiquidToken() public {
        string memory tokenName = "Test Token";
        string memory tokenSymbol = "TEST";
        string memory tokenUri = "ipfs://QmTestTokenURI";

        vm.startPrank(tokenCreator);

        address newToken = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            tokenUri,
            tokenName,
            tokenSymbol
        );

        vm.stopPrank();

        // Verify token was created
        assertTrue(newToken != address(0));

        // Verify the created token works
        Liquid liquidToken = Liquid(payable(newToken));
        assertEq(liquidToken.name(), tokenName);
        assertEq(liquidToken.symbol(), tokenSymbol);
        assertEq(liquidToken.tokenUri(), tokenUri);
        assertEq(liquidToken.tokenCreator(), tokenCreator);
    }

    function testCreateMultipleTokens() public {
        vm.startPrank(tokenCreator);

        // Create first token
        address token1 = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://token1",
            "Token1",
            "TK1"
        );

        // Create second token
        address token2 = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://token2",
            "Token2",
            "TK2"
        );

        vm.stopPrank();

        // Verify both tokens were created
        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
    }

    function testCreateTokenWithDifferentCreators() public {
        vm.startPrank(tokenCreator);
        address token1 = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://token1",
            "Token1",
            "TK1"
        );
        vm.stopPrank();

        vm.startPrank(user1);
        address token2 = factory.createLiquidToken{value: 0.1 ether}(
            user1,
            "ipfs://token2",
            "Token2",
            "TK2"
        );
        vm.stopPrank();

        // Verify tokens were created
        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
    }

    function testCreateTokenWithZeroPlatformReferrer() public {
        vm.startPrank(tokenCreator);

        address newToken = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST"
        );

        vm.stopPrank();

        // Verify token was created successfully
        Liquid liquidToken = Liquid(payable(newToken));
        assertEq(liquidToken.tokenCreator(), tokenCreator);
    }

    function testCreateTokenWithInitialBuy() public {
        vm.startPrank(tokenCreator);

        address newToken = factory.createLiquidToken{value: 1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST"
        );

        vm.stopPrank();

        // Verify the token was created and initialized with the ETH
        Liquid liquidToken = Liquid(payable(newToken));

        // Creator should have exactly the initial distribution (100k tokens)
        // All sent ETH goes to initial liquidity, NOT to an auto-buy
        uint256 creatorBalance = liquidToken.balanceOf(tokenCreator);
        assertEq(
            creatorBalance,
            100_000e18,
            "Creator should have initial distribution only"
        );

        // Verify pool has liquidity from the 1 ETH sent
        assertTrue(
            PoolId.unwrap(liquidToken.poolId()) != bytes32(0),
            "Pool should be initialized"
        );
    }

    function test_RevertWhen_CreateTokenWithoutImplementation() public {
        // Create a new factory without setting implementation
        MockBurner newMockBurner = new MockBurner();
        LiquidFactory newFactory = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            address(newMockBurner), // rareBurner
            0, // rareBurnFeeBPS (0% of remainder)
            5000, // protocolFeeBPS (50% of remainder)
            5000, // referrerFeeBPS (50% of remainder)
            100, // defaultTotalFeeBPS (1%)
            2500, // defaultCreatorFeeBPS (25%)
            -180, // lpTickLower - max expensive (after price rises) - multiple of 60
            120000, // lpTickUpper - starting point (cheap tokens) - multiple of 60
            config.uniswapV4Quoter, // Use wrapper instead of raw quoter
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            300, // internalMaxSlippageBps (3%)
            0.005 ether, // minOrderSizeWei
            1e15 // minInitialLiquidityWei (0.001 ETH)
        );

        vm.startPrank(tokenCreator);
        vm.expectRevert(ILiquidFactory.ImplementationNotSet.selector);
        newFactory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST"
        );
        vm.stopPrank();
    }

    function test_RevertWhen_CreateTokenWithZeroCreator() public {
        vm.startPrank(tokenCreator);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.createLiquidToken{value: 0.1 ether}(
            address(0), // Zero creator
            "ipfs://test",
            "Test",
            "TEST"
        );
        vm.stopPrank();
    }

    /// @notice Test creation fails when ETH is below minInitialLiquidityWei
    /// @dev Verifies EthAmountTooSmall() error when msg.value < minInitialLiquidityWei
    function test_RevertWhen_CreateTokenBelowMinInitialLiquidity() public {
        uint256 minInitialLiquidity = factory.minInitialLiquidityWei();

        // Try to create token with ETH below minimum
        vm.startPrank(tokenCreator);
        vm.expectRevert(ILiquid.EthAmountTooSmall.selector);
        factory.createLiquidToken{value: minInitialLiquidity - 1}(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST"
        );
        vm.stopPrank();
    }

    /// @notice Test creation succeeds at exact minInitialLiquidityWei
    /// @dev Verifies boundary condition works correctly
    function test_CreateTokenAtExactMinInitialLiquidity() public {
        uint256 minInitialLiquidity = factory.minInitialLiquidityWei();

        // Create token with exact minimum
        vm.startPrank(tokenCreator);
        address newToken = factory.createLiquidToken{
            value: minInitialLiquidity
        }(tokenCreator, "ipfs://exact-min", "ExactMin", "EMIN");
        vm.stopPrank();

        // Verify token was created successfully
        assertTrue(
            newToken != address(0),
            "Token should be created at exact minimum"
        );
        Liquid liquidToken = Liquid(payable(newToken));
        assertEq(
            liquidToken.balanceOf(tokenCreator),
            100_000e18,
            "Creator should receive initial tokens"
        );
    }

    function testUpdateImplementation() public {
        // Deploy new implementation
        vm.startPrank(admin);
        Liquid newImplementation = new Liquid();

        factory.updateImplementation(address(newImplementation));
        vm.stopPrank();

        // Verify implementation was updated
        assertEq(factory.liquidImplementation(), address(newImplementation));

        // Create a new token with the updated implementation
        vm.startPrank(tokenCreator);
        address newToken = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST"
        );
        vm.stopPrank();

        // Verify the token was created successfully
        assertTrue(newToken != address(0));
    }

    function test_RevertWhen_UpdateImplementationToZero() public {
        vm.startPrank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.updateImplementation(address(0));
        vm.stopPrank();
    }

    function testUpdateConfig() public {
        // Create new config values
        vm.startPrank(admin);
        address newRecipient = makeAddr("newRecipient");

        factory.setProtocolFeeRecipient(newRecipient);
        vm.stopPrank();

        // Verify new config values are active
        assertEq(factory.protocolFeeRecipient(), newRecipient);
    }

    function test_RevertWhen_SetConfigWithZeroAddress() public {
        vm.startPrank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setProtocolFeeRecipient(address(0));
        vm.stopPrank();
    }

    function testLiquidTokenCreatedEvent() public {
        vm.startPrank(tokenCreator);

        // Create the token and capture the address
        address newToken = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST"
        );

        vm.stopPrank();

        // Verify the event was emitted with the correct token address
        // Note: We can't easily test the exact event emission in this case
        // since the token address is determined during creation
        assertTrue(newToken != address(0));
    }

    function testImplementationUpdatedEvent() public {
        vm.startPrank(admin);

        Liquid newImplementation = new Liquid();

        address oldImplementation = factory.liquidImplementation();

        vm.expectEmit(true, true, false, false);
        emit ILiquidFactory.ImplementationUpdated(
            oldImplementation,
            address(newImplementation)
        );

        factory.updateImplementation(address(newImplementation));

        vm.stopPrank();
    }

    // ============================================
    // SECTION A: Access Control & Invalid Configs
    // ============================================

    // ========== Access Control Tests ==========

    /// @notice Test that non-owner cannot call updateImplementation
    function test_RevertWhen_NonOwner_UpdateImplementation() public {
        Liquid newImpl = new Liquid();

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                user1
            )
        );
        factory.updateImplementation(address(newImpl));
        vm.stopPrank();
    }

    /// @notice Test that non-owner cannot call pushConfig
    function test_RevertWhen_NonOwner_PushConfig() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                user1
            )
        );
        factory.setProtocolFeeRecipient(protocolFeeRecipient);
        vm.stopPrank();
    }

    /// @notice Test that non-owner cannot call setTradingKnobs
    function test_RevertWhen_NonOwner_SetTradingKnobs() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                user1
            )
        );
        factory.setInternalMaxSlippageBps(300);
        vm.stopPrank();
    }

    /// @notice Test that regular user (non-owner) cannot call any admin functions
    function test_RevertWhen_NonOwner_AllAdminFunctions() public {
        Liquid newImpl = new Liquid();

        // Try all admin functions as user2
        vm.startPrank(user2);

        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                user2
            )
        );
        factory.updateImplementation(address(newImpl));

        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                user2
            )
        );
        factory.setProtocolFeeRecipient(protocolFeeRecipient);

        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                user2
            )
        );
        factory.setInternalMaxSlippageBps(500);

        vm.stopPrank();
    }

    // ========== Invalid Config Tests ==========

    /// @notice Test that invalid tick range (lower >= upper) reverts with InvalidTickRange
    function test_RevertWhen_InvalidTickRange_LowerEqualsUpper() public {
        vm.startPrank(admin);
        factory.setLpTickLower(120);
        vm.expectRevert(ILiquidFactory.InvalidTickRange.selector);
        factory.setLpTickUpper(120); // lower >= upper (invalid)
        vm.stopPrank();
    }

    /// @notice Test that invalid tick range (lower > upper) reverts with InvalidTickRange
    function test_RevertWhen_InvalidTickRange_LowerGreaterThanUpper() public {
        vm.startPrank(admin);
        factory.setLpTickLower(540);
        vm.expectRevert(ILiquidFactory.InvalidTickRange.selector);
        factory.setLpTickUpper(120); // lower > upper (invalid)
        vm.stopPrank();
    }

    /// @notice Test that fees not summing to 100% reverts with InvalidFeeDistribution
    function test_RevertWhen_InvalidBurnFee_OverFiftyPercent() public {
        vm.startPrank(admin);
        // Current state: rareBurnFeeBPS=0, protocolFeeBPS=5000, referrerFeeBPS=5000 (valid)
        // Try to set rareBurnFeeBPS to 5001 while keeping other fees unchanged
        // Total would be: 5001 + 5000 + 5000 = 15001, not 10000
        vm.expectRevert(ILiquidFactory.InvalidFeeDistribution.selector);
        factory.setTier3FeeSplits(5001, 5000, 5000); // This would make total > 10000
        vm.stopPrank();
    }

    /// @notice Test that fees not summing to exactly 10000 BPS reverts
    function test_RevertWhen_InvalidBurnFee_HundredPercent() public {
        vm.startPrank(admin);
        // Current state: rareBurnFeeBPS=0, protocolFeeBPS=5000, referrerFeeBPS=5000 (valid)
        // Try to set rareBurnFeeBPS to 10000 while keeping other fees unchanged
        // Total would be: 10000 + 5000 + 5000 = 20000, not 10000
        vm.expectRevert(ILiquidFactory.InvalidFeeDistribution.selector);
        factory.setTier3FeeSplits(10000, 5000, 5000); // This would make total >> 10000
        vm.stopPrank();
    }

    /// @notice Test that burn fee of exactly 5000 BPS (50%) is allowed - boundary test
    function test_BurnFee_ExactlyFiftyPercent_Succeeds() public {
        // Create a new factory with the target fees (can't change step-by-step due to validation)
        vm.startPrank(admin);
        MockBurner testBurner = new MockBurner();
        LiquidFactory factoryWithBurn = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            address(testBurner),
            5000, // rareBurnFeeBPS (50%)
            2500, // protocolFeeBPS
            2500, // referrerFeeBPS
            100, // defaultTotalFeeBPS
            2500, // defaultCreatorFeeBPS
            -180, // lpTickLower - max expensive (after price rises) - multiple of 60
            120000, // lpTickUpper - starting point (cheap tokens) - multiple of 60
            config.uniswapV4Quoter, // Use wrapper instead of raw quoter
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            300, // internalMaxSlippageBps
            0.005 ether, // minOrderSizeWei
            1e15 // minInitialLiquidityWei (0.001 ETH)
        );
        vm.stopPrank();

        // Verify values were set
        assertEq(factoryWithBurn.rareBurnFeeBPS(), 5000);
        assertEq(factoryWithBurn.protocolFeeBPS(), 2500);
        assertEq(factoryWithBurn.referrerFeeBPS(), 2500);
    }

    /// @notice Test that zero burn fee is valid
    function test_BurnFee_Zero_Succeeds() public {
        vm.startPrank(admin);
        factory.setTier3FeeSplits(0, 5000, 5000); // rareBurn=0, protocol=5000, referrer=5000
        vm.stopPrank();

        // Verify values were set
        assertEq(factory.rareBurnFeeBPS(), 0);
        assertEq(factory.protocolFeeBPS(), 5000);
        assertEq(factory.referrerFeeBPS(), 5000);
    }

    // ========== Tick Spacing Validation Tests ==========

    /// @notice Test that setting lpTickLower with invalid tick spacing reverts
    function test_RevertWhen_SetLpTickLower_InvalidTickSpacing() public {
        vm.startPrank(admin);
        // Current tick spacing is 60, so ticks must be multiples of 60
        // Try to set lpTickLower to -200 (not a multiple of 60: -200 % 60 = -20)
        vm.expectRevert(ILiquidFactory.InvalidTickSpacing.selector);
        factory.setLpTickLower(-200);
        vm.stopPrank();
    }

    /// @notice Test that setting lpTickLower with valid tick spacing succeeds
    function test_SetLpTickLower_ValidTickSpacing_Succeeds() public {
        vm.startPrank(admin);
        // Current tick spacing is 60, so -240 is valid (-240 % 60 = 0)
        factory.setLpTickLower(-240);
        vm.stopPrank();

        // Verify value was set
        assertEq(factory.lpTickLower(), -240);
    }

    /// @notice Test that setting lpTickUpper with invalid tick spacing reverts
    function test_RevertWhen_SetLpTickUpper_InvalidTickSpacing() public {
        vm.startPrank(admin);
        // Current tick spacing is 60, so ticks must be multiples of 60
        // Try to set lpTickUpper to 120001 (not a multiple of 60: 120001 % 60 = 1)
        vm.expectRevert(ILiquidFactory.InvalidTickSpacing.selector);
        factory.setLpTickUpper(120001);
        vm.stopPrank();
    }

    /// @notice Test that setting lpTickUpper with valid tick spacing succeeds
    function test_SetLpTickUpper_ValidTickSpacing_Succeeds() public {
        vm.startPrank(admin);
        // Current tick spacing is 60, so 120060 is valid (120060 % 60 = 0)
        factory.setLpTickUpper(120060);
        vm.stopPrank();

        // Verify value was set
        assertEq(factory.lpTickUpper(), 120060);
    }

    /// @notice Test that setting poolTickSpacing with incompatible existing ticks reverts
    function test_RevertWhen_SetPoolTickSpacing_IncompatibleTicks() public {
        vm.startPrank(admin);
        // Current ticks are -180 and 120000, both multiples of 60
        // Try to set tick spacing to 100 (would make -180 % 100 = -80, invalid)
        vm.expectRevert(ILiquidFactory.InvalidTickSpacing.selector);
        factory.setPoolTickSpacing(100);
        vm.stopPrank();
    }

    /// @notice Test that setting poolTickSpacing with compatible existing ticks succeeds
    function test_SetPoolTickSpacing_CompatibleTicks_Succeeds() public {
        vm.startPrank(admin);
        // Current ticks are -180 and 120000
        // Both are divisible by 60, 30, 20, 15, 12, 10, 6, 5, 4, 3, 2, 1
        // Try setting to 20 (both -180 and 120000 are multiples of 20)
        factory.setPoolTickSpacing(20);
        vm.stopPrank();

        // Verify value was set
        assertEq(factory.poolTickSpacing(), 20);
    }

    /// @notice Test that constructor rejects ticks not aligned to spacing
    function test_RevertWhen_Constructor_InvalidTickSpacing() public {
        vm.startPrank(admin);
        MockBurner testBurner = new MockBurner();

        // Try to create factory with lpTickLower=-200 and tickSpacing=60
        // -200 % 60 = -20, so this should revert
        vm.expectRevert(ILiquidFactory.InvalidTickSpacing.selector);
        new LiquidFactory(
            admin,
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager,
            address(testBurner),
            0, // rareBurnFeeBPS
            5000, // protocolFeeBPS
            5000, // referrerFeeBPS
            100, // defaultTotalFeeBPS
            2500, // defaultCreatorFeeBPS
            -200, // lpTickLower - NOT a multiple of 60
            120000, // lpTickUpper
            config.uniswapV4Quoter,
            address(0), // poolHooks
            60, // poolTickSpacing
            300, // internalMaxSlippageBps
            0.005 ether, // minOrderSizeWei
            1e15 // minInitialLiquidityWei
        );
        vm.stopPrank();
    }

    /// @notice Test that constructor accepts ticks aligned to spacing
    function test_Constructor_ValidTickSpacing_Succeeds() public {
        vm.startPrank(admin);
        MockBurner testBurner = new MockBurner();

        // Create factory with properly aligned ticks
        LiquidFactory newFactory = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager,
            address(testBurner),
            0, // rareBurnFeeBPS
            5000, // protocolFeeBPS
            5000, // referrerFeeBPS
            100, // defaultTotalFeeBPS
            2500, // defaultCreatorFeeBPS
            -240, // lpTickLower - multiple of 60
            120060, // lpTickUpper - multiple of 60
            config.uniswapV4Quoter,
            address(0), // poolHooks
            60, // poolTickSpacing
            300, // internalMaxSlippageBps
            0.005 ether, // minOrderSizeWei
            1e15 // minInitialLiquidityWei
        );
        vm.stopPrank();

        // Verify values were set correctly
        assertEq(newFactory.lpTickLower(), -240);
        assertEq(newFactory.lpTickUpper(), 120060);
        assertEq(newFactory.poolTickSpacing(), 60);
    }
}
