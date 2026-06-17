// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

interface IPermit2Minimal {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IPositionManagerMinimal {
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

/**
 * @title CreateRareEthPool
 * @notice Initializes and seeds a native ETH/RARE Uniswap V4 pool through PositionManager.
 * @dev Using PositionManager stores poolKeys(bytes25), which DeployLiquidSystem later uses to recover the PoolKey.
 *
 * Required env:
 * - DEPLOYER_PRIVATE_KEY
 * - ETH_AMOUNT_MAX
 * - RARE_AMOUNT_MAX
 *
 * Optional env:
 * - TARGET_CHAIN_ID (default: 84532)
 * - TARGET_FORK_ALIAS (default: base_sepolia)
 * - MAINNET_FORK_ALIAS (default: mainnet)
 * - TARGET_SQRT_PRICE_X96 (overrides live mainnet lookup)
 * - POOL_FEE (default: 100; Base Sepolia 3000/60 is already initialized at a stale price)
 * - TICK_SPACING (default: 1)
 * - POOL_HOOKS (default: address(0))
 * - TICK_LOWER / TICK_UPPER (default: -120000 / 120000)
 * - POSITION_DEADLINE_SECONDS (default: 1800)
 * - ALLOW_EXISTING_POOL (default: false). When true, an already-initialized pool is not reinitialized;
 *   the script mints through PositionManager at the live pool price, which registers poolKeys(bytes25).
 *
 * Usage:
 *   ETH_AMOUNT_MAX=100000000000000000 RARE_AMOUNT_MAX=1000000000000000000000 \
 *   forge script script/CreateRareEthPool.s.sol:CreateRareEthPool \
 *     --rpc-url base_sepolia --broadcast -vv
 */
contract CreateRareEthPool is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 private constant DEFAULT_TARGET_CHAIN_ID = 84532;
    uint8 private constant ACTION_MINT_POSITION = 0x02;
    uint8 private constant ACTION_SETTLE_PAIR = 0x0d;
    uint8 private constant ACTION_SWEEP = 0x14;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint256 targetChainId = _readUintEnvOr("TARGET_CHAIN_ID", DEFAULT_TARGET_CHAIN_ID);
        uint256 ethAmountMax = vm.envUint("ETH_AMOUNT_MAX");
        uint256 rareAmountMax = vm.envUint("RARE_AMOUNT_MAX");
        require(ethAmountMax > 0, "ETH_AMOUNT_MAX=0");
        require(rareAmountMax > 0, "RARE_AMOUNT_MAX=0");
        require(ethAmountMax <= type(uint128).max, "ETH_AMOUNT_MAX > uint128");
        require(rareAmountMax <= type(uint128).max, "RARE_AMOUNT_MAX > uint128");

        uint160 targetSqrtPriceX96 = _resolveTargetSqrtPrice();

        string memory targetForkAlias = _readStringEnvOr("TARGET_FORK_ALIAS", "base_sepolia");
        vm.createSelectFork(targetForkAlias);

        NetworkConfig.Config memory cfg = NetworkConfig.getConfig(targetChainId);
        require(cfg.rareToken != address(0), "RARE token not configured");
        require(cfg.uniswapV4PoolManager != address(0), "PoolManager not configured");
        require(cfg.uniswapV4PositionManager != address(0), "PositionManager not configured");

        uint24 poolFee = _readUint24EnvOr("POOL_FEE", 100);
        int24 tickSpacing = _readInt24EnvOr("TICK_SPACING", 1);
        address hooks = _readAddressEnvOr("POOL_HOOKS", address(0));

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(cfg.rareToken),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
        PoolId poolId = key.toId();

        IPoolManager poolManager = IPoolManager(cfg.uniswapV4PoolManager);
        IPositionManagerMinimal positionManager = IPositionManagerMinimal(cfg.uniswapV4PositionManager);

        (uint160 liveSqrtPriceX96, int24 liveTick,,) = poolManager.getSlot0(poolId);
        bool initializePool = liveSqrtPriceX96 == 0;
        bool allowExistingPool = _readBoolEnvOr("ALLOW_EXISTING_POOL", false);
        require(initializePool || allowExistingPool, "pool already initialized");

        uint160 activeSqrtPriceX96 = initializePool ? targetSqrtPriceX96 : liveSqrtPriceX96;
        int24 activeTick = initializePool ? TickMath.getTickAtSqrtPrice(targetSqrtPriceX96) : liveTick;
        (int24 tickLower, int24 tickUpper) = _resolveTicks(tickSpacing);

        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity =
            _calculateLiquidity(activeSqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, ethAmountMax, rareAmountMax);
        require(liquidity > 0, "liquidity=0");

