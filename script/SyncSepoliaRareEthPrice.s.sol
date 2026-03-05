// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";

/**
 * @title SyncSepoliaRareEthPrice
 * @notice Reads mainnet RARE/ETH price, then syncs the Sepolia pool to match.
 *
 * @dev Two-phase approach:
 *   Phase 1 (always): Dry-run — simulates the swap on a Sepolia fork snapshot using
 *                      vm.deal / deal to fake-fund a syncer. Reports the exact RARE or
 *                      ETH needed, then rolls back state via vm.revertToAndDelete.
 *   Phase 2 (broadcast only): Executes the real swap using the deployer's funds.
 *
 *   The sqrtPriceLimitX96 is set to the mainnet price so V4 stops at exactly the right
 *   price. We overshoot the input — V4 only consumes what's needed.
 *
 * Environment Variables:
 *   - MAINNET_RPC_URL      : mainnet RPC (foundry.toml alias "mainnet")
 *   - ETH_SEPOLIA          : Sepolia RPC  (foundry.toml alias "sepolia")
 *   - DEPLOYER_PRIVATE_KEY : private key of the account executing the swap
 *
 * Usage:
 *   # Simulate (shows exact amounts needed, no on-chain tx):
 *   forge script script/SyncSepoliaRareEthPrice.s.sol:SyncSepoliaRareEthPrice -vv
 *
 *   # Execute (broadcasts the swap on Sepolia):
 *   forge script script/SyncSepoliaRareEthPrice.s.sol:SyncSepoliaRareEthPrice \
 *     --rpc-url sepolia --broadcast -vv
 */
