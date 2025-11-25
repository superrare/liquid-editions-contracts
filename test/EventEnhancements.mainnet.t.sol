// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/LiquidFactory.sol";
import "../src/Liquid.sol";
import "../src/RAREBurner.sol";
import "../src/interfaces/ILiquidFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {NetworkConfig} from "../script/NetworkConfig.sol";

// Mock ERC20 for testing
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock RARE", "MRARE") {
        _mint(msg.sender, 1000000 ether);
    }
}

// Mock PoolManager
contract MockPoolManager {
    function unlock(
        bytes calldata /* data */
    ) external pure returns (bytes memory) {
        return "";
    }
}

/// @title EventEnhancements Mainnet Test
/// @notice Integration tests for BurnerDeposit and ConfigDigest events on Base mainnet fork
contract EventEnhancementsMainnetTest is Test {
    // Network configuration
    NetworkConfig.Config public config;

    // Test accounts
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public user1 = makeAddr("user1");
    address public burnAddress = 0x000000000000000000000000000000000000dEaD;

    // Contracts
    LiquidFactory public factory;
    Liquid public liquidImpl;
    Liquid public token;
    RAREBurner public burner;
    MockERC20 public mockRARE;
    MockPoolManager public mockPoolManager;

    // LP tick range (wide range like other tests to support full price discovery)
    int24 constant LP_TICK_LOWER = -180; // Max expensive (after price rises) - multiple of 60
    int24 constant LP_TICK_UPPER = 120000; // Starting point - cheap tokens

    event BurnerDeposit(
        address indexed liquidToken,
        address indexed burnerAccumulator,
        uint256 ethAmount,
        bool depositSuccess
    );

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

    function setUp() public {
        // Fork Base mainnet for realistic testing
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
        vm.deal(user1, 100 ether);
        vm.deal(protocolFeeRecipient, 100 ether);

        // Deploy contracts
        vm.startPrank(admin);

        // Deploy mock contracts
        mockRARE = new MockERC20();
        mockPoolManager = new MockPoolManager();

        // Configure RARE burn with CORRECT pool ID computed from parameters
        uint24 poolFee = 3000;
        int24 tickSpacing = 60;
        address hooks = address(0);

        // Deploy burner accumulator with full configuration
        burner = new RAREBurner(
            admin,
            false, // don't auto-try on deposit
            address(mockRARE), // RARE token
            address(mockPoolManager), // V4 PoolManager
            poolFee, // 0.3% pool fee
            tickSpacing, // tick spacing
            hooks, // no hooks
            burnAddress, // burn address
            address(0), // no quoter
            0, // 0% max slippage (no quoter available)
            true // enabled
        );

        // Deploy Liquid implementation
        liquidImpl = new Liquid();


        // Deploy factory with burner (25% burn fee for integration tests)
        factory = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            address(burner), // RAREBurner
            2500, // rareBurnFeeBPS (25% of remainder)
            3750, // protocolFeeBPS (37.5% of remainder)
            3750, // referrerFeeBPS (37.5% of remainder)
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

        // Set implementation
        factory.setImplementation(address(liquidImpl));

        vm.stopPrank();
    }

    /// @notice Test factory constructor sets config values correctly
    function testFactoryConstructorSetsConfigValues() public {
        // Deploy new factory and verify config values are set correctly
        vm.startPrank(admin);

        LiquidFactory newFactory = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            config.weth,
            config.uniswapV4PoolManager, // V4 PoolManager
            address(burner),
            1000, // rareBurnFeeBPS (10% of remainder)
            4500, // protocolFeeBPS (45% of remainder)
            4500, // referrerFeeBPS (45% of remainder)
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

        vm.stopPrank();

        // Verify config values are set correctly
        assertEq(newFactory.internalMaxSlippageBps(), 300);
        assertEq(newFactory.minOrderSizeWei(), 0.005 ether);
        assertEq(newFactory.rareBurnFeeBPS(), 1000);
        assertEq(newFactory.protocolFeeBPS(), 4500);
        assertEq(newFactory.referrerFeeBPS(), 4500);
    }

    /// @notice Test individual setters update configuration immediately
    function testIndividualSettersUpdateConfig() public {
        vm.startPrank(admin);

        // Test updating slippage
        vm.expectEmit(true, false, false, true);
        emit ILiquidFactory.InternalMaxSlippageBpsUpdated(500);
        factory.setInternalMaxSlippageBps(500);
        assertEq(factory.internalMaxSlippageBps(), 500);

        // Test updating min order size
        vm.expectEmit(true, false, false, true);
        emit ILiquidFactory.MinOrderSizeWeiUpdated(0.01 ether);
        factory.setMinOrderSizeWei(0.01 ether);
        assertEq(factory.minOrderSizeWei(), 0.01 ether);

        vm.stopPrank();
    }

    /// @notice Test BurnerDeposit event emission on real buy
    /// @dev Integration test that triggers actual trade to emit BurnerDeposit event
    function testBurnerDepositEventEmittedOnBuy() public {
        // Create a Liquid token
        vm.prank(tokenCreator);
        address tokenAddr = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST"
        );
        token = Liquid(payable(tokenAddr));

        // Execute buy and expect BurnerDeposit event
        uint256 buyAmount = 0.1 ether;

        // Calculate expected rareBurnFee from primary fees using three-tier system
        uint256 totalFee = (buyAmount * token.TOTAL_FEE_BPS()) / 10_000;
        uint256 creatorFee = (totalFee * token.TOKEN_CREATOR_FEE_BPS()) /
            10_000;
        uint256 remainder = totalFee - creatorFee;
        uint256 expectedPrimaryRareBurnFee = (remainder * 2500) / 10_000; // 25% of remainder (not total)

        // Record burner balance before
        uint256 burnerBalanceBefore = burner.pendingEth();

        // Expect BurnerDeposit event with correct parameters (from primary fees)
        // Note: Secondary rewards (LP fees) may also generate BurnerDeposit events,
        // but amounts are unpredictable, so we only check the primary fee event
        vm.expectEmit(true, true, false, true);
        emit BurnerDeposit(
            address(token),
            address(burner),
            expectedPrimaryRareBurnFee,
            true // depositSuccess
        );

        // Execute buy
        vm.prank(user1);
        token.buy{value: buyAmount}(user1, address(0), 0, 0);

        // Verify ETH was deposited to burner
        // Total includes primary fees + secondary rewards (LP fees), so should be >= expected
        uint256 burnerBalanceAfter = burner.pendingEth();
        uint256 totalBurnFeeReceived = burnerBalanceAfter - burnerBalanceBefore;
        assertGe(
            totalBurnFeeReceived,
            expectedPrimaryRareBurnFee,
            "Burner should receive at least rareBurnFee from primary fees (may include secondary rewards)"
        );
        assertGt(
            burnerBalanceAfter,
            burnerBalanceBefore,
            "Burner balance should increase"
        );
    }

    /// @notice Test BurnerDeposit event with failed deposit
    /// @dev Verifies depositSuccess flag is false when burner deposit fails
    function testBurnerDepositEventWithFailedDeposit() public {
        // Create a token and make initial buy to establish trading
        vm.prank(tokenCreator);
        address tokenAddr = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test2",
            "Test Token 2",
            "TEST2"
        );
        token = Liquid(payable(tokenAddr));

        // First buy to establish the token works normally
        vm.prank(user1);
        token.buy{value: 0.05 ether}(user1, address(0), 0, 0);

        // Now create a new factory config that points to a broken burner
        // We'll use vm.etch to replace burner address with reverting code
        address brokenBurner = address(
            0xbadb00000000000000000000000000000000dEAd
        );

        // Deploy bytecode that always reverts
        vm.etch(brokenBurner, hex"60006000fd"); // PUSH1 0 PUSH1 0 REVERT

        // Update factory to use broken burner
        vm.startPrank(admin);
        factory.setRareBurner(brokenBurner);
        vm.stopPrank();

        // Calculate expected rareBurnFee using three-tier system
        uint256 buyAmount = 0.1 ether;
        uint256 totalFee = (buyAmount * token.TOTAL_FEE_BPS()) / 10_000;
        uint256 creatorFee = (totalFee * token.TOKEN_CREATOR_FEE_BPS()) /
            10_000;
        uint256 remainder = totalFee - creatorFee;
        uint256 rareBurnFee = (remainder * 2500) / 10_000; // 25% of remainder (not total)

        // Record protocol fee recipient balance before (direct ETH balance)
        uint256 protocolBalanceBefore = protocolFeeRecipient.balance;

        // Expect BurnerDeposit event with depositSuccess = false
        vm.expectEmit(true, true, false, true);
        emit BurnerDeposit(
            address(token),
            brokenBurner,
            rareBurnFee,
            false // depositSuccess = false
        );

        // Execute buy - should succeed even though burner deposit fails
        vm.prank(user1);
        token.buy{value: buyAmount}(user1, address(0), 0, 0);

        // Verify ETH fell back to protocol fee recipient via direct transfer
        // When burner deposit fails, rareBurnFee is added to protocolFee and sent directly
        uint256 protocolBalanceAfter = protocolFeeRecipient.balance;
        assertGt(
            protocolBalanceAfter,
            protocolBalanceBefore,
            "Protocol should receive fallback ETH via direct transfer"
        );

        // The fallback should include the rareBurnFee that couldn't be deposited
        // (Note: exact amount checking would require detailed fee calculation)
    }

    /// @notice Test individual setters update values correctly
    function testIndividualSettersUpdateValues() public {
        // Test that individual setters update values correctly
        vm.startPrank(admin);

        // Update slippage
        factory.setInternalMaxSlippageBps(400);
        assertEq(factory.internalMaxSlippageBps(), 400);

        // Update min order size
        factory.setMinOrderSizeWei(0.02 ether);
        assertEq(factory.minOrderSizeWei(), 0.02 ether);

        vm.stopPrank();
    }

    /// @notice Test that configuration changes take effect immediately
    function testConfigChangesTakeEffectImmediately() public {
        // Create a token
        vm.prank(tokenCreator);
        address tokenAddr = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test3",
            "Test Token 3",
            "TEST3"
        );
        Liquid testToken = Liquid(payable(tokenAddr));

        // Update min order size
        vm.startPrank(admin);
        factory.setMinOrderSizeWei(0.02 ether);
        vm.stopPrank();

        // Try to buy with less than new minimum - should fail
        vm.prank(user1);
        vm.expectRevert(ILiquid.EthAmountTooSmall.selector);
        testToken.buy{value: 0.01 ether}(user1, address(0), 0, 0);

        // Try to buy with more than new minimum - should succeed
        vm.prank(user1);
        testToken.buy{value: 0.05 ether}(user1, address(0), 0, 0);
    }
}
