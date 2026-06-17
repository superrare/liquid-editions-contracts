// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title RoutePolicy
/// @notice Validates Universal Router command/input pairs before execution
/// @dev This library enforces recipient and action policy so swap proceeds cannot be redirected.
library RoutePolicy {
    // Universal Router command type mask (strips allow-revert and reserved bits)
    uint8 internal constant COMMAND_TYPE_MASK = 0x3f;
    uint8 internal constant COMMAND_FLAGS_MASK = 0xc0;

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
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SWAP_EXACT_IN = 0x07;
    uint8 internal constant SETTLE = 0x0b;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE = 0x0e;
    uint8 internal constant TAKE_ALL = 0x0f;

    // V4 action sentinels (from ActionConstants.sol)
    uint256 internal constant OPEN_DELTA = 0;
    uint256 internal constant CONTRACT_BALANCE =
        0x8000000000000000000000000000000000000000000000000000000000000000;

    error DisallowedCommand(bytes1 command);
    error DisallowedCommandFlags(bytes1 command);
    error InvalidRouteRecipient(bytes1 command, address recipient);
    error MissingUnwrapWeth();
    error InvalidFinalRouteCommand(bytes1 command);
    error InvalidFinalRecipient(bytes1 command, address recipient);
    error BlockedV4Action(uint8 action);
    error InvalidCommandInput(bytes1 command);
    error InvalidV4ActionSequence();
    error InvalidV4ActionParameters(uint8 action);

    struct V4ActionResolution {
        bool consumesRouterBalance;
        bool outputsToRouter;
    }

    /// @notice Validates a Universal Router route before execution
    /// @param commands Universal Router command bytes
    /// @param inputs ABI-encoded command inputs (one per command)
    /// @param expectsEthOutput Whether this route is expected to deliver ETH to msg.sender
    function validateRoute(
        bytes memory commands,
        bytes[] memory inputs,
        bool expectsEthOutput
    ) internal pure {
        bool pendingRouterBalance;
        bytes1 lastCommand;

        uint256 commandCount = commands.length;
        for (uint256 i; i < commandCount; ) {
            bytes1 rawCommand = commands[i];
            if ((uint8(rawCommand) & COMMAND_FLAGS_MASK) != 0) {
                revert DisallowedCommandFlags(rawCommand);
            }

            bytes1 command = _commandType(rawCommand);
            bytes memory input = inputs[i];

            // Strict allowlist: only permit commands we explicitly handle
            if (command == V2_SWAP_EXACT_IN || command == V3_SWAP_EXACT_IN) {
                (
                    address recipient,
                    bool payerIsUser
                ) = _decodeSwapRecipientAndPayer(command, input);
                if (recipient != MSG_SENDER && recipient != ROUTER_ADDRESS) {
                    revert InvalidRouteRecipient(command, recipient);
                }

                if (!payerIsUser) {
                    pendingRouterBalance = false;
                }

                if (recipient == ROUTER_ADDRESS) {
                    pendingRouterBalance = true;
                }
            } else if (command == WRAP_ETH) {
                address recipient = _decodeRecipient(command, input);
                if (recipient != ROUTER_ADDRESS) {
                    revert InvalidRouteRecipient(command, recipient);
                }
                pendingRouterBalance = true;
            } else if (command == UNWRAP_WETH) {
                address recipient = _decodeRecipient(command, input);
                if (recipient != MSG_SENDER && recipient != ROUTER_ADDRESS) {
                    revert InvalidRouteRecipient(command, recipient);
                }
                if (!pendingRouterBalance) {
                    revert MissingUnwrapWeth();
                }
                pendingRouterBalance = recipient == ROUTER_ADDRESS;
            } else if (command == V4_SWAP) {
                V4ActionResolution memory resolution = _validateV4Actions(
                    input
                );
                if (resolution.consumesRouterBalance) {
                    pendingRouterBalance = false;
                }
                if (resolution.outputsToRouter) {
                    pendingRouterBalance = true;
                }
            } else {
                // Default-reject: any command not explicitly allowlisted is blocked.
                // This covers PERMIT2_TRANSFER_FROM, EXECUTE_SUB_PLAN, SWEEP,
                // TRANSFER, PAY_PORTION, position manager calls, etc.
                revert DisallowedCommand(command);
            }

            lastCommand = command;

            unchecked {
                ++i;
            }
        }

        // Enforce final route shape so output cannot remain in ROUTER_ADDRESS.
        if (expectsEthOutput) {
            if (lastCommand == WRAP_ETH) {
                revert InvalidFinalRouteCommand(lastCommand);
            }

            if (pendingRouterBalance) {
                revert MissingUnwrapWeth();
            }

            // ETH output must end with either explicit unwrap-to-sender
            // or a final V4 route that takes native ETH to msg.sender.
            if (lastCommand != UNWRAP_WETH && lastCommand != V4_SWAP) {
                revert InvalidFinalRouteCommand(lastCommand);
            }
        } else {
            if (lastCommand == WRAP_ETH || lastCommand == UNWRAP_WETH) {
                revert InvalidFinalRouteCommand(lastCommand);
            }

            if (pendingRouterBalance) {
                revert InvalidFinalRecipient(lastCommand, ROUTER_ADDRESS);
            }

            if (
                lastCommand != V2_SWAP_EXACT_IN &&
                lastCommand != V3_SWAP_EXACT_IN &&
                lastCommand != V4_SWAP
            ) {
                revert InvalidFinalRouteCommand(lastCommand);
            }
        }
    }

    /// @notice Extracts command type from raw command byte by masking out flags
    /// @dev Universal Router command bytes have a two-part structure:
    ///      - Lower 6 bits (0x3f): Command type (e.g., V3_SWAP_EXACT_IN = 0x00)
    ///      - Upper 2 bits (0xc0): Flags (allow-revert bit, reserved bits)
    ///      This function extracts only the command type by masking with COMMAND_TYPE_MASK (0x3f),
    ///      effectively stripping the upper 2 bits. This allows validation to focus on command type
    ///      regardless of flag settings (flags are validated separately in validateRoute()).
    /// @param rawCommand Raw command byte with potential flags in upper bits
    /// @return Command type byte with flags stripped (lower 6 bits only)
    function _commandType(bytes1 rawCommand) private pure returns (bytes1) {
        return bytes1(uint8(rawCommand) & COMMAND_TYPE_MASK);
    }

    /// @notice Decodes recipient address from Universal Router command input
    /// @dev Universal Router command inputs are ABI-encoded tuples. For WRAP/UNWRAP,
    ///      the first parameter is always the recipient address.
    function _decodeRecipient(
        bytes1 command,
        bytes memory input
    ) private pure returns (address recipient) {
        if (input.length < 32) revert InvalidCommandInput(command);
        recipient = abi.decode(input, (address));
    }

    /// @notice Decodes recipient and payer flag from a V2/V3 exact-input command
    /// @dev Both variants share the same fixed ABI head:
    ///      (address recipient, uint256 amountIn, uint256 amountOutMin, <dynamic>, bool payerIsUser)
    function _decodeSwapRecipientAndPayer(
        bytes1 command,
        bytes memory input
    ) private pure returns (address recipient, bool payerIsUser) {
        if (input.length < 160) revert InvalidCommandInput(command);

        assembly {
            recipient := mload(add(input, 32))
            payerIsUser := iszero(iszero(mload(add(input, 160))))
        }
    }

    /// @notice Validates V4 swap actions and returns how the route interacts with router custody
    /// @dev The policy intentionally admits only the exact action sequences used by the router today:
    ///      1. SWAP_EXACT_IN -> SETTLE_ALL -> TAKE_ALL
    ///      2. SETTLE -> SWAP_EXACT_IN_SINGLE -> TAKE_ALL
    ///      3. SWAP_EXACT_IN_SINGLE -> SETTLE_ALL -> TAKE
    ///      4. SWAP_EXACT_IN -> SETTLE_ALL -> TAKE
    function _validateV4Actions(
        bytes memory input
    ) private pure returns (V4ActionResolution memory resolution) {
        (bytes memory actions, bytes[] memory params) = abi.decode(
            input,
            (bytes, bytes[])
        );

        if (actions.length != 3 || params.length != 3) {
            revert InvalidV4ActionSequence();
        }

        uint8 action0 = uint8(actions[0]);
        uint8 action1 = uint8(actions[1]);
        uint8 action2 = uint8(actions[2]);

        _ensureAllowlistedV4Action(action0);
        _ensureAllowlistedV4Action(action1);
        _ensureAllowlistedV4Action(action2);

        if (
            action0 == SWAP_EXACT_IN &&
            action1 == SETTLE_ALL &&
            action2 == TAKE_ALL
        ) {
            return resolution;
        }

        if (
            action0 == SETTLE &&
            action1 == SWAP_EXACT_IN_SINGLE &&
            action2 == TAKE_ALL
        ) {
            _validateSettleAction(params[0]);
            resolution.consumesRouterBalance = true;
            return resolution;
        }

        if (
            action0 == SWAP_EXACT_IN_SINGLE &&
            action1 == SETTLE_ALL &&
            action2 == TAKE
        ) {
            _validateTakeAction(params[2]);
            resolution.outputsToRouter = true;
            return resolution;
        }

        if (
            action0 == SWAP_EXACT_IN && action1 == SETTLE_ALL && action2 == TAKE
        ) {
            _validateTakeAction(params[2]);
            resolution.outputsToRouter = true;
            return resolution;
        }

        revert InvalidV4ActionSequence();
    }

    function _ensureAllowlistedV4Action(uint8 action) private pure {
        if (
            action != SWAP_EXACT_IN_SINGLE &&
            action != SWAP_EXACT_IN &&
            action != SETTLE &&
            action != SETTLE_ALL &&
            action != TAKE &&
            action != TAKE_ALL
        ) {
            revert BlockedV4Action(action);
        }
    }

    function _validateSettleAction(bytes memory input) private pure {
        (address currency, uint256 amount, bool payerIsUser) = abi.decode(
            input,
            (address, uint256, bool)
        );
        currency;

        if (payerIsUser || amount != CONTRACT_BALANCE) {
            revert InvalidV4ActionParameters(SETTLE);
        }
    }

    function _validateTakeAction(bytes memory input) private pure {
        (address currency, address recipient, uint256 amount) = abi.decode(
            input,
            (address, address, uint256)
        );
        currency;

        if (recipient != ROUTER_ADDRESS || amount != OPEN_DELTA) {
            revert InvalidV4ActionParameters(TAKE);
        }
    }
}
