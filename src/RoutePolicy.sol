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
    uint8 internal constant SWAP_EXACT_IN = 0x07;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;

    error DisallowedCommand(bytes1 command);
    error DisallowedCommandFlags(bytes1 command);
    error InvalidRouteRecipient(bytes1 command, address recipient);
    error MissingUnwrapWeth();
    error MissingV4TakeAll();
    error InvalidFinalRouteCommand(bytes1 command);
    error InvalidFinalRecipient(bytes1 command, address recipient);
    error BlockedV4Action(uint8 action);
    error InvalidCommandInput(bytes1 command);

    /// @notice Validates a Universal Router route before execution
    /// @param commands Universal Router command bytes
    /// @param inputs ABI-encoded command inputs (one per command)
    /// @param expectsEthOutput Whether this route is expected to deliver ETH to msg.sender
    function validateRoute(
        bytes memory commands,
        bytes[] memory inputs,
        bool expectsEthOutput
    ) internal pure {
        bool outputsWethToRouter;
        bool hasUnwrapWethToSender;
        bytes1 lastCommand;
        address lastRecipient;

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
                address recipient = _decodeRecipient(command, input);
                if (recipient != MSG_SENDER && recipient != ROUTER_ADDRESS) {
                    revert InvalidRouteRecipient(command, recipient);
                }
                if (expectsEthOutput && recipient == ROUTER_ADDRESS) {
                    outputsWethToRouter = true;
                }

                lastRecipient = recipient;
            } else if (command == WRAP_ETH) {
                address recipient = _decodeRecipient(command, input);
                if (recipient != ROUTER_ADDRESS) {
                    revert InvalidRouteRecipient(command, recipient);
                }
                lastRecipient = recipient;
            } else if (command == UNWRAP_WETH) {
                address recipient = _decodeRecipient(command, input);
                if (recipient != MSG_SENDER) {
                    revert InvalidRouteRecipient(command, recipient);
                }
                hasUnwrapWethToSender = true;
                lastRecipient = recipient;
            } else if (command == V4_SWAP) {
                _validateV4Actions(input);
                lastRecipient = MSG_SENDER; // TAKE_ALL resolves to msgSender() in Universal Router.
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

        if (
            expectsEthOutput &&
            outputsWethToRouter &&
            !hasUnwrapWethToSender
        ) {
            revert MissingUnwrapWeth();
        }

        // Enforce final route shape so output cannot remain in ROUTER_ADDRESS.
        if (expectsEthOutput) {
            // ETH output must end with either explicit unwrap-to-sender or v4 TAKE_ALL route.
            if (lastCommand != UNWRAP_WETH && lastCommand != V4_SWAP) {
                revert InvalidFinalRouteCommand(lastCommand);
            }
            // If route used router-held WETH, unwrap must be the final command.
            if (outputsWethToRouter && lastCommand != UNWRAP_WETH) {
                revert InvalidFinalRouteCommand(lastCommand);
            }
        } else {
            // Token-output routes must deliver final output to msg.sender.
            if (lastCommand == V2_SWAP_EXACT_IN || lastCommand == V3_SWAP_EXACT_IN) {
                if (lastRecipient != MSG_SENDER) {
                    revert InvalidFinalRecipient(lastCommand, lastRecipient);
                }
            } else if (lastCommand == WRAP_ETH || lastCommand == UNWRAP_WETH) {
                revert InvalidFinalRouteCommand(lastCommand);
            } else if (lastCommand != V4_SWAP) {
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
    /// @dev Universal Router command inputs are ABI-encoded tuples. For V2/V3 swap commands,
    ///      the first parameter is always the recipient address. This function:
    ///      1. Validates input length is at least 32 bytes (minimum for ABI-encoded address)
    ///      2. Decodes the first address from the ABI-encoded input
    ///      3. Returns the recipient address for validation against allowed recipients (MSG_SENDER, ROUTER_ADDRESS)
    ///      Used to extract and validate recipient addresses from swap command inputs to prevent
    ///      unauthorized token redirection.
    /// @param command Command byte (used for error reporting if input is invalid)
    /// @param input ABI-encoded command input bytes (must contain at least one address parameter)
    /// @return recipient Decoded recipient address (first address in the ABI-encoded input)
    function _decodeRecipient(
        bytes1 command,
        bytes memory input
    ) private pure returns (address recipient) {
        // Validate input has at least 32 bytes (minimum for ABI-encoded address)
        if (input.length < 32) revert InvalidCommandInput(command);
        // Decode first address from ABI-encoded input (ignores additional parameters)
        recipient = abi.decode(input, (address));
    }

    /// @notice Validates V4 swap actions are allowlisted and properly sequenced
    /// @dev V4 swaps use an actions array that specifies the sequence of operations to perform.
    ///      This function validates that:
    ///      1. Only explicitly allowlisted actions are present (SWAP_EXACT_IN, SETTLE_ALL, TAKE_ALL)
    ///      2. TAKE_ALL action is present (required to claim output tokens)
    ///      3. No unauthorized actions are included (default-reject security model)
    ///
    ///      **Allowed Actions:**
    ///      - SWAP_EXACT_IN (0x07): Executes the swap with exact input amount
    ///      - SETTLE_ALL (0x0c): Settles all token debts to the pool (pays input tokens)
    ///      - TAKE_ALL (0x0f): Claims all output tokens from the pool (required for token output)
    ///
    ///      **Security Rationale:**
    ///      - TAKE_ALL is mandatory because without it, output tokens remain in PoolManager and cannot be accessed
    ///      - Other V4 actions (e.g., TAKE, SETTLE, DONATE) are blocked to prevent token redirection or unauthorized operations
    ///      - Default-reject model: any action not explicitly allowlisted is blocked
    /// @param input Encoded V4 swap input (ABI-encoded tuple: actions bytes, params bytes[])
    function _validateV4Actions(bytes memory input) private pure {
        // Decode V4 swap input: (actions: bytes, params: bytes[])
        (bytes memory actions, ) = abi.decode(input, (bytes, bytes[]));

        bool hasTakeAll;
        uint256 actionCount = actions.length;
        // Iterate through each action byte in the actions array
        for (uint256 i; i < actionCount; ) {
            uint8 action = uint8(actions[i]);
            if (action == SWAP_EXACT_IN) {
                // Explicitly permitted: executes the swap
            } else if (action == SETTLE_ALL) {
                // Explicitly permitted: settles token debts to pool
            } else if (action == TAKE_ALL) {
                // Explicitly permitted: claims output tokens (required)
                hasTakeAll = true;
            } else {
                // Default-reject: block any action not explicitly allowlisted
                // This prevents unauthorized actions like TAKE (selective token claim),
                // SETTLE (selective debt settlement), DONATE, etc.
                revert BlockedV4Action(action);
            }

            unchecked {
                ++i;
            }
        }

        // Require TAKE_ALL to be present - without it, output tokens remain stuck in PoolManager
        if (!hasTakeAll) revert MissingV4TakeAll();
    }
}
