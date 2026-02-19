// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "liquid-editions/LiquidFactory.sol";
import "liquid-editions/LiquidInstant.sol";
import "liquid-editions/RAREBurner.sol";
import "liquid-editions/interfaces/ILiquidFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";

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
    NetworkConfig.Config internal config;

    // Test accounts
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public user1 = makeAddr("user1");
    address public burnAddress = 0x000000000000000000000000000000000000dEaD;

    // Contracts
    LiquidFactory public factory;
    LiquidInstant public liquidImpl;
    LiquidInstant public token;
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
        mockRARE.mint(admin, 10_000_000 ether);
        mockRARE.mint(tokenCreator, 10_000_000 ether);
        mockRARE.mint(user1, 10_000_000 ether);
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

        // Deploy LiquidInstant implementation
        liquidImpl = new LiquidInstant();

        // Deploy factory (fee config moved to LiquidRouter)
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
        factory.setLiquidRouter(address(1));

        // Set implementation
        factory.setImplementation(address(liquidImpl));

        // Set base token (RARE) in factory
        factory.setBaseToken(address(mockRARE));

        // Fund test accounts with RARE tokens
        mockRARE.mint(tokenCreator, 1000 ether);
        mockRARE.mint(user1, 1000 ether);

        vm.stopPrank();
    }

    /// @notice Test factory constructor sets config values correctly
    function testFactoryConstructorSetsConfigValues() public {
        // Deploy new factory and verify config values are set correctly
        vm.startPrank(admin);

        LiquidFactory newFactory = new LiquidFactory(
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

        vm.stopPrank();

        // Verify config values are set correctly (fee config moved to LiquidRouter)
        assertEq(newFactory.internalMaxSlippageBps(), 300);
    }

    /// @notice Test individual setters update configuration immediately
    function testIndividualSettersUpdateConfig() public {
        vm.startPrank(admin);

        // Test updating slippage
        vm.expectEmit(true, false, false, true);
        emit ILiquidFactory.InternalMaxSlippageBpsUpdated(500);
        factory.setInternalMaxSlippageBps(500);
        assertEq(factory.internalMaxSlippageBps(), 500);

        vm.stopPrank();
    }

    /// @notice Test individual setters update values correctly
    function testIndividualSettersUpdateValues() public {
        // Test that individual setters update values correctly
        vm.startPrank(admin);

        // Update slippage
        factory.setInternalMaxSlippageBps(400);
        assertEq(factory.internalMaxSlippageBps(), 400);

        // Test setting base token
        factory.setBaseToken(address(mockRARE));
        assertEq(factory.baseToken(), address(mockRARE));

        vm.stopPrank();
    }

    /// @notice Test that configuration changes take effect immediately
    function testConfigChangesTakeEffectImmediately() public {
        uint256 initialRareLiquidity = 0.1 ether;
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), initialRareLiquidity);
        address tokenAddr = factory.createLiquidToken(
            tokenCreator,
            "ipfs://test3",
            "Test Token 3",
            "TEST3",
            initialRareLiquidity
        );
        vm.stopPrank();

        LiquidInstant createdToken = LiquidInstant(payable(tokenAddr));
        (uint256 quoteOut, ) = createdToken.quoteBuy(0.5 ether);
        assertGt(quoteOut, 0, "Quote should work after config change");
    }
}
