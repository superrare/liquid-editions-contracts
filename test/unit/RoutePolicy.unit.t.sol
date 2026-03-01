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
        bytes memory actions = abi.encodePacked(uint8(0x09), uint8(0x0f)); // SETTLE + TAKE_ALL
        bytes[] memory params = new bytes[](0);
        inputs[0] = abi.encode(actions, params);

        vm.expectRevert(
            abi.encodeWithSelector(
                RoutePolicy.BlockedV4Action.selector,
                uint8(0x09)
            )
        );
        harness.validate(commands, inputs, false);
    }

    function testValidateRouteRevertsOnMissingV4TakeAll() public {
        bytes memory commands = hex"10"; // V4_SWAP
        bytes[] memory inputs = new bytes[](1);
        bytes memory actions = abi.encodePacked(uint8(0x0c)); // SETTLE_ALL only
        bytes[] memory params = new bytes[](0);
        inputs[0] = abi.encode(actions, params);

        vm.expectRevert(RoutePolicy.MissingV4TakeAll.selector);
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
}
