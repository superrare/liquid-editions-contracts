// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title RoutePolicy
/// @notice Validates Universal Router command/input pairs before execution
/// @dev This library enforces recipient and action policy so swap proceeds cannot be redirected.
library RoutePolicy {
    // Universal Router command type mask (strips allow-revert and reserved bits)
    uint8 internal constant COMMAND_TYPE_MASK = 0x3f;

    // Allowlisted Universal Router command bytes
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant V2_SWAP_EXACT_IN = 0x08;
    bytes1 internal constant WRAP_ETH = 0x0b;
    bytes1 internal constant UNWRAP_WETH = 0x0c;
    bytes1 internal constant V4_SWAP = 0x10;

    // Universal Router recipient sentinels
    address internal constant MSG_SENDER =
        address(0x0000000000000000000000000000000000000001);
    address internal constant ROUTER_ADDRESS =
        address(0x0000000000000000000000000000000000000002);

    // Allowlisted V4 action bytes (from v4-periphery Actions.sol)
    uint8 internal constant SWAP_EXACT_IN = 0x07;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;

    error DisallowedCommand(bytes1 command);
    error InvalidRouteRecipient(bytes1 command, address recipient);
    error MissingUnwrapWeth();
    error MissingV4TakeAll();
    error BlockedV4Action(uint8 action);
    error InvalidCommandInput(bytes1 command);

    /// @notice Validates a Universal Router route before execution
    /// @param commands Universal Router command bytes
    /// @param inputs ABI-encoded command inputs (one per command)
    /// @param expectsEthOutput Whether this route is expected to deliver ETH to msg.sender
    function validateRoute(
        bytes calldata commands,
        bytes[] calldata inputs,
        bool expectsEthOutput
    ) internal pure {
        bool outputsWethToRouter;
        bool hasUnwrapWethToSender;

        uint256 commandCount = commands.length;
        for (uint256 i; i < commandCount; ) {
            bytes1 command = _commandType(commands[i]);
            bytes calldata input = inputs[i];

            // Strict allowlist: only permit commands we explicitly handle
            if (command == V2_SWAP_EXACT_IN || command == V3_SWAP_EXACT_IN) {
                address recipient = _decodeRecipient(command, input);
                if (recipient != MSG_SENDER && recipient != ROUTER_ADDRESS) {
                    revert InvalidRouteRecipient(command, recipient);
                }
                if (expectsEthOutput && recipient == ROUTER_ADDRESS) {
                    outputsWethToRouter = true;
                }
            } else if (command == WRAP_ETH) {
                address recipient = _decodeRecipient(command, input);
                if (recipient != ROUTER_ADDRESS) {
                    revert InvalidRouteRecipient(command, recipient);
                }
            } else if (command == UNWRAP_WETH) {
                address recipient = _decodeRecipient(command, input);
                if (recipient != MSG_SENDER) {
                    revert InvalidRouteRecipient(command, recipient);
                }
                hasUnwrapWethToSender = true;
            } else if (command == V4_SWAP) {
                _validateV4Actions(input);
            } else {
                // Default-reject: any command not explicitly allowlisted is blocked.
                // This covers PERMIT2_TRANSFER_FROM, EXECUTE_SUB_PLAN, SWEEP,
                // TRANSFER, PAY_PORTION, position manager calls, etc.
                revert DisallowedCommand(command);
            }

            unchecked {
                ++i;
            }
        }

        if (
            expectsEthOutput &&
            outputsWethToRouter &&
            !hasUnwrapWethToSender
        ) {
            revert MissingUnwrapWeth();
        }
    }

    function _commandType(bytes1 rawCommand) private pure returns (bytes1) {
        return bytes1(uint8(rawCommand) & COMMAND_TYPE_MASK);
    }

    function _decodeRecipient(
        bytes1 command,
        bytes calldata input
    ) private pure returns (address recipient) {
        if (input.length < 32) revert InvalidCommandInput(command);
        recipient = abi.decode(input, (address));
    }

    function _validateV4Actions(bytes calldata input) private pure {
        (bytes memory actions, ) = abi.decode(input, (bytes, bytes[]));

        bool hasTakeAll;
        uint256 actionCount = actions.length;
        for (uint256 i; i < actionCount; ) {
            uint8 action = uint8(actions[i]);
            if (action == SWAP_EXACT_IN) {
                // Explicitly permitted action.
            } else if (action == SETTLE_ALL) {
                // Explicitly permitted action.
            } else if (action == TAKE_ALL) {
                hasTakeAll = true;
            } else {
                // Default-reject: any V4 action not explicitly allowlisted is blocked.
                revert BlockedV4Action(action);
            }

            unchecked {
                ++i;
            }
        }

        if (!hasTakeAll) revert MissingV4TakeAll();
    }
}
