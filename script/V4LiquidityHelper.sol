// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

interface IPermit2 {
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;

    function transferFrom(
        address from,
        address to,
        uint160 amount,
        address token
    ) external;
}

contract V4LiquidityHelper is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    IPoolManager public immutable POOL_MANAGER;
    IPermit2 public immutable PERMIT2;
    address public immutable OWNER;

    error NotOwner();
    error AddressZero();

    struct ModifyParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta; // positive=add, negative=remove
        uint256 amount0Max; // max currency0 owed (for adds)
        uint256 amount1Max; // max currency1 owed (for adds)
        bytes32 salt; // position salt (defaults to 0x0)
    }

    constructor(IPoolManager _poolManager, IPermit2 _permit2, address _owner) {
        if (
            address(_poolManager) == address(0) ||
            address(_permit2) == address(0) ||
            _owner == address(0)
        ) {
            revert AddressZero();
        }
        POOL_MANAGER = _poolManager;
        PERMIT2 = _permit2;
        OWNER = _owner;
    }

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    function modifyLiquidity(
        ModifyParams calldata params
    ) external payable onlyOwner returns (int128 amount0Delta, int128 amount1Delta) {
        bytes memory result = POOL_MANAGER.unlock(abi.encode(params));
        (amount0Delta, amount1Delta) = abi.decode(result, (int128, int128));
    }

    function addLiquidity(ModifyParams calldata params) external payable onlyOwner {
        require(params.liquidityDelta > 0, "liquidityDelta must be > 0");
        POOL_MANAGER.unlock(abi.encode(params));
    }

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "only PM");
        ModifyParams memory p = abi.decode(data, (ModifyParams));

        IPoolManager.ModifyLiquidityParams memory mlp = IPoolManager
            .ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: p.liquidityDelta,
                salt: p.salt
            });

        (BalanceDelta delta, ) = POOL_MANAGER.modifyLiquidity(p.key, mlp, "");
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();

        _settleCurrency(p.key.currency0, a0, p.amount0Max, true);
        _settleCurrency(p.key.currency1, a1, p.amount1Max, false);

        // Refund any leftover ETH to owner (e.g. excess msg.value on add)
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok, ) = OWNER.call{value: bal}("");
            require(ok, "refund failed");
        }

        return abi.encode(a0, a1);
    }

    function _settleCurrency(
        Currency currency,
        int128 deltaAmount,
        uint256 maxOwed,
        bool isCurrency0
    ) internal {
        address token = Currency.unwrap(currency);

        // Negative delta means this helper owes the pool.
        if (deltaAmount < 0) {
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: int128 delta fits uint128 when negated
            uint128 owed = uint128(-deltaAmount);
            if (isCurrency0) {
                require(owed <= maxOwed, "exceeds amount0Max");
            } else {
                require(owed <= maxOwed, "exceeds amount1Max");
            }

            if (token == address(0)) {
                POOL_MANAGER.settle{value: owed}();
            } else {
                POOL_MANAGER.sync(currency);
                PERMIT2.transferFrom(OWNER, address(POOL_MANAGER), uint160(owed), token);
                POOL_MANAGER.settle();
            }
            return;
        }

        // Positive delta means the pool owes this helper. Take and forward to owner.
        if (deltaAmount > 0) {
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: int128 positive fits uint128
            uint128 received = uint128(deltaAmount);
            POOL_MANAGER.take(currency, address(this), received);

            if (token == address(0)) {
                (bool ok, ) = OWNER.call{value: received}("");
                require(ok, "eth transfer failed");
            } else {
                IERC20(token).safeTransfer(OWNER, received);
            }
        }
    }

    receive() external payable {}
}
