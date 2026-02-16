// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BoundaryConstants} from "liquid-editions-test/helpers/bases/BoundaryConstants.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";

/// @title Mock Universal Router for LiquidRouter testing
contract MockUniversalRouterForRouter {
    MockERC20 public token;
    uint256 public tokenPerEth = 1000e18;
    bool public shouldFail;
    uint256 public pullAmountOverride;

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

    receive() external payable {
        if (msg.value > 0 && !shouldFail) {
            uint256 tokensOut = (msg.value * tokenPerEth) / 1e18;
            token.mint(msg.sender, tokensOut);
        }
    }

    function execute(
        bytes calldata,
        bytes[] calldata,
        uint256
    ) external payable virtual {
        if (shouldFail) revert("Router: swap failed");

        if (msg.value > 0) {
            uint256 tokensOut = (msg.value * tokenPerEth) / 1e18;
            token.mint(msg.sender, tokensOut);
        } else {
            uint256 approved = token.allowance(msg.sender, PERMIT2);
            if (approved > 0) {
                uint256 amountToPull = pullAmountOverride > 0
                    ? pullAmountOverride
                    : approved;
                if (amountToPull > approved) amountToPull = approved;

                token.transferFrom(msg.sender, address(this), amountToPull);
                uint256 ethOut = (amountToPull * 1e18) / tokenPerEth;
                (bool success, ) = msg.sender.call{value: ethOut}("");
                require(success, "ETH transfer failed");
            }
        }
    }

    function fundRouter() external payable {}
}

/// @title Mock Universal Router with ETH refund capability
contract MockUniversalRouterWithRefundForRouter is
    MockUniversalRouterForRouter
{
    bool public shouldRefund;
    uint256 public refundAmount;

    constructor(address _token) MockUniversalRouterForRouter(_token) {}

    function setShouldRefund(bool _should) external {
        shouldRefund = _should;
    }

    function setRefundAmount(uint256 _amount) external {
        refundAmount = _amount;
    }

    function execute(
        bytes calldata,
        bytes[] calldata,
        uint256
    ) external payable override {
        if (shouldFail) revert("Router: swap failed");

        if (msg.value > 0) {
            uint256 tokensOut = (msg.value * tokenPerEth) / 1e18;
            token.mint(msg.sender, tokensOut);

            if (shouldRefund && refundAmount > 0) {
                (bool success, ) = msg.sender.call{value: refundAmount}("");
                require(success, "Refund failed");
            }
        } else {
            uint256 approved = token.allowance(msg.sender, PERMIT2);
            if (approved > 0) {
                uint256 amountToPull = pullAmountOverride > 0
                    ? pullAmountOverride
                    : approved;
                if (amountToPull > approved) amountToPull = approved;

                token.transferFrom(msg.sender, address(this), amountToPull);
                uint256 ethOut = (amountToPull * 1e18) / tokenPerEth;
                (bool success, ) = msg.sender.call{value: ethOut}("");
                require(success, "ETH transfer failed");
            }
        }
    }
}

/// @title Reentrant Recipient for reentrancy tests
contract ReentrantRecipientForRouter {
    LiquidRouter public router;
    bool public shouldReenter;
    address public token;
    address public beneficiary;

    constructor(address payable _router) {
        router = LiquidRouter(_router);
    }

    function setShouldReenter(bool _should) external {
        shouldReenter = _should;
    }

    function setToken(address _token) external {
        token = _token;
    }

    function setBeneficiary(address _beneficiary) external {
        beneficiary = _beneficiary;
    }

    receive() external payable {
        if (shouldReenter) {
            router.buy{value: 0.01 ether}(
                token,
                beneficiary,
                address(0),
                1,
                abi.encodePacked(bytes1(0x00)),
                block.timestamp + 1 hours
            );
        }
    }
}

/// @title Mock Permit2 for LiquidRouter
contract MockPermit2ForRouter {
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

/// @title Mock RARE Burner for LiquidRouter
contract MockRAREBurnerForRouter {
    uint256 public deposited;
    bool public shouldFail;

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    function depositForBurn() external payable {
        if (shouldFail) revert("Burner: deposit failed");
        deposited += msg.value;
    }

    receive() external payable {}
}

/// @title Rejecting Recipient for fee failure tests
contract RejectingRecipientForRouter {
    receive() external payable {
        revert("I reject ETH");
    }
}

/// @title LiquidRouter Unit Test Base
/// @notice Shared setUp, mocks, and helpers for all LiquidRouter unit tests
abstract contract LiquidRouterUnitTestBase is Test {
    LiquidRouter public liquidRouter;
    MockERC20 public token;
    MockUniversalRouterForRouter public router;
    MockRAREBurnerForRouter public burner;

    address public admin = makeAddr("admin");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public beneficiary = makeAddr("beneficiary");
    address public referrer = makeAddr("referrer");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    uint256 constant TOTAL_FEE_BPS = 400;
    uint256 constant BENEFICIARY_FEE_BPS = 2500;
    uint256 constant RARE_BURN_FEE_BPS = 5000;
    uint256 constant PROTOCOL_FEE_BPS = 3000;
    uint256 constant REFERRER_FEE_BPS = 2000;

    function deployLiquidRouter(
        address universalRouter,
        address _protocolFeeRecipient,
        address rareBurner,
        uint256 rareBurnFeeBPS,
        uint256 protocolFeeBPS,
        uint256 referrerFeeBPS,
        address owner
    ) internal returns (LiquidRouter) {
        return
            new LiquidRouter(
                owner,
                universalRouter,
                _protocolFeeRecipient,
                rareBurner,
                rareBurnFeeBPS,
                protocolFeeBPS,
                referrerFeeBPS
            );
    }

    function setUp() public virtual {
        token = new MockERC20();

        router = new MockUniversalRouterForRouter(address(token));
        vm.deal(address(router), 1000 ether);

        address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        MockPermit2ForRouter mockPermit2 = new MockPermit2ForRouter();
        vm.etch(PERMIT2, address(mockPermit2).code);

        burner = new MockRAREBurnerForRouter();

        liquidRouter = deployLiquidRouter(
            address(router),
            protocolFeeRecipient,
            address(burner),
            RARE_BURN_FEE_BPS,
            PROTOCOL_FEE_BPS,
            REFERRER_FEE_BPS,
            admin
        );

        vm.prank(admin);
        liquidRouter.registerToken(address(token), beneficiary);

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        token.mint(user1, 10000e18);
        token.mint(user2, 10000e18);
    }
}
