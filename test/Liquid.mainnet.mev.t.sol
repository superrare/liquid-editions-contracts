// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidFactory} from "../src/LiquidFactory.sol";
import {Liquid} from "../src/Liquid.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {ILiquidFactory} from "../src/interfaces/ILiquidFactory.sol";
import {NetworkConfig} from "../script/config/NetworkConfig.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {MockRARE} from "./helpers/MockRARE.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock burner for testing
contract MockBurner {
    receive() external payable {}

    function depositForBurn() external payable {}
}

/**
 * @title Liquid MEV Protection Tests
 * @notice Tests to verify MEV protection on reward conversions
 * @dev Quoter-based slippage protection is used for LP fee conversions (LIQUID → WETH).
 *      Initialize auto-buy intentionally has NO slippage protection (atomic transaction, no MEV risk).
 */
contract Liquid_MEV_Protection_Test is Test {
    using StateLibrary for IPoolManager;

    // Network configuration
    NetworkConfig.Config public config;

    address admin = makeAddr("admin");
    address creator = makeAddr("creator");
    address protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address user = makeAddr("user");

    LiquidFactory factory;
    Liquid token;
    MockRARE public mockRARE;

    function setUp() public {
        // Fork Base mainnet at a recent block
        string memory forkUrl = vm.envOr(
            "FORK_URL",
            string("https://mainnet.base.org")
        );
        vm.createSelectFork(forkUrl, 37520000);

        // Get network configuration (Base mainnet chain ID = 8453)
        config = NetworkConfig.getConfig(block.chainid);

        vm.deal(admin, 100 ether);
        vm.deal(creator, 50 ether);
        vm.deal(user, 50 ether);
        vm.deal(protocolFeeRecipient, 0);

        // Deploy MockRARE and fund accounts
        mockRARE = new MockRARE();
        mockRARE.mint(admin, 10_000_000 ether);
        mockRARE.mint(creator, 10_000_000 ether);
        mockRARE.mint(user, 10_000_000 ether);

        vm.startPrank(admin);
        MockBurner mockBurner = new MockBurner();

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
        factory.setImplementation(address(new Liquid()));

        // Set base token to MockRARE
        factory.setBaseToken(address(mockRARE));

        vm.stopPrank();
    }

    /**
     * @notice Test that configs without quoter are rejected (security requirement)
     * @dev Quoter is mandatory to protect reward conversions (LIQUID → WETH) from MEV drainage
     */
    function test_revertWhen_ConfigWithoutQuoter() public {
        // Attempt to set quoter to zero address
        vm.startPrank(admin);
        // Should revert because quoter is required
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setV4Quoter(address(0));
        vm.stopPrank();
    }
}
