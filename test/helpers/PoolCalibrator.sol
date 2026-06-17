// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PoolCalibrator
 * @notice Adds deep full-range liquidity to a V4 pool without changing its price.
 *
 *  Strategy (single unlock callback):
 *   1. Add a full-range liquidity position using pre-funded ETH + RARE.
 *   2. Settle all net currency deltas atomically.
 *
 *  The pool's current price is preserved — only depth increases.
 *
 *  Usage from a Forge test (setUp):
 *   ```
 *   PoolCalibrator calibrator = new PoolCalibrator();
 *   vm.deal(address(calibrator), 1000 ether);
 *   deal(rareToken, address(calibrator), 500_000 ether);
 *   calibrator.calibrate(pm, rareEthKey, rareToken);
 *   ```
 */
contract PoolCalibrator is IUnlockCallback {
    // Full-range tick bounds for tickSpacing = 60
    // MIN_TICK = -887272 → rounded up to multiple of 60 = -887220
    // MAX_TICK = +887272 → rounded down to multiple of 60 = +887220
    int24 public constant TICK_LOWER = -887220;
    int24 public constant TICK_UPPER = 887220;

    // Liquidity delta for the full-range position.
    int256 public constant LIQUIDITY_DELTA = 1e21;

    // Temporary state used during the unlock callback
    IPoolManager private _pm;
    PoolKey private _key;
    address private _rareToken;

    /// @dev Accept ETH returned by pm.take() during the callback.
    receive() external payable {}

    /**
     * @notice Add deep full-range liquidity to the pool at its current price.
     * @param pm          V4 PoolManager on the testnet fork
     * @param rareEthKey  PoolKey for the ETH/RARE pool on testnet
     * @param rareToken   RARE token address on testnet
     */
    function calibrate(
        IPoolManager pm,
        PoolKey calldata rareEthKey,
        address rareToken
    ) external {
        _pm = pm;
        _key = rareEthKey;
        _rareToken = rareToken;
        pm.unlock(bytes(""));
    }

    /**
     * @dev V4 unlock callback. Adds full-range liquidity and settles deltas.
     */
    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        IPoolManager pm = _pm;
        PoolKey memory key = _key;
        address rareToken = _rareToken;

        Currency ethCurrency = Currency.wrap(address(0));
        Currency rareCurrency = Currency.wrap(rareToken);

        // Add full-range liquidity at the current pool price
        (BalanceDelta addDelta,) = pm.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: LIQUIDITY_DELTA,
                salt: bytes32(0)
            }),
            ""
        );

        // Settle currency deltas
        int128 netEth = addDelta.amount0();
        int128 netRare = addDelta.amount1();

        // Settle RARE debt (sync → transfer → settle)
        if (netRare < 0) {
            uint256 rareOwed = uint256(uint128(-netRare));
            pm.sync(rareCurrency);
            IERC20(rareToken).transfer(address(pm), rareOwed);
            pm.settle();
        } else if (netRare > 0) {
            pm.take(rareCurrency, address(this), uint128(netRare));
        }

        // Settle ETH
        if (netEth < 0) {
            pm.settle{value: uint256(uint128(-netEth))}();
        } else if (netEth > 0) {
            pm.take(ethCurrency, address(this), uint128(netEth));
        }

        return "";
    }
}
