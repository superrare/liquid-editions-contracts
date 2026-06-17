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

contract SmokeLiquidRouterDocExamples is Script {
    address internal constant LIQUID_ROUTER = 0x429c3Ee66E7f6CDA12C5BadE4104aF3277aA2305;
    address internal constant LIQUID_TOKEN = 0x3A011493585f46e625E178a30338A944A456b105;
    address internal constant RARE = 0x197FaeF3f59eC80113e773Bb6206a17d183F97CB;
    address internal constant ETH = address(0);
    address internal constant NO_HOOKS = address(0);
    address internal constant LIQUID_HOOKS = 0x90ef3674D843C7bBeA2e1f2bAfB2652dF18d20Cc;

    bytes1 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN = 0x07;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;

    struct PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    function run() external {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address recipient = vm.addr(privateKey);
        uint256 deadline = block.timestamp + 20 minutes;

        string memory step = vm.envOr("ROUTER_SMOKE_STEP", string("all"));
        uint256 ethAmountIn = 0.000001 ether;
        uint256 tokenAmount = 0.001 ether;
        uint256 rareAmountIn = 0.001 ether;
        uint256 minOut = 1;

        ILiquidRouterMinimal router = ILiquidRouterMinimal(payable(LIQUID_ROUTER));

        vm.startBroadcast(privateKey);

        if (_matches(step, "all") || _matches(step, "buy")) {
            (bytes memory buyCommands, bytes[] memory buyInputs) = _encodeBuyRoute(ethAmountIn, minOut);
            uint256 bought =
                router.buy{value: ethAmountIn}(LIQUID_TOKEN, recipient, minOut, buyCommands, buyInputs, deadline);
            console2.log("buy tokensReceived", bought);
        }

        if (_matches(step, "all") || _matches(step, "sell")) {
            IERC20(LIQUID_TOKEN).approve(LIQUID_ROUTER, tokenAmount);
            (bytes memory sellCommands, bytes[] memory sellInputs) = _encodeSellRoute(tokenAmount, minOut);
            uint256 sold = router.sell(LIQUID_TOKEN, tokenAmount, recipient, minOut, sellCommands, sellInputs, deadline);
            console2.log("sell ethReceived", sold);
        }

        if (_matches(step, "all") || _matches(step, "swap")) {
            IERC20(RARE).approve(LIQUID_ROUTER, rareAmountIn);
            (bytes memory swapCommands, bytes[] memory swapInputs) = _encodeRareToLiquidSwapRoute(rareAmountIn, minOut);
            uint256 swapped =
                router.swap(RARE, rareAmountIn, LIQUID_TOKEN, recipient, minOut, swapCommands, swapInputs, deadline);
            console2.log("swap tokensReceived", swapped);
        }

        vm.stopBroadcast();
    }

    function _encodeBuyRoute(uint256 amountIn, uint256 minAmountOut)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        PathKey[] memory path = new PathKey[](2);
        path[0] =
            PathKey({intermediateCurrency: RARE, fee: 3000, tickSpacing: 60, hooks: NO_HOOKS, hookData: bytes("")});
        path[1] = PathKey({
            intermediateCurrency: LIQUID_TOKEN, fee: 0, tickSpacing: 60, hooks: LIQUID_HOOKS, hookData: bytes("")
        });

        return _encodeV4ExactInInput(ETH, path, amountIn, minAmountOut, LIQUID_TOKEN);
    }

    function _encodeSellRoute(uint256 amountIn, uint256 minAmountOut)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        PathKey[] memory path = new PathKey[](2);
        path[0] =
            PathKey({intermediateCurrency: RARE, fee: 0, tickSpacing: 60, hooks: LIQUID_HOOKS, hookData: bytes("")});
        path[1] = PathKey({intermediateCurrency: ETH, fee: 3000, tickSpacing: 60, hooks: NO_HOOKS, hookData: bytes("")});

        return _encodeV4ExactInInput(LIQUID_TOKEN, path, amountIn, minAmountOut, ETH);
    }

    function _encodeRareToLiquidSwapRoute(uint256 amountIn, uint256 minAmountOut)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: LIQUID_TOKEN, fee: 0, tickSpacing: 60, hooks: LIQUID_HOOKS, hookData: bytes("")
        });

        return _encodeV4ExactInInput(RARE, path, amountIn, minAmountOut, LIQUID_TOKEN);
    }

    function _encodeV4ExactInInput(
        address currencyIn,
        PathKey[] memory path,
        uint256 amountIn,
        uint256 minAmountOut,
        address currencyOut
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        bytes memory actions = abi.encodePacked(uint8(SWAP_EXACT_IN), uint8(SETTLE_ALL), uint8(TAKE_ALL));

        bytes[] memory params = new bytes[](3);
        bytes memory exactInput = abi.encode(currencyIn, path, uint128(amountIn), uint128(minAmountOut));
        params[0] = currencyIn == ETH ? exactInput : abi.encodePacked(uint256(0x20), exactInput);
        params[1] = abi.encode(currencyIn, uint128(amountIn));
        params[2] = abi.encode(currencyOut, uint128(minAmountOut));

        commands = abi.encodePacked(V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _matches(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
