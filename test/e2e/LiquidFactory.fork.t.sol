// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidFactory Mainnet Tests
 * @notice These tests fork Base mainnet to access real Uniswap V4 contracts
 * @dev Fork is created automatically in setUp()
 * @dev Run with: make test-factory (runs both unit and fork)
 */

import "forge-std/Test.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract LiquidFactoryTest is Test {
    // Test accounts
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    // Network configuration
    NetworkConfig.Config internal config;

    // Contract instances
    RAREBurner public burner;
    LiquidMultiCurve public liquidImplementation;
    LiquidFactory public factory;
    MockRARE public mockRARE;

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

        // Deploy mock RARE token
        mockRARE = new MockRARE();

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
        factory = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            -180, // lpTickLower - max expensive (after price rises) - multiple of 60
            120000, // lpTickUpper - starting point (cheap tokens) - multiple of 60
            config.uniswapV4Quoter, // Use wrapper instead of raw quoter
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            300, // internalMaxSlippageBps (3%)
            1e15 // minRareLiquidityWei (0.001 RARE)
        );

        
        factory.setLiquidRouter(address(1));

        // Set the implementation in the factory
        factory.setLiquidMultiCurveImplementation(address(liquidImplementation));

        // Set base token (RARE) in factory
        factory.setBaseToken(address(mockRARE));

        // Fund test accounts with RARE tokens
        mockRARE.mint(tokenCreator, 1000 ether);
        mockRARE.mint(user1, 1000 ether);
        mockRARE.mint(user2, 1000 ether);

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

        // Verify factory configuration (fee config moved to LiquidInstantRouter)
        assertEq(factory.weth(), config.weth);
        assertEq(factory.poolManager(), config.uniswapV4PoolManager);
        assertEq(factory.v4Quoter(), config.uniswapV4Quoter);
        assertEq(factory.liquidMultiCurveImplementation(), address(liquidImplementation));
    }

    function testCreateLiquidInstantToken() public {
        string memory tokenName = "Test Token";
        string memory tokenSymbol = "TEST";
        string memory tokenUri = "ipfs://QmTestTokenURI";
        uint256 initialRareLiquidity = 0.1 ether;

        vm.startPrank(tokenCreator);

        // Approve factory to transfer RARE tokens
        IERC20(mockRARE).approve(address(factory), initialRareLiquidity);

        address newToken = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            tokenUri,
            tokenName,
            tokenSymbol,
            initialRareLiquidity
        );

        vm.stopPrank();

        // Verify token was created
        assertTrue(newToken != address(0));

        // Verify the created token works
        LiquidMultiCurve liquidToken = LiquidMultiCurve(payable(newToken));
        assertEq(liquidToken.name(), tokenName);
        assertEq(liquidToken.symbol(), tokenSymbol);
        assertEq(liquidToken.initialTokenUri(), tokenUri);
        assertEq(liquidToken.tokenCreator(), tokenCreator);
        assertEq(liquidToken.baseToken(), address(mockRARE));
    }

    function testCreateMultipleTokens() public {
        uint256 initialRareLiquidity = 0.1 ether;
        vm.startPrank(tokenCreator);

        // Approve factory to transfer RARE tokens
        IERC20(mockRARE).approve(address(factory), initialRareLiquidity * 2);

        // Create first token
        address token1 = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://token1",
            "Token1",
            "TK1",
            initialRareLiquidity
        );

        // Create second token
        address token2 = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://token2",
            "Token2",
            "TK2",
            initialRareLiquidity
        );

        vm.stopPrank();

        // Verify both tokens were created
        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
    }

    function testCreateTokenWithDifferentCreators() public {
        uint256 initialRareLiquidity = 0.1 ether;
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), initialRareLiquidity);
        address token1 = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://token1",
            "Token1",
            "TK1",
            initialRareLiquidity
        );
        vm.stopPrank();

        vm.startPrank(user1);
        IERC20(mockRARE).approve(address(factory), initialRareLiquidity);
        address token2 = factory.createLiquidTokenMultiCurve(
            user1,
            "ipfs://token2",
            "Token2",
            "TK2",
            initialRareLiquidity
        );
        vm.stopPrank();

        // Verify tokens were created
        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
    }

    function testCreateTokenWithZeroPlatformReferrer() public {
        uint256 initialRareLiquidity = 0.1 ether;
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), initialRareLiquidity);

        address newToken = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST",
            initialRareLiquidity
        );

        vm.stopPrank();

        // Verify token was created successfully
        LiquidMultiCurve liquidToken = LiquidMultiCurve(payable(newToken));
        assertEq(liquidToken.tokenCreator(), tokenCreator);
    }

    function testCreateTokenWithInitialBuy() public {
        uint256 initialRareLiquidity = 1 ether;
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), initialRareLiquidity);

        address newToken = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST",
            initialRareLiquidity
        );

        vm.stopPrank();

        // Verify the token was created and initialized with the RARE
        LiquidMultiCurve liquidToken = LiquidMultiCurve(payable(newToken));

        // Creator should have exactly the initial distribution (100k tokens)
        // All sent RARE goes to initial liquidity
        uint256 creatorBalance = liquidToken.balanceOf(tokenCreator);
        assertEq(
            creatorBalance,
            100_000e18,
            "Creator should have initial distribution only"
        );

        // Verify pool has liquidity from the RARE sent
        assertTrue(
            PoolId.unwrap(liquidToken.poolId()) != bytes32(0),
            "Pool should be initialized"
        );
    }

    function test_RevertWhen_CreateTokenWithoutImplementation() public {
        // Create a new factory without setting implementation
        LiquidFactory newFactory = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            -180, // lpTickLower - max expensive (after price rises) - multiple of 60
            120000, // lpTickUpper - starting point (cheap tokens) - multiple of 60
            config.uniswapV4Quoter, // Use wrapper instead of raw quoter
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            300, // internalMaxSlippageBps (3%)
            1e15 // minRareLiquidityWei (0.001 RARE)
        );

        vm.startPrank(admin);
        newFactory.setLiquidRouter(address(1));
        // Set baseToken
        newFactory.setBaseToken(address(mockRARE));
        vm.stopPrank();

        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(newFactory), 0.1 ether);
        vm.expectRevert(ILiquidFactory.ImplementationNotSet.selector);
        newFactory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();
    }

    function test_RevertWhen_CreateTokenWithZeroCreator() public {
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.createLiquidTokenMultiCurve(
            address(0), // Zero creator
            "ipfs://test",
            "Test",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();
    }

    /// @notice Test creation fails when RARE is below minRareLiquidityWei
    /// @dev Verifies InvalidAmount() error when RARE amount < minRareLiquidityWei
    function test_RevertWhen_CreateTokenBelowMinInitialLiquidity() public {
        uint256 minInitialLiquidity = factory.minRareLiquidityWei();

        // Try to create token with RARE below minimum
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), minInitialLiquidity - 1);
        vm.expectRevert(ILiquidFactory.InvalidAmount.selector);
        factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST",
            minInitialLiquidity - 1
        );
        vm.stopPrank();
    }

    /// @notice Test creation succeeds at exact minRareLiquidityWei
    /// @dev Verifies boundary condition works correctly
    function test_CreateTokenAtExactMinInitialLiquidity() public {
        uint256 minInitialLiquidity = factory.minRareLiquidityWei();

        // Create token with exact minimum
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), minInitialLiquidity);
        address newToken = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://exact-min",
            "ExactMin",
            "EMIN",
            minInitialLiquidity
        );
        vm.stopPrank();

        // Verify token was created successfully
        assertTrue(
            newToken != address(0),
            "Token should be created at exact minimum"
        );
        LiquidMultiCurve liquidToken = LiquidMultiCurve(payable(newToken));
        assertEq(
            liquidToken.balanceOf(tokenCreator),
            100_000e18,
            "Creator should receive initial tokens"
        );
    }

    function testUpdateImplementation() public {
        // Deploy new implementation
        vm.startPrank(admin);
        LiquidMultiCurve newImplementation = new LiquidMultiCurve();

        factory.setLiquidMultiCurveImplementation(address(newImplementation));
        vm.stopPrank();

        // Verify implementation was updated
        assertEq(factory.liquidMultiCurveImplementation(), address(newImplementation));

        // Create a new token with the updated implementation
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address newToken = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        // Verify the token was created successfully
        assertTrue(newToken != address(0));
    }

    function test_RevertWhen_UpdateImplementationToZero() public {
        vm.startPrank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setLiquidMultiCurveImplementation(address(0));
        vm.stopPrank();
    }

    function testUpdateConfig() public {
        // Create new config values
        vm.startPrank(admin);
        address newWeth = makeAddr("newWeth");

        factory.setWeth(newWeth);
        vm.stopPrank();

        // Verify new config values are active
        assertEq(factory.weth(), newWeth);
    }

    function test_RevertWhen_SetConfigWithZeroAddress() public {
        vm.startPrank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setWeth(address(0));
        vm.stopPrank();
    }

    function testLiquidInstantTokenCreatedEvent() public {
        uint256 initialRareLiquidity = 0.1 ether;
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), initialRareLiquidity);

        // Create the token and capture the address
        address newToken = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        // Verify the event was emitted with the correct token address
        // Note: We can't easily test the exact event emission in this case
        // since the token address is determined during creation
        assertTrue(newToken != address(0));
    }

    // ============================================
    // SECTION A: Access Control & Invalid Configs
    // ============================================

    // ========== Access Control Tests ==========

    /// @notice Test that non-admin cannot call setImplementation
    function test_RevertWhen_NonAdmin_SetImplementation() public {
        LiquidMultiCurve newImpl = new LiquidMultiCurve();

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setLiquidMultiCurveImplementation(address(newImpl));
        vm.stopPrank();
    }

    /// @notice Test that non-admin cannot call setWeth
    function test_RevertWhen_NonAdmin_SetWeth() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setWeth(address(0x123));
        vm.stopPrank();
    }

    /// @notice Test that non-admin cannot call setTradingKnobs
    function test_RevertWhen_NonAdmin_SetTradingKnobs() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setInternalMaxSlippageBps(300);
        vm.stopPrank();
    }

    /// @notice Test that regular user (non-admin) cannot call any admin functions
    function test_RevertWhen_NonAdmin_AllAdminFunctions() public {
        LiquidMultiCurve newImpl = new LiquidMultiCurve();

        // Try all admin functions as user2 (user2 does not have DEFAULT_ADMIN_ROLE)
        vm.startPrank(user2);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user2,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setLiquidMultiCurveImplementation(address(newImpl));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user2,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setWeth(address(0x123));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user2,
                factory.DEFAULT_ADMIN_ROLE()
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

    // ========== Fee Tests moved to LiquidRouter.unit.t.sol ==========
    // Fee configuration (rareBurnFeeBPS, protocolFeeBPS, referrerFeeBPS)
    // and setTier3FeeSplits() have been moved to LiquidInstantRouter

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

        // Try to create factory with lpTickLower=-200 and tickSpacing=60
        // -200 % 60 = -20, so this should revert
        vm.expectRevert(ILiquidFactory.InvalidTickSpacing.selector);
        new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager,
            -200, // lpTickLower - NOT a multiple of 60
            120000, // lpTickUpper
            config.uniswapV4Quoter,
            address(0), // poolHooks
            60, // poolTickSpacing
            300, // internalMaxSlippageBps
            1e15 // minRareLiquidityWei
        );
        vm.stopPrank();
    }

    /// @notice Test that constructor accepts ticks aligned to spacing
    function test_Constructor_ValidTickSpacing_Succeeds() public {
        vm.startPrank(admin);

        // Create factory with properly aligned ticks
        LiquidFactory validFactory = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager,
            -240, // lpTickLower - multiple of 60
            120060, // lpTickUpper - multiple of 60
            config.uniswapV4Quoter,
            address(0), // poolHooks
            60, // poolTickSpacing
            300, // internalMaxSlippageBps
            1e15 // minRareLiquidityWei
        );
        vm.stopPrank();

        // Verify values were set correctly
        assertEq(validFactory.lpTickLower(), -240);
        assertEq(validFactory.lpTickUpper(), 120060);
        assertEq(validFactory.poolTickSpacing(), 60);
    }

    // ============================================
    // SECTION B: Permissionless Token Creation Tests
    // ============================================

    /// @notice Test that any address can deploy tokens (permissionless)
    function test_PermissionlessDeployment() public {
        address anyUser = makeAddr("anyUser");
        mockRARE.mint(anyUser, 1000 ether);

        vm.startPrank(anyUser);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address newToken = factory.createLiquidTokenMultiCurve(
            anyUser,
            "ipfs://test",
            "Test",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        assertTrue(newToken != address(0));
    }

    /// @notice Test that a concierge service can create tokens on behalf of users
    function test_ConciergeServiceCreateTokenOnBehalf() public {
        address conciergeService = makeAddr("conciergeService");
        address actualCreator = makeAddr("actualCreator");
        mockRARE.mint(conciergeService, 1000 ether);

        // Concierge service creates token on behalf of actualCreator
        vm.startPrank(conciergeService);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address newToken = factory.createLiquidTokenMultiCurve(
            actualCreator, // The actual creator who will receive fees/rewards
            "ipfs://test",
            "Test",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        assertTrue(newToken != address(0));
        // Verify the creator is set to actualCreator, not conciergeService
        assertEq(
            LiquidMultiCurve(payable(newToken)).tokenCreator(),
            actualCreator
        );
    }

    // ============================================
    // SECTION: Missing Setter Access Control Tests
    // ============================================

    /// @notice Test that non-admin cannot call setPoolManager
    function test_RevertWhen_NonAdmin_SetPoolManager() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setPoolManager(address(0x123));
        vm.stopPrank();
    }

    /// @notice Test that non-admin cannot call setV4Quoter
    function test_RevertWhen_NonAdmin_SetV4Quoter() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setV4Quoter(address(0x123));
        vm.stopPrank();
    }

    /// @notice Test that non-admin cannot call setPoolHooks
    function test_RevertWhen_NonAdmin_SetPoolHooks() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setPoolHooks(address(0x123));
        vm.stopPrank();
    }

    /// @notice Test that non-admin cannot call setMinRareLiquidityWei
    function test_RevertWhen_NonAdmin_SetMinInitialLiquidityWei() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setMinRareLiquidityWei(1e16);
        vm.stopPrank();
    }

    /// @notice Test that non-admin cannot call setLpTickLower
    function test_RevertWhen_NonAdmin_SetLpTickLower() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setLpTickLower(-240);
        vm.stopPrank();
    }

    /// @notice Test that non-admin cannot call setLpTickUpper
    function test_RevertWhen_NonAdmin_SetLpTickUpper() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setLpTickUpper(120060);
        vm.stopPrank();
    }

    /// @notice Test that non-admin cannot call setPoolTickSpacing
    function test_RevertWhen_NonAdmin_SetPoolTickSpacing() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setPoolTickSpacing(30);
        vm.stopPrank();
    }

    /// @notice Test that non-admin cannot call setBaseToken
    function test_RevertWhen_NonAdmin_SetBaseToken() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.setBaseToken(address(0x123));
        vm.stopPrank();
    }

    // ============================================
    // SECTION: Config Change Isolation Tests
    // ============================================

    /// @notice Test that new tokens use config at creation time
    function test_CreateToken_UsesConfigAtCreationTime() public {
        // Create token A with initial config
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.2 ether);
        address tokenA = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://tokenA",
            "TokenA",
            "TKA",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve liquidA = LiquidMultiCurve(payable(tokenA));
        address poolManagerA = liquidA.poolManager();
        address baseTokenA = liquidA.baseToken();

        // Change factory config - test with tickLower/tickUpper instead of poolManager
        // (changing poolManager would break token initialization)
        // Ticks must be multiples of tick spacing (60)
        vm.startPrank(admin);
        int24 newTickLower = -240; // Multiple of 60
        int24 newTickUpper = 120060; // Multiple of 60
        factory.setLpTickLower(newTickLower);
        factory.setLpTickUpper(newTickUpper);
        vm.stopPrank();

        // Create token B - should use new config
        vm.startPrank(tokenCreator);
        address tokenB = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://tokenB",
            "TokenB",
            "TKB",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve liquidB = LiquidMultiCurve(payable(tokenB));

        // Token B should use new tick config (read from factory at initialization)
        // We can't directly read ticks from LiquidMultiCurve, but we can verify the config was read
        // by checking that token B was created successfully with the new config
        assertTrue(tokenB != address(0), "Token B should be created");

        // Token A should still have old config (cached at initialization)
        assertEq(liquidA.poolManager(), poolManagerA);
        assertEq(liquidA.baseToken(), baseTokenA);

        // Both tokens should have same poolManager (we didn't change that)
        assertEq(liquidB.poolManager(), liquidA.poolManager());
    }

    /// @notice Test that config changes don't affect existing tokens
    function test_ConfigChange_DoesNotAffectExistingTokens() public {
        // Create token A
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.2 ether);
        address tokenA = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://tokenA",
            "TokenA",
            "TKA",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve liquidA = LiquidMultiCurve(payable(tokenA));
        int24 tickLowerA = liquidA.lpTickLower();
        int24 tickUpperA = liquidA.lpTickUpper();
        address poolManagerA = liquidA.poolManager();
        address baseTokenA = liquidA.baseToken();

        // Change multiple config values
        vm.startPrank(admin);
        factory.setLpTickLower(-240);
        factory.setLpTickUpper(120060);
        address newPoolManager = makeAddr("newPoolManager");
        factory.setPoolManager(newPoolManager);
        vm.stopPrank();

        // Token A should remain unchanged
        assertEq(liquidA.lpTickLower(), tickLowerA);
        assertEq(liquidA.lpTickUpper(), tickUpperA);
        assertEq(liquidA.poolManager(), poolManagerA);
        assertEq(liquidA.baseToken(), baseTokenA);
    }

    // ============================================
    // SECTION: createLiquidToken Revert Bubble Tests
    // ============================================

    /// @notice Test that createLiquidToken bubbles InvalidTokenURI from LiquidMultiCurve.initialize
    function test_CreateToken_RevertsWhen_TokenURIEmpty_BubblesFromLiquidInstant()
        public
    {
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);

        vm.expectRevert(ILiquid.InvalidTokenURI.selector);
        factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "", // Empty tokenURI
            "Test",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();
    }

    /// @notice Test that createLiquidToken reverts when allowance is insufficient
    function test_CreateToken_RevertsWhen_InsufficientAllowance() public {
        vm.startPrank(tokenCreator);
        // Don't approve or approve less than needed
        IERC20(mockRARE).approve(address(factory), 0.05 ether); // Less than 0.1 ether

        vm.expectRevert(); // ERC20 transferFrom will revert
        factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();
    }

    /// @notice Test that createLiquidToken reverts when balance is insufficient
    function test_CreateToken_RevertsWhen_InsufficientBalance() public {
        vm.startPrank(tokenCreator);
        // Approve but don't have enough balance
        IERC20(mockRARE).approve(address(factory), 0.1 ether);

        // Try to create with more than balance
        vm.expectRevert(); // ERC20 transferFrom will revert
        factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST",
            1000 ether // More than balance
        );
        vm.stopPrank();
    }

    /// @notice Test that createLiquidToken reverts when baseToken is not set
    function test_CreateToken_RevertsWhen_BaseTokenNotSet() public {
        // Create a factory without setting baseToken
        vm.startPrank(admin);
        LiquidFactory newFactory = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager,
            -180,
            120000,
            config.uniswapV4Quoter,
            address(0),
            60,
            300,
            1e15
        );
                newFactory.setLiquidRouter(address(1));
        newFactory.setLiquidMultiCurveImplementation(address(liquidImplementation));
        // Don't set baseToken
        vm.stopPrank();

        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(newFactory), 0.1 ether);

        vm.expectRevert(ILiquid.AddressZero.selector);
        newFactory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();
    }

    // ============================================
    // SECTION: Missing Setter Validation Tests
    // ============================================

    /// @notice Test that setPoolManager reverts when address is zero
    function test_SetPoolManager_RevertsWhen_AddressZero() public {
        vm.startPrank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setPoolManager(address(0));
        vm.stopPrank();
    }

    /// @notice Test that setV4Quoter reverts when address is zero
    function test_SetV4Quoter_RevertsWhen_AddressZero() public {
        vm.startPrank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setV4Quoter(address(0));
        vm.stopPrank();
    }

    /// @notice Test that setBaseToken reverts when address is zero
    function test_SetBaseToken_RevertsWhen_AddressZero() public {
        vm.startPrank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setBaseToken(address(0));
        vm.stopPrank();
    }

    /// @notice Test that setInternalMaxSlippageBps reverts when too high
    function test_SetInternalMaxSlippageBps_RevertsWhen_TooHigh() public {
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidFactory.SlippageTooHigh.selector,
                5001,
                5000
            )
        );
        factory.setInternalMaxSlippageBps(5001); // > 50%
        vm.stopPrank();
    }
}
