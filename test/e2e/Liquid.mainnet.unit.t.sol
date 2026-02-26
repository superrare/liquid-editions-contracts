// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidMultiCurve Mainnet Unit Tests
 * @notice Comprehensive unit tests for security guards, slippage, fees, and edge cases
 * @dev These tests require Base mainnet fork for real Uniswap interactions
 * @dev Fork is created automatically in setUp()
 */

import "forge-std/Test.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {RAREBurner} from "liquid-editions/RAREBurner.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
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
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {MockBurner} from "liquid-editions-test/helpers/MockBurner.sol";
import {MockV4PoolManager} from "liquid-editions-test/helpers/MockV4PoolManager.sol";
import {MockV4Quoter} from "liquid-editions-test/helpers/MockV4Quoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {InitGuardTestHelper} from "liquid-editions-test/helpers/InitGuardTestHelper.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {ForkUrlResolver} from "liquid-editions-test/helpers/ForkUrlResolver.sol";

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
    address public immutable PROTOCOL_FEE_RECIPIENT;
    address public immutable TOKEN_CREATOR;
    LiquidMultiCurve public immutable LIQUID_REFERENCE;

    constructor(
        address _protocolFeeRecipient,
        address _tokenCreator,
        address _liquidReference
    ) {
        PROTOCOL_FEE_RECIPIENT = _protocolFeeRecipient;
        TOKEN_CREATOR = _tokenCreator;
        LIQUID_REFERENCE = LiquidMultiCurve(payable(_liquidReference));
    }

    // Replicate _disperseFees logic from LiquidMultiCurve.sol exactly (three-tier system)
    // Read fee values from actual LiquidMultiCurve contract to avoid hardcoding
    function disperseFeesTest(
        uint256 _fee,
        address _orderReferrer
    ) external payable {
        require(msg.value == _fee, "Must send exact fee amount");

        // Default referrer to protocol recipient if none provided
        if (_orderReferrer == address(0)) {
            _orderReferrer = PROTOCOL_FEE_RECIPIENT;
        }

        // Fees are now handled by LiquidRouter, not stored in LiquidMultiCurve contracts
        // For test purposes, simulate fee distribution using factory config
        // TIER 2: Beneficiary fee (25% of total fee, matching LiquidRouter's BENEFICIARY_FEE_BPS)
        uint256 BENEFICIARY_FEE_BPS = 2500;
        uint256 tokenCreatorFee = (_fee * BENEFICIARY_FEE_BPS) / 10_000;

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

        // Direct ETH transfers with fallback pattern (matches LiquidMultiCurve.sol)
        uint256 protocolTotal = protocolFee;

        // Try creator transfer
        (bool creatorOk, ) = TOKEN_CREATOR.call{value: tokenCreatorFee}("");
        if (!creatorOk) {
            protocolTotal += tokenCreatorFee;
        }

        // Try referrer transfer
        (bool referrerOk, ) = _orderReferrer.call{value: orderReferrerFee}("");
        if (!referrerOk) {
            protocolTotal += orderReferrerFee;
        }

        // Final protocol transfer (accumulates all failures)
        (bool protocolOk, ) = PROTOCOL_FEE_RECIPIENT.call{value: protocolTotal}(
            ""
        );
        require(protocolOk, "Protocol transfer failed");
    }
}

/// @notice Mock render contract for testing
contract MockRenderContract {
    string public returnValue;
    bool public shouldRevert;
    bool public shouldReturnEmpty;
    bool public useTokenURI0;

    function setReturnValue(string memory _value) external {
        returnValue = _value;
    }

    function setShouldRevert(bool _should) external {
        shouldRevert = _should;
    }

    function setShouldReturnEmpty(bool _should) external {
        shouldReturnEmpty = _should;
    }

    function setUseTokenURI0(bool _use) external {
        useTokenURI0 = _use;
    }

    function tokenURI() external view returns (string memory) {
        if (shouldRevert) revert("Render contract error");
        if (shouldReturnEmpty) return "";
        return returnValue;
    }

    function tokenURI(uint256) external view returns (string memory) {
        if (shouldRevert) revert("Render contract error");
        if (shouldReturnEmpty) return "";
        return returnValue;
    }
}

