// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidRouter} from "../src/LiquidRouter.sol";
import {ILiquidRouter} from "../src/interfaces/ILiquidRouter.sol";
import {ILiquidFactory} from "../src/interfaces/ILiquidFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Mock ERC20 Token for testing
/// @dev Includes Permit2 simulation for sell testing
contract MockERC20 is IERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Canonical Permit2 address (same on all chains)
    address internal constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(
        address to,
        uint256 amount
    ) external virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external virtual returns (bool) {
        // Check if spender has direct allowance OR if Permit2 has allowance
        // This simulates how Permit2 allows approved protocols to pull tokens
        if (allowance[from][msg.sender] >= amount) {
            allowance[from][msg.sender] -= amount;
        } else if (allowance[from][PERMIT2] >= amount) {
            // Permit2 simulation: if Permit2 is approved, allow the transfer
            allowance[from][PERMIT2] -= amount;
        } else {
            revert("ERC20: insufficient allowance");
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @title Mock Fee-On-Transfer ERC20
/// @dev Burns 1% on each transfer/transferFrom to simulate deflationary behavior
contract MockFeeOnTransferToken is MockERC20 {
    uint256 public constant FEE_BPS = 100; // 1%

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 sendAmount = amount - fee;

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += sendAmount;
        totalSupply -= fee;

        emit Transfer(msg.sender, to, sendAmount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (allowance[from][msg.sender] >= amount) {
            allowance[from][msg.sender] -= amount;
        } else if (allowance[from][PERMIT2] >= amount) {
            allowance[from][PERMIT2] -= amount;
        } else {
            revert("ERC20: insufficient allowance");
        }

        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 sendAmount = amount - fee;

        balanceOf[from] -= amount;
        balanceOf[to] += sendAmount;
        totalSupply -= fee;

        emit Transfer(from, to, sendAmount);
        return true;
    }
}

/// @title Mock Universal Router for testing
/// @dev Simulates swap behavior by minting/transferring tokens
///      In production, Universal Router pulls tokens via Permit2
///      This mock simulates that by checking Permit2 approval
contract MockUniversalRouter {
    MockERC20 public token;
    uint256 public tokenPerEth = 1000e18; // 1000 tokens per ETH
    bool public shouldFail;
    uint256 public pullAmountOverride;

    /// @notice Canonical Permit2 address (same on all chains)
    address internal constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    constructor(address _token) {
        token = MockERC20(_token);
    }

    function setTokenPerEth(uint256 _rate) external {
        tokenPerEth = _rate;
    }

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    function setPullAmountOverride(uint256 amount) external {
        pullAmountOverride = amount;
    }

    /// @dev Mock execute function that simulates swaps
    /// For buys: mints tokens to the caller based on ETH sent
    /// For sells: sends ETH to caller based on token approval
    receive() external payable {
        // Buy: ETH in, tokens out
        if (msg.value > 0 && !shouldFail) {
            uint256 tokensOut = (msg.value * tokenPerEth) / 1e18;
            token.mint(msg.sender, tokensOut);
        }
    }

    /// @dev Mock execute for sells (token -> ETH)
    ///      Real Universal Router pulls tokens via Permit2
    ///      MockERC20 simulates Permit2 by allowing transfers when Permit2 is approved
    function execute(
        bytes calldata,
        bytes[] calldata,
        uint256
    ) external payable {
        if (shouldFail) {
            revert("Router: swap failed");
        }

        if (msg.value > 0) {
            // Buy: ETH -> tokens
            uint256 tokensOut = (msg.value * tokenPerEth) / 1e18;
            token.mint(msg.sender, tokensOut);
        } else {
            // Sell: tokens -> ETH
            // Real flow: Universal Router calls Permit2.transferFrom()
            // MockERC20 simulates this by checking Permit2 allowance in transferFrom
            uint256 approved = token.allowance(msg.sender, PERMIT2);
            if (approved > 0) {
                // Pull tokens (MockERC20 allows this if Permit2 is approved)
                uint256 amountToPull = pullAmountOverride > 0
                    ? pullAmountOverride
                    : approved;

                // Clamp to approved amount to avoid over-pulling
                if (amountToPull > approved) amountToPull = approved;

                token.transferFrom(msg.sender, address(this), amountToPull);
                uint256 ethOut = (amountToPull * 1e18) / tokenPerEth;
                (bool success, ) = msg.sender.call{value: ethOut}("");
                require(success, "ETH transfer failed");
            }
        }
    }

    /// @dev Fund the router with ETH for sells
    function fundRouter() external payable {}
}

/// @title Mock Permit2 for testing
/// @dev Simulates Permit2's allowance system for Universal Router
contract MockPermit2 {
    // Mapping: owner => token => spender => (amount, expiration)
    mapping(address => mapping(address => mapping(address => uint160)))
        public amounts;
    mapping(address => mapping(address => mapping(address => uint48)))
        public expirations;

    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external {
        amounts[msg.sender][token][spender] = amount;
        expirations[msg.sender][token][spender] = expiration;
    }

    function allowance(
        address owner,
        address token,
        address spender
    ) external view returns (uint160 amount, uint48 expiration, uint48 nonce) {
        return (
            amounts[owner][token][spender],
            expirations[owner][token][spender],
            0
        );
    }
}

/// @title Mock RARE Burner for testing
contract MockRAREBurner {
    uint256 public deposited;
    bool public shouldFail;

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    function depositForBurn() external payable {
        if (shouldFail) {
            revert("Burner: deposit failed");
        }
        deposited += msg.value;
    }

    receive() external payable {}
}

/// @title Mock contract that rejects ETH transfers for testing fee failures
contract RejectingRecipient {
    receive() external payable {
        revert("I reject ETH");
    }
}

/// @title Mock LiquidFactory for testing
/// @dev Provides fee configuration to LiquidRouter
contract MockLiquidFactory {
    address public protocolFeeRecipient;
    address public rareBurner;
    uint256 public rareBurnFeeBPS;
    uint256 public protocolFeeBPS;
    uint256 public referrerFeeBPS;
    uint128 public minOrderSizeWei;

    // Unused by router but required by interface
    address public weth;
    address public poolManager;
    address public v4Quoter;
    address public poolHooks;
    uint16 public internalMaxSlippageBps;
    uint256 public minInitialLiquidityWei;
    int24 public lpTickLower;
    int24 public lpTickUpper;
    int24 public poolTickSpacing;

    constructor(
        address _protocolFeeRecipient,
        address _rareBurner,
        uint256 _rareBurnFeeBPS,
        uint256 _protocolFeeBPS,
        uint256 _referrerFeeBPS
    ) {
        protocolFeeRecipient = _protocolFeeRecipient;
        rareBurner = _rareBurner;
        rareBurnFeeBPS = _rareBurnFeeBPS;
        protocolFeeBPS = _protocolFeeBPS;
        referrerFeeBPS = _referrerFeeBPS;
        minOrderSizeWei = 0.0001 ether;
    }

    function setProtocolFeeRecipient(address _recipient) external {
        protocolFeeRecipient = _recipient;
    }

    function setRareBurner(address _burner) external {
        rareBurner = _burner;
    }

    function setFeeDistribution(
        uint256 _rareBurnFeeBPS,
        uint256 _protocolFeeBPS,
        uint256 _referrerFeeBPS
    ) external {
        rareBurnFeeBPS = _rareBurnFeeBPS;
        protocolFeeBPS = _protocolFeeBPS;
        referrerFeeBPS = _referrerFeeBPS;
    }

    function setMinOrderSizeWei(uint128 _minOrderSize) external {
        minOrderSizeWei = _minOrderSize;
    }
}

/// @title LiquidRouter Unit Tests
/// @notice Comprehensive unit tests for LiquidRouter buy/sell/quote and fee distribution
/// @dev Tests use TOTAL_FEE_BPS = 300 (3%) and BENEFICIARY_FEE_BPS = 0 (0%)
contract LiquidRouterUnitTest is Test {
    // Contracts
    LiquidRouter public liquidRouter;
    MockERC20 public token;
    MockUniversalRouter public router;
    MockRAREBurner public burner;
    MockLiquidFactory public mockFactory;

    // Test accounts
    address public admin = makeAddr("admin");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public beneficiary = makeAddr("beneficiary");
    address public referrer = makeAddr("referrer");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    // Fee configuration from router constants
    uint256 constant TOTAL_FEE_BPS = 300; // 3% total fee
    uint256 constant BENEFICIARY_FEE_BPS = 2500; // 25% of total fee to beneficiary

    // Factory fee configuration (must sum to 10000)
    uint256 constant RARE_BURN_FEE_BPS = 5000; // 50%
    uint256 constant PROTOCOL_FEE_BPS = 3000; // 30%
    uint256 constant REFERRER_FEE_BPS = 2000; // 20%

    function setUp() public {
        // Deploy mock token
        token = new MockERC20();

        // Deploy mock router and fund it
        router = new MockUniversalRouter(address(token));
        vm.deal(address(router), 1000 ether);

        // Deploy MockPermit2 at the canonical Permit2 address
        // This is needed because LiquidRouter calls IPermit2(PERMIT2).approve()
        address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        MockPermit2 mockPermit2 = new MockPermit2();
        vm.etch(PERMIT2, address(mockPermit2).code);

        // Deploy mock burner
        burner = new MockRAREBurner();

        // Deploy mock factory
        mockFactory = new MockLiquidFactory(
            protocolFeeRecipient,
            address(burner),
            RARE_BURN_FEE_BPS,
            PROTOCOL_FEE_BPS,
            REFERRER_FEE_BPS
        );

        // Deploy router
        vm.prank(admin);
        liquidRouter = new LiquidRouter(address(router), address(mockFactory));

        // Register token with beneficiary
        vm.prank(admin);
        liquidRouter.registerToken(address(token), beneficiary);

        // Fund test accounts
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        // Mint tokens to users for sell tests
        token.mint(user1, 10000e18);
        token.mint(user2, 10000e18);
    }

    // ============================================
    // CONSTRUCTOR TESTS
    // ============================================

    function testConstructorSetsParameters() public view {
        assertEq(liquidRouter.universalRouter(), address(router));
        assertEq(liquidRouter.factory(), address(mockFactory));
    }

    function testConstructorRevertsOnZeroRouter() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        new LiquidRouter(address(0), address(mockFactory));
    }

    function testConstructorRevertsOnZeroFactory() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        new LiquidRouter(address(router), address(0));
    }

    // ============================================
    // QUOTE TESTS
    // ============================================

    function testQuoteFeeBreakdown() public view {
        uint256 totalFee = 1 ether;
        (
            uint256 beneficiaryFee,
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 burnFee
        ) = liquidRouter.quoteFeeBreakdown(totalFee);

        // Beneficiary gets 25% of total fee (BENEFICIARY_FEE_BPS = 2500)
        assertEq(beneficiaryFee, (totalFee * 2500) / 10000);

        // Remaining 75% split among burn/protocol/referrer: 50%/30%/20%
        uint256 remainder = totalFee - beneficiaryFee;
        assertEq(burnFee, (remainder * RARE_BURN_FEE_BPS) / 10000);
        assertEq(referrerFee, (remainder * REFERRER_FEE_BPS) / 10000);
        // Protocol gets remainder including dust
        assertTrue(protocolFee >= (remainder * PROTOCOL_FEE_BPS) / 10000);
    }

    // ============================================
    // BUY TESTS
    // ============================================

    function testBuyBasic() public {
        uint256 ethAmount = 1 ether;
        uint256 expectedFee = (ethAmount * TOTAL_FEE_BPS) / 10000; // 3%
        uint256 ethForSwap = ethAmount - expectedFee;
        uint256 expectedTokens = (ethForSwap * router.tokenPerEth()) / 1e18;

        vm.prank(user1);
        uint256 tokensReceived = liquidRouter.buy{value: ethAmount}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        assertEq(tokensReceived, expectedTokens);
        assertEq(token.balanceOf(user1), 10000e18 + expectedTokens); // Initial + bought
    }

    function testBuyEmitsEvent() public {
        uint256 ethAmount = 1 ether;

        vm.expectEmit(true, true, true, false);
        emit ILiquidRouter.RouterBuy(
            address(token),
            user1,
            user1,
            referrer,
            ethAmount,
            0, // ethFee (checked loosely)
            0, // ethSwapped
            0, // tokensReceived
            0, // protocolFee
            0, // referrerFee
            0, // beneficiaryFee
            0 // burnFee
        );

        vm.prank(user1);
        liquidRouter.buy{value: ethAmount}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    function testBuyDistributesFees() public {
        uint256 ethAmount = 1 ether;
        uint256 totalFee = (ethAmount * TOTAL_FEE_BPS) / 10000; // 3%

        uint256 protocolBalBefore = protocolFeeRecipient.balance;
        uint256 referrerBalBefore = referrer.balance;
        uint256 beneficiaryBalBefore = beneficiary.balance;
        uint256 burnerBalBefore = burner.deposited();

        vm.prank(user1);
        liquidRouter.buy{value: ethAmount}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // Beneficiary gets 25% (BENEFICIARY_FEE_BPS = 2500)
        assertTrue(beneficiary.balance > beneficiaryBalBefore);

        // Remaining 75% fee split among burn/protocol/referrer
        uint256 beneficiaryFee = (totalFee * 2500) / 10000;
        uint256 remainingFee = totalFee - beneficiaryFee;
        uint256 burnFee = (remainingFee * RARE_BURN_FEE_BPS) / 10000;
        uint256 referrerFee = (remainingFee * REFERRER_FEE_BPS) / 10000;

        assertEq(burner.deposited() - burnerBalBefore, burnFee);
        assertEq(referrer.balance - referrerBalBefore, referrerFee);
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testBuyRevertsOnZeroToken() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(0),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            "",
            block.timestamp + 1 hours
        );
    }

    function testBuyRevertsOnZeroRecipient() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            address(0),
            referrer,
            1, // minTokensOut (must be > 0)
            "",
            block.timestamp + 1 hours
        );
    }

    function testBuyRevertsOnSlippageExceeded() public {
        uint256 ethAmount = 1 ether;
        uint256 unreasonablyHighMinOut = 1000000e18;

        vm.expectRevert(ILiquidRouter.SlippageExceeded.selector);
        vm.prank(user1);
        liquidRouter.buy{value: ethAmount}(
            address(token),
            user1,
            referrer,
            unreasonablyHighMinOut,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    function testBuyRevertsOnSwapFailure() public {
        router.setShouldFail(true);

        vm.expectRevert("Router: swap failed");
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    // ============================================
    // SELL TESTS
    // ============================================

    function testSellBasic() public {
        uint256 tokenAmount = 1000e18;
        uint256 grossEth = (tokenAmount * 1e18) / router.tokenPerEth();
        uint256 fee = (grossEth * TOTAL_FEE_BPS) / 10000; // 3%
        uint256 expectedEth = grossEth - fee;

        // Approve tokens
        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        uint256 balBefore = user1.balance;

        vm.prank(user1);
        uint256 ethReceived = liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1, // minEthOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        assertEq(ethReceived, expectedEth);
        assertEq(user1.balance - balBefore, expectedEth);
    }

    function testSellDistributesFees() public {
        uint256 tokenAmount = 1000e18;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        uint256 protocolBalBefore = protocolFeeRecipient.balance;
        uint256 referrerBalBefore = referrer.balance;
        uint256 beneficiaryBalBefore = beneficiary.balance;
        uint256 burnerBalBefore = burner.deposited();

        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // Verify fees were distributed (beneficiary gets 25% with BENEFICIARY_FEE_BPS = 2500)
        assertTrue(beneficiary.balance > beneficiaryBalBefore);
        assertTrue(burner.deposited() > burnerBalBefore);
        assertTrue(referrer.balance > referrerBalBefore);
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testSellRevertsOnZeroAmount() public {
        vm.expectRevert(ILiquidRouter.InvalidAmount.selector);
        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            0,
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            "",
            block.timestamp + 1 hours
        );
    }

    function testSellRevertsOnSlippageExceeded() public {
        uint256 tokenAmount = 1000e18;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.expectRevert(ILiquidRouter.SlippageExceeded.selector);
        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1000 ether, // Unreasonably high min out
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    function testSellRevertsOnUnexpectedTokenRefund() public {
        uint256 tokenAmount = 1000e18;
        uint256 amountToPull = tokenAmount / 2;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        // Configure mock Universal Router to only pull half the approved tokens
        router.setPullAmountOverride(amountToPull);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidRouter.UnexpectedTokenRefund.selector,
                tokenAmount,
                tokenAmount - amountToPull
            )
        );

        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1, // minEthOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    function testSellRevertsOnFeeOnTransferToken() public {
        uint256 tokenAmount = 1000e18;

        // Deploy fee-on-transfer token and dedicated router/universal router pair
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken();
        MockUniversalRouter fotRouter = new MockUniversalRouter(address(fot));
        vm.deal(address(fotRouter), 1000 ether);

        vm.prank(admin);
        LiquidRouter fotLiquidRouter = new LiquidRouter(
            address(fotRouter),
            address(mockFactory)
        );

        vm.prank(admin);
        fotLiquidRouter.registerToken(address(fot), beneficiary);

        // Fund user and approve router
        fot.mint(user1, tokenAmount);
        vm.prank(user1);
        fot.approve(address(fotLiquidRouter), tokenAmount);

        bytes memory routeData = abi.encodeWithSelector(
            fotRouter.execute.selector,
            "",
            new bytes[](0),
            block.timestamp
        );

        uint256 expectedReceived = tokenAmount -
            ((tokenAmount * fot.FEE_BPS()) / 10_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidRouter.FeeOnTransferDetected.selector,
                tokenAmount,
                expectedReceived
            )
        );

        vm.prank(user1);
        fotLiquidRouter.sell(
            address(fot),
            tokenAmount,
            user1,
            referrer,
            1, // minEthOut (must be > 0)
            routeData,
            block.timestamp + 1 hours
        );
    }

    function testBuyRevertsOnFeeOnTransferToken() public {
        uint256 ethAmount = 1 ether;

        // Deploy fee-on-transfer token and dedicated router/universal router pair
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken();
        MockUniversalRouter fotRouter = new MockUniversalRouter(address(fot));
        vm.deal(address(fotRouter), 1000 ether);

        vm.prank(admin);
        LiquidRouter fotLiquidRouter = new LiquidRouter(
            address(fotRouter),
            address(mockFactory)
        );

        vm.prank(admin);
        fotLiquidRouter.registerToken(address(fot), beneficiary);

        bytes memory routeData = abi.encodeWithSelector(
            fotRouter.execute.selector,
            "",
            new bytes[](0),
            block.timestamp
        );

        // Calculate expected amounts after swap
        uint256 fee = (ethAmount * TOTAL_FEE_BPS) / 10000; // 3%
        uint256 ethForSwap = ethAmount - fee;
        uint256 tokensFromSwap = (ethForSwap * fotRouter.tokenPerEth()) / 1e18;

        // When router transfers to user1, FOT token takes 1% fee
        uint256 expectedReceived = tokensFromSwap -
            ((tokensFromSwap * fot.FEE_BPS()) / 10_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidRouter.FeeOnTransferDetected.selector,
                tokensFromSwap,
                expectedReceived
            )
        );

        vm.prank(user1);
        fotLiquidRouter.buy{value: ethAmount}(
            address(fot),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            routeData,
            block.timestamp + 1 hours
        );
    }

    // ============================================
    // ALLOWLIST TESTS
    // ============================================

    function testAllowlistBlocksUnregisteredToken() public {
        // Enable allowlist
        vm.prank(admin);
        liquidRouter.setAllowlistEnabled(true);

        // Create new unregistered token
        MockERC20 newToken = new MockERC20();

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidRouter.TokenNotAllowed.selector,
                address(newToken)
            )
        );
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(newToken),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            "",
            block.timestamp + 1 hours
        );
    }

    function testAllowlistAllowsRegisteredToken() public {
        // Enable allowlist
        vm.prank(admin);
        liquidRouter.setAllowlistEnabled(true);

        // Should work for registered token
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    function testDisabledAllowlistAllowsAnyToken() public {
        // Allowlist is disabled by default
        assertFalse(liquidRouter.allowlistEnabled());

        // Create new unregistered token with mock router
        MockERC20 newToken = new MockERC20();
        MockUniversalRouter newRouter = new MockUniversalRouter(
            address(newToken)
        );
        vm.deal(address(newRouter), 100 ether);

        // Deploy new router with new router
        vm.prank(admin);
        LiquidRouter newLiquidRouter = new LiquidRouter(
            address(newRouter),
            address(mockFactory)
        );

        // Should work without registration when allowlist is disabled
        vm.prank(user1);
        newLiquidRouter.buy{value: 1 ether}(
            address(newToken),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                newRouter.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    // ============================================
    // ADMIN TESTS
    // ============================================

    function testOnlyOwnerCanRegisterToken() public {
        MockERC20 newToken = new MockERC20();

        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.registerToken(address(newToken), beneficiary);

        // Should work for owner
        vm.prank(admin);
        liquidRouter.registerToken(address(newToken), beneficiary);
        assertEq(
            liquidRouter.tokenBeneficiaries(address(newToken)),
            beneficiary
        );
    }

    function testOnlyOwnerCanUpdateBeneficiary() public {
        address newBeneficiary = makeAddr("newBeneficiary");

        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.updateBeneficiary(address(token), newBeneficiary);

        vm.prank(admin);
        liquidRouter.updateBeneficiary(address(token), newBeneficiary);
        assertEq(
            liquidRouter.tokenBeneficiaries(address(token)),
            newBeneficiary
        );
    }

    // ============================================
    // FACTORY CONFIG SYNC TESTS
    // ============================================

    function testFeeConfigPulledFromFactory() public {
        // Update factory config
        mockFactory.setFeeDistribution(4000, 4000, 2000); // 40/40/20 split

        uint256 ethAmount = 1 ether;
        uint256 totalFee = (ethAmount * TOTAL_FEE_BPS) / 10000; // 3%

        uint256 protocolBalBefore = protocolFeeRecipient.balance;
        uint256 burnerBalBefore = burner.deposited();

        vm.prank(user1);
        liquidRouter.buy{value: ethAmount}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // With BENEFICIARY_FEE_BPS = 2500, beneficiary gets 25% first, then remainder is split
        uint256 beneficiaryFee = (totalFee * 2500) / 10000; // 25%
        uint256 remainingFee = totalFee - beneficiaryFee;
        uint256 expectedBurnFee = (remainingFee * 4000) / 10000; // 40% of remainder

        assertEq(burner.deposited() - burnerBalBefore, expectedBurnFee);
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    // ============================================
    // BURNER FALLBACK TESTS
    // ============================================

    function testBurnerFailureFallsBackToProtocol() public {
        // Make burner fail
        burner.setShouldFail(true);

        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // Burner should have received nothing
        assertEq(burner.deposited(), 0);

        // Protocol should have received extra (burn fee redirected)
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testNoBurnerConfiguredFallsBackToProtocol() public {
        // Set factory burner to address(0)
        mockFactory.setRareBurner(address(0));

        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // Protocol should have received burn fee as well
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    // ============================================
    // NO BENEFICIARY TESTS
    // ============================================

    function testNoBeneficiaryFallsBackToProtocol() public {
        // Create unregistered token (no beneficiary set)
        MockERC20 newToken = new MockERC20();
        MockUniversalRouter newRouter = new MockUniversalRouter(
            address(newToken)
        );
        vm.deal(address(newRouter), 100 ether);

        vm.prank(admin);
        LiquidRouter newLiquidRouter = new LiquidRouter(
            address(newRouter),
            address(mockFactory)
        );

        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        // Buy token that has no beneficiary registered
        vm.prank(user1);
        newLiquidRouter.buy{value: 1 ether}(
            address(newToken),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                newRouter.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // Protocol should have received beneficiary fee as well (though it's 0% anyway)
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    // ============================================
    // DEFAULT REFERRER TESTS
    // ============================================

    function testZeroReferrerDefaultsToProtocol() public {
        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            address(0), // No referrer
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // Protocol should have received referrer fee as well
        // (referrer fee goes to protocol when referrer is address(0))
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    // ============================================
    // PAUSE TESTS
    // ============================================

    function testPauseBlocksBuy() public {
        // Pause the contract
        vm.prank(admin);
        liquidRouter.pause();

        assertTrue(liquidRouter.paused());

        // Buy should revert when paused
        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    function testPauseBlocksSell() public {
        // Pause the contract
        vm.prank(admin);
        liquidRouter.pause();

        // Approve tokens
        vm.prank(user1);
        token.approve(address(liquidRouter), 1000e18);

        // Sell should revert when paused
        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            1000e18,
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    function testUnpauseAllowsTrading() public {
        // Pause then unpause
        vm.prank(admin);
        liquidRouter.pause();
        vm.prank(admin);
        liquidRouter.unpause();

        assertFalse(liquidRouter.paused());

        // Buy should work after unpause
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    function testOnlyOwnerCanPause() public {
        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.pause();

        // Should work for owner
        vm.prank(admin);
        liquidRouter.pause();
        assertTrue(liquidRouter.paused());
    }

    function testOnlyOwnerCanUnpause() public {
        vm.prank(admin);
        liquidRouter.pause();

        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.unpause();

        // Should work for owner
        vm.prank(admin);
        liquidRouter.unpause();
        assertFalse(liquidRouter.paused());
    }

    // ============================================
    // DEADLINE TESTS
    // ============================================

    function testBuyRevertsOnExpiredDeadline() public {
        // Set deadline in the past
        uint256 pastDeadline = block.timestamp - 1;

        vm.expectRevert(ILiquidRouter.DeadlineExpired.selector);
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            pastDeadline
        );
    }

    function testSellRevertsOnExpiredDeadline() public {
        uint256 tokenAmount = 1000e18;
        uint256 pastDeadline = block.timestamp - 1;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.expectRevert(ILiquidRouter.DeadlineExpired.selector);
        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1, // minTokensOut (must be > 0)
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            pastDeadline
        );
    }

    // ============================================
    // ROUTE DATA VALIDATION TESTS
    // ============================================

    function testBuyRevertsOnEmptyRouteData() public {
        vm.expectRevert(ILiquidRouter.InvalidRouteData.selector);
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1, // minTokensOut (must be > 0 to reach routeData check)
            "", // Empty routeData
            block.timestamp + 1 hours
        );
    }

    function testSellRevertsOnEmptyRouteData() public {
        uint256 tokenAmount = 1000e18;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.expectRevert(ILiquidRouter.InvalidRouteData.selector);
        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            1, // minEthOut (must be > 0)
            "", // Empty routeData
            block.timestamp + 1 hours
        );
    }

    // ============================================
    // RESCUE TESTS
    // ============================================

    function testRescueTokens() public {
        // Accidentally send tokens to router
        uint256 rescueAmount = 500e18;
        token.mint(address(liquidRouter), rescueAmount);

        uint256 adminBalBefore = token.balanceOf(admin);

        vm.prank(admin);
        liquidRouter.rescueTokens(address(token), admin, rescueAmount);

        assertEq(token.balanceOf(admin) - adminBalBefore, rescueAmount);
        assertEq(token.balanceOf(address(liquidRouter)), 0);
    }

    function testRescueTokensEmitsEvent() public {
        uint256 rescueAmount = 500e18;
        token.mint(address(liquidRouter), rescueAmount);

        vm.expectEmit(true, true, false, true);
        emit ILiquidRouter.TokensRescued(address(token), admin, rescueAmount);

        vm.prank(admin);
        liquidRouter.rescueTokens(address(token), admin, rescueAmount);
    }

    function testRescueTokensRevertsOnZeroTo() public {
        token.mint(address(liquidRouter), 100e18);

        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(admin);
        liquidRouter.rescueTokens(address(token), address(0), 100e18);
    }

    function testRescueTokensRevertsOnZeroAmount() public {
        vm.expectRevert(ILiquidRouter.InvalidAmount.selector);
        vm.prank(admin);
        liquidRouter.rescueTokens(address(token), admin, 0);
    }

    function testOnlyOwnerCanRescueTokens() public {
        token.mint(address(liquidRouter), 100e18);

        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.rescueTokens(address(token), user1, 100e18);
    }

    function testRescueETH() public {
        // Send ETH to router
        uint256 rescueAmount = 1 ether;
        vm.deal(address(liquidRouter), rescueAmount);

        uint256 adminBalBefore = admin.balance;

        vm.prank(admin);
        liquidRouter.rescueETH(admin, rescueAmount);

        assertEq(admin.balance - adminBalBefore, rescueAmount);
        assertEq(address(liquidRouter).balance, 0);
    }

    function testRescueETHEmitsEvent() public {
        uint256 rescueAmount = 1 ether;
        vm.deal(address(liquidRouter), rescueAmount);

        vm.expectEmit(true, false, false, true);
        emit ILiquidRouter.EthRescued(admin, rescueAmount);

        vm.prank(admin);
        liquidRouter.rescueETH(admin, rescueAmount);
    }

    function testRescueETHRevertsOnZeroTo() public {
        vm.deal(address(liquidRouter), 1 ether);

        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(admin);
        liquidRouter.rescueETH(address(0), 1 ether);
    }

    function testRescueETHRevertsOnZeroAmount() public {
        vm.expectRevert(ILiquidRouter.InvalidAmount.selector);
        vm.prank(admin);
        liquidRouter.rescueETH(admin, 0);
    }

    function testRescueETHRevertsOnInsufficientBalance() public {
        vm.expectRevert(ILiquidRouter.InsufficientBalance.selector);
        vm.prank(admin);
        liquidRouter.rescueETH(admin, 1 ether);
    }

    function testOnlyOwnerCanRescueETH() public {
        vm.deal(address(liquidRouter), 1 ether);

        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.rescueETH(user1, 1 ether);
    }

    // ============================================
    // REMOVE TOKEN TESTS
    // ============================================

    function testRemoveToken() public {
        // Verify token is registered
        assertTrue(liquidRouter.allowedTokens(address(token)));
        assertEq(liquidRouter.tokenBeneficiaries(address(token)), beneficiary);

        vm.prank(admin);
        liquidRouter.removeToken(address(token));

        // Verify token is removed
        assertFalse(liquidRouter.allowedTokens(address(token)));
        assertEq(liquidRouter.tokenBeneficiaries(address(token)), address(0));
    }

    function testRemoveTokenEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit ILiquidRouter.TokenRemoved(address(token));

        vm.prank(admin);
        liquidRouter.removeToken(address(token));
    }

    function testRemoveTokenRevertsOnZeroAddress() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(admin);
        liquidRouter.removeToken(address(0));
    }

    function testOnlyOwnerCanRemoveToken() public {
        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.removeToken(address(token));
    }

    function testRemovedTokenBlockedWhenAllowlistEnabled() public {
        // Enable allowlist and remove token
        vm.prank(admin);
        liquidRouter.setAllowlistEnabled(true);
        vm.prank(admin);
        liquidRouter.removeToken(address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidRouter.TokenNotAllowed.selector,
                address(token)
            )
        );
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            referrer,
            1,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    // ============================================
    // SETTER TESTS (universalRouter and factory)
    // ============================================

    function testSetUniversalRouter() public {
        address newRouter = makeAddr("newRouter");

        vm.prank(admin);
        liquidRouter.setUniversalRouter(newRouter);

        assertEq(liquidRouter.universalRouter(), newRouter);
    }

    function testSetUniversalRouterEmitsEvent() public {
        address newRouter = makeAddr("newRouter");
        address oldRouter = liquidRouter.universalRouter();

        vm.expectEmit(true, true, false, false);
        emit ILiquidRouter.UniversalRouterUpdated(oldRouter, newRouter);

        vm.prank(admin);
        liquidRouter.setUniversalRouter(newRouter);
    }

    function testSetUniversalRouterRevertsOnZeroAddress() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(admin);
        liquidRouter.setUniversalRouter(address(0));
    }

    function testOnlyOwnerCanSetUniversalRouter() public {
        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.setUniversalRouter(makeAddr("newRouter"));
    }

    function testSetFactory() public {
        address newFactory = makeAddr("newFactory");

        vm.prank(admin);
        liquidRouter.setFactory(newFactory);

        assertEq(liquidRouter.factory(), newFactory);
    }

    function testSetFactoryEmitsEvent() public {
        address newFactory = makeAddr("newFactory");
        address oldFactory = liquidRouter.factory();

        vm.expectEmit(true, true, false, false);
        emit ILiquidRouter.FactoryUpdated(oldFactory, newFactory);

        vm.prank(admin);
        liquidRouter.setFactory(newFactory);
    }

    function testSetFactoryRevertsOnZeroAddress() public {
        vm.expectRevert(ILiquidRouter.AddressZero.selector);
        vm.prank(admin);
        liquidRouter.setFactory(address(0));
    }

    function testOnlyOwnerCanSetFactory() public {
        vm.expectRevert();
        vm.prank(user1);
        liquidRouter.setFactory(makeAddr("newFactory"));
    }

    // ============================================
    // FEE TRANSFER FAILURE TESTS
    // ============================================

    function testBeneficiaryTransferFailureFallsBackToProtocol() public {
        // Register a rejecting contract as beneficiary
        RejectingRecipient rejecter = new RejectingRecipient();

        // Create new token and router setup
        MockERC20 newToken = new MockERC20();
        MockUniversalRouter newRouter = new MockUniversalRouter(
            address(newToken)
        );
        vm.deal(address(newRouter), 100 ether);

        vm.prank(admin);
        LiquidRouter newLiquidRouter = new LiquidRouter(
            address(newRouter),
            address(mockFactory)
        );

        // Register token with rejecting beneficiary
        vm.prank(admin);
        newLiquidRouter.registerToken(address(newToken), address(rejecter));

        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        // Buy should succeed despite beneficiary rejection
        vm.prank(user1);
        newLiquidRouter.buy{value: 1 ether}(
            address(newToken),
            user1,
            referrer,
            1,
            abi.encodeWithSelector(
                newRouter.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // Protocol should have received extra (beneficiary fee redirected)
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testReferrerTransferFailureFallsBackToProtocol() public {
        // Use rejecting contract as referrer
        RejectingRecipient rejecter = new RejectingRecipient();

        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        // Buy should succeed despite referrer rejection
        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            address(rejecter), // Rejecting referrer
            1,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // Protocol should have received extra (referrer fee redirected)
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    // ============================================
    // DIFFERENT RECIPIENT TESTS
    // ============================================

    function testBuyToDifferentRecipient() public {
        uint256 ethAmount = 1 ether;
        uint256 user2TokensBefore = token.balanceOf(user2);

        // user1 buys for user2
        vm.prank(user1);
        uint256 tokensReceived = liquidRouter.buy{value: ethAmount}(
            address(token),
            user2, // recipient is user2
            referrer,
            1,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // user2 should have received the tokens
        assertEq(token.balanceOf(user2) - user2TokensBefore, tokensReceived);
    }

    function testSellToDifferentRecipient() public {
        uint256 tokenAmount = 1000e18;
        uint256 user2EthBefore = user2.balance;

        // user1 sells, user2 receives ETH
        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.prank(user1);
        uint256 ethReceived = liquidRouter.sell(
            address(token),
            tokenAmount,
            user2, // recipient is user2
            referrer,
            1,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // user2 should have received the ETH
        assertEq(user2.balance - user2EthBefore, ethReceived);
    }

    // ============================================
    // MINETHOUT SEMANTICS TESTS
    // ============================================

    function testSellMinEthOutIsGrossAmount() public {
        uint256 tokenAmount = 1000e18;
        // Calculate expected gross ETH from swap
        uint256 grossEth = (tokenAmount * 1e18) / router.tokenPerEth();

        // minEthOut is now the GROSS amount expected
        // The contract internally adjusts for fees
        uint256 minEthOut = grossEth;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        // This should succeed because:
        // - grossEthReceived = grossEth
        // - minNetExpected = minEthOut - fee(minEthOut) = grossEth * 0.97
        // - ethReceived = grossEth - fee(grossEth) = grossEth * 0.97
        // - ethReceived >= minNetExpected ✓
        vm.prank(user1);
        uint256 ethReceived = liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            minEthOut,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // Verify we received the expected net amount
        uint256 fee = (grossEth * TOTAL_FEE_BPS) / 10000;
        assertEq(ethReceived, grossEth - fee);
    }

    function testSellSlippageWithGrossMinEthOut() public {
        uint256 tokenAmount = 1000e18;
        uint256 grossEth = (tokenAmount * 1e18) / router.tokenPerEth();

        // Set minEthOut slightly higher than what swap will produce
        // This should fail
        uint256 minEthOut = grossEth + 1;

        vm.prank(user1);
        token.approve(address(liquidRouter), tokenAmount);

        vm.expectRevert(ILiquidRouter.SlippageExceeded.selector);
        vm.prank(user1);
        liquidRouter.sell(
            address(token),
            tokenAmount,
            user1,
            referrer,
            minEthOut,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );
    }

    // ============================================
    // OPTIMIZED REFERRER TRANSFER TESTS
    // ============================================

    function testNoDoubleTransferWhenReferrerIsZero() public {
        // This test verifies gas optimization - when referrer is zero,
        // we don't do a separate transfer to protocol
        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            address(0), // No referrer
            1,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // Protocol should have received its fee + referrer fee in one transfer
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }

    function testNoDoubleTransferWhenReferrerIsProtocol() public {
        // When referrer equals protocol, skip separate transfer
        uint256 protocolBalBefore = protocolFeeRecipient.balance;

        vm.prank(user1);
        liquidRouter.buy{value: 1 ether}(
            address(token),
            user1,
            protocolFeeRecipient, // Referrer is protocol
            1,
            abi.encodeWithSelector(
                router.execute.selector,
                "",
                new bytes[](0),
                block.timestamp
            ),
            block.timestamp + 1 hours
        );

        // Protocol should have received combined fee
        assertTrue(protocolFeeRecipient.balance > protocolBalBefore);
    }
}