contract SyncSepoliaRareEthPrice is Script, StdCheats {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 constant POOL_FEE = 3000;
    int24 constant POOL_TICK_SPACING = 60;

    /// @dev Generous ceiling for the dry-run simulation. V4's sqrtPriceLimitX96 ensures
    ///      only what's needed is consumed. These never leave the fork snapshot.
    uint256 constant SIM_RARE_CEILING = 10_000_000 ether;
    uint256 constant SIM_ETH_CEILING = 10_000 ether;

    function run() external {
        // ================================================================
        //  1. Read mainnet RARE/ETH pool price
        // ================================================================
        NetworkConfig.Config memory mainnetCfg = NetworkConfig.getConfig(1);

        vm.createSelectFork("mainnet");

        IPoolManager mainnetPm = IPoolManager(mainnetCfg.uniswapV4PoolManager);
        PoolId mainnetPoolId = PoolId.wrap(mainnetCfg.rareEthPoolId);

        (uint160 mainnetSqrt, int24 mainnetTick, , ) = mainnetPm.getSlot0(mainnetPoolId);
        require(mainnetSqrt != 0, "Mainnet RARE/ETH pool not initialized");

        console.log("================================================");
        console.log("  MAINNET RARE/ETH (source of truth)");
        console.log("================================================");
        console.log("  sqrtPriceX96 :", uint256(mainnetSqrt));
        console.log("  tick         :", _tickStr(mainnetTick));
        _logPrice("  price", _sqrtPriceToWad(mainnetSqrt));
        console.log("");

        // ================================================================
        //  2. Switch to Sepolia, read pool state
        // ================================================================
        NetworkConfig.Config memory sepCfg = NetworkConfig.getConfig(11155111);

        vm.createSelectFork("sepolia");

        IPoolManager sepPm = IPoolManager(sepCfg.uniswapV4PoolManager);
        PoolId sepPoolId = PoolId.wrap(sepCfg.rareEthPoolId);

        (uint160 sepSqrt, int24 sepTick, , ) = sepPm.getSlot0(sepPoolId);
        uint128 sepLiq = sepPm.getLiquidity(sepPoolId);
        require(sepSqrt != 0, "Sepolia RARE/ETH pool not initialized");

        console.log("================================================");
        console.log("  SEPOLIA RARE/ETH (to be synced)");
        console.log("================================================");
        console.log("  sqrtPriceX96 :", uint256(sepSqrt));
        console.log("  tick         :", _tickStr(sepTick));
        console.log("  liquidity    :", uint256(sepLiq));
        _logPrice("  price", _sqrtPriceToWad(sepSqrt));
        console.log("");

        if (mainnetSqrt == sepSqrt) {
            console.log("  Prices already in sync. Nothing to do.");
            return;
        }

        bool sellRare = mainnetSqrt > sepSqrt;

        console.log("================================================");
        console.log("  SYNC PLAN");
        console.log("================================================");
        if (sellRare) {
            console.log("  Direction    : SELL RARE -> ETH (Sepolia RARE too expensive)");
        } else {
            console.log("  Direction    : BUY RARE <- ETH  (Sepolia RARE too cheap)");
        }
        console.log("  Target sqrt  :", uint256(mainnetSqrt));
        console.log("  Target tick  :", _tickStr(mainnetTick));
        console.log("");

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(sepCfg.rareToken),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // ================================================================
        //  3. DRY RUN — simulate swap on a snapshot, report exact amounts
        // ================================================================
        // Snapshot so we can roll back after the simulation.
        uint256 snap = vm.snapshotState();

        RareEthSyncer simSyncer = new RareEthSyncer();

        // Fund the sim syncer with generous ceilings — this is off-chain only
        vm.deal(address(simSyncer), SIM_ETH_CEILING);
        deal(sepCfg.rareToken, address(simSyncer), SIM_RARE_CEILING);

        (int128 simDeltaEth, int128 simDeltaRare) = simSyncer.sync(
            sepPm, key, sepCfg.rareToken, mainnetSqrt, sellRare
        );

        // Read the post-swap price to check if we fully synced
        (uint160 simFinalSqrt, int24 simFinalTick, , ) = sepPm.getSlot0(sepPoolId);
        bool fullSync = (simFinalSqrt == mainnetSqrt);

        // Roll back — pool state is restored to pre-simulation
        vm.revertToStateAndDelete(snap);

        // Report simulation results
        uint256 rareNeeded = simDeltaRare < 0 ? uint256(uint128(-simDeltaRare)) : 0;
        uint256 ethNeeded = simDeltaEth < 0 ? uint256(uint128(-simDeltaEth)) : 0;
        uint256 rareReceived = simDeltaRare > 0 ? uint256(uint128(simDeltaRare)) : 0;
        uint256 ethReceived = simDeltaEth > 0 ? uint256(uint128(simDeltaEth)) : 0;

        console.log("================================================");
        console.log("  DRY RUN RESULT (exact amounts from V4)");
        console.log("================================================");

        if (sellRare) {
            _logAmount("  RARE to sell ", rareNeeded);
            _logAmount("  ETH received ", ethReceived);
        } else {
            _logAmount("  ETH to spend ", ethNeeded);
            _logAmount("  RARE received", rareReceived);
        }
        console.log("");

        console.log("  Post-swap sqrtPriceX96 :", uint256(simFinalSqrt));
        console.log("  Post-swap tick         :", _tickStr(simFinalTick));
        _logPrice("  Post-swap price", _sqrtPriceToWad(simFinalSqrt));

        if (fullSync) {
            console.log("  Sync status  : FULL SYNC (will match mainnet exactly)");
        } else {
            console.log("  Sync status  : PARTIAL (pool exhausts liquidity before target)");
            console.log("                 The pool doesn't have enough depth to reach mainnet price.");
            console.log("                 You'd need to add liquidity first for a full sync.");
        }
        console.log("");

        // ================================================================
        //  4. EXECUTE — broadcast the real swap (only runs with --broadcast)
        // ================================================================
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("================================================");
        console.log("  EXECUTION");
        console.log("================================================");
        console.log("  Deployer     :", deployer);

        if (sellRare) {
            uint256 rareBal = IERC20(sepCfg.rareToken).balanceOf(deployer);
            console.log("  RARE balance :", rareBal / 1e18, "RARE");
            console.log("  RARE needed  :", rareNeeded / 1e18, "RARE");
            require(rareBal >= rareNeeded, "Insufficient RARE - transfer more to deployer before running with --broadcast");
        } else {
            console.log("  ETH balance  :", deployer.balance / 1e18, "ETH");
            console.log("  ETH needed   :", ethNeeded / 1e18, "ETH");
            require(deployer.balance >= ethNeeded, "Insufficient ETH - send more to deployer before running with --broadcast");
        }
        console.log("");

        vm.startBroadcast(pk);

        RareEthSyncer syncer = new RareEthSyncer();

        // Fund only what's needed (plus a tiny buffer for rounding)
        uint256 fundAmount = sellRare ? rareNeeded + 1 ether : ethNeeded + 0.01 ether;

        if (sellRare) {
            IERC20(sepCfg.rareToken).transfer(address(syncer), fundAmount);
        } else {
            payable(address(syncer)).transfer(fundAmount);
        }

        (int128 deltaEth, int128 deltaRare) = syncer.sync(
            sepPm, key, sepCfg.rareToken, mainnetSqrt, sellRare
        );

        // Recover leftover funds
        uint256 leftoverRare = IERC20(sepCfg.rareToken).balanceOf(address(syncer));
        if (leftoverRare > 0) {
            syncer.recoverERC20(sepCfg.rareToken, deployer, leftoverRare);
        }
        uint256 leftoverEth = address(syncer).balance;
        if (leftoverEth > 0) {
            syncer.recoverETH(deployer, leftoverEth);
        }

        vm.stopBroadcast();

        // Final report
        console.log("================================================");
        console.log("  SWAP EXECUTED");
        console.log("================================================");
        if (deltaEth >= 0) {
            console.log("  ETH received :", uint256(uint128(deltaEth)) / 1e18, "ETH");
        } else {
            console.log("  ETH spent    :", uint256(uint128(-deltaEth)) / 1e18, "ETH");
        }
        if (deltaRare >= 0) {
            console.log("  RARE received:", uint256(uint128(deltaRare)) / 1e18, "RARE");
        } else {
            console.log("  RARE spent   :", uint256(uint128(-deltaRare)) / 1e18, "RARE");
        }
        if (leftoverRare > 0) console.log("  RARE returned:", leftoverRare / 1e18, "(unused)");
        if (leftoverEth > 0) console.log("  ETH returned :", leftoverEth / 1e18, "(unused)");
        console.log("");

        (uint160 finalSqrt, int24 finalTick, , ) = sepPm.getSlot0(sepPoolId);
        console.log("  Final sqrtPriceX96 :", uint256(finalSqrt));
        console.log("  Final tick         :", _tickStr(finalTick));
        _logPrice("  Final price", _sqrtPriceToWad(finalSqrt));
        console.log(finalSqrt == mainnetSqrt ? "  STATUS: FULLY SYNCED" : "  STATUS: PARTIALLY SYNCED");
    }

    // ================================================================
    //  HELPERS
    // ================================================================

    function _sqrtPriceToWad(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 sqrtQ48 = uint256(sqrtPriceX96) >> 48;
        return (sqrtQ48 * sqrtQ48 * 1e18) >> 96;
    }

    function _logPrice(string memory label, uint256 priceWad) internal pure {
        uint256 whole = priceWad / 1e18;
        uint256 frac = (priceWad % 1e18) / 1e12;
        console.log(string.concat(label, " (RARE/ETH) : ", vm.toString(whole), ".", _pad(vm.toString(frac), 6)));
        if (priceWad > 0) {
            uint256 inv = 1e36 / priceWad;
            uint256 invWhole = inv / 1e18;
            uint256 invFrac = (inv % 1e18) / 1e8;
            console.log(string.concat(label, " (ETH/RARE) : ", vm.toString(invWhole), ".", _pad(vm.toString(invFrac), 10)));
        }
    }

    function _logAmount(string memory label, uint256 amount) internal pure {
        uint256 whole = amount / 1e18;
        uint256 frac = (amount % 1e18) / 1e12;
        console.log(string.concat(label, " : ", vm.toString(whole), ".", _pad(vm.toString(frac), 6)));
        console.log(string.concat("                  (wei: ", vm.toString(amount), ")"));
    }

    function _tickStr(int24 tick) internal pure returns (string memory) {
        if (tick >= 0) return vm.toString(int256(tick));
        return string.concat("-", vm.toString(uint256(uint24(-tick))));
    }

    function _pad(string memory s, uint256 w) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= w) return s;
        bytes memory p = new bytes(w - b.length);
        for (uint256 i; i < p.length; i++) p[i] = "0";
        return string.concat(string(p), s);
    }
}