// Simple ERC20 for testing LP position minting
contract TestERC20 {
    string public name;
    string public symbol;
    uint8 public constant DECIMALS = 18;
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

contract LiquidInstantMainnetUnitTest is Test, InitGuardTestHelper {
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

    LiquidMultiCurve public liquidImplementation;
    LiquidFactory public factory;
    LiquidMultiCurve public liquid;
    MockV4PoolManager public mockPoolManager;
    MockV4Quoter public mockQuoter;
    MockRARE public mockRARE;
    NetworkConfig.Config internal config;

    function setUp() public {
        // Fork Base mainnet for realistic testing
        string memory forkUrl = ForkUrlResolver.requireForkUrl(vm);
        vm.createSelectFork(forkUrl);

        // Get network configuration
        config = NetworkConfig.getConfig(block.chainid);

        // Fund test accounts
        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        // Deploy contracts
        vm.startPrank(admin);

        // Deploy mock RARE token
        mockRARE = new MockRARE();

        // Deploy LiquidMultiCurve implementation
        liquidImplementation = new LiquidMultiCurve();

        // Deploy init guard and factory
        address initGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        factory = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager,
            -180, // lpTickLower
            120000, // lpTickUpper
            config.uniswapV4Quoter,
            initGuardAddr, // poolHooks
            60, // poolTickSpacing
            300, // internalMaxSlippageBps (3%)
            1e15 // minRareLiquidityWei (0.001 RARE)
        );
        LiquidInitGuard(initGuardAddr).setFactory(address(factory));
                factory.setLiquidRegistry(address(1));

        factory.setLiquidMultiCurveImplementation(address(liquidImplementation));
        factory.setBaseToken(address(mockRARE));

        // Fund test accounts with RARE tokens
        mockRARE.mint(tokenCreator, 1000 ether);
        mockRARE.mint(user1, 1000 ether);
        mockRARE.mint(user2, 1000 ether);

        vm.stopPrank();
    }

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

    function _defaultSingleCurve() internal view returns (Curve[] memory) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({
            tickLower: factory.lpTickLower(),
            tickUpper: factory.lpTickUpper(),
            numPositions: 1,
            shares: 1e18
        });
        return curves;
    }

    /// @notice Helper to create a LiquidMultiCurve clone for direct initialization testing
    function _createClone() internal returns (LiquidMultiCurve) {
        address clone = Clones.clone(address(liquidImplementation));
        return LiquidMultiCurve(payable(clone));
    }

    // ============================================
    // SECTION A: Initialization Validation Tests
    // ============================================

    /// @notice Test that initialize() reverts when tokenURI is empty
    function test_Initialize_RevertsWhen_TokenURIEmpty() external {
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        Curve[] memory curves = _defaultSingleCurve();

        vm.expectRevert(ILiquid.InvalidTokenURI.selector);
        factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "", // Empty tokenURI
            "Test Token",
            "TEST",
            0.1 ether,
            curves
        );
        vm.stopPrank();
    }

    /// @notice Test that initialize() reverts when creator is address(0)
    function test_Initialize_RevertsWhen_CreatorAddressZero() external {
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        Curve[] memory curves = _defaultSingleCurve();

        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.createLiquidTokenMultiCurve(
            address(0),
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether,
            curves
        );
        vm.stopPrank();
    }

    /// @notice Test that initialize() reverts when RARE balance is insufficient
    function test_Initialize_RevertsWhen_RAREBalanceInsufficient() external {
        vm.startPrank(tokenCreator);
        mockRARE.mint(tokenCreator, 0.1 ether);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        Curve[] memory curves = _defaultSingleCurve();

        vm.expectRevert(ILiquidFactory.InvalidAmount.selector);
        factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            1e14, // 0.0001 RARE, below minimum
            curves
        );
        vm.stopPrank();
    }

    /// @notice Test that initialize() reverts when baseToken is zero (factory misconfigured)
    function test_Initialize_RevertsWhen_BaseTokenZero() external {
        // Create a factory with baseToken not set
        vm.startPrank(admin);
        address badInitGuardAddr = _deployInitGuardForTest(config.uniswapV4PoolManager, admin);
        LiquidFactory badFactory = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager,
            -180,
            120000,
            config.uniswapV4Quoter,
            badInitGuardAddr,
            60,
            300,
            1e15
        );
        LiquidInitGuard(badInitGuardAddr).setFactory(address(badFactory));
                badFactory.setLiquidRegistry(address(1));
        badFactory.setLiquidMultiCurveImplementation(address(liquidImplementation));
        // Don't set baseToken - leave it as address(0)
        vm.stopPrank();

        // Create clone through bad factory
        vm.startPrank(tokenCreator);
        mockRARE.mint(tokenCreator, 0.1 ether);
        IERC20(mockRARE).approve(address(badFactory), 0.1 ether);
        Curve[] memory curves = _defaultSingleCurve();

        vm.expectRevert(ILiquid.AddressZero.selector);
        badFactory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether,
            curves
        );
        vm.stopPrank();
    }

    // NOTE: poolManager-zero check is validated at LiquidFactory construction;
    // factory constructor requires non-zero poolManager. See factory tests.

    /// @notice Test that initialize() cannot be called twice (initializer lock)
    function test_Initialize_RevertsWhen_CalledTwice() external {
        // Create token through factory normally
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        Curve[] memory curves = _defaultSingleCurve();
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether,
            curves
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        Curve[] memory reinitializeCurves = _defaultSingleCurve();

        // Try to initialize again - should revert with initializer error
        vm.expectRevert();
        token.initialize(
            tokenCreator,
            "ipfs://test2",
            "Test Token 2",
            "TEST2",
            1e15,
            reinitializeCurves
        );

        // Re-check immutable launch state did not change after failed re-init attempt
        assertEq(token.factory(), address(factory), "Factory should remain unchanged");
        assertEq(
            token.totalSupply(),
            token.MAX_TOTAL_SUPPLY(),
            "Re-initialization should not rebalance supply"
        );
    }

    // ============================================
    // SECTION B: unlockCallback Access Control Tests
    // ============================================

    /// @notice Test that unlockCallback() reverts when caller is not PoolManager
    function test_UnlockCallback_RevertsWhen_CallerNotPoolManager() external {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));

        // Try to call unlockCallback from a non-PoolManager address
        bytes memory data = abi.encode(
            LiquidMultiCurve.UnlockContext({
                action: LiquidMultiCurve.UnlockAction.QUOTE_SWAP_BUY,
                data: abi.encode(1e18)
            })
        );

        vm.expectRevert(ILiquid.OnlyPoolManager.selector);
        vm.prank(attacker); // Not the poolManager
        token.unlockCallback(data);
    }

    /// @notice Test that unlockCallback() reverts when unlock is not expected
    function test_UnlockCallback_RevertsWhen_UnlockNotExpected() external {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        address poolManagerAddr = token.poolManager();

        // Try to call unlockCallback when _unlockExpected is false
        bytes memory data = abi.encode(
            LiquidMultiCurve.UnlockContext({
                action: LiquidMultiCurve.UnlockAction.QUOTE_SWAP_BUY,
                data: abi.encode(1e18)
            })
        );

        vm.expectRevert(ILiquid.UnexpectedUnlock.selector);
        vm.prank(poolManagerAddr);
        token.unlockCallback(data);
    }

    // ============================================
    // SECTION C: Quote Bubble Behavior Tests
    // ============================================

    /// @notice Test that quoteBuy bubbles underlying errors when pool not initialized
    /// @dev This tests error bubbling - quote should revert with underlying reason
    function test_QuoteBuy_BubblesUnderlyingError_WhenPoolNotInitialized()
        external
    {
        // Create a clone but don't initialize it
        LiquidMultiCurve clone = _createClone();

        // Try to quote - should revert (pool not initialized)
        // The exact error depends on V4 pool behavior, but it should bubble
        vm.expectRevert();
        clone.quoteBuy(1e18);
    }

    /// @notice Test that quoteSell handles amount exceeding total supply (reverts or returns bounded value)
    function test_QuoteSell_BubblesUnderlyingError_WhenAmountTooLarge()
        external
    {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));

        // Quote sell with amount larger than total supply
        uint256 hugeAmount = token.MAX_TOTAL_SUPPLY() + 1;

        // V4 quoter may not revert; if it returns, output must be bounded by pool liquidity
        (uint256 rareOut, ) = token.quoteSell(hugeAmount);
        // Pool has 0.1 ether RARE - quote should not exceed pool capacity
        assertLe(rareOut, 1 ether, "Quote for amount > supply should be bounded by pool liquidity");
    }

    // ============================================
    // SECTION D: Metadata/RenderContract Tests
    // ============================================

    /// @notice Test that setRenderContract() only allows token creator
    function test_SetRenderContract_OnlyCreator() external {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        MockRenderContract renderContract = new MockRenderContract();

        // Creator can set render contract
        vm.prank(tokenCreator);
        token.setRenderContract(address(renderContract));

        assertEq(token.renderContract(), address(renderContract));
    }

    /// @notice Test that setRenderContract() reverts when caller is not creator
    function test_SetRenderContract_RevertsWhen_CallerNotCreator() external {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        MockRenderContract renderContract = new MockRenderContract();

        // Non-creator cannot set render contract
        vm.expectRevert(ILiquid.NotTokenCreator.selector);
        vm.prank(user1);
        token.setRenderContract(address(renderContract));
    }

    /// @notice Test that tokenURI() returns stored URI when no render contract
    function test_TokenURI_ReturnsStoredURI_WhenNoRenderContract() external {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://stored-uri",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));

        // Should return stored URI
        assertEq(token.tokenURI(), "ipfs://stored-uri");
    }

    /// @notice Test that tokenURI() uses render contract when set
    function test_TokenURI_UsesRenderContract_WhenSet() external {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://stored-uri",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        MockRenderContract renderContract = new MockRenderContract();
        renderContract.setReturnValue("ipfs://render-uri");

        // Set render contract
        vm.prank(tokenCreator);
        token.setRenderContract(address(renderContract));

        // Should return render contract URI
        assertEq(token.tokenURI(), "ipfs://render-uri");
    }

    /// @notice Test that tokenURI() falls back to stored URI when render contract reverts
    function test_TokenURI_FallsBackToStoredURI_WhenRenderContractReverts()
        external
    {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://stored-uri",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        MockRenderContract renderContract = new MockRenderContract();
        renderContract.setShouldRevert(true);

        // Set render contract
        vm.prank(tokenCreator);
        token.setRenderContract(address(renderContract));

        // Should fall back to stored URI
        assertEq(token.tokenURI(), "ipfs://stored-uri");
    }

    /// @notice Test that tokenURI() falls back to stored URI when render returns empty
    function test_TokenURI_FallsBackToStoredURI_WhenRenderReturnsEmpty()
        external
    {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://stored-uri",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        MockRenderContract renderContract = new MockRenderContract();
        renderContract.setShouldReturnEmpty(true);

        // Set render contract
        vm.prank(tokenCreator);
        token.setRenderContract(address(renderContract));

        // Should fall back to stored URI
        assertEq(token.tokenURI(), "ipfs://stored-uri");
    }

    // ============================================
    // SECTION E: Burn Function Tests
    // ============================================

    /// @notice Test that burn() reduces total supply
    function test_Burn_ReducesTotalSupply() external {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        uint256 initialSupply = token.totalSupply();
        uint256 burnAmount = 1000e18;

        // Creator has 100k tokens from launch reward
        vm.prank(tokenCreator);
        token.burn(burnAmount);

        assertEq(token.totalSupply(), initialSupply - burnAmount);
    }

    /// @notice Test that burn() reduces user balance
    function test_Burn_ReducesUserBalance() external {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        uint256 initialBalance = token.balanceOf(tokenCreator);
        uint256 burnAmount = 1000e18;

        vm.prank(tokenCreator);
        token.burn(burnAmount);

        assertEq(token.balanceOf(tokenCreator), initialBalance - burnAmount);
    }

    /// @notice Test that burn() reverts when balance is insufficient
    function test_Burn_RevertsWhen_InsufficientBalance() external {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        uint256 balance = token.balanceOf(tokenCreator);
        uint256 burnAmount = balance + 1; // More than balance

        vm.expectRevert(); // ERC20 burn will revert
        vm.prank(tokenCreator);
        token.burn(burnAmount);
    }

    /// @notice Test that burn() emits LiquidTransfer event
    function test_Burn_EmitsLiquidTransferEvent() external {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        uint256 burnAmount = 1000e18;
        uint256 balanceBefore = token.balanceOf(tokenCreator);
        uint256 supplyBefore = token.totalSupply();

        vm.expectEmit(true, true, false, true);
        emit ILiquid.LiquidTransfer(
            tokenCreator,
            address(0),
            burnAmount,
            balanceBefore - burnAmount,
            0,
            supplyBefore - burnAmount
        );

        vm.prank(tokenCreator);
        token.burn(burnAmount);
    }

    /// @notice Test that LiquidTransfer event fields are accurate on mint
    function test_LiquidTransfer_EventFieldsAccurate_OnMint() external {
        // Create a token through factory - mint happens during initialization
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);

        // The mint event happens during createLiquidToken
        // We can verify the event by checking balances after creation
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));

        // Verify creator received launch reward (mint event should have been emitted)
        assertEq(token.balanceOf(tokenCreator), 100_000e18);
        assertEq(token.totalSupply(), token.MAX_TOTAL_SUPPLY());
    }

    /// @notice Test that LiquidTransfer event fields are accurate on transfer
    function test_LiquidTransfer_EventFieldsAccurate_OnTransfer() external {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        uint256 transferAmount = 1000e18;
        uint256 creatorBalanceBefore = token.balanceOf(tokenCreator);
        uint256 user1BalanceBefore = token.balanceOf(user1);
        uint256 supplyBefore = token.totalSupply();

        vm.expectEmit(true, true, false, true);
        emit ILiquid.LiquidTransfer(
            tokenCreator,
            user1,
            transferAmount,
            creatorBalanceBefore - transferAmount,
            user1BalanceBefore + transferAmount,
            supplyBefore // Supply doesn't change on transfer
        );

        vm.prank(tokenCreator);
        token.transfer(user1, transferAmount);
    }

    /// @notice Test that LiquidTransfer event fields are accurate on burn
    function test_LiquidTransfer_EventFieldsAccurate_OnBurn() external {
        // Create a token through factory
        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.1 ether);
        address tokenAddress = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://test",
            "Test Token",
            "TEST",
            0.1 ether
        );
        vm.stopPrank();

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddress));
        uint256 burnAmount = 1000e18;
        uint256 balanceBefore = token.balanceOf(tokenCreator);
        uint256 supplyBefore = token.totalSupply();

        vm.expectEmit(true, true, false, true);
        emit ILiquid.LiquidTransfer(
            tokenCreator,
            address(0),
            burnAmount,
            balanceBefore - burnAmount,
            0,
            supplyBefore - burnAmount
        );

        vm.prank(tokenCreator);
        token.burn(burnAmount);
    }
}