        console.log("=== Create Native ETH/RARE V4 Pool ===");
        console.log("Target chain ID:");
        console.logUint(targetChainId);
        console.log("Deployer:");
        console.logAddress(deployer);
        console.log("PoolManager:");
        console.logAddress(cfg.uniswapV4PoolManager);
        console.log("PositionManager:");
        console.logAddress(cfg.uniswapV4PositionManager);
        console.log("RARE:");
        console.logAddress(cfg.rareToken);
        console.log("Hooks:");
        console.logAddress(hooks);
        console.log("Fee:");
        console.logUint(poolFee);
        console.log("Tick spacing:");
        console.logInt(tickSpacing);
        console.log("PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("Initialize pool:");
        console.log(initializePool ? "true" : "false");
        if (!initializePool) {
            console.log("Live sqrtPriceX96:");
            console.logUint(liveSqrtPriceX96);
            console.log("Live tick:");
            console.logInt(liveTick);
        }
        console.log("Target sqrtPriceX96:");
        console.logUint(targetSqrtPriceX96);
        console.log("Active tick:");
        console.logInt(activeTick);
        console.log("Tick lower:");
        console.logInt(tickLower);
        console.log("Tick upper:");
        console.logInt(tickUpper);
        console.log("ETH amount max:");
        console.logUint(ethAmountMax);
        console.log("RARE amount max:");
        console.logUint(rareAmountMax);
        console.log("Liquidity:");
        console.logUint(liquidity);

        uint256 rareBalance = IERC20(cfg.rareToken).balanceOf(deployer);
        require(rareBalance >= rareAmountMax, "deployer RARE balance too low");
        require(deployer.balance >= ethAmountMax, "deployer ETH balance too low");

        vm.startBroadcast(pk);

        if (initializePool) {
            positionManager.initializePool(key, targetSqrtPriceX96);
        }

        IERC20(cfg.rareToken).approve(PERMIT2, rareAmountMax);
        IPermit2Minimal(PERMIT2)
            .approve(cfg.rareToken, cfg.uniswapV4PositionManager, uint160(rareAmountMax), type(uint48).max);

        bytes memory actions = abi.encodePacked(ACTION_MINT_POSITION, ACTION_SETTLE_PAIR, ACTION_SWEEP);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(ethAmountMax),
            uint128(rareAmountMax),
            deployer,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, deployer);

        uint256 deadline = block.timestamp + _readUintEnvOr("POSITION_DEADLINE_SECONDS", 1800);
        positionManager.modifyLiquidities{value: ethAmountMax}(abi.encode(actions, params), deadline);

        vm.stopBroadcast();

        (uint160 finalSqrtPriceX96, int24 finalTick, uint24 finalProtocolFee, uint24 finalLpFee) =
            poolManager.getSlot0(poolId);
        uint128 finalLiquidity = poolManager.getLiquidity(poolId);
        (
            address storedCurrency0,
            address storedCurrency1,
            uint24 storedFee,
            int24 storedTickSpacing,
            address storedHooks
        ) = _readPositionManagerPoolKey(cfg.uniswapV4PositionManager, PoolId.unwrap(poolId));

        console.log("");
        console.log("=== Bootstrap Complete ===");
        console.log("PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("Final sqrtPriceX96:");
        console.logUint(finalSqrtPriceX96);
        console.log("Final tick:");
        console.logInt(finalTick);
        console.log("Final protocol fee:");
        console.logUint(finalProtocolFee);
        console.log("Final LP fee:");
        console.logUint(finalLpFee);
        console.log("Final liquidity:");
        console.logUint(finalLiquidity);
        console.log("PositionManager stored currency0:");
        console.logAddress(storedCurrency0);
        console.log("PositionManager stored currency1:");
        console.logAddress(storedCurrency1);
        console.log("PositionManager stored fee:");
        console.logUint(storedFee);
        console.log("PositionManager stored tick spacing:");
        console.logInt(storedTickSpacing);
        console.log("PositionManager stored hooks:");
        console.logAddress(storedHooks);
        require(storedCurrency0 == address(0), "PositionManager currency0 not ETH");
        require(storedCurrency1 == cfg.rareToken, "PositionManager currency1 not RARE");
        require(storedFee == poolFee, "PositionManager fee mismatch");
        require(storedTickSpacing == tickSpacing, "PositionManager tick spacing mismatch");
        require(storedHooks == hooks, "PositionManager hooks mismatch");
        console.log("");
        console.log("Update NetworkConfig.rareEthPoolId with:");
        console.logBytes32(PoolId.unwrap(poolId));
    }