/**
 * @title RareEthSyncer
 * @notice Deployed by the script to execute a V4 swap via the unlock callback pattern.
 *         Handles both directions (sell RARE / buy RARE) and settles all deltas atomically.
 */
contract RareEthSyncer is IUnlockCallback {
    IPoolManager private _pm;
    PoolKey private _key;
    address private _rareToken;
    uint160 private _targetSqrt;
    bool private _sellRare;
    int128 private _resultDeltaEth;
    int128 private _resultDeltaRare;

    receive() external payable {}

    function sync(
        IPoolManager pm,
        PoolKey calldata key,
        address rareToken,
        uint160 targetSqrt,
        bool sellRare
    ) external returns (int128 deltaEth, int128 deltaRare) {
        _pm = pm;
        _key = key;
        _rareToken = rareToken;
        _targetSqrt = targetSqrt;
        _sellRare = sellRare;

        pm.unlock(bytes(""));

        return (_resultDeltaEth, _resultDeltaRare);
    }

    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        IPoolManager pm = _pm;
        PoolKey memory key = _key;
        address rareToken = _rareToken;

        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(rareToken);

        BalanceDelta delta;

        if (_sellRare) {
            uint256 rareBal = IERC20(rareToken).balanceOf(address(this));
            delta = pm.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(rareBal),
                    sqrtPriceLimitX96: _targetSqrt
                }),
                ""
            );
        } else {
            uint256 ethBal = address(this).balance;
            delta = pm.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(ethBal),
                    sqrtPriceLimitX96: _targetSqrt
                }),
                ""
            );
        }

        _resultDeltaEth = delta.amount0();
        _resultDeltaRare = delta.amount1();

        int128 ethDelta = delta.amount0();
        int128 rareDelta = delta.amount1();

        if (rareDelta < 0) {
            uint256 owed = uint256(uint128(-rareDelta));
            pm.sync(rareC);
            IERC20(rareToken).transfer(address(pm), owed);
            pm.settle();
        } else if (rareDelta > 0) {
            pm.take(rareC, address(this), uint128(rareDelta));
        }

        if (ethDelta < 0) {
            pm.settle{value: uint256(uint128(-ethDelta))}();
        } else if (ethDelta > 0) {
            pm.take(ethC, address(this), uint128(ethDelta));
        }

        return "";
    }

    function recoverERC20(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }

    function recoverETH(address to, uint256 amount) external {
        payable(to).transfer(amount);
    }
}
