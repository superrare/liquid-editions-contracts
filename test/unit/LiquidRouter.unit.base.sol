// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BoundaryConstants} from "liquid-editions-test/helpers/bases/BoundaryConstants.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";

contract EthDonorForRouter {
    function donate(address payable to, uint256 amount) external {
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH donation failed");
    }

    receive() external payable {}
}

/// @title Mock Universal Router for LiquidRouter testing
contract MockUniversalRouterForRouter {
    address internal constant ETH_SINK =
        address(0x000000000000000000000000000000000000dEaD);
    MockERC20 public token;
    MockERC20 public outputToken;
    uint256 public tokenPerEth = 1000e18;
    bool public shouldFail;
    uint256 public pullAmountOverride;
    bool public retainEthOnExecute;
    address public ethDonationSource;
    uint256 public ethDonationAmount;

    address internal constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    constructor(address _token) {
        token = MockERC20(_token);
        outputToken = MockERC20(_token);
    }

    function setOutputToken(address _outputToken) external {
        outputToken = MockERC20(_outputToken);
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

    function setRetainEthOnExecute(bool retain) external {
        retainEthOnExecute = retain;
    }

    function setEthDonation(address source, uint256 amount) external {
        ethDonationSource = source;
        ethDonationAmount = amount;
    }

    receive() external payable {
        if (msg.value > 0 && !shouldFail) {
            uint256 tokensOut = (msg.value * tokenPerEth) / 1e18;
            outputToken.mint(msg.sender, tokensOut);
        }
    }

    function _consumeEth(uint256 amount) internal {
        if (amount == 0) return;

        (bool success, ) = ETH_SINK.call{value: amount}("");
        require(success, "ETH consume failed");
    }

    function _donateEthToSelf() internal {
        if (ethDonationSource == address(0) || ethDonationAmount == 0) return;
        EthDonorForRouter(payable(ethDonationSource)).donate(
            payable(address(this)),
            ethDonationAmount
        );
    }

    function execute(
        bytes calldata commands,
        bytes[] calldata,
        uint256
    ) external payable virtual {
        if (shouldFail) revert("Router: swap failed");

        if (msg.value > 0) {
            uint256 tokensOut = (msg.value * tokenPerEth) / 1e18;
            outputToken.mint(msg.sender, tokensOut);
            if (!retainEthOnExecute) {
                _consumeEth(msg.value);
            }
            _donateEthToSelf();
        } else {
            uint256 approved = token.allowance(msg.sender, PERMIT2);
            if (approved > 0) {
                uint256 amountToPull = pullAmountOverride > 0
                    ? pullAmountOverride
                    : approved;
                if (amountToPull > approved) amountToPull = approved;

                token.transferFrom(msg.sender, address(this), amountToPull);
                // Test-only switch: multi-command routes emulate token output.
                // Single-command routes emulate ETH output.
                if (commands.length > 1) {
                    uint256 tokensOut = (amountToPull * tokenPerEth) / 1e18;
                    outputToken.mint(msg.sender, tokensOut);
                } else {
                    uint256 ethOut = (amountToPull * 1e18) / tokenPerEth;
                    (bool success, ) = msg.sender.call{value: ethOut}("");
                    require(success, "ETH transfer failed");
                }
                _donateEthToSelf();
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
        bytes calldata commands,
        bytes[] calldata,
        uint256
    ) external payable override {
        if (shouldFail) revert("Router: swap failed");

        if (msg.value > 0) {
            uint256 tokensOut = (msg.value * tokenPerEth) / 1e18;
            outputToken.mint(msg.sender, tokensOut);
            uint256 ethToConsume = msg.value;

            if (shouldRefund && refundAmount > 0) {
                ethToConsume -= refundAmount;
                (bool success, ) = msg.sender.call{value: refundAmount}("");
                require(success, "Refund failed");
            }
            if (!retainEthOnExecute) {
                _consumeEth(ethToConsume);
            }
            _donateEthToSelf();
        } else {
            uint256 approved = token.allowance(msg.sender, PERMIT2);
            if (approved > 0) {
                uint256 amountToPull = pullAmountOverride > 0
                    ? pullAmountOverride
                    : approved;
                if (amountToPull > approved) amountToPull = approved;

                token.transferFrom(msg.sender, address(this), amountToPull);
                if (commands.length > 1) {
                    uint256 tokensOut = (amountToPull * tokenPerEth) / 1e18;
                    outputToken.mint(msg.sender, tokensOut);
                } else {
                    uint256 ethOut = (amountToPull * 1e18) / tokenPerEth;
                    (bool success, ) = msg.sender.call{value: ethOut}("");
                    require(success, "ETH transfer failed");
                }

                if (shouldRefund && refundAmount > 0) {
                    (bool refundSuccess, ) = msg.sender.call{value: refundAmount}("");
                    require(refundSuccess, "Refund failed");
                }
                _donateEthToSelf();
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
            bytes[] memory inputs = new bytes[](1);
            bytes memory actions = abi.encodePacked(uint8(0x07), uint8(0x0c), uint8(0x0f));
            bytes[] memory params = new bytes[](3);
            inputs[0] = abi.encode(actions, params);
            router.buy{value: 0.01 ether}(
                token,
                beneficiary,
                1,
                hex"10",
                inputs,
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

/// @title Gas Hog Recipient for fee transfer stress tests
contract GasHogRecipientForRouter {
    receive() external payable {
        while (true) {}
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

    function _validRoute()
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        commands = hex"10";
        inputs = new bytes[](1);

        // V4 route with allowed actions only.
        bytes memory actions = abi.encodePacked(uint8(0x07), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        inputs[0] = abi.encode(actions, params);
    }

    /// @notice Shared registry exposed for tests that need to register tokens directly
    LiquidRegistry internal liquidRegistry;

    function deployLiquidRouter(
        address universalRouter,
        address, // _protocolFeeRecipient — no longer used by router (fees handled by LiquidGuard)
        address owner
    ) internal returns (LiquidRouter) {
        liquidRegistry = new LiquidRegistry(owner);
        LiquidRouter newLiquidRouter = new LiquidRouter(
            owner,
            universalRouter,
            address(liquidRegistry)
        );
        return newLiquidRouter;
    }

    /// @notice Fee BPS is now managed by LiquidGuard hook, not the router.
    ///         Returns TOTAL_FEE_BPS constant for backward compat with existing test math.
    function _totalFeeBpsForRouter(
        LiquidRouter
    ) internal pure returns (uint256) {
        return TOTAL_FEE_BPS;
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
            admin
        );

        vm.prank(admin);
        liquidRegistry.setBeneficiary(address(token), beneficiary);

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        token.mint(user1, 10000e18);
        token.mint(user2, 10000e18);
    }
}
