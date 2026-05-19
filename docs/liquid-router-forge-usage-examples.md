# Liquid Router Forge Usage Examples

These examples show how to build `commands` and `inputs` from Solidity and call
the Sepolia Liquid Router with Forge scripts.

```solidity
address constant LIQUID_ROUTER = 0x429c3Ee66E7f6CDA12C5BadE4104aF3277aA2305;
address constant LIQUID_TOKEN = 0x3A011493585f46e625E178a30338A944A456b105;
address constant RARE = 0x197FaeF3f59eC80113e773Bb6206a17d183F97CB;
address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
address constant ETH = address(0);
address constant NO_HOOKS = address(0);
address constant LIQUID_HOOKS = 0x90ef3674D843C7bBeA2e1f2bAfB2652dF18d20Cc;
```

## Script Setup

Create a Forge script that imports Forge utilities and an ERC-20 interface.
Define the minimal Liquid Router interface inline so the script does not depend
on this repo's `ILiquidRouter.sol`.

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILiquidRouterMinimal {
    function buy(
        address token,
        address recipient,
        uint256 minTokensOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable returns (uint256 tokensReceived);

    function sell(
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external returns (uint256 ethReceived);

    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        address recipient,
        uint256 minAmountOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable returns (uint256 amountOut);
}

contract LiquidRouterForgeExamples is Script {
    address constant LIQUID_ROUTER = 0x429c3Ee66E7f6CDA12C5BadE4104aF3277aA2305;
    address constant LIQUID_TOKEN = 0x3A011493585f46e625E178a30338A944A456b105;
    address constant RARE = 0x197FaeF3f59eC80113e773Bb6206a17d183F97CB;
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant ETH = address(0);
    address constant NO_HOOKS = address(0);
    address constant LIQUID_HOOKS = 0x90ef3674D843C7bBeA2e1f2bAfB2652dF18d20Cc;

    bytes1 constant V4_SWAP = 0x10;
    uint8 constant SWAP_EXACT_IN = 0x07;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;

    struct PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }
}
```

## Shared Encoder

All examples below are single `V4_SWAP` commands. The V4 action sequence is:

```solidity
bytes memory actions = abi.encodePacked(
    uint8(SWAP_EXACT_IN),
    uint8(SETTLE_ALL),
    uint8(TAKE_ALL)
);
```

Use this helper inside the script:

```solidity
function _encodeV4ExactInInput(
    address currencyIn,
    PathKey[] memory path,
    uint256 amountIn,
    uint256 minAmountOut,
    address currencyOut
) internal pure returns (bytes memory commands, bytes[] memory inputs) {
    bytes memory actions = abi.encodePacked(
        uint8(SWAP_EXACT_IN),
        uint8(SETTLE_ALL),
        uint8(TAKE_ALL)
    );

    bytes[] memory params = new bytes[](3);
    bytes memory exactInput = abi.encode(
        currencyIn,
        path,
        uint128(amountIn),
        uint128(minAmountOut)
    );

    params[0] = currencyIn == ETH
        ? exactInput
        : abi.encodePacked(uint256(0x20), exactInput);
    params[1] = abi.encode(currencyIn, uint128(amountIn));
    params[2] = abi.encode(currencyOut, uint128(minAmountOut));

    commands = abi.encodePacked(V4_SWAP);
    inputs = new bytes[](1);
    inputs[0] = abi.encode(actions, params);
}
```

The `params[0]` branch is intentional. ETH-input routes use the direct
`ExactInputParams` tuple encoding. ERC-20-input routes require a 32-byte dynamic
offset prefix before the tuple bytes.

## ETH To Liquid With `buy`

Path:

```txt
ETH -> RARE -> LIQUID
```

```solidity
function buyExample() external {
    uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address recipient = vm.addr(privateKey);
    uint256 ethAmountIn = 0.000001 ether;
    uint256 minTokensOut = 1;
    uint256 deadline = block.timestamp + 20 minutes;

    PathKey[] memory path = new PathKey[](2);
    path[0] = PathKey({
        intermediateCurrency: RARE,
        fee: 3000,
        tickSpacing: 60,
        hooks: NO_HOOKS,
        hookData: bytes("")
    });
    path[1] = PathKey({
        intermediateCurrency: LIQUID_TOKEN,
        fee: 0,
        tickSpacing: 60,
        hooks: LIQUID_HOOKS,
        hookData: bytes("")
    });

    (bytes memory commands, bytes[] memory inputs) =
        _encodeV4ExactInInput(ETH, path, ethAmountIn, minTokensOut, LIQUID_TOKEN);

    vm.startBroadcast(privateKey);
    uint256 tokensReceived = ILiquidRouterMinimal(payable(LIQUID_ROUTER)).buy{
        value: ethAmountIn
    }(LIQUID_TOKEN, recipient, minTokensOut, commands, inputs, deadline);
    vm.stopBroadcast();

    console2.log("tokensReceived", tokensReceived);
}
```

## Liquid To ETH With `sell`

Path:

```txt
LIQUID -> RARE -> ETH
```

```solidity
function sellExample() external {
    uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address recipient = vm.addr(privateKey);
    uint256 tokenAmount = 0.001 ether;
    uint256 minEthOut = 1;
    uint256 deadline = block.timestamp + 20 minutes;

    PathKey[] memory path = new PathKey[](2);
    path[0] = PathKey({
        intermediateCurrency: RARE,
        fee: 0,
        tickSpacing: 60,
        hooks: LIQUID_HOOKS,
        hookData: bytes("")
    });
    path[1] = PathKey({
        intermediateCurrency: ETH,
        fee: 3000,
        tickSpacing: 60,
        hooks: NO_HOOKS,
        hookData: bytes("")
    });

    (bytes memory commands, bytes[] memory inputs) =
        _encodeV4ExactInInput(LIQUID_TOKEN, path, tokenAmount, minEthOut, ETH);

    vm.startBroadcast(privateKey);
    IERC20(LIQUID_TOKEN).approve(LIQUID_ROUTER, tokenAmount);
    uint256 ethReceived = ILiquidRouterMinimal(payable(LIQUID_ROUTER)).sell(
        LIQUID_TOKEN,
        tokenAmount,
        recipient,
        minEthOut,
        commands,
        inputs,
        deadline
    );
    vm.stopBroadcast();

    console2.log("ethReceived", ethReceived);
}
```

## RARE To Liquid With `swap`

Path:

```txt
RARE -> LIQUID
```

```solidity
function rareToLiquidSwapExample() external {
    uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address recipient = vm.addr(privateKey);
    uint256 rareAmountIn = 0.001 ether;
    uint256 minTokensOut = 1;
    uint256 deadline = block.timestamp + 20 minutes;

    PathKey[] memory path = new PathKey[](1);
    path[0] = PathKey({
        intermediateCurrency: LIQUID_TOKEN,
        fee: 0,
        tickSpacing: 60,
        hooks: LIQUID_HOOKS,
        hookData: bytes("")
    });

    (bytes memory commands, bytes[] memory inputs) =
        _encodeV4ExactInInput(RARE, path, rareAmountIn, minTokensOut, LIQUID_TOKEN);

    vm.startBroadcast(privateKey);
    IERC20(RARE).approve(LIQUID_ROUTER, rareAmountIn);
    uint256 tokensReceived = ILiquidRouterMinimal(payable(LIQUID_ROUTER)).swap(
        RARE,
        rareAmountIn,
        LIQUID_TOKEN,
        recipient,
        minTokensOut,
        commands,
        inputs,
        deadline
    );
    vm.stopBroadcast();

    console2.log("tokensReceived", tokensReceived);
}
```

## USDC To Liquid With `swap`

Path:

```txt
USDC -> ETH -> RARE -> LIQUID
```

Sepolia USDC uses 6 decimals.

```solidity
function usdcToLiquidSwapExample() external {
    uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address recipient = vm.addr(privateKey);
    uint256 usdcAmountIn = 10_000_000;
    uint256 minTokensOut = 1;
    uint256 deadline = block.timestamp + 20 minutes;

    PathKey[] memory path = new PathKey[](3);
    path[0] = PathKey({
        intermediateCurrency: ETH,
        fee: 3000,
        tickSpacing: 60,
        hooks: NO_HOOKS,
        hookData: bytes("")
    });
    path[1] = PathKey({
        intermediateCurrency: RARE,
        fee: 3000,
        tickSpacing: 60,
        hooks: NO_HOOKS,
        hookData: bytes("")
    });
    path[2] = PathKey({
        intermediateCurrency: LIQUID_TOKEN,
        fee: 0,
        tickSpacing: 60,
        hooks: LIQUID_HOOKS,
        hookData: bytes("")
    });

    (bytes memory commands, bytes[] memory inputs) =
        _encodeV4ExactInInput(USDC, path, usdcAmountIn, minTokensOut, LIQUID_TOKEN);

    vm.startBroadcast(privateKey);
    IERC20(USDC).approve(LIQUID_ROUTER, usdcAmountIn);
    uint256 tokensReceived = ILiquidRouterMinimal(payable(LIQUID_ROUTER)).swap(
        USDC,
        usdcAmountIn,
        LIQUID_TOKEN,
        recipient,
        minTokensOut,
        commands,
        inputs,
        deadline
    );
    vm.stopBroadcast();

    console2.log("tokensReceived", tokensReceived);
}
```

## Running With Forge

Set an RPC URL and private key in `.env`:

```sh
ETH_SEPOLIA="https://..."
DEPLOYER_PRIVATE_KEY="0x..."
```

Simulate first:

```sh
source .env
forge script script/YourScript.s.sol:LiquidRouterForgeExamples \
  --sig "buyExample()" \
  --rpc-url "$ETH_SEPOLIA" \
  -vvvv
```

Broadcast after simulation succeeds:

```sh
source .env
forge script script/YourScript.s.sol:LiquidRouterForgeExamples \
  --sig "buyExample()" \
  --rpc-url "$ETH_SEPOLIA" \
  --broadcast \
  --slow
```

Replace `buyExample()` with `sellExample()`, `rareToLiquidSwapExample()`, or
`usdcToLiquidSwapExample()` to run the other routes.

## Notes

- No Uniswap SDK is required for these Forge examples.
- You need Forge, an ERC-20 interface, an RPC URL, and a funded signer. The
  minimal Liquid Router interface is included inline above.
- `minTokensOut`, `minEthOut`, and `minAmountOut` should come from a quote with
  the user's chosen slippage. The `1` values above are smoke-test values only.
- ERC-20 input routes require approval to the Liquid Router. The Liquid Router
  handles Permit2 internally after pulling tokens from the signer.
