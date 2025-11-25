// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

contract V4LiquidityHelper is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable POOL_MANAGER;
    IPermit2 public immutable PERMIT2;

    struct AddParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta; // positive for add
        address owner;         // EOA providing funds
        address token;         // ERC20 token address (currency1)
        uint256 amount0Max;    // max ETH/native (if currency0 is native)
        uint256 amount1Max;    // max token amount
    }

    constructor(IPoolManager _poolManager, IPermit2 _permit2) {
        POOL_MANAGER = _poolManager;
        PERMIT2 = _permit2;
    }

    function addLiquidity(AddParams calldata params) external payable {
        POOL_MANAGER.unlock(abi.encode(params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "only PM");
        AddParams memory p = abi.decode(data, (AddParams));

        IPoolManager.ModifyLiquidityParams memory mlp = IPoolManager.ModifyLiquidityParams({
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            liquidityDelta: p.liquidityDelta,
            salt: bytes32(0)
        });

        (BalanceDelta delta, ) = POOL_MANAGER.modifyLiquidity(p.key, mlp, "");
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();

        // For adds, negative delta means we owe the pool
        if (a0 < 0) {
            uint128 owe0 = uint128(-a0);
            require(owe0 <= p.amount0Max, "exceeds amount0Max");
            POOL_MANAGER.settle{value: owe0}();
        }
        if (a1 < 0) {
            uint128 owe1 = uint128(-a1);
            require(owe1 <= p.amount1Max, "exceeds amount1Max");
            POOL_MANAGER.sync(Currency.wrap(p.token));
            PERMIT2.transferFrom(p.owner, address(POOL_MANAGER), uint160(owe1), p.token);
            POOL_MANAGER.settle();
        }

        // Refund any leftover ETH to owner
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok, ) = p.owner.call{value: bal}("");
            require(ok, "refund failed");
        }

        return bytes("");
    }

    receive() external payable {}
}
