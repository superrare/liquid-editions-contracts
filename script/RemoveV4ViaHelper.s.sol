// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {V4LiquidityHelper} from "./V4LiquidityHelper.sol";

contract RemoveV4ViaHelper is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint256 chainId = _readUintEnvOr("CHAIN_ID", block.chainid);
        uint24 fee = _readUint24EnvOr("POOL_FEE", 3000);
        int24 tickSpacing = _readInt24EnvOr("TICK_SPACING", 60);
        int24 tickLower = _readInt24EnvOr("TICK_LOWER", 0);
        int24 tickUpper = _readInt24EnvOr("TICK_UPPER", 0);
        bytes32 salt = _readBytes32EnvOr("POSITION_SALT", bytes32(0));

        require(tickLower < tickUpper, "TICK_LOWER >= TICK_UPPER");

        address helperAddress = vm.envAddress("V4_LIQUIDITY_HELPER");
        require(helperAddress != address(0), "V4_LIQUIDITY_HELPER required");

        NetworkConfig.Config memory cfg = NetworkConfig.getConfig(chainId);
        address hooks = _readAddressEnvOr("POOL_HOOKS", address(0));
        IPoolManager poolManager = IPoolManager(cfg.uniswapV4PoolManager);

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(cfg.rareToken),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
        PoolId poolId = key.toId();

        (uint128 positionLiquidity, , ) = poolManager.getPositionInfo(
            poolId,
            helperAddress,
            tickLower,
            tickUpper,
            salt
        );
        require(positionLiquidity > 0, "position liquidity is zero");

        uint128 removeAmount = uint128(
            _readUintEnvOr("LIQUIDITY_REMOVE", positionLiquidity)
        );
        require(removeAmount > 0, "LIQUIDITY_REMOVE must be > 0");
        require(removeAmount <= positionLiquidity, "remove > position liquidity");
        require(
            removeAmount <= uint128(type(int128).max),
            "remove exceeds int128 max"
        );

        uint256 amount0Max = _readUintEnvOr("AMOUNT0_MAX", 0);
        uint256 amount1Max = _readUintEnvOr("AMOUNT1_MAX", 0);

        console.log("=== Remove via Helper ===");
        console.log("Deployer:");
        console.logAddress(deployer);
        console.log("Helper:");
        console.logAddress(helperAddress);
        console.log("PoolManager:");
        console.logAddress(cfg.uniswapV4PoolManager);
        console.log("PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("tickLower:");
        console.logInt(tickLower);
        console.log("tickUpper:");
        console.logInt(tickUpper);
        console.log("position salt:");
        console.logBytes32(salt);
        console.log("position liquidity:");
        console.logUint(positionLiquidity);
        console.log("liquidity to remove:");
        console.logUint(removeAmount);

        V4LiquidityHelper helper = V4LiquidityHelper(payable(helperAddress));
        try helper.OWNER() returns (address owner) {
            require(owner == deployer, "deployer is not helper owner");
        } catch {
            revert(
                "legacy helper cannot remove; add with new helper first"
            );
        }

        vm.startBroadcast(pk);

        // forge-lint: disable-next-line(unsafe-typecast) -- safe: removeAmount checked <= int128 max
        int128 liqDelta = -int128(int256(uint256(removeAmount)));
        V4LiquidityHelper.ModifyParams memory p = V4LiquidityHelper.ModifyParams({
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liqDelta,
            amount0Max: amount0Max,
            amount1Max: amount1Max,
            salt: salt
        });

        (int128 amount0Delta, int128 amount1Delta) = helper.modifyLiquidity(p);
        vm.stopBroadcast();

        (uint128 newPositionLiquidity, , ) = poolManager.getPositionInfo(
            poolId,
            helperAddress,
            tickLower,
            tickUpper,
            salt
        );

        console.log("amount0 delta:");
        console.logInt(amount0Delta);
        console.log("amount1 delta:");
        console.logInt(amount1Delta);
        console.log("new position liquidity:");
        console.logUint(newPositionLiquidity);
    }

    function _readAddressEnvOr(
        string memory envKey,
        address defaultValue
    ) internal view returns (address) {
        try vm.envAddress(envKey) returns (address value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function _readUintEnvOr(
        string memory envKey,
        uint256 defaultValue
    ) internal view returns (uint256) {
        try vm.envUint(envKey) returns (uint256 value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function _readUint24EnvOr(
        string memory envKey,
        uint24 defaultValue
    ) internal view returns (uint24) {
        try vm.envUint(envKey) returns (uint256 value) {
            require(value <= type(uint24).max, "uint24 env overflow");
            return uint24(value);
        } catch {
            return defaultValue;
        }
    }

    function _readInt24EnvOr(
        string memory envKey,
        int24 defaultValue
    ) internal view returns (int24) {
        try vm.envInt(envKey) returns (int256 value) {
            require(
                value >= type(int24).min && value <= type(int24).max,
                "int24 env overflow"
            );
            return int24(value);
        } catch {
            return defaultValue;
        }
    }

    function _readBytes32EnvOr(
        string memory envKey,
        bytes32 defaultValue
    ) internal view returns (bytes32) {
        try vm.envBytes32(envKey) returns (bytes32 value) {
            return value;
        } catch {
            return defaultValue;
        }
    }
}
