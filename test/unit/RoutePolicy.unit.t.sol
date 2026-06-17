// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {RoutePolicy} from "liquid-editions/RoutePolicy.sol";

contract RoutePolicyHarness {
    function validate(
        bytes calldata commands,
        bytes[] calldata inputs,
        bool expectsEthOutput
    ) external pure {
        RoutePolicy.validateRoute(commands, inputs, expectsEthOutput);
    }
}

contract RoutePolicyUnitTest is Test {
    RoutePolicyHarness internal harness;
    uint8 internal constant ALLOW_REVERT_FLAG = 0x80;
    uint256 internal constant CONTRACT_BALANCE =
        0x8000000000000000000000000000000000000000000000000000000000000000;
    uint256 internal constant OPEN_DELTA = 0;

    address internal constant MSG_SENDER =
        address(0x0000000000000000000000000000000000000001);
    address internal constant ROUTER_ADDRESS =
        address(0x0000000000000000000000000000000000000002);

    function setUp() public {
        harness = new RoutePolicyHarness();
    }

    function testValidateRouteRevertsOnDisallowedCommand() public {
        bytes memory commands = hex"04"; // SWEEP
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = "";

        vm.expectRevert(
            abi.encodeWithSelector(
                RoutePolicy.DisallowedCommand.selector,
                bytes1(0x04)
            )
        );
        harness.validate(commands, inputs, false);
    }

    function testValidateRouteRevertsOnInvalidV3Recipient() public {
        bytes memory commands = hex"00"; // V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(0xBEEF),
            uint256(1),
            uint256(1),
            bytes(""),
            true
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                RoutePolicy.InvalidRouteRecipient.selector,
                bytes1(0x00),
                address(0xBEEF)
            )
        );
        harness.validate(commands, inputs, false);
    }

    function testValidateRouteRevertsWhenEthOutputMissingUnwrapWeth() public {
        bytes memory commands = hex"00"; // V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            ROUTER_ADDRESS,
            uint256(1),
            uint256(1),
            bytes(""),
            true
        );

        vm.expectRevert(RoutePolicy.MissingUnwrapWeth.selector);
        harness.validate(commands, inputs, true);
    }

    function testValidateRouteRevertsOnBlockedV4Action() public {
        bytes memory commands = hex"10"; // V4_SWAP
        bytes[] memory inputs = new bytes[](1);
        bytes memory actions = abi.encodePacked(uint8(0x09), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        inputs[0] = abi.encode(actions, params);

        vm.expectRevert(
            abi.encodeWithSelector(
                RoutePolicy.BlockedV4Action.selector,
                uint8(0x09)
            )
        );
        harness.validate(commands, inputs, false);
    }

    function testValidateRouteRevertsOnInvalidV4ActionSequence() public {
        bytes memory commands = hex"10"; // V4_SWAP
        bytes[] memory inputs = new bytes[](1);
        bytes memory actions = abi.encodePacked(uint8(0x0c)); // SETTLE_ALL only
        bytes[] memory params = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.expectRevert(RoutePolicy.InvalidV4ActionSequence.selector);
        harness.validate(commands, inputs, false);
    }

    function testValidateRouteAllowsV2ToRouterWithUnwrapToSender() public view {
        bytes memory commands = hex"080c"; // V2_SWAP_EXACT_IN + UNWRAP_WETH
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            ROUTER_ADDRESS,
            uint256(1),
            uint256(1),
            new address[](0),
            false
        );
        inputs[1] = abi.encode(MSG_SENDER, uint256(1));

        harness.validate(commands, inputs, true);
    }

    function testValidateRouteAllowsUnwrapToRouterThenV4TokenOutput()
        public
        view
    {
        bytes memory commands = hex"100c10"; // V4_SWAP + UNWRAP_WETH + V4_SWAP
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = _encodeSingleTakeRouter();
        inputs[1] = abi.encode(ROUTER_ADDRESS, uint256(1));
        inputs[2] = _encodeSettleSingleTakeAll(address(0));

        harness.validate(commands, inputs, false);
    }

    function testValidateRouteAllowsUnwrapToRouterThenWrapEthThenV3TokenOutput()
        public
        view
    {
        bytes memory commands = hex"100c0b00"; // V4_SWAP + UNWRAP_WETH + WRAP_ETH + V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](4);
        inputs[0] = _encodeSingleTakeRouter();
        inputs[1] = abi.encode(ROUTER_ADDRESS, uint256(1));
        inputs[2] = abi.encode(ROUTER_ADDRESS, CONTRACT_BALANCE);
        inputs[3] = abi.encode(
            MSG_SENDER,
            uint256(1),
            uint256(1),
            bytes(""),
            false
        );

        harness.validate(commands, inputs, false);
    }

    function testValidateRouteRevertsOnAllowRevertBit() public {
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(bytes1(0x08)) | ALLOW_REVERT_FLAG) // V2_SWAP_EXACT_IN | allowRevert
        );
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            ROUTER_ADDRESS,
            uint256(1),
            uint256(1),
            new address[](0),
            false
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                RoutePolicy.DisallowedCommandFlags.selector,
                bytes1(uint8(bytes1(0x08)) | ALLOW_REVERT_FLAG)
            )
        );
        harness.validate(commands, inputs, true);
    }

    function testValidateRouteRevertsWhenTokenOutputFinalRecipientIsRouter()
        public
    {
        bytes memory commands = hex"00"; // V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            ROUTER_ADDRESS,
            uint256(1),
            uint256(1),
            bytes(""),
            true
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                RoutePolicy.InvalidFinalRecipient.selector,
                bytes1(0x00),
                ROUTER_ADDRESS
            )
        );
        harness.validate(commands, inputs, false);
    }

    function testValidateRouteRevertsWhenEthOutputRouteDoesNotEndInUnwrap()
        public
    {
        bytes memory commands = hex"080c0b"; // V2_SWAP_EXACT_IN + UNWRAP_WETH + WRAP_ETH
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(
            ROUTER_ADDRESS,
            uint256(1),
            uint256(1),
            new address[](0),
            false
        );
        inputs[1] = abi.encode(MSG_SENDER, uint256(1));
        inputs[2] = abi.encode(ROUTER_ADDRESS, uint256(1));

        vm.expectRevert(
            abi.encodeWithSelector(
                RoutePolicy.InvalidFinalRouteCommand.selector,
                bytes1(0x0b)
            )
        );
        harness.validate(commands, inputs, true);
    }

    function testValidateRouteRevertsOnInputLengthTooShort() public {
        bytes memory commands = hex"00"; // V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = hex"1234"; // less than 32 bytes

        vm.expectRevert(
            abi.encodeWithSelector(
                RoutePolicy.InvalidCommandInput.selector,
                bytes1(0x00)
            )
        );
        harness.validate(commands, inputs, false);
    }

    function testValidateRouteRevertsWhenTokenOutputLastCommandWrapEth() public {
        bytes memory commands = hex"0b"; // WRAP_ETH
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            ROUTER_ADDRESS,
            uint256(1)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                RoutePolicy.InvalidFinalRouteCommand.selector,
                bytes1(0x0b)
            )
        );
        harness.validate(commands, inputs, false);
    }

    function _encodeSettleSingleTakeAll(address settleCurrency)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(
            uint8(0x0b),
            uint8(0x06),
            uint8(0x0f)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(settleCurrency, CONTRACT_BALANCE, false);
        params[1] = hex"1234";
        params[2] = abi.encode(address(0x5678), uint256(1));
        return abi.encode(actions, params);
    }

    function _encodeSingleTakeRouter()
        internal
        pure
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(
            uint8(0x06),
            uint8(0x0c),
            uint8(0x0e)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = hex"1234";
        params[1] = abi.encode(address(0x1234), uint256(1));
        params[2] = abi.encode(address(0x5678), ROUTER_ADDRESS, OPEN_DELTA);
        return abi.encode(actions, params);
    }
}
