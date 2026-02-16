// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

/// @title Mock V4 PoolManager for testing
/// @dev Simulates Uniswap V4 PoolManager for unit tests without forking
contract MockV4PoolManager {
    address public callbackContract;
    bytes public lastUnlockData;

    function unlock(bytes calldata data) external returns (bytes memory) {
        callbackContract = msg.sender;
        lastUnlockData = data;
        if (callbackContract.code.length > 0) {
            return IUnlockCallback(callbackContract).unlockCallback(data);
        }
        return "";
    }

    function swap(
        PoolKey memory,
        IPoolManager.SwapParams memory,
        bytes memory
    ) external pure returns (BalanceDelta delta) {
        // Mock swap - return deltas: -1 ETH in, +0.1 RARE out
        // BalanceDelta is a packed uint256 encoding two int128 values
        assembly {
            let amount0 := 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC18 // -1e18
            let amount1 := 0x000000000000000000000000000000016345785D8A0000 // +1e17
            delta := or(amount1, shl(128, amount0))
        }
    }

    function settle() external payable {}

    function sync(Currency) external {}

    function take(Currency, address, uint256) external {}

    function modifyLiquidity(
        PoolKey memory,
        IPoolManager.ModifyLiquidityParams memory,
        bytes memory
    ) external pure returns (BalanceDelta, BalanceDelta) {
        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function initialize(PoolKey memory, uint160) external pure returns (int24) {
        return 0;
    }

    function extsload(bytes32) external pure returns (bytes32) {
        uint160 sqrtPrice = 79228162514264337593543950336; // sqrt(1) in Q96 format
        int24 tick = 0;
        return bytes32((uint256(sqrtPrice) << 24) | uint256(uint24(tick)));
    }
}
