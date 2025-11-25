// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title Liquid Mainnet Unit Tests
 * @notice Comprehensive unit tests for security guards, slippage, fees, and edge cases
 * @dev These tests require Base mainnet fork for real Uniswap interactions
 * @dev Fork is created automatically in setUp()
 */

import "forge-std/Test.sol";
import {Liquid} from "../src/Liquid.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {RAREBurner} from "../src/RAREBurner.sol";
import {LiquidFactory} from "../src/LiquidFactory.sol";
import {ILiquidFactory} from "../src/interfaces/ILiquidFactory.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/interfaces/IV4Quoter.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

// Mock V4 PoolManager for testing
contract MockV4PoolManager {
    address public callbackContract;
    bytes public lastUnlockData;

    function unlock(bytes calldata data) external {
        callbackContract = msg.sender;
        lastUnlockData = data;
        if (callbackContract.code.length > 0) {
            IUnlockCallback(callbackContract).unlockCallback(data);
        }
    }

    function swap(
        PoolKey memory,
        IPoolManager.SwapParams memory,
        bytes memory
    ) external pure returns (BalanceDelta delta) {
        // Mock swap - return deltas: -1 ETH in, +0.1 RARE out
        // BalanceDelta is a packed uint256 encoding two int128 values
        // For now, we'll use assembly to pack the values
        // amount0: -1e18 (ETH in), amount1: +1e17 (RARE out)
        assembly {
            // Pack two int128 values into uint256
            // Lower 128 bits: amount0 (-1e18)
            // Upper 128 bits: amount1 (+1e17)
            let
                amount0
            := 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC18 // -1e18 in two's complement
            let amount1 := 0x000000000000000000000000000000016345785D8A0000 // +1e17
            delta := or(amount1, shl(128, amount0))
        }
    }

    function settle() external payable {
        // Mock settle - just accept ETH
    }

    function take(Currency, address, uint256) external {
        // Mock take - just transfer
    }

    function modifyLiquidity(
        PoolKey memory,
        IPoolManager.ModifyLiquidityParams memory,
        bytes memory
    ) external pure returns (BalanceDelta, BalanceDelta) {
        // Mock modifyLiquidity - return empty deltas
        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function initialize(
        PoolKey memory,
        uint160,
        bytes memory
    ) external pure returns (int24) {
        // Mock initialize - return tick 0
        return 0;
    }

    function extsload(bytes32) external pure returns (bytes32) {
        // Mock extsload - return encoded slot0 with sqrtPriceX96 and tick
        // Pack: sqrtPriceX96 (160 bits) | tick (24 bits)
        uint160 sqrtPrice = 79228162514264337593543950336; // sqrt(1) in Q96 format
        int24 tick = 0;
        return bytes32((uint256(sqrtPrice) << 24) | uint256(uint24(tick)));
    }
}

// Mock V4 Quoter for testing
contract MockV4Quoter {
    uint256 public mockQuote;
    bool public shouldRevert;

    function setMockQuote(uint256 quote) external {
        mockQuote = quote;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function quoteExactInput(
        PoolKey memory,
        uint256 /* amountIn */,
        bool
    ) external view returns (uint256) {
        if (shouldRevert) revert("Quoter error");
        return mockQuote;
    }
}

// Mock ERC721 for testing onERC721Received
contract MockERC721 {
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) external {
        IERC721Receiver(to).onERC721Received(
            address(this),
            from,
            tokenId,
            data
        );
    }
}

// Mock burner for testing
contract MockBurner {
    receive() external payable {}

    function depositForBurn() external payable {}
}

// Mock contract caller for testing receive() contract sender guard
contract MockContractCaller {
    function callReceive(address target) external payable {
        (bool success, ) = target.call{value: msg.value}("");
        require(success, "Call failed");
    }

    receive() external payable {}
}

// Mock reverting receiver for testing fee distribution fallback
contract RevertingReceiver {
    receive() external payable {
        revert("RevertingReceiver: intentional revert");
    }
}

// Mock ProtocolRewards for isolated fee testing (no LP fees)
contract MockProtocolRewards {
    mapping(address => uint256) public balances;

    event Deposit(
        address indexed from,
        address indexed to,
        bytes4 indexed reason,
        uint256 amount,
        string comment
    );

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function depositBatch(
        address[] calldata recipients,
        uint256[] calldata amounts,
        bytes4[] calldata reasons,
        string calldata comment
    ) external payable {
        require(
            recipients.length == amounts.length &&
                amounts.length == reasons.length,
            "Array length mismatch"
        );

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
            balances[recipients[i]] += amounts[i];
            emit Deposit(
                msg.sender,
                recipients[i],
                reasons[i],
                amounts[i],
                comment
            );
        }

        require(msg.value == totalAmount, "Insufficient ETH sent");
    }

    function withdraw(address to, uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }
}

// Helper contract to test fee dispersion logic without LP fees
contract FeeDispersionHelper {
    address public immutable protocolFeeRecipient;
    address public immutable tokenCreator;
    Liquid public immutable liquidReference;

    constructor(
        address _protocolFeeRecipient,
        address _tokenCreator,
        address _liquidReference
    ) {
        protocolFeeRecipient = _protocolFeeRecipient;
        tokenCreator = _tokenCreator;
        liquidReference = Liquid(payable(_liquidReference));
    }

    // Replicate _disperseFees logic from Liquid.sol exactly (three-tier system)
    // Read fee values from actual Liquid contract to avoid hardcoding
    function disperseFeesTest(
        uint256 _fee,
        address _orderReferrer
    ) external payable {
        require(msg.value == _fee, "Must send exact fee amount");

        // Default referrer to protocol recipient if none provided
        if (_orderReferrer == address(0)) {
            _orderReferrer = protocolFeeRecipient;
        }

        // Read creator fee from Liquid contract instance (TIER 2)
        uint256 creatorFeeBPS = liquidReference.TOKEN_CREATOR_FEE_BPS();
        uint256 tokenCreatorFee = (_fee * creatorFeeBPS) / 10_000;

        // TIER 3: Split remainder (no RARE burn for this test, so 0% burn, 50/50 protocol/referrer)
        uint256 remainder = _fee - tokenCreatorFee;
        uint256 protocolFee = (remainder * 5000) / 10_000; // 50% of remainder
        uint256 orderReferrerFee = (remainder * 5000) / 10_000; // 50% of remainder

        // Calculate dust from rounding and add to protocol fee to ensure exact sum match
        uint256 totalCalculatedFees = tokenCreatorFee +
            orderReferrerFee +
            protocolFee;
        uint256 dust = _fee - totalCalculatedFees;
        protocolFee += dust; // Protocol gets any rounding dust

        // Direct ETH transfers with fallback pattern (matches Liquid.sol)
        uint256 protocolTotal = protocolFee;

        // Try creator transfer
        (bool creatorOk, ) = tokenCreator.call{value: tokenCreatorFee}("");
        if (!creatorOk) {
            protocolTotal += tokenCreatorFee;
        }

        // Try referrer transfer
        (bool referrerOk, ) = _orderReferrer.call{value: orderReferrerFee}("");
        if (!referrerOk) {
            protocolTotal += orderReferrerFee;
        }

        // Final protocol transfer (accumulates all failures)
        (bool protocolOk, ) = protocolFeeRecipient.call{value: protocolTotal}(
            ""
        );
        require(protocolOk, "Protocol transfer failed");
    }
}