    function _resolveTargetSqrtPrice() internal returns (uint160 targetSqrtPriceX96) {
        try vm.envUint("TARGET_SQRT_PRICE_X96") returns (uint256 overrideSqrt) {
            require(overrideSqrt > 0 && overrideSqrt <= type(uint160).max, "bad TARGET_SQRT_PRICE_X96");
            return uint160(overrideSqrt);
        } catch {}

        string memory mainnetForkAlias = _readStringEnvOr("MAINNET_FORK_ALIAS", "mainnet");
        vm.createSelectFork(mainnetForkAlias);

        NetworkConfig.Config memory mainnetCfg = NetworkConfig.getConfig(1);
        IPoolManager mainnetPoolManager = IPoolManager(mainnetCfg.uniswapV4PoolManager);
        PoolId mainnetPoolId = PoolId.wrap(mainnetCfg.rareEthPoolId);
        (targetSqrtPriceX96,,,) = mainnetPoolManager.getSlot0(mainnetPoolId);
        require(targetSqrtPriceX96 != 0, "mainnet RARE/ETH pool not initialized");

        console.log("=== Mainnet RARE/ETH Price Source ===");
        console.log("Mainnet poolId:");
        console.logBytes32(mainnetCfg.rareEthPoolId);
        console.log("Target sqrtPriceX96:");
        console.logUint(targetSqrtPriceX96);
    }

    function _resolveTicks(int24 tickSpacing) internal view returns (int24 tickLower, int24 tickUpper) {
        tickLower = _readInt24EnvOr("TICK_LOWER", -120000);
        tickUpper = _readInt24EnvOr("TICK_UPPER", 120000);
        tickLower = _floorToSpacing(tickLower, tickSpacing);
        tickUpper = _ceilToSpacing(tickUpper, tickSpacing);

        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        if (tickLower < minTick) tickLower = minTick;
        if (tickUpper > maxTick) tickUpper = maxTick;
        require(tickLower < tickUpper, "invalid tick range");
    }

    function _readPositionManagerPoolKey(address positionManager, bytes32 poolId)
        internal
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        bytes25 truncatedId = bytes25(poolId);
        (bool ok, bytes memory data) =
            positionManager.staticcall(abi.encodeWithSignature("poolKeys(bytes25)", truncatedId));
        require(ok && data.length >= 160, "poolKeys lookup failed");
        (Currency c0, Currency c1, uint24 keyFee, int24 keyTickSpacing, IHooks keyHooks) =
            abi.decode(data, (Currency, Currency, uint24, int24, IHooks));
        currency0 = Currency.unwrap(c0);
        currency1 = Currency.unwrap(c1);
        fee = keyFee;
        tickSpacing = keyTickSpacing;
        hooks = address(keyHooks);
    }

    function _calculateLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            return _getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 l0 = _getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 l1 = _getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);
            return l0 < l1 ? l0 : l1;
        } else {
            return _getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    function _getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
        uint256 liquidity = FullMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96);
        require(liquidity <= type(uint128).max, "liq0 max");
        return uint128(liquidity);
    }

    function _getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        uint256 liquidity = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96);
        require(liquidity <= type(uint128).max, "liq1 max");
        return uint128(liquidity);
    }

    function _floorToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function _ceilToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick > 0 && tick % tickSpacing != 0) compressed++;
        return compressed * tickSpacing;
    }

    function _readAddressEnvOr(string memory envKey, address defaultValue) internal view returns (address) {
        try vm.envAddress(envKey) returns (address value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function _readBoolEnvOr(string memory envKey, bool defaultValue) internal view returns (bool) {
        try vm.envBool(envKey) returns (bool value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function _readInt24EnvOr(string memory envKey, int24 defaultValue) internal view returns (int24) {
        try vm.envInt(envKey) returns (int256 value) {
            require(value >= type(int24).min && value <= type(int24).max, "int24 env overflow");
            return int24(value);
        } catch {
            return defaultValue;
        }
    }

    function _readStringEnvOr(string memory envKey, string memory defaultValue) internal view returns (string memory) {
        try vm.envString(envKey) returns (string memory value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function _readUintEnvOr(string memory envKey, uint256 defaultValue) internal view returns (uint256) {
        try vm.envUint(envKey) returns (uint256 value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function _readUint24EnvOr(string memory envKey, uint24 defaultValue) internal view returns (uint24) {
        try vm.envUint(envKey) returns (uint256 value) {
            require(value <= type(uint24).max, "uint24 env overflow");
            return uint24(value);
        } catch {
            return defaultValue;
        }
    }
}