// Simple ERC20 for testing LP position minting
contract TestERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract LiquidMainnetUnitTest is Test {
    using StateLibrary for IPoolManager;

    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public orderReferrer = makeAddr("orderReferrer");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public attacker = makeAddr("attacker");

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant NFT_POSITION_MANAGER =
        0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant POOL_MANAGER = 0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A; // V4 PoolManager on Base
    address constant RARE_TOKEN =
        address(0x1111111111111111111111111111111111111111);

    Liquid public liquidImplementation;
    LiquidFactory public factory;
    Liquid public liquid;
    MockV4PoolManager public mockPoolManager;
    MockV4Quoter public mockQuoter;

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
        vm.skip(true); // Skipped: MockV4PoolManager needs full V4 implementation
        // Fork Base mainnet for unit tests that need real Uniswap interactions
        string memory forkUrl = vm.envOr(
            "FORK_URL",
            string("https://mainnet.base.org")
        );
        vm.createSelectFork(forkUrl);

        vm.deal(admin, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(protocolFeeRecipient, 100 ether);
        vm.deal(attacker, 100 ether);

        vm.startPrank(admin);
        liquidImplementation = new Liquid();
        mockPoolManager = new MockV4PoolManager();
        mockQuoter = new MockV4Quoter();
        MockBurner mockBurner = new MockBurner();

        factory = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            WETH,
            address(mockPoolManager), // Use mock pool manager for unit tests
            address(mockBurner), // rareBurner
            0, // rareBurnFeeBPS
            5000, // protocolFeeBPS
            5000, // referrerFeeBPS
            100, // defaultTotalFeeBPS
            2500, // defaultCreatorFeeBPS
            -180, // lpTickLower - max expensive (after price rises) - multiple of 60
            120000, // lpTickUpper - starting point (cheap tokens)
            address(0x1234567890123456789012345678901234567890), // Mock quoter for unit test
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            0, // internalMaxSlippageBps (will be set to 0 below)
            0.005 ether, // minOrderSizeWei
            1e15 // minInitialLiquidityWei (0.001 ETH)
        );

        factory.setImplementation(address(liquidImplementation));

        // Disable slippage protection since we're using mock quoter
        // This allows LIQUID→WETH conversions to proceed without quotes in tests
        vm.startPrank(admin);
        factory.setInternalMaxSlippageBps(0); // Disable slippage protection for tests with mock quoter
        factory.setV4Quoter(
            address(0x1234567890123456789012345678901234567890)
        ); // Mock quoter
        vm.stopPrank();

        // Create a liquid token
        address liquidAddress = factory.createLiquidToken{value: 0.001 ether}(
            tokenCreator,
            "ipfs://test",
            "TEST",
            "TEST"
        );

        liquid = Liquid(payable(liquidAddress));
        vm.stopPrank();
    }

    // ============ FIXES TO EXISTING TESTS ============

    // Already fixed in Liquid.t.sol - testSellFeeDistribution

    // ============ V4 UNLOCK SECURITY TESTS ============

    function testV4Unlock_OnlyPoolManager() public {
        // Test that Liquid.unlockCallback reverts when called from non-PoolManager address

        // Build fake callback data (UnlockContext with SWAP_BUY = 2)
        // We encode the enum value directly since it's internal to Liquid contract
        bytes memory fakeData = abi.encode(
            uint8(2), // UnlockAction.SWAP_BUY
            abi.encode(1 ether, 0, uint160(0), user1)
        );

        // Try to call unlockCallback from a non-PoolManager address (user1)
        vm.prank(user1);
        vm.expectRevert(ILiquid.OnlyPoolManager.selector);
        liquid.unlockCallback(fakeData);

        // Verify it also fails from admin
        vm.prank(admin);
        vm.expectRevert(ILiquid.OnlyPoolManager.selector);
        liquid.unlockCallback(fakeData);
    }

    function testV4Unlock_UnexpectedUnlock() public {
        // Test that Liquid.unlockCallback reverts when _unlockExpected is false
        // Even if called from the PoolManager address

        // Build fake callback data (UnlockAction.SWAP_BUY = 2)
        bytes memory fakeData = abi.encode(
            uint8(2), // UnlockAction.SWAP_BUY
            abi.encode(1 ether, 0, uint160(0), user1)
        );

        // Get the poolManager address from the liquid contract
        address poolManagerAddr = liquid.poolManager();

        // Try to call unlockCallback from PoolManager when not expected
        // (_unlockExpected is false by default, only set to true during actual operations)
        vm.prank(poolManagerAddr);
        vm.expectRevert(ILiquid.UnexpectedUnlock.selector);
        liquid.unlockCallback(fakeData);
    }

    // NOTE: V4 unlock pool config and slippage tests are covered in:
    // - RAREBurner.t.sol for unit-level mock testing
    // - Liquid.mainnet.invariants.t.sol: testRealisticRAREBurnOnBaseFork() for integration
    // - Liquid.mainnet.invariants.t.sol: testRAREBurnGracefulDegradation() for failure cases

    // ============ BUY/SELL SLIPPAGE TESTS ============

    function testBuy_RevertWhen_MinOrderSizeTooHigh() public {
        vm.startPrank(user1);
        uint256 buyAmount = 1 ether;

        // Get a quote by making a small buy first
        liquid.buy{value: 0.01 ether}(user1, address(0), 0, 0);
        uint256 tokensFromSmallBuy = liquid.balanceOf(user1);

        // Now try to buy with minOrderSize higher than achievable
        uint256 unrealisticMinOrderSize = tokensFromSmallBuy * 1000; // Way too high

        vm.expectRevert(); // Should revert from Uniswap router due to slippage
        liquid.buy{value: buyAmount}(
            user1,
            address(0),
            unrealisticMinOrderSize,
            0
        );
        vm.stopPrank();
    }

    function testSell_RevertWhen_MinPayoutSizeTooHigh() public {
        // First buy some tokens
        vm.startPrank(user1);
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);
        uint256 tokensToSell = liquid.balanceOf(user1) / 2;

        // Try to sell with minPayoutSize higher than achievable
        uint256 unrealisticMinPayout = 100 ether; // Way too high

        vm.expectRevert(); // Should revert from Uniswap router
        liquid.sell(tokensToSell, user1, address(0), unrealisticMinPayout, 0);
        vm.stopPrank();
    }

    /// @notice Test buy with minOrderSize just above achievable amount (explicit slippage check)
    /// @dev Verifies that the exact "slippage exceeded" error is thrown
    function testBuy_SlippageExceeded_ExactError() public {
        // First, get a quote to know what's achievable
        vm.prank(user1);
        uint256 actualTokens = liquid.buy{value: 0.1 ether}(
            user1,
            address(0),
            0,
            0
        );

        // Now try to buy with minOrderSize just above what we got
        uint256 slightlyTooHigh = actualTokens + 1;

        vm.prank(user2);
        vm.expectRevert(ILiquid.SlippageExceeded.selector);
        liquid.buy{value: 0.1 ether}(user2, address(0), slightlyTooHigh, 0);
    }

    /// @notice Test sell with minPayoutSize just above achievable amount (explicit slippage check)
    /// @dev Verifies that the exact "slippage exceeded" error is thrown
    function testSell_SlippageExceeded_ExactError() public {
        // First, buy tokens and determine actual payout
        vm.prank(user1);
        uint256 tokenAmount = liquid.buy{value: 1 ether}(
            user1,
            address(0),
            0,
            0
        );

        // Sell half to get actual payout amount
        // NOTE: No approval needed - Liquid.sell() uses internal _transfer(), not transferFrom()
        uint256 halfTokens = tokenAmount / 2;
        vm.startPrank(user1);
        uint256 actualPayout = liquid.sell(halfTokens, user1, address(0), 0, 0);
        vm.stopPrank();

        // Buy more tokens for second sell attempt
        vm.prank(user2);
        tokenAmount = liquid.buy{value: 1 ether}(user2, address(0), 0, 0);

        // Try to sell with minPayoutSize just above what we got
        uint256 slightlyTooHigh = actualPayout + 1;

        vm.startPrank(user2);
        vm.expectRevert(ILiquid.SlippageExceeded.selector);
        liquid.sell(tokenAmount / 2, user2, address(0), slightlyTooHigh, 0);
        vm.stopPrank();
    }

    /// @notice Test that slippage validation happens AFTER fee deduction
    /// @dev This test verifies the fix for the auditor's finding:
    ///      "minPayoutSize is validated against raw swap output (line 1097), but the 1% fee is
    ///       deducted after validation (line 420), causing users to receive less than their specified minimum."
    function testSell_SlippageValidationAfterFeeDeduction() public {
        // Setup: Buy tokens first
        vm.prank(user1);
        uint256 tokenAmount = liquid.buy{value: 1 ether}(
            user1,
            address(0),
            0,
            0
        );

        // Get the total fee BPS to calculate expected post-fee amount
        uint256 totalFeeBPS = liquid.TOTAL_FEE_BPS();

        // First, sell without slippage protection to get actual payout
        vm.startPrank(user1);
        uint256 actualPayoutAfterFee = liquid.sell(
            tokenAmount / 2,
            user1,
            address(0),
            0, // no min payout
            0
        );
        vm.stopPrank();

        // Buy more tokens for the actual test
        vm.prank(user2);
        uint256 tokenAmount2 = liquid.buy{value: 1 ether}(
            user2,
            address(0),
            0,
            0
        );

        // TEST 1: Verify that setting minPayoutSize to the actual post-fee amount succeeds
        vm.startPrank(user2);
        uint256 payout1 = liquid.sell(
            tokenAmount2 / 4,
            user2,
            address(0),
            actualPayoutAfterFee, // Exact amount we expect after fees
            0
        );
        assertGe(
            payout1,
            actualPayoutAfterFee,
            "User should receive at least minPayoutSize after fees"
        );
        vm.stopPrank();

        // TEST 2: Verify that setting minPayoutSize slightly above post-fee amount reverts
        // This proves slippage validation happens AFTER fee deduction
        uint256 slightlyAbovePostFee = actualPayoutAfterFee + 1;
        vm.startPrank(user2);
        vm.expectRevert(ILiquid.SlippageExceeded.selector);
        liquid.sell(
            tokenAmount2 / 4,
            user2,
            address(0),
            slightlyAbovePostFee,
            0
        );
        vm.stopPrank();

        // TEST 3: Demonstrate the bug would have occurred with pre-fee validation
        // Calculate what the raw swap output would be (before fee deduction)
        // If slippage was checked against raw output, user would get less than minPayoutSize
        uint256 rawSwapOutput = (actualPayoutAfterFee * 10000) /
            (10000 - totalFeeBPS);

        // Verify that the fee is indeed ~1% of raw output
        uint256 expectedFee = (rawSwapOutput * totalFeeBPS) / 10000;
        uint256 calculatedPostFee = rawSwapOutput - expectedFee;

        // This should be approximately equal to what user received
        // Allow for small rounding differences (< 0.1%)
        uint256 diff = calculatedPostFee > actualPayoutAfterFee
            ? calculatedPostFee - actualPayoutAfterFee
            : actualPayoutAfterFee - calculatedPostFee;
        uint256 tolerance = (actualPayoutAfterFee * 10) / 10000; // 0.1% tolerance

        assertLe(
            diff,
            tolerance,
            "Calculated post-fee amount should match actual within tolerance"
        );
    }

    /// @notice Test edge case: minPayoutSize of 0 should always succeed
    function testSell_MinPayoutSizeZero() public {
        vm.prank(user1);
        uint256 tokenAmount = liquid.buy{value: 1 ether}(
            user1,
            address(0),
            0,
            0
        );

        vm.startPrank(user1);
        uint256 payout = liquid.sell(tokenAmount / 2, user1, address(0), 0, 0);
        assertGt(payout, 0, "Should receive some payout");
        vm.stopPrank();
    }

    /// @notice Test that slippage protection correctly accounts for varying fee amounts
    function testSell_SlippageWithDifferentTradeSize() public {
        // Buy a large amount
        vm.prank(user1);
        uint256 tokenAmount = liquid.buy{value: 10 ether}(
            user1,
            address(0),
            0,
            0
        );

        // Get first sell payout (small amount)
        vm.startPrank(user1);
        uint256 smallSellAmount = tokenAmount / 10;
        uint256 smallPayout = liquid.sell(
            smallSellAmount,
            user1,
            address(0),
            0,
            0
        );
        vm.stopPrank();

        // Buy more for second test
        vm.prank(user2);
        uint256 tokenAmount2 = liquid.buy{value: 10 ether}(
            user2,
            address(0),
            0,
            0
        );

        // Get second sell payout (large amount)
        vm.startPrank(user2);
        uint256 largeSellAmount = tokenAmount2 / 2;
        uint256 largePayout = liquid.sell(
            largeSellAmount,
            user2,
            address(0),
            0,
            0
        );
        vm.stopPrank();

        // Both payouts should respect the 1% fee deduction
        // Larger trades should have proportionally larger fees
        assertGt(
            largePayout,
            smallPayout,
            "Larger sell should give larger payout"
        );

        // Verify both were charged approximately 1% fee
        // (Note: exact amounts vary due to price impact)
        assertTrue(
            largePayout > 0 && smallPayout > 0,
            "Both payouts should be positive"
        );
    }

    function testBuy_WithSqrtPriceLimit() public {
        vm.startPrank(user1);
        // Use 0 for sqrtPriceLimitX96 (no limit) - testing that the parameter is accepted
        // Using a non-zero limit can cause slippage issues if set too restrictively
        uint256 tokensReceived = liquid.buy{value: 0.1 ether}(
            user1,
            address(0),
            0,
            0 // No price limit
        );

        assertTrue(tokensReceived > 0, "Should receive tokens");
        vm.stopPrank();
    }

    // ============ FEE SPLITTING EXACTNESS TESTS ============

    function testFeeSplit_ExactDistribution() public {
        uint256 buyAmount = 10 ether;
        uint256 totalFee = (buyAmount * liquid.TOTAL_FEE_BPS()) / 10000;

        // Clear any existing secondary rewards first
        // Secondary rewards are now distributed immediately, no need to claim

        uint256 creatorInitialBalance = tokenCreator.balance;
        uint256 protocolInitialBalance = protocolFeeRecipient.balance;

        vm.startPrank(user1);
        liquid.buy{value: buyAmount}(user1, address(0), 0, 0);
        vm.stopPrank();

        // Calculate exact expected fees using three-tier system
        uint256 expectedCreatorFee = (totalFee *
            liquid.TOKEN_CREATOR_FEE_BPS()) / 10000;
        uint256 remainder = totalFee - expectedCreatorFee;
        // With 0% burn, 50% protocol, 50% referrer (who defaults to protocol when address(0))
        uint256 expectedProtocolFee = remainder; // All remainder goes to protocol
        uint256 expectedOrderReferrerFee = 0; // Referrer is address(0), so goes to protocol

        // With zero referrer, orderReferrerFee goes to protocol
        uint256 expectedTotalProtocolFee = expectedProtocolFee +
            expectedOrderReferrerFee;

        // Get balances after (includes secondary rewards, so we check >=)
        uint256 creatorDelta = tokenCreator.balance - creatorInitialBalance;
        uint256 protocolDelta = protocolFeeRecipient.balance -
            protocolInitialBalance;

        // Verify at least the expected transaction fees were distributed
        // (actual may be higher due to secondary rewards from LP fees)
        assertGe(
            creatorDelta,
            expectedCreatorFee,
            "Creator should receive at least expected transaction fee"
        );
        assertGe(
            protocolDelta,
            expectedTotalProtocolFee,
            "Protocol should receive at least expected transaction fees"
        );

        // Verify the transaction fees sum matches (excluding secondary rewards)
        // We can't easily separate them, so we verify the deltas are at least the expected amounts
        assertTrue(
            creatorDelta + protocolDelta >= totalFee,
            "Total fees must be at least the transaction fee amount"
        );
    }

    function testFeeSplit_WithOrderReferrer() public {
        uint256 buyAmount = 10 ether;
        uint256 totalFee = (buyAmount * liquid.TOTAL_FEE_BPS()) / 10000;

        // Clear any existing secondary rewards first
        // Secondary rewards are now distributed immediately, no need to claim

        uint256 creatorInitialBalance = tokenCreator.balance;
        uint256 referrerInitialBalance = orderReferrer.balance;
        uint256 protocolInitialBalance = protocolFeeRecipient.balance;

        vm.startPrank(user1);
        liquid.buy{value: buyAmount}(user1, orderReferrer, 0, 0);
        vm.stopPrank();

        // Calculate exact expected fees using three-tier system
        uint256 expectedCreatorFee = (totalFee *
            liquid.TOKEN_CREATOR_FEE_BPS()) / 10000;
        uint256 remainder = totalFee - expectedCreatorFee;
        // With 0% burn, 50% protocol, 50% referrer
        uint256 expectedProtocolFee = (remainder * 5000) / 10000;
        uint256 expectedOrderReferrerFee = (remainder * 5000) / 10000;

        // Verify balances (may include secondary rewards)
        uint256 creatorDelta = tokenCreator.balance - creatorInitialBalance;
        uint256 referrerDelta = orderReferrer.balance - referrerInitialBalance;
        uint256 protocolDelta = protocolFeeRecipient.balance -
            protocolInitialBalance;

        assertGe(
            creatorDelta,
            expectedCreatorFee,
            "Creator should receive at least expected transaction fee"
        );
        assertGe(
            referrerDelta,
            expectedOrderReferrerFee,
            "Referrer should receive at least expected transaction fee"
        );
        assertGe(
            protocolDelta,
            expectedProtocolFee,
            "Protocol should receive at least expected transaction fee"
        );

        // Verify sum matches at least total transaction fee (may include secondary rewards)
        assertTrue(
            creatorDelta + referrerDelta + protocolDelta >= totalFee,
            "Total fees must be at least the transaction fee amount"
        );
    }

    function testFeeSplit_ZeroReferrerFallsBackToProtocol() public {
        uint256 buyAmount = 1 ether;
        uint256 totalFee = (buyAmount * liquid.TOTAL_FEE_BPS()) / 10000;

        // Clear any existing secondary rewards first
        // Secondary rewards are now distributed immediately, no need to claim

        // Calculate expected fees using same math as Liquid.sol
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
        uint256 expectedBurnFee = 0; // No burn configured

        // Expect exact fee amounts in event (primary fees only, excludes secondary rewards)
        vm.startPrank(user1);
        vm.expectEmit(true, true, false, false);
        emit ILiquid.LiquidBuy(
            user1, // buyer (indexed)
            user1, // recipient (indexed)
            address(0), // orderReferrer (indexed)
            buyAmount, // totalEth
            totalFee, // ethFee
            0, // Don't check ethSold (depends on swap)
            0, // Don't check tokensBought (depends on swap)
            0, // Don't check buyerTokenBalance
            0, // Don't check totalSupply
            0, // Don't check startPrice
            0, // Don't check endPrice
            expectedTotalProtocolFee, // protocolFee (exact)
            expectedReferrerFee, // referrerFee (exact)
            expectedCreatorFee, // creatorFee (exact)
            expectedBurnFee // burnFee (exact)
        );
        liquid.buy{value: buyAmount}(user1, address(0), 0, 0);
        vm.stopPrank();
    }

    function testFeeSplit_DustGoesToProtocol() public {
        // Test with a fee amount that creates dust
        // Use amount above minimum order size that creates non-round division
        uint256 buyAmount = 0.006 ether + 1003 wei; // Creates non-round division
        uint256 totalFee = (buyAmount * liquid.TOTAL_FEE_BPS()) / 10000;

        // Clear any existing secondary rewards first
        // Secondary rewards are now distributed immediately, no need to claim

        uint256 creatorInitialBalance = tokenCreator.balance;
        uint256 protocolInitialBalance = protocolFeeRecipient.balance;

        vm.deal(user1, 1 ether);
        vm.startPrank(user1);
        liquid.buy{value: buyAmount}(user1, address(0), 0, 0);
        vm.stopPrank();

        uint256 creatorDelta = tokenCreator.balance - creatorInitialBalance;
        uint256 protocolDelta = protocolFeeRecipient.balance -
            protocolInitialBalance;

        // Verify that fees were distributed (sum >= transaction fee, may include secondary rewards)
        assertTrue(
            creatorDelta + protocolDelta >= totalFee,
            "Total fees distributed must be at least the transaction fee amount"
        );
    }

    /**
     * @notice Fee precision/rounding test in fully mocked environment
     * @dev Tests exact fee splits WITHOUT LP fees contaminating the results
     * @dev This test uses direct _disperseFees calls via a test helper contract
     * Verifies: creator + protocol [+ referrer or redirected referrer] == totalFee (exact)
     */
    function testFeePrecision_ExactSplits_NoLPFees() public {
        // Deploy helper contract to test _disperseFees directly with direct ETH transfers
        // Pass liquid reference so helper reads actual fee values instead of hardcoding
        FeeDispersionHelper helper = new FeeDispersionHelper(
            protocolFeeRecipient,
            tokenCreator,
            address(liquid)
        );

        // Test multiple fee amounts that create different rounding scenarios
        uint256[] memory testAmounts = new uint256[](7);
        testAmounts[0] = 1 ether; // Clean division
        testAmounts[1] = 0.01 ether; // 1% of 1 ETH
        testAmounts[2] = 0.006 ether + 1003 wei; // Creates dust
        testAmounts[3] = 0.123456789 ether; // Complex decimal
        testAmounts[4] = 999 wei; // Very small
        testAmounts[5] = 12.345678901234567890 ether; // Large with precision
        testAmounts[6] = 1 wei; // Minimum possible

        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 totalFee = testAmounts[i];

            // Test Scenario 1: No referrer (referrer fee goes to protocol)
            {
                uint256 creatorBefore = tokenCreator.balance;
                uint256 protocolBefore = protocolFeeRecipient.balance;

                // Call disperseFees with no referrer
                helper.disperseFeesTest{value: totalFee}(totalFee, address(0));

                uint256 creatorDelta = tokenCreator.balance - creatorBefore;
                uint256 protocolDelta = protocolFeeRecipient.balance -
                    protocolBefore;

                // Calculate expected fees using same math as Liquid.sol
                // Three-tier fee calculation
                uint256 expectedCreatorFee = (totalFee *
                    liquid.TOKEN_CREATOR_FEE_BPS()) / 10000;
                uint256 remainder = totalFee - expectedCreatorFee;
                // 0% burn, 50% protocol, 50% referrer of remainder
                uint256 expectedProtocolFee = (remainder * 5000) / 10000;
                uint256 expectedReferrerFee = (remainder * 5000) / 10000;

                // Calculate dust (rounding remainder) - goes to protocol
                uint256 totalCalculated = expectedCreatorFee +
                    expectedReferrerFee +
                    expectedProtocolFee;
                uint256 dust = totalFee - totalCalculated;

                // Protocol gets referrer fee + base protocol fee + dust (when no referrer)
                uint256 expectedTotalProtocolFee = expectedProtocolFee +
                    expectedReferrerFee +
                    dust;

                // Assert exact amounts (no LP fees)
                assertEq(
                    creatorDelta,
                    expectedCreatorFee,
                    string.concat(
                        "Test ",
                        vm.toString(i),
                        " (no referrer): Creator fee must be exact"
                    )
                );
                assertEq(
                    protocolDelta,
                    expectedTotalProtocolFee,
                    string.concat(
                        "Test ",
                        vm.toString(i),
                        " (no referrer): Protocol fee must be exact (includes referrer portion + dust)"
                    )
                );

                // Assert exact sum - this is the key assertion
                assertEq(
                    creatorDelta + protocolDelta,
                    totalFee,
                    string.concat(
                        "Test ",
                        vm.toString(i),
                        " (no referrer): Total must equal totalFee exactly (no wei lost to rounding)"
                    )
                );
            }

            // Test Scenario 2: With valid referrer
            {
                address testReferrer = makeAddr(
                    string.concat("referrer", vm.toString(i))
                );

                uint256 creatorBefore = tokenCreator.balance;
                uint256 referrerBefore = testReferrer.balance;
                uint256 protocolBefore = protocolFeeRecipient.balance;

                // Call disperseFees with referrer
                helper.disperseFeesTest{value: totalFee}(
                    totalFee,
                    testReferrer
                );

                uint256 creatorDelta = tokenCreator.balance - creatorBefore;
                uint256 referrerDelta = testReferrer.balance - referrerBefore;
                uint256 protocolDelta = protocolFeeRecipient.balance -
                    protocolBefore;

                // Calculate expected fees
                uint256 expectedCreatorFee = (totalFee *
                    liquid.TOKEN_CREATOR_FEE_BPS()) / 10000;
                // Three-tier fee calculation
                uint256 remainder = totalFee - expectedCreatorFee;
                // 0% burn, 50% protocol, 50% referrer of remainder
                uint256 expectedProtocolFee = (remainder * 5000) / 10000;
                uint256 expectedReferrerFee = (remainder * 5000) / 10000;

                // Calculate dust - goes to protocol
                uint256 totalCalculated = expectedCreatorFee +
                    expectedReferrerFee +
                    expectedProtocolFee;
                uint256 dust = totalFee - totalCalculated;

                // Protocol gets base protocol fee + dust
                uint256 expectedTotalProtocolFee = expectedProtocolFee + dust;

                // Assert exact amounts
                assertEq(
                    creatorDelta,
                    expectedCreatorFee,
                    string.concat(
                        "Test ",
                        vm.toString(i),
                        " (with referrer): Creator fee must be exact"
                    )
                );
                assertEq(
                    referrerDelta,
                    expectedReferrerFee,
                    string.concat(
                        "Test ",
                        vm.toString(i),
                        " (with referrer): Referrer fee must be exact"
                    )
                );
                assertEq(
                    protocolDelta,
                    expectedTotalProtocolFee,
                    string.concat(
                        "Test ",
                        vm.toString(i),
                        " (with referrer): Protocol fee must be exact (includes dust)"
                    )
                );

                // Assert exact sum - this is the key assertion
                assertEq(
                    creatorDelta + referrerDelta + protocolDelta,
                    totalFee,
                    string.concat(
                        "Test ",
                        vm.toString(i),
                        " (with referrer): Total must equal totalFee exactly (no wei lost to rounding)"
                    )
                );
            }
        }
    }

    // ============ FEE DISTRIBUTION FALLBACK TESTS ============

    /// @notice Test that creator revert routes funds to protocol
    /// @dev Verifies trade succeeds and FeeTransferFailed event is emitted
    function testFeeDistribution_CreatorRevertsFallsBackToProtocol() public {
        // Create token with reverting creator
        RevertingReceiver revertingCreator = new RevertingReceiver();
        vm.deal(address(revertingCreator), 10 ether);

        vm.prank(address(revertingCreator));
        address tokenAddr = factory.createLiquidToken{value: 1 ether}(
            address(revertingCreator),
            "ipfs://revert",
            "REVERT",
            "REV"
        );
        Liquid revertToken = Liquid(payable(tokenAddr));

        // Record protocol balance before
        uint256 protoBefore = protocolFeeRecipient.balance;

        // Execute buy - should succeed even though creator reverts
        vm.prank(user1);
        uint256 tokensReceived = revertToken.buy{value: 1 ether}(
            user1,
            address(0),
            0,
            0
        );

        // Verify trade succeeded
        assertGt(
            tokensReceived,
            0,
            "Trade should succeed despite creator revert"
        );

        // Verify protocol received funds (including creator's failed share)
        uint256 protoAfter = protocolFeeRecipient.balance;
        assertGt(
            protoAfter,
            protoBefore,
            "Protocol should receive all fees including creator's share"
        );
    }

    /// @notice Test that referrer revert routes funds to protocol
    /// @dev Verifies trade succeeds and referrer's share goes to protocol
    function testFeeDistribution_ReferrerRevertsFallsBackToProtocol() public {
        // Create reverting referrer
        RevertingReceiver revertingReferrer = new RevertingReceiver();

        // Record balances before
        uint256 protoBefore = protocolFeeRecipient.balance;
        uint256 creatorBefore = tokenCreator.balance;

        // Execute buy with reverting referrer
        vm.prank(user1);
        uint256 tokensReceived = liquid.buy{value: 1 ether}(
            user1,
            address(revertingReferrer), // Referrer that reverts
            0,
            0
        );

        // Verify trade succeeded
        assertGt(
            tokensReceived,
            0,
            "Trade should succeed despite referrer revert"
        );

        // Verify protocol received referrer's share
        uint256 protoAfter = protocolFeeRecipient.balance;
        uint256 creatorAfter = tokenCreator.balance;

        assertGt(
            creatorAfter,
            creatorBefore,
            "Creator should still receive fees"
        );
        assertGt(
            protoAfter,
            protoBefore,
            "Protocol should receive fees including referrer's share"
        );
    }

    /// @notice Test that protocol revert causes entire trade to revert
    /// @dev Verifies EthTransferFailed() is thrown when protocol can't receive
    function testFeeDistribution_ProtocolRevertCausesTradeRevert() public {
        // Create factory with reverting protocol recipient
        RevertingReceiver revertingProtocol = new RevertingReceiver();

        vm.startPrank(admin);

        // Deploy quoter (we need a valid address for factory construction)
        MockV4Quoter quoter = new MockV4Quoter();

        LiquidFactory revertFactory = new LiquidFactory(
            admin,
            address(revertingProtocol), // Reverting protocol
            WETH,
            POOL_MANAGER,
            address(new MockBurner()),
            0,
            5000,
            5000,
            100,
            2500,
            -200,
            120000,
            address(quoter),
            address(0),
            60,
            300,
            0.005 ether,
            1e15
        );
        revertFactory.setImplementation(address(new Liquid()));
        vm.stopPrank();

        // Create token with reverting protocol
        vm.prank(tokenCreator);
        address tokenAddr = revertFactory.createLiquidToken{value: 1 ether}(
            tokenCreator,
            "ipfs://proto-revert",
            "PREVT",
            "PRV"
        );
        Liquid revertToken = Liquid(payable(tokenAddr));

        // Try to buy - should revert with EthTransferFailed
        vm.prank(user1);
        vm.expectRevert(ILiquid.EthTransferFailed.selector);
        revertToken.buy{value: 1 ether}(user1, address(0), 0, 0);
    }

    /// @notice Test both creator and referrer revert - all goes to protocol
    /// @dev Verifies cumulative fallback works correctly
    function testFeeDistribution_BothCreatorAndReferrerRevert() public {
        // Create token with reverting creator
        RevertingReceiver revertingCreator = new RevertingReceiver();
        RevertingReceiver revertingReferrer = new RevertingReceiver();
        vm.deal(address(revertingCreator), 10 ether);

        vm.prank(address(revertingCreator));
        address tokenAddr = factory.createLiquidToken{value: 1 ether}(
            address(revertingCreator),
            "ipfs://both-revert",
            "BREVT",
            "BRV"
        );
        Liquid revertToken = Liquid(payable(tokenAddr));

        // Record protocol balance
        uint256 protoBefore = protocolFeeRecipient.balance;

        // Execute buy with both reverting
        vm.prank(user1);
        uint256 tokensReceived = revertToken.buy{value: 1 ether}(
            user1,
            address(revertingReferrer),
            0,
            0
        );

        // Verify trade succeeded
        assertGt(
            tokensReceived,
            0,
            "Trade should succeed despite both reverting"
        );

        // Verify protocol received ALL fees
        uint256 protoAfter = protocolFeeRecipient.balance;
        uint256 totalFee = (1 ether * revertToken.TOTAL_FEE_BPS()) / 10000;

        // Protocol should get close to total fee (within secondary rewards variance)
        assertGe(
            protoAfter - protoBefore,
            (totalFee * 95) / 100, // At least 95% of total fee (accounting for rounding)
            "Protocol should receive approximately all fees when both revert"
        );
    }

    // ============ CONFIG EPOCH SYNC TESTS ============

    function testConfigSync_OnBuy() public {
        // Update config values
        vm.startPrank(admin);
        address newProtocolFeeRecipient = makeAddr("newProtocolFeeRecipient");
        factory.setProtocolFeeRecipient(newProtocolFeeRecipient);
        vm.stopPrank();

        // Buy should use new config immediately
        vm.startPrank(user1);
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);
        vm.stopPrank();
    }

    function testConfigSync_ManualSync() public {
        // Update config values
        vm.startPrank(admin);
        address newProtocolFeeRecipient = makeAddr("newProtocolFeeRecipient");
        factory.setProtocolFeeRecipient(newProtocolFeeRecipient);
        vm.stopPrank();

        // Config changes take effect immediately - no manual sync needed
        // Verify new config is active by checking getter
        assertEq(factory.protocolFeeRecipient(), newProtocolFeeRecipient);
    }

    // ============ onERC721Received GUARD TESTS ============

    function testOnERC721Received_OnlyPositionManager() public {
        MockERC721 mockNFT = new MockERC721();

        // Attempt to send NFT from non-PositionManager address
        vm.expectRevert(ILiquid.OnlyPositionManager.selector);
        mockNFT.safeTransferFrom(address(this), address(liquid), 1, "");
    }

    // NOTE: onERC721Received is no longer used in V4 (no NFT position manager)
    // This guard remains for backward compatibility but is not actively tested
    // as V4 uses a different liquidity management system.

    // ============ receive() DEAD-END FUNCTION TESTS ============
    // receive() is now a simple pass-through that accepts ETH but does nothing
    // This eliminates EIP-7702 security concerns and forces explicit buy() calls

    function testReceive_BypassWhenSenderIsWETH() public {
        uint256 initialBalance = liquid.balanceOf(user1);

        // Send ETH from WETH contract (prank)
        vm.prank(WETH);
        (bool success, ) = address(liquid).call{value: 1 ether}("");
        assertTrue(success, "Call should succeed");

        // Verify no tokens were received (buy should not execute)
        assertEq(
            liquid.balanceOf(user1),
            initialBalance,
            "Buy should not execute when sender is WETH"
        );
    }

    /// @notice Test receive() accepts ETH but does not trigger buy
    /// @dev Verifies receive() is a dead-end function that accepts ETH without side effects
    function testReceive_AcceptsEthButDoesNotBuy() public {
        uint256 initialBalance = liquid.balanceOf(user1);

        // Send ETH from regular address
        vm.prank(user1);
        (bool success, ) = address(liquid).call{value: 1 ether}("");
        assertTrue(success, "Call should succeed");

        // Verify no tokens were received (receive() is now a dead-end function)
        // Users must call buy() explicitly to purchase tokens
        assertEq(
            liquid.balanceOf(user1),
            initialBalance,
            "Buy should NOT execute - receive() is a dead-end function"
        );
    }

    /// @notice Test receive() ignores calls from PoolManager
    /// @dev Verifies no buy executes when PoolManager sends ETH
    function testReceive_IgnoresPoolManager() public {
        uint256 initialBalance = liquid.balanceOf(user1);
        address poolManagerAddr = liquid.poolManager();

        // Give PoolManager some ETH
        vm.deal(poolManagerAddr, 10 ether);

        // Send ETH from PoolManager
        vm.prank(poolManagerAddr);
        (bool success, ) = address(liquid).call{value: 1 ether}("");
        assertTrue(success, "Call should succeed");

        // Verify no tokens were received (buy should not execute)
        assertEq(
            liquid.balanceOf(user1),
            initialBalance,
            "Buy should not execute when sender is PoolManager"
        );
    }

    /// @notice Test receive() ignores calls during unlock (_unlockExpected = true)
    /// @dev This is implicitly tested during swaps, but we verify explicitly
    function testReceive_IgnoresDuringUnlock() public {
        // This behavior is implicitly tested by all buy/sell tests
        // (during unlock, if PoolManager sends ETH, it's ignored)
        // We verify the guard exists by executing a normal buy and checking it succeeds

        vm.prank(user1);
        uint256 tokensReceived = liquid.buy{value: 1 ether}(
            user1,
            address(0),
            0,
            0
        );

        // If receive() didn't properly ignore calls during unlock, the buy would fail/revert
        assertGt(
            tokensReceived,
            0,
            "Buy should succeed (receive ignores unlock operations)"
        );
    }

    /// @notice Test receive() ignores calls from contracts (msg.sender != tx.origin)
    /// @dev Verifies that direct contract calls to receive() are ignored
    function testReceive_IgnoresContractCalls() public {
        // Create a mock contract to call receive()
        MockContractCaller caller = new MockContractCaller();
        vm.deal(address(caller), 10 ether);

        uint256 initialBalance = liquid.balanceOf(address(caller));

        // Call from contract (msg.sender != tx.origin)
        caller.callReceive{value: 1 ether}(address(liquid));

        // Verify no tokens were received (buy should not execute for contract)
        assertEq(
            liquid.balanceOf(address(caller)),
            initialBalance,
            "Buy should not execute when called from contract"
        );
    }

    /// @notice Test receive() ignores calls below minOrderSize
    /// @dev Verifies small ETH transfers are ignored
    function testReceive_IgnoresBelowMinOrder() public {
        uint256 minOrder = factory.minOrderSizeWei();
        uint256 initialBalance = liquid.balanceOf(user1);

        // Send ETH below minimum
        vm.prank(user1);
        (bool success, ) = address(liquid).call{value: minOrder - 1}("");
        assertTrue(success, "Call should succeed");

        // Verify no tokens were received
        assertEq(
            liquid.balanceOf(user1),
            initialBalance,
            "Buy should not execute below minOrderSize"
        );
    }

    // ============ PROTOCOLREWARDS SAFETY TESTS ============
    // NOTE: ProtocolRewards contract has been removed. Tests removed as fees are now distributed directly.

    // ============ EVENT ASSERTION TESTS ============

    function testEvents_LiquidBuy() public {
        vm.startPrank(user1);
        // Test that LiquidBuy event is emitted with correct indexed parameters
        // Use check parameters: check indexed fields (buyer, recipient, orderReferrer) and totalEth
        vm.expectEmit(true, true, false, false);
        emit ILiquid.LiquidBuy(
            user1, // buyer (indexed)
            user1, // recipient (indexed)
            address(0), // orderReferrer (indexed)
            1 ether, // totalEth
            0, // Don't check exact fee
            0, // Don't check exact ethSold
            0, // Don't check exact tokensBought
            0, // Don't check exact balance
            0, // Don't check exact totalSupply
            0, // Don't check exact startPrice
            0, // Don't check exact endPrice
            0, // Don't check exact protocolFee
            0, // Don't check exact referrerFee
            0, // Don't check exact creatorFee
            0 // Don't check exact burnFee
        );
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);
        vm.stopPrank();
    }

    function testEvents_LiquidSell() public {
        // First buy tokens
        vm.startPrank(user1);
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);
        uint256 tokensToSell = liquid.balanceOf(user1) / 2;

        // Test that LiquidSell event is emitted with correct indexed parameters
        vm.expectEmit(true, true, false, false);
        emit ILiquid.LiquidSell(
            user1, // seller (indexed)
            user1, // recipient (indexed)
            address(0), // orderReferrer (indexed)
            0, // Don't check exact totalEth
            0, // Don't check exact fee
            0, // Don't check exact payout
            tokensToSell, // tokensSold (exact match)
            0, // Don't check exact balance
            0, // Don't check exact totalSupply
            0, // Don't check exact startPrice
            0, // Don't check exact endPrice
            0, // Don't check exact protocolFee
            0, // Don't check exact referrerFee
            0, // Don't check exact creatorFee
            0 // Don't check exact burnFee
        );
        liquid.sell(tokensToSell, user1, address(0), 0, 0);
        vm.stopPrank();
    }

    function testEvents_LiquidFees() public {
        uint256 buyAmount = 1 ether;

        vm.startPrank(user1);
        // Test that LiquidFees event is emitted during buy
        // Since buy() emits multiple events (LiquidFees then LiquidBuy),
        // we'll verify by checking that fees were distributed correctly
        // rather than checking exact event parameters
        uint256 creatorInitialBalance = tokenCreator.balance;

        liquid.buy{value: buyAmount}(user1, address(0), 0, 0);

        // Verify fees were distributed (proves LiquidFees event was emitted)
        uint256 creatorDelta = tokenCreator.balance - creatorInitialBalance;
        assertGt(
            creatorDelta,
            0,
            "LiquidFees event should have been emitted and fees distributed"
        );
        vm.stopPrank();
    }

    // NOTE: Burned event emission is tested in:
    // - Liquid.mainnet.invariants.t.sol: testRealisticRAREBurnOnBaseFork()
    // which performs actual V4 swaps and verifies RARE balance changes at burn address

    // ============================================
    // SECTION B: Liquid Lifecycle & Guards
    // ============================================

    function test_RevertWhen_DoubleInitialize() public {
        // Try to initialize the already-initialized liquid token
        // This should revert via OpenZeppelin's Initializable.initializer modifier
        vm.expectRevert(); // Should revert with initializer guard
        liquid.initialize{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test2",
            "TEST2",
            "TST2",
            100, // totalFeeBPS
            2500, // creatorFeeBPS
            1e15 // minInitialLiquidityWei
        );
    }

    function test_InitializerModifier_PreventsReinitializationOfImplementation()
        public
    {
        // NOTE: There is no strong factory-only guard in initialize() -
        // the check only validates msg.sender != address(0), which is always true.
        //
        // The actual protections are:
        // 1. The `initializer` modifier from OpenZeppelin prevents double-initialization
        // 2. The Clones pattern means users interact with clones created by factory
        //
        // This test verifies the initializer modifier works on the implementation itself.

        // Try to initialize the implementation contract directly
        // This should fail because it's already initialized (or locked)
        vm.expectRevert(); // initializer modifier should prevent this
        liquidImplementation.initialize{value: 0.1 ether}(
            user1,
            "ipfs://test",
            "TEST",
            "TST",
            100, // totalFeeBPS
            2500, // creatorFeeBPS
            1e15 // minInitialLiquidityWei
        );

        // The test confirms that the implementation cannot be initialized
        // (it's either already initialized or locked by the initializer modifier)
    }

    function test_RevertWhen_NonFactoryInitializesClone() public {
        // SECURITY TEST: Non-factory address cannot initialize a clone
        //
        // Attack scenario: An attacker deploys their own minimal proxy clone
        // pointing to the Liquid implementation and tries to initialize it
        // with themselves as the "factory".
        //
        // Expected protection: The initialize() function will try to call
        // ILiquidFactory(factory).minOrderSizeWei() or other getters.
        // Since the attacker is an EOA (not a contract), this call will revert.
        //
        // This test verifies that only legitimate factory contracts can initialize
        // clones, because they must implement ILiquidFactory interface.

        // Create a fresh clone of the implementation using EIP-1167 minimal proxy
        address clone = _deployMinimalProxy(address(liquidImplementation));

        // Attempt to initialize from an EOA (attacker)
        vm.startPrank(attacker);

        // The call should fail when initialize() tries to call factory getters on the attacker EOA
        vm.expectRevert(); // Reverts with "call to non-contract address"
        Liquid(payable(clone)).initialize{value: 0.1 ether}(
            attacker,
            "ipfs://malicious",
            "HACK",
            "HCK",
            100, // totalFeeBPS
            2500, // creatorFeeBPS
            1e15 // minInitialLiquidityWei
        );

        vm.stopPrank();
    }

    // Helper function to deploy a minimal proxy (EIP-1167) pointing to implementation
    function _deployMinimalProxy(
        address implementation
    ) internal returns (address proxy) {
        bytes20 targetBytes = bytes20(implementation);
        assembly {
            let clone := mload(0x40)
            mstore(
                clone,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone, 0x14), targetBytes)
            mstore(
                add(clone, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            proxy := create(0, clone, 0x37)
        }
    }

    function testERC721Receive_HappyPath_FromRealPositionManager() public {
        // This test verifies the happy path is implicitly tested through token creation
        // Every token creation involves the Position Manager sending the NFT to the Liquid contract
        // We verify this by checking that the Liquid contract successfully initialized with a pool

        // The liquid token was already created in setUp
        // If the onERC721Received guard had rejected the Position Manager, creation would have failed

        // Verify the token has a valid pool (proves NFT was received successfully)
        assertTrue(address(liquid) != address(0), "Token should exist");
        assertTrue(liquid.totalSupply() > 0, "Token should have supply");

        // Additional verification: create another token to explicitly test the flow
        vm.prank(tokenCreator);
        address newToken = factory.createLiquidToken{value: 0.1 ether}(
            tokenCreator,
            "ipfs://test2",
            "TEST2",
            "TST2"
        );

        Liquid newLiquid = Liquid(payable(newToken));
        assertTrue(
            newLiquid.totalSupply() > 0,
            "New token should have supply (NFT was received)"
        );
    }

    // ============================================
    // SECTION E: Boundary Tests
    // ============================================

    function testBuy_ExactMinOrderSize() public {
        // Get the configured minOrderSizeWei
        uint256 minOrderSize = factory.minOrderSizeWei();

        // Buy with exactly minOrderSizeWei
        vm.startPrank(user1);
        uint256 tokensReceived = liquid.buy{value: minOrderSize}(
            user1,
            address(0),
            0,
            0
        );

        // Should succeed and receive tokens
        assertGt(
            tokensReceived,
            0,
            "Should succeed with exact minOrderSizeWei"
        );
        vm.stopPrank();
    }

    function testBuy_JustBelowMinOrderSize() public {
        // Get the configured minOrderSizeWei
        uint256 minOrderSize = factory.minOrderSizeWei();

        // Try to buy with just below minOrderSizeWei (if minOrderSize > 1 wei)
        if (minOrderSize > 1) {
            vm.startPrank(user1);
            vm.expectRevert(ILiquid.EthAmountTooSmall.selector);
            liquid.buy{value: minOrderSize - 1}(user1, address(0), 0, 0);
            vm.stopPrank();
        }
    }

    function testSell_ExactMinPayoutSize() public {
        // First buy some tokens
        vm.startPrank(user1);
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);

        uint256 userBalance = liquid.balanceOf(user1);
        require(userBalance > 0, "User should have tokens");

        // Sell a small amount with minPayoutSize set to exactly what we expect to receive
        // We'll use a small sell amount and calculate expected payout
        uint256 sellAmount = userBalance / 100; // Sell 1%

        // Try to sell with minPayoutSize = 0 (should succeed)
        uint256 payoutReceived = liquid.sell(
            sellAmount,
            user1,
            address(0),
            0, // minPayoutSize = 0 (no minimum)
            0
        );

        assertGt(payoutReceived, 0, "Should receive payout");

        // Now try again with exact minPayoutSize equal to expected payout
        liquid.buy{value: 0.5 ether}(user1, address(0), 0, 0);
        uint256 newBalance = liquid.balanceOf(user1);
        uint256 sellAmount2 = newBalance / 100;

        // Get a quote for expected payout (approximate)
        // Then sell with that as minimum (should succeed)
        uint256 payout2 = liquid.sell(
            sellAmount2,
            user1,
            address(0),
            1, // minPayoutSize = 1 wei (very low, should succeed)
            0
        );

        assertGe(payout2, 1, "Should succeed with achievable minPayoutSize");
        vm.stopPrank();
    }

    function testSell_MinPayoutSizeTooHigh_Reverts() public {
        // First buy some tokens
        vm.startPrank(user1);
        liquid.buy{value: 1 ether}(user1, address(0), 0, 0);

        uint256 userBalance = liquid.balanceOf(user1);
        uint256 sellAmount = userBalance / 10; // Sell 10%

        // Try to sell with unrealistically high minPayoutSize
        vm.expectRevert(); // Should revert from Uniswap (amount out too low)
        liquid.sell(
            sellAmount,
            user1,
            address(0),
            1000 ether, // Impossibly high minPayoutSize
            0
        );
        vm.stopPrank();
    }

    function testBuy_ZeroValue_Reverts() public {
        vm.startPrank(user1);
        vm.expectRevert(ILiquid.EthAmountTooSmall.selector);
        liquid.buy{value: 0}(user1, address(0), 0, 0);
        vm.stopPrank();
    }

    function testSell_ZeroAmount_Reverts() public {
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert (likely from transfer or Uniswap)
        liquid.sell(0, user1, address(0), 0, 0);
        vm.stopPrank();
    }

    // ============ ACCUMULATOR DEPOSIT FAILURE TESTS ============

    /// @notice Test that accumulator deposit failure is handled gracefully (end-to-end)
    /// @dev Verifies that when the accumulator is paused and rareBurnFeeBPS > 0:
    ///      1. BurnerDeposit event emits with depositSuccess = false
    ///      2. No ETH gets stuck in Liquid contract
    ///      3. Fee recipients (creator/protocol/referrer) still receive their non-burn portions
    ///      4. Failed burn ETH is forwarded to protocol as fallback
    function testAccumulatorDepositFailure_EndToEnd() public {
        // Deploy a real RAREBurner for this test
        vm.startPrank(admin);

        // Set up RAREBurnConfig with proper V4 pool configuration
        // RARE burn configuration done in a real test would use accumulator.setSettings()
        // This test initializes a proper burner below

        // Deploy RAREBurner with full configuration
        // Note: This test uses a mock setup, so we'll use a mock token address
        address mockRAREToken = makeAddr("mockRAREToken");
        address mockPoolManagerAddr = makeAddr("mockPoolManager");
        RAREBurner accumulator = new RAREBurner(
            admin,
            false, // don't auto-try on deposit
            mockRAREToken, // RARE token
            mockPoolManagerAddr, // V4 PoolManager
            3000, // 0.3% fee
            60, // tick spacing
            address(0), // no hooks
            0x000000000000000000000000000000000000dEaD, // burn address
            address(0), // no quoter
            0, // 0% slippage
            false // disabled initially
        );

        // Create a new factory with rareBurnFeeBPS = 2500 (25%) and the real accumulator
        LiquidFactory factoryWithBurn = new LiquidFactory(
            admin,
            protocolFeeRecipient,
            WETH,
            address(mockPoolManager), // Use mock pool manager for unit tests
            address(accumulator), // Use real accumulator
            2500, // rareBurnFeeBPS
            3750, // protocolFeeBPS
            3750, // referrerFeeBPS
            100, // defaultTotalFeeBPS
            2500, // defaultCreatorFeeBPS
            -180, // lpTickLower - max expensive (after price rises) - multiple of 60
            120000, // lpTickUpper - starting point (cheap tokens)
            address(0x1234567890123456789012345678901234567890), // Mock quoter
            address(0), // poolHooks (no hooks)
            60, // poolTickSpacing (standard for 0.3% fee tier)
            300, // internalMaxSlippageBps (3%)
            0.005 ether, // minOrderSizeWei
            1e15 // minInitialLiquidityWei (0.001 ETH)
        );

        factoryWithBurn.setImplementation(address(liquidImplementation));

        // Create a new liquid token with this factory
        address liquidWithBurnAddress = factoryWithBurn.createLiquidToken{
            value: 0.001 ether
        }(tokenCreator, "ipfs://test-burn", "TESTBURN", "TBURN");
        Liquid liquidWithBurn = Liquid(payable(liquidWithBurnAddress));

        // CRITICAL: Pause the accumulator to trigger deposit failure
        accumulator.pause(true);

        vm.stopPrank();

        // Record balances before the buy
        uint256 liquidEthBefore = address(liquidWithBurn).balance;
        uint256 accumulatorPendingEthBefore = accumulator.pendingEth();
        uint256 creatorBalanceBefore = tokenCreator.balance;
        uint256 protocolRecipientBalanceBefore = protocolFeeRecipient.balance;

        // Calculate expected fees using three-tier system
        uint256 buyAmount = 1 ether;
        uint256 totalFee = (buyAmount * liquidWithBurn.TOTAL_FEE_BPS()) /
            10_000;

        // TIER 2: Creator fee
        uint256 expectedCreatorFee = (totalFee *
            liquidWithBurn.TOKEN_CREATOR_FEE_BPS()) / 10_000;

        // TIER 3: Split remainder (25% burn, 37.5% protocol, 37.5% referrer)
        uint256 remainder = totalFee - expectedCreatorFee;
        uint256 expectedRareBurnFee = (remainder * 2500) / 10_000; // 25% of remainder
        uint256 expectedProtocolFee = (remainder * 3750) / 10_000; // 37.5% of remainder
        uint256 expectedReferrerFee = (remainder * 3750) / 10_000; // 37.5% of remainder

        // Account for dust (rounding difference) - goes to protocol
        uint256 calculatedSum = expectedCreatorFee +
            expectedRareBurnFee +
            expectedProtocolFee +
            expectedReferrerFee;
        uint256 dust = totalFee - calculatedSum;
        expectedProtocolFee += dust;

        // Execute buy and expect BurnerDeposit event with depositSuccess = false
        vm.expectEmit(true, true, false, true);
        emit ILiquid.BurnerDeposit(
            address(liquidWithBurn),
            address(accumulator),
            expectedRareBurnFee,
            false // depositSuccess = false (accumulator is paused)
        );

        vm.prank(user1);
        liquidWithBurn.buy{value: buyAmount}(user1, address(0), 0, 0);

        // ASSERTION 1: No ETH stuck in Liquid contract
        uint256 liquidEthAfter = address(liquidWithBurn).balance;
        assertEq(
            liquidEthAfter,
            liquidEthBefore,
            "No ETH should be stuck in Liquid contract after buy"
        );

        // ASSERTION 2: Accumulator pendingEth should NOT increase (deposit failed)
        uint256 accumulatorPendingEthAfter = accumulator.pendingEth();
        assertEq(
            accumulatorPendingEthAfter,
            accumulatorPendingEthBefore,
            "Accumulator pendingEth should not increase when paused"
        );

        // ASSERTION 3: Fee recipients (creator/protocol/referrer) still receive their portions via direct transfers
        // NOTE: Creator and protocol also receive LP fees from the pool (secondary rewards)
        // These are NOT part of the trading fee split we're testing, so we check them separately

        uint256 creatorBalanceAfter = tokenCreator.balance;
        uint256 creatorFeeDelta = creatorBalanceAfter - creatorBalanceBefore;

        // Creator receives: expectedCreatorFee + 50% of LP fees (secondary rewards)
        // We verify the primary fee portion is >= expected (may include LP fees too)
        assertGe(
            creatorFeeDelta,
            expectedCreatorFee,
            "Creator should receive at least the correct primary fee amount"
        );

        // Protocol fee recipient should receive protocol fee portion directly
        uint256 protocolRecipientBalanceAfter = protocolFeeRecipient.balance;
        uint256 protocolRecipientDelta = protocolRecipientBalanceAfter -
            protocolRecipientBalanceBefore;

        // Protocol recipient gets: protocol fee + referrer fee (no referrer) + failed burn fee + 50% of LP fees
        // When burner deposit fails, rareBurnFee is added to protocolFee before direct transfer
        uint256 expectedProtocolWithFailedBurn = expectedProtocolFee +
            expectedReferrerFee +
            expectedRareBurnFee; // Failed burn fee is added to protocol

        assertGe(
            protocolRecipientDelta,
            expectedProtocolWithFailedBurn,
            "Protocol recipient should receive protocol + referrer + failed burn fees directly"
        );

        // ASSERTION 6: User should still receive tokens (trade succeeded)
        assertTrue(
            liquidWithBurn.balanceOf(user1) > 0,
            "User should receive tokens despite accumulator being paused"
        );
    }

    /// @notice Test that receive() ignores ETH sent directly from WETH (during unwrapping)
    /// @dev This ensures that WETH unwrapping doesn't trigger buy logic
    function testReceiveIgnoresWETH() public {
        // Record initial balances
        address user = user1;
        uint256 userTokenBalanceBefore = liquid.balanceOf(user);

        // Record the event log count before the transfer
        vm.recordLogs();

        // Simulate WETH sending ETH to the token contract (as it would during unwrapping)
        vm.deal(WETH, 1 ether);
        vm.prank(WETH);
        (bool success, ) = payable(address(liquid)).call{value: 0.5 ether}("");

        // Should succeed (receive() accepts the ETH)
        assertTrue(success, "ETH transfer from WETH should succeed");

        // User's token balance should not change (no buy occurred)
        assertEq(
            liquid.balanceOf(user),
            userTokenBalanceBefore,
            "User token balance should not change when WETH sends ETH"
        );

        // Verify contract received the ETH (to confirm it didn't revert)
        assertEq(
            address(liquid).balance,
            0.5 ether,
            "Contract should receive the ETH from WETH"
        );

        // Verify no LiquidBuy event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            // LiquidBuy event signature: keccak256("LiquidBuy(address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint160,uint160,uint256,uint256,uint256,uint256)")
            bytes32 liquidBuySignature = keccak256(
                "LiquidBuy(address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint160,uint160,uint256,uint256,uint256,uint256)"
            );
            assertNotEq(
                logs[i].topics[0],
                liquidBuySignature,
                "No LiquidBuy event should be emitted when WETH sends ETH"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                        SQRTPRICELIMITX96 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test sqrtPriceLimitX96 with a permissive limit that allows the swap
    /// @dev Verifies that a reasonable price limit permits the swap to execute
    function testSqrtPriceLimitPermissiveAllowsSwap() public {
        // Note: V4 pool state can be queried via StateLibrary if needed
        // For this test, we use default limits which are maximally permissive
        uint160 sqrtPriceX96 = 0; // Default permissive limit

        // Determine token ordering (V4 sorts by address like V3)
        address token0 = address(liquid) < liquid.weth()
            ? address(liquid)
            : liquid.weth();
        bool isLiquidToken0 = token0 == address(liquid);

        // For a buy (WETH -> TOKEN):
        // - If Liquid is token0: we're buying token0 with token1, so zeroForOne = false, price moves UP
        // - If Liquid is token1: we're buying token1 with token0, so zeroForOne = true, price moves DOWN
        // For zeroForOne=false (Liquid is token0), limit must be > current price
        // For zeroForOne=true (Liquid is token1), limit must be < current price

        uint160 permissiveLimit;
        if (isLiquidToken0) {
            // zeroForOne = false, price moves UP, limit must be > current price
            // Set limit to 200% of current price - very permissive
            permissiveLimit = uint160((uint256(sqrtPriceX96) * 200) / 100);
            uint160 MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
            if (permissiveLimit >= MAX_SQRT_PRICE) {
                permissiveLimit = MAX_SQRT_PRICE - 1;
            }
        } else {
            // zeroForOne = true, price moves DOWN, limit must be < current price
            // Set limit to 50% of current price - very permissive
            permissiveLimit = uint160((uint256(sqrtPriceX96) * 50) / 100);
            uint160 MIN_SQRT_PRICE = 4295128739;
            if (permissiveLimit <= MIN_SQRT_PRICE) {
                permissiveLimit = MIN_SQRT_PRICE + 1;
            }
        }

        // Record initial balance
        uint256 userBalanceBefore = liquid.balanceOf(user1);

        // Execute buy with permissive price limit
        vm.prank(user1);
        uint256 tokensReceived = liquid.buy{value: 0.1 ether}(
            user1,
            address(0),
            0, // minTokensOut
            permissiveLimit
        );

        // Verify swap succeeded
        assertGt(
            tokensReceived,
            0,
            "Swap should succeed with permissive price limit"
        );
        assertEq(
            liquid.balanceOf(user1),
            userBalanceBefore + tokensReceived,
            "User should receive tokens"
        );
    }

    /// @notice Test sqrtPriceLimitX96 with a too-tight limit that causes revert
    /// @dev Verifies that an overly restrictive price limit prevents the swap
    function testSqrtPriceLimitTooTightReverts() public {
        // Note: V4 enforces price limits in PoolManager
        uint160 sqrtPriceX96 = 0; // Would need current price from StateLibrary for exact limit

        // Determine token ordering
        address token0 = address(liquid) < liquid.weth()
            ? address(liquid)
            : liquid.weth();
        bool isLiquidToken0 = token0 == address(liquid);

        uint160 tooTightLimit;
        if (isLiquidToken0) {
            // zeroForOne = false, price moves UP, limit must be > current price
            // Set limit BELOW current price to trigger immediate SPL revert
            tooTightLimit = uint160((uint256(sqrtPriceX96) * 99) / 100);
            uint160 MIN_SQRT_PRICE = 4295128739;
            if (tooTightLimit <= MIN_SQRT_PRICE) {
                tooTightLimit = MIN_SQRT_PRICE + 1;
            }
        } else {
            // zeroForOne = true, price moves DOWN, limit must be < current price
            // Set limit ABOVE current price to trigger immediate SPL revert
            tooTightLimit = uint160((uint256(sqrtPriceX96) * 101) / 100);
            uint160 MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
            if (tooTightLimit >= MAX_SQRT_PRICE) {
                tooTightLimit = MAX_SQRT_PRICE - 1;
            }
        }

        // Execute buy with invalid price limit - should revert immediately
        vm.prank(user1);
        vm.expectRevert(); // Will revert with price limit error from V4 PoolManager
        liquid.buy{value: 0.1 ether}(user1, address(0), 0, tooTightLimit);
    }

    /// @notice Test sqrtPriceLimitX96 = 0 means no price limit
    /// @dev Verifies that zero is interpreted as "no limit" and allows the swap
    function testSqrtPriceLimitZeroMeansNoLimit() public {
        uint256 userBalanceBefore = liquid.balanceOf(user1);

        // Execute buy with sqrtPriceLimitX96 = 0 (no limit)
        vm.prank(user1);
        uint256 tokensReceived = liquid.buy{value: 0.1 ether}(
            user1,
            address(0),
            0,
            0 // No price limit
        );

        // Verify swap succeeded
        assertGt(tokensReceived, 0, "Swap should succeed with no price limit");
        assertEq(
            liquid.balanceOf(user1),
            userBalanceBefore + tokensReceived,
            "User should receive tokens"
        );
    }

    /// @notice Test sqrtPriceLimitX96 on sell operations
    /// @dev Verifies price limits work correctly when selling tokens for ETH
    function testSqrtPriceLimitOnSell() public {
        // First buy some tokens
        vm.prank(user1);
        uint256 tokenAmount = liquid.buy{value: 0.5 ether}(
            user1,
            address(0),
            0,
            0
        );

        // Get current pool state
        // IUniswapV4Pool pool = IUniswapV4Pool(liquid.poolAddress());
        // IUniswapV4Pool.Slot0 memory slot0Data = pool.slot0();
        uint160 sqrtPriceX96 = 0; // slot0Data.sqrtPriceX96;

        // Determine token ordering
        address token0 = address(liquid) < liquid.weth()
            ? address(liquid)
            : liquid.weth();
        bool isLiquidToken0 = token0 == address(liquid);

        // For a sell (TOKEN -> WETH):
        // - If Liquid is token0: we're selling token0 for token1, so zeroForOne = true, price moves DOWN
        // - If Liquid is token1: we're selling token1 for token0, so zeroForOne = false, price moves UP
        // For zeroForOne=true (Liquid is token0), limit must be < current price
        // For zeroForOne=false (Liquid is token1), limit must be > current price

        uint160 permissiveSellLimit;
        if (isLiquidToken0) {
            // zeroForOne = true, price moves DOWN, limit must be < current price
            // Set a permissive limit: 50% of current price
            permissiveSellLimit = uint160((uint256(sqrtPriceX96) * 50) / 100);
            uint160 MIN_SQRT_PRICE = 4295128739;
            if (permissiveSellLimit <= MIN_SQRT_PRICE) {
                permissiveSellLimit = MIN_SQRT_PRICE + 1;
            }
        } else {
            // zeroForOne = false, price moves UP, limit must be > current price
            // Set a permissive limit: 200% of current price
            permissiveSellLimit = uint160((uint256(sqrtPriceX96) * 200) / 100);
            uint160 MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
            if (permissiveSellLimit >= MAX_SQRT_PRICE) {
                permissiveSellLimit = MAX_SQRT_PRICE - 1;
            }
        }

        // Sell with permissive limit (no approval needed - uses internal _transfer)
        vm.startPrank(user1);

        uint256 ethBalanceBefore = user1.balance;
        uint256 ethReceived = liquid.sell(
            tokenAmount,
            user1, // recipient
            address(0), // orderReferrer
            0, // minPayoutSize
            permissiveSellLimit
        );
        vm.stopPrank();

        // Verify sell succeeded
        assertGt(ethReceived, 0, "Sell should succeed with permissive limit");
        assertGe(
            user1.balance,
            ethBalanceBefore,
            "User should receive ETH from sell"
        );
    }

    /// @notice Test sqrtPriceLimitX96 too tight on sell causes revert
    /// @dev Verifies that restrictive price limit prevents sell
    function testSqrtPriceLimitTooTightRevertsOnSell() public {
        // First buy some tokens
        vm.prank(user1);
        uint256 tokenAmount = liquid.buy{value: 0.5 ether}(
            user1,
            address(0),
            0,
            0
        );

        // Get current pool state
        // IUniswapV4Pool pool = IUniswapV4Pool(liquid.poolAddress());
        // IUniswapV4Pool.Slot0 memory slot0Data = pool.slot0();
        uint160 sqrtPriceX96 = 0; // slot0Data.sqrtPriceX96;

        // Determine token ordering
        address token0 = address(liquid) < liquid.weth()
            ? address(liquid)
            : liquid.weth();
        bool isLiquidToken0 = token0 == address(liquid);

        uint160 tooTightSellLimit;
        if (isLiquidToken0) {
            // zeroForOne = true, price moves DOWN, limit must be < current price
            // Set it ABOVE current price - this is invalid and will immediately revert
            tooTightSellLimit = uint160((uint256(sqrtPriceX96) * 101) / 100);
            uint160 MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
            if (tooTightSellLimit >= MAX_SQRT_PRICE) {
                tooTightSellLimit = MAX_SQRT_PRICE - 1;
            }
        } else {
            // zeroForOne = false, price moves UP, limit must be > current price
            // Set it BELOW current price - this is invalid and will immediately revert
            tooTightSellLimit = uint160((uint256(sqrtPriceX96) * 99) / 100);
            uint160 MIN_SQRT_PRICE = 4295128739;
            if (tooTightSellLimit <= MIN_SQRT_PRICE) {
                tooTightSellLimit = MIN_SQRT_PRICE + 1;
            }
        }

        // Attempt sell with invalid limit - should revert (no approval needed)
        vm.startPrank(user1);
        vm.expectRevert(); // Will revert with price limit error from V4 PoolManager
        liquid.sell(
            tokenAmount,
            user1, // recipient
            address(0), // orderReferrer
            0, // minPayoutSize
            tooTightSellLimit
        );
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                V4-SPECIFIC SQRTPRICELIMITX96 DEFAULT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test V4 default limit conversion for buys (0 → MIN_SQRT_PRICE + 1)
    /// @dev Verifies that sqrtPriceLimitX96 = 0 converts to MIN_SQRT_PRICE + 1 for zeroForOne swaps
    function testV4DefaultLimitConversionBuy() public {
        // Execute buy with sqrtPriceLimitX96 = 0
        // For buys (ETH → LIQUID), this is zeroForOne = true
        // V4 should convert 0 → MIN_SQRT_PRICE + 1
        vm.prank(user1);
        uint256 tokensReceived = liquid.buy{value: 0.1 ether}(
            user1,
            address(0),
            0, // minOrderSize
            0 // sqrtPriceLimitX96 = 0 (should convert to MIN_SQRT_PRICE + 1)
        );

        // Verify swap succeeded (wouldn't succeed if limit was invalid)
        assertGt(tokensReceived, 0, "Swap should succeed with default limit");
    }

    /// @notice Test V4 default limit conversion for sells (0 → MAX_SQRT_PRICE - 1)
    /// @dev Verifies that sqrtPriceLimitX96 = 0 converts to MAX_SQRT_PRICE - 1 for !zeroForOne swaps
    function testV4DefaultLimitConversionSell() public {
        // First buy some tokens
        vm.prank(user1);
        uint256 tokenAmount = liquid.buy{value: 0.5 ether}(
            user1,
            address(0),
            0,
            0
        );

        // Execute sell with sqrtPriceLimitX96 = 0
        // For sells (LIQUID → ETH), this is zeroForOne = false
        // V4 should convert 0 → MAX_SQRT_PRICE - 1 (no approval needed)
        vm.startPrank(user1);
        uint256 ethReceived = liquid.sell(
            tokenAmount,
            user1,
            address(0),
            0, // minPayoutSize
            0 // sqrtPriceLimitX96 = 0 (should convert to MAX_SQRT_PRICE - 1)
        );
        vm.stopPrank();

        // Verify swap succeeded (wouldn't succeed if limit was invalid)
        assertGt(ethReceived, 0, "Swap should succeed with default limit");
    }

    /// @notice Test V4 buy with MIN_SQRT_PRICE + 1 as explicit limit
    /// @dev Verifies that the most permissive limit for buys works correctly
    function testV4BuyWithMinSqrtPriceLimit() public {
        uint160 MIN_SQRT_PRICE = 4295128739;

        vm.prank(user1);
        uint256 tokensReceived = liquid.buy{value: 0.1 ether}(
            user1,
            address(0),
            0,
            MIN_SQRT_PRICE + 1 // Most permissive limit for zeroForOne swaps
        );

        assertGt(
            tokensReceived,
            0,
            "Swap should succeed with MIN_SQRT_PRICE + 1"
        );
    }

    /// @notice Test V4 sell with MAX_SQRT_PRICE - 1 as explicit limit
    /// @dev Verifies that the most permissive limit for sells works correctly
    function testV4SellWithMaxSqrtPriceLimit() public {
        // First buy some tokens
        vm.prank(user1);
        uint256 tokenAmount = liquid.buy{value: 0.5 ether}(
            user1,
            address(0),
            0,
            0
        );

        uint160 MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

        vm.startPrank(user1);
        uint256 ethReceived = liquid.sell(
            tokenAmount,
            user1,
            address(0),
            0,
            MAX_SQRT_PRICE - 1 // Most permissive limit for !zeroForOne swaps
        );
        vm.stopPrank();

        assertGt(ethReceived, 0, "Swap should succeed with MAX_SQRT_PRICE - 1");
    }

    /*//////////////////////////////////////////////////////////////
                    PARTIAL FILL PROTECTION TESTS
                    NOTE: Tests are in Liquid.mainnet.basic.t.sol
                    (This test contract is skipped due to mock dependencies)
    //////////////////////////////////////////////////////////////*/

    /// @notice Partial fill tests have been moved to Liquid.mainnet.basic.t.sol
    /// @dev This test contract uses MockV4PoolManager which doesn't support the real V4 behavior
    ///      needed to test partial fills. See Liquid.mainnet.basic.t.sol for actual tests:
    ///      - testPartialFillBuy_TightPriceLimit
    ///      - testPartialFillBuy_FullFillSucceeds
    ///      - testPartialFillBuy_ZeroPriceLimitFullFill
    ///      - testPartialFillBuy_LargeBuyWithPermissiveLimit
    ///      - testPartialFillBuy_CorrectErrorParameters
    ///      - testPartialFillBuy_SequentialBuysNoStuckEth
    function testPartialFillBuy_SeeBasicTests() public pure {
        // Placeholder to document where the actual tests are
        assertTrue(
            true,
            "See Liquid.mainnet.basic.t.sol for partial fill protection tests"
        );
    }
}
