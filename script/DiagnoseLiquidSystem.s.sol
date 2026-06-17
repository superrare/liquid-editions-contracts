// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";

interface IFactoryDiag {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function poolHooks() external view returns (address);
    function liquidRegistry() external view returns (address);
    function migrationExecutor() external view returns (address);
    function poolManager() external view returns (address);
    function baseToken() external view returns (address);
    function liquidMultiCurveImplementation() external view returns (address);
    function poolTickSpacing() external view returns (int24);
}

interface IRouterDiag {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function liquidRegistry() external view returns (address);
    function universalRouter() external view returns (address);
    function isCurrencyWhitelisted(address) external view returns (bool);
}

interface IGuardDiag {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function factory() external view returns (address);
    function feeDistributor() external view returns (address);
    function totalFeeBPS() external view returns (uint16);
    function POOL_MANAGER() external view returns (address);
    function RARE_TOKEN() external view returns (address);
}

interface IFeeDistributorDiag {
    function owner() external view returns (address);
    function POOL_MANAGER() external view returns (address);
    function RARE_TOKEN() external view returns (address);
    function PROTOCOL_FEE_RECIPIENT() external view returns (address);
    function totalFeeBPS() external view returns (uint16);
    function maxSlippageBps() external view returns (uint16);
    function conversionEnabled() external view returns (bool);
    function beneficiaryShareBPS() external view returns (uint16);
    function beneficiaryRegistry() external view returns (address);
    function rareEthPoolKey() external view returns (address, address, uint24, int24, address);
    function approvedHooks(address) external view returns (bool);
}

interface IRegistryDiag {
    function owner() external view returns (address);
    function isWriter(address) external view returns (bool);
    function isRegistered(address) external view returns (bool);
    function beneficiaryOf(address) external view returns (address);
}

interface IMigrationExecutorDiag {
    function owner() external view returns (address);
    function protocolVault() external view returns (address);
    function liquidRegistry() external view returns (address);
    function approvedHooks(address) external view returns (bool);
    function allowedTickSpacings(int24) external view returns (bool);
    function allowedFees(uint24) external view returns (bool);
}

interface ITokenDiag {
    function poolKey()
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
}

interface IPoolManagerDiag {
    function getSlot0(bytes32 id)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

/**
 * @title DiagnoseLiquidSystem
 * @notice Read-only runbook script for quick deployment state checks.
 *
 * Addresses resolve from environment variables first, then fallback to NetworkConfig by chain.
 *
 * Output uses three prefixes:
 *   OK   – check passed
 *   DIAG – misconfiguration detected
 *   WARN – component not deployed / address missing
 *
 * A final summary section at the end replays every DIAG/WARN so operators
 * get a single consolidated view of what needs attention.
 */
contract DiagnoseLiquidSystem is Script {
    // ---------------------------------------------------------------------------
    // Findings accumulator (max 64 issues before truncation)
    // ---------------------------------------------------------------------------

    uint256 private _issueCount;
    string[64] private _issues;

    function _recordIssue(string memory msg_) private {
        if (_issueCount < 64) {
            _issues[_issueCount] = msg_;
        }
        _issueCount++;
    }

    // ---------------------------------------------------------------------------
    // Entry point
    // ---------------------------------------------------------------------------

    function run() external {
        uint256 chainId = block.chainid;
        try vm.envUint("CHAIN_ID") returns (uint256 configured) {
            chainId = configured;
        } catch {}

        NetworkConfig.Config memory cfg = NetworkConfig.getConfig(chainId);
        bool hasConfig = cfg.liquid.factory != address(0) || cfg.liquid.router != address(0)
            || cfg.liquid.liquidGuard != address(0) || cfg.liquid.liquidRegistry != address(0)
            || cfg.liquid.feeDistributor != address(0) || cfg.liquid.migrationExecutor != address(0);

        if (!hasConfig) {
            console.log("WARN: NetworkConfig unsupported for chain id; env-only mode only.");
        }

        address FACTORY = _resolveWithAlias("FACTORY", "LIQUID_FACTORY", cfg.liquid.factory);
        address ROUTER = _resolveWithAlias("ROUTER", "LIQUID_ROUTER", cfg.liquid.router);
        address GUARD = _resolveWithAlias("GUARD", "LIQUID_GUARD", cfg.liquid.liquidGuard);
        address REGISTRY = _resolveWithAlias("REGISTRY", "LIQUID_REGISTRY", cfg.liquid.liquidRegistry);
        address FEE_DIST = _resolveWithAlias("FEE_DISTRIBUTOR", "", cfg.liquid.feeDistributor);
        address MIG_EXEC = _resolveWithAlias("MIG_EXEC", "MIGRATION_EXECUTOR", cfg.liquid.migrationExecutor);
        address TOKEN = _resolveWithAlias("TOKEN", "", address(0));
        address RARE = _resolveWithAlias("RARE", "RARE_TOKEN", cfg.rareToken);
        address USDC = _resolveWithAlias("USDC", "", cfg.usdc);

        console.log("");
        console.log("== Liquid System Diagnostics ==");
        console.log("Chain ID:");
        console.logUint(chainId);
        console.log("NetworkConfig present:");
        console.logUint(hasConfig ? 1 : 0);
        console.log("");
        console.log("Addresses used:");
        _emit("FACTORY", FACTORY);
        _emit("ROUTER", ROUTER);
        _emit("GUARD", GUARD);
        _emit("REGISTRY", REGISTRY);
        _emit("FEE_DISTRIBUTOR", FEE_DIST);
        _emit("MIG_EXEC", MIG_EXEC);
        _emit("TOKEN", TOKEN);

        // Warn on missing core components immediately so it shows up near the top
        _warnMissing("FACTORY", FACTORY);
        _warnMissing("ROUTER", ROUTER);
        _warnMissing("GUARD", GUARD);
        _warnMissing("REGISTRY", REGISTRY);
        _warnMissing("FEE_DISTRIBUTOR", FEE_DIST);
        _warnMissing("MIG_EXEC", MIG_EXEC);

        _factory(FACTORY);
        _router(ROUTER, RARE, USDC);
        _guard(GUARD);
        _registry(REGISTRY, FACTORY, GUARD);
        _feeDistributor(FEE_DIST, GUARD, REGISTRY);
        _migrationExec(MIG_EXEC, GUARD, ROUTER);
        _token(TOKEN);
        _derivedChecks(FACTORY, ROUTER, GUARD, REGISTRY, FEE_DIST, MIG_EXEC);
        _contractIdentityChecks(FACTORY, ROUTER, GUARD, REGISTRY, FEE_DIST, MIG_EXEC);
        _tickRangeChecks(FACTORY);
        _rareEthPoolKeyCheck(FEE_DIST, FACTORY, cfg.rareEthPoolId);
        _ownerConsistencyCheck(FACTORY, ROUTER, GUARD, REGISTRY, FEE_DIST, MIG_EXEC);

        _printSummary();
    }

    // ---------------------------------------------------------------------------
    // Summary
    // ---------------------------------------------------------------------------

    function _printSummary() private view {
        console.log("");
        console.log("================================================");
        console.log("== SUMMARY ==");
        console.log("================================================");
        if (_issueCount == 0) {
            console.log("OK: Everything looks good. No issues detected.");
        } else {
            console.log("Issues found:");
            console.logUint(_issueCount);
            uint256 shown = _issueCount < 64 ? _issueCount : 64;
            for (uint256 i = 0; i < shown; i++) {
                console.log(_issues[i]);
            }
            if (_issueCount > 64) {
                console.log("... (truncated - more than 64 issues)");
            }
        }
        console.log("================================================");
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    function _warnMissing(string memory label, address target) private {
        if (target == address(0)) {
            string memory msg_ =
                string.concat("WARN: ", label, " address is not set (component not deployed or not configured)");
            console.log(msg_);
            _recordIssue(msg_);
        }
    }

    function _emit(string memory label, address target) private pure {
        console.log(label);
        if (target == address(0)) {
            console.log("<missing>");
            return;
        }
        console.logAddress(target);
    }

    function _emitCurrency(string memory label, address target) private pure {
        console.log(label);
        if (target == address(0)) {
            console.log("address(0) [native ETH]");
            return;
        }
        console.logAddress(target);
    }

    function _emitBool(string memory label, bool value) private pure {
        console.log(string.concat(label, ": ", value ? "true" : "false"));
    }

    function _emitInt24(string memory label, int24 value) private pure {
        console.log(label);
        console.logInt(int256(value));
    }

    function _emitString(string memory label, string memory value) private pure {
        console.log(string.concat(label, ": ", value));
    }

    function _diagIf(bool condition, string memory msg_) private {
        if (condition) {
            _emitString("DIAG", msg_);
            _recordIssue(string.concat("DIAG: ", msg_));
        }
    }

    function _okIf(bool condition, string memory msg_) private pure {
        if (condition) {
            _emitString("OK", msg_);
        }
    }

    function _resolveWithAlias(string memory key, string memory aliasKey, address fallbackAddress)
        private
        view
        returns (address resolved)
    {
        try vm.envAddress(key) returns (address explicit) {
            if (explicit != address(0)) return explicit;
        } catch {}

        if (bytes(aliasKey).length != 0) {
            try vm.envAddress(aliasKey) returns (address explicitAlias) {
                if (explicitAlias != address(0)) return explicitAlias;
            } catch {}
        }
        return fallbackAddress;
    }

    // ---------------------------------------------------------------------------
    // Per-component sections
    // ---------------------------------------------------------------------------

    function _factory(address target) private {
        console.log("");
        console.log("## Factory");
        if (target == address(0)) {
            console.log("not configured");
            return;
        }

        IFactoryDiag f = IFactoryDiag(target);

        try f.owner() returns (address value) {
            _emit("owner", value);
        } catch {
            console.log("owner: <error>");
        }

        try f.paused() returns (bool value) {
            _emitBool("paused", value);
            _diagIf(value, "Factory is PAUSED - all token creation blocked");
        } catch {
            console.log("paused: <error>");
        }

        try f.poolHooks() returns (address value) {
            _emit("poolHooks", value);
            _diagIf(
                value == address(0), "Factory.poolHooks is address(0) - MultiCurve creation will revert PoolHooksNotSet"
            );
        } catch {
            console.log("poolHooks: <error>");
        }

        try f.liquidRegistry() returns (address value) {
            _emit("liquidRegistry", value);
            _diagIf(
                value == address(0),
                "Factory.liquidRegistry is address(0) - tokens will not be registered after creation"
            );
        } catch {
            console.log("liquidRegistry: <error>");
        }

        try f.migrationExecutor() returns (address value) {
            _emit("migrationExecutor", value);
            _diagIf(
                value == address(0),
                "Factory.migrationExecutor is address(0) - migrateLiquidity will revert on all tokens"
            );
        } catch {
            console.log("migrationExecutor: <error>");
        }

        try f.poolManager() returns (address value) {
            _emit("poolManager", value);
        } catch {
            console.log("poolManager: <error>");
        }

        try f.baseToken() returns (address value) {
            _emit("baseToken", value);
            _diagIf(value == address(0), "Factory.baseToken is address(0) - all token creation will revert");
        } catch {
            console.log("baseToken: <error>");
        }

        try f.liquidMultiCurveImplementation() returns (address value) {
            _emit("liquidMultiCurveImplementation", value);
            _diagIf(
                value == address(0),
                "Factory.liquidMultiCurveImplementation not set - createLiquidTokenMultiCurve will revert"
            );
        } catch {
            console.log("liquidMultiCurveImplementation: <error>");
        }

        try f.poolTickSpacing() returns (int24 value) {
            _emitInt24("poolTickSpacing", value);
        } catch {
            console.log("poolTickSpacing: <error>");
        }
    }

    function _router(address target, address rare, address usdc) private {
        console.log("");
        console.log("## Router");
        if (target == address(0)) {
            console.log("not configured");
            return;
        }

        IRouterDiag r = IRouterDiag(target);

        try r.owner() returns (address value) {
            _emit("owner", value);
        } catch {
            console.log("owner: <error>");
        }

        try r.paused() returns (bool value) {
            _emitBool("paused", value);
        } catch {
            console.log("paused: <error>");
        }

        try r.liquidRegistry() returns (address value) {
            _emit("liquidRegistry", value);
        } catch {
            console.log("liquidRegistry: <error>");
        }

        try r.universalRouter() returns (address value) {
            _emit("universalRouter", value);
        } catch {
            console.log("universalRouter: <error>");
        }

        if (rare != address(0)) {
            try r.isCurrencyWhitelisted(rare) returns (bool value) {
                _emitBool("isCurrencyWhitelisted(rare)", value);
                _diagIf(!value, "Router: RARE token is not whitelisted (buy/sell will revert)");
                _okIf(value, "Router: RARE token is whitelisted");
            } catch {
                console.log("isCurrencyWhitelisted(rare): <error>");
            }
        }

        if (usdc != address(0)) {
            try r.isCurrencyWhitelisted(usdc) returns (bool value) {
                _emitBool("isCurrencyWhitelisted(usdc)", value);
                _diagIf(!value, "Router: USDC is not whitelisted");
                _okIf(value, "Router: USDC is whitelisted");
            } catch {
                console.log("isCurrencyWhitelisted(usdc): <error>");
            }
        }
    }

    function _guard(address target) private {
        console.log("");
        console.log("## LiquidGuard");
        if (target == address(0)) {
            console.log("not configured");
            return;
        }

        IGuardDiag g = IGuardDiag(target);

        try g.owner() returns (address value) {
            _emit("owner", value);
        } catch {
            console.log("owner: <error>");
        }

        try g.factory() returns (address value) {
            _emit("factory", value);
            _diagIf(
                value == address(0),
                "LiquidGuard.factory is address(0) - Factory cannot call addInitializer, token creation will fail"
            );
        } catch {
            console.log("factory: <error>");
        }

        try g.feeDistributor() returns (address value) {
            _emit("feeDistributor", value);
            _diagIf(
                value == address(0), "LiquidGuard.feeDistributor is address(0) - fees silently skipped on every swap"
            );
        } catch {
            console.log("feeDistributor: <error>");
        }

        try g.totalFeeBPS() returns (uint16 value) {
            console.log("totalFeeBPS");
            console.logUint(value);
            _diagIf(value == 0, "LiquidGuard.totalFeeBPS is 0 - no fees will be collected");
        } catch {
            console.log("totalFeeBPS: <error>");
        }
    }

    function _feeDistributor(address target, address guard, address registry) private {
        console.log("");
        console.log("## FeeDistributor");
        if (target == address(0)) {
            console.log("not configured");
            return;
        }

        IFeeDistributorDiag d = IFeeDistributorDiag(target);

        try d.owner() returns (address value) {
            _emit("owner", value);
        } catch {
            console.log("owner: <error>");
        }

        try d.PROTOCOL_FEE_RECIPIENT() returns (address value) {
            _emit("protocolFeeRecipient", value);
        } catch {
            console.log("protocolFeeRecipient: <error>");
        }

        try d.beneficiaryRegistry() returns (address value) {
            _emit("beneficiaryRegistry", value);
            if (registry != address(0)) {
                bool match_ = value == registry;
                _diagIf(
                    !match_, "FeeDistributor.beneficiaryRegistry != LiquidRegistry (beneficiary payouts will be wrong)"
                );
                _okIf(match_, "FeeDistributor.beneficiaryRegistry == LiquidRegistry");
            }
        } catch {
            console.log("beneficiaryRegistry: <error>");
        }

        try d.conversionEnabled() returns (bool value) {
            _emitBool("conversionEnabled", value);
        } catch {
            console.log("conversionEnabled: <error>");
        }

        try d.maxSlippageBps() returns (uint16 value) {
            console.log("maxSlippageBps");
            console.logUint(value);
        } catch {
            console.log("maxSlippageBps: <error>");
        }

        try d.beneficiaryShareBPS() returns (uint16 value) {
            console.log("beneficiaryShareBPS");
            console.logUint(value);
        } catch {
            console.log("beneficiaryShareBPS: <error>");
        }

        try d.totalFeeBPS() returns (uint16 value) {
            console.log("totalFeeBPS(immutable)");
            console.logUint(value);
        } catch {
            console.log("totalFeeBPS(immutable): <error>");
        }

        try d.rareEthPoolKey() returns (address c0, address c1, uint24 fee, int24 tickSpacing, address hook) {
            _emitCurrency("rareEthPoolKey.currency0", c0);
            _emitCurrency("rareEthPoolKey.currency1", c1);
            console.log("rareEthPoolKey.fee");
            console.logUint(fee);
            _emitInt24("rareEthPoolKey.tickSpacing", tickSpacing);
            _emit("rareEthPoolKey.hook", hook);
        } catch {
            console.log("rareEthPoolKey: <error>");
        }

        if (guard != address(0)) {
            try d.approvedHooks(guard) returns (bool value) {
                _emitBool("approvedHooks(guard)", value);
                _diagIf(
                    !value,
                    "FeeDistributor.approvedHooks(guard) == false: LiquidGuard cannot call notifyFee - fees will be silently skipped"
                );
                _okIf(value, "FeeDistributor.approvedHooks(guard) == true");
            } catch {
                console.log("approvedHooks(guard): <error>");
            }
        }
    }

    function _registry(address target, address factory, address guard) private {
        console.log("");
        console.log("## LiquidRegistry");
        if (target == address(0)) {
            console.log("not configured");
            return;
        }

        IRegistryDiag r = IRegistryDiag(target);

        try r.owner() returns (address value) {
            _emit("owner", value);
        } catch {
            console.log("owner: <error>");
        }

        if (factory != address(0)) {
            try r.isWriter(factory) returns (bool value) {
                _emitBool("isWriter(factory)", value);
                _diagIf(
                    !value, "Registry.isWriter(factory) == false: Factory cannot register tokens or set beneficiaries"
                );
                _okIf(value, "Registry.isWriter(factory) == true");
            } catch {
                console.log("isWriter(factory): <error>");
            }
        }

        if (guard != address(0)) {
            try r.isWriter(guard) returns (bool value) {
                _emitBool("isWriter(guard)", value);
                // Guard does not need to be a writer in the standard wiring; just report.
            } catch {
                console.log("isWriter(guard): <error>");
            }
        }
    }

    function _migrationExec(address target, address guard, address router) private {
        console.log("");
        console.log("## MigrationExecutor");
        if (target == address(0)) {
            console.log("not configured");
            return;
        }

        IMigrationExecutorDiag m = IMigrationExecutorDiag(target);

        try m.owner() returns (address value) {
            _emit("owner", value);
        } catch {
            console.log("owner: <error>");
        }

        try m.protocolVault() returns (address value) {
            _emit("protocolVault", value);
        } catch {
            console.log("protocolVault: <error>");
        }

        try m.liquidRegistry() returns (address value) {
            _emit("liquidRegistry", value);
        } catch {
            console.log("liquidRegistry: <error>");
        }

        if (guard != address(0)) {
            try m.approvedHooks(guard) returns (bool value) {
                _emitBool("approvedHooks(guard)", value);
                _diagIf(
                    !value, "MigrationExecutor.approvedHooks(guard) == false: migration to LiquidGuard hook will revert"
                );
                _okIf(value, "MigrationExecutor.approvedHooks(guard) == true");
            } catch {
                console.log("approvedHooks(guard): <error>");
            }
        }

        if (router != address(0)) {
            try m.approvedHooks(router) returns (bool value) {
                _emitBool("approvedHooks(router)", value);
                // Router is not typically a hook target; just informational.
            } catch {
                console.log("approvedHooks(router): <error>");
            }
        }

        _migrationCheckValues(m, 30);
        _migrationCheckValues(m, 60);
        _migrationCheckValues(m, 100);
        _migrationCheckValues(m, 300);
        _migrationCheckValues(m, 500);
        _migrationCheckValues(m, 3000);

        _migrationCheckSpacings(m, 1);
        _migrationCheckSpacings(m, 10);
        _migrationCheckSpacings(m, 60);
    }

    function _migrationCheckValues(IMigrationExecutorDiag target, uint24 fee) private view {
        console.log("allowedFees");
        console.logUint(fee);
        try target.allowedFees(fee) returns (bool value) {
            console.logUint(value ? 1 : 0);
        } catch {
            console.log("<error>");
        }
    }

    function _migrationCheckSpacings(IMigrationExecutorDiag target, int24 spacing) private view {
        console.log("allowedTickSpacings");
        console.logInt(int256(spacing));
        try target.allowedTickSpacings(spacing) returns (bool value) {
            console.logUint(value ? 1 : 0);
        } catch {
            console.log("<error>");
        }
    }

    function _token(address target) private view {
        if (target == address(0)) return;

        console.log("");
        console.log("## Token");
        try ITokenDiag(target).poolKey() returns (
            address currency0, address currency1, uint24 fee, int24 tickSpacing, address hook
        ) {
            _emit("token.poolKey.currency0", currency0);
            _emit("token.poolKey.currency1", currency1);
            console.log("token.poolKey.fee");
            console.logUint(fee);
            _emitInt24("token.poolKey.tickSpacing", tickSpacing);
            _emit("token.poolKey.hook", hook);
        } catch {
            console.log("token.poolKey: <error>");
        }
    }

    // ---------------------------------------------------------------------------
    // Derived wiring checks
    // ---------------------------------------------------------------------------

    function _derivedChecks(
        address FACTORY,
        address ROUTER,
        address GUARD,
        address REGISTRY,
        address FEE_DIST,
        address MIG_EXEC
    ) private {
        console.log("");
        console.log("## Derived wiring checks");

        if (FACTORY == address(0) || GUARD == address(0)) {
            console.log("DIAG skipped: Factory and Guard both required for coupling checks.");
            return;
        }

        // --- Factory <-> Guard ---
        address factoryHooks;
        address guardFactory;
        try IFactoryDiag(FACTORY).poolHooks() returns (address value) {
            factoryHooks = value;
        } catch {}
        try IGuardDiag(GUARD).factory() returns (address value) {
            guardFactory = value;
        } catch {}

        bool hooksOk = factoryHooks != address(0) && factoryHooks == GUARD;
        _diagIf(factoryHooks != address(0) && factoryHooks != GUARD, "Factory.poolHooks() != LiquidGuard");
        _okIf(hooksOk, "Factory.poolHooks() == LiquidGuard");

        bool guardFactoryOk = guardFactory != address(0) && guardFactory == FACTORY;
        _diagIf(guardFactory != address(0) && guardFactory != FACTORY, "LiquidGuard.factory() != Factory");
        _okIf(guardFactoryOk, "LiquidGuard.factory() == Factory");

        // Bi-directional: both must agree
        if (factoryHooks != address(0) && guardFactory != address(0)) {
            _diagIf(
                factoryHooks == GUARD && guardFactory != FACTORY,
                "Factory points to Guard but Guard points to a different Factory - bi-directional mismatch"
            );
            _diagIf(
                factoryHooks != GUARD && guardFactory == FACTORY,
                "Guard points to Factory but Factory points to a different Guard - bi-directional mismatch"
            );
        }

        // --- Guard feeDistributor ---
        address distViaGuard;
        try IGuardDiag(GUARD).feeDistributor() returns (address value) {
            distViaGuard = value;
        } catch {}

        _diagIf(distViaGuard == address(0), "LiquidGuard.feeDistributor is address(0) - fees will not be distributed");
        if (FEE_DIST != address(0) && distViaGuard != address(0)) {
            _diagIf(distViaGuard != FEE_DIST, "Guard.feeDistributor != configured FeeDistributor");
            _okIf(distViaGuard == FEE_DIST, "Guard.feeDistributor == FeeDistributor");
        }

        // --- Registry writers ---
        address factoryRegistry;
        address routerRegistry;
        try IFactoryDiag(FACTORY).liquidRegistry() returns (address value) {
            factoryRegistry = value;
        } catch {}
        try IRouterDiag(ROUTER).liquidRegistry() returns (address value) {
            routerRegistry = value;
        } catch {}

        if (REGISTRY != address(0)) {
            bool factoryIsWriter;
            try IRegistryDiag(REGISTRY).isWriter(FACTORY) returns (bool v) {
                factoryIsWriter = v;
            } catch {}
            _diagIf(!factoryIsWriter, "Registry.isWriter(factory) == false - token creation will fail");
            _okIf(factoryIsWriter, "Registry.isWriter(factory) == true");
        }

        // --- Registry consistency across components ---
        if (routerRegistry != address(0) && factoryRegistry != address(0)) {
            _diagIf(routerRegistry != factoryRegistry, "Router/Factory liquidRegistry mismatch");
            _okIf(routerRegistry == factoryRegistry, "Router/Factory liquidRegistry match");
        }
        if (REGISTRY != address(0) && factoryRegistry != address(0)) {
            _diagIf(factoryRegistry != REGISTRY, "Factory.liquidRegistry != expected REGISTRY address");
            _okIf(factoryRegistry == REGISTRY, "Factory.liquidRegistry == REGISTRY");
        }
        if (REGISTRY != address(0) && routerRegistry != address(0)) {
            _diagIf(routerRegistry != REGISTRY, "Router.liquidRegistry != expected REGISTRY address");
            _okIf(routerRegistry == REGISTRY, "Router.liquidRegistry == REGISTRY");
        }

        // --- MigrationExecutor registry ---
        if (MIG_EXEC != address(0) && REGISTRY != address(0)) {
            address migRegistry;
            try IMigrationExecutorDiag(MIG_EXEC).liquidRegistry() returns (address value) {
                migRegistry = value;
            } catch {}
            if (migRegistry != address(0)) {
                _diagIf(migRegistry != REGISTRY, "MigrationExecutor.liquidRegistry != expected REGISTRY address");
                _okIf(migRegistry == REGISTRY, "MigrationExecutor.liquidRegistry == REGISTRY");
            }
        }

        // --- FeeDistributor approvedHooks(guard) ---
        if (FEE_DIST != address(0)) {
            try IFeeDistributorDiag(FEE_DIST).approvedHooks(GUARD) returns (bool value) {
                _diagIf(!value, "FeeDistributor.approvedHooks(guard) == false - Guard cannot call notifyFee");
                _okIf(value, "FeeDistributor.approvedHooks(guard) == true");
            } catch {}
        }

        // --- MigrationExecutor approvedHooks(guard) ---
        if (MIG_EXEC != address(0)) {
            try IMigrationExecutorDiag(MIG_EXEC).approvedHooks(GUARD) returns (bool value) {
                _diagIf(!value, "MigrationExecutor.approvedHooks(guard) == false - migration to guard hook will revert");
                _okIf(value, "MigrationExecutor.approvedHooks(guard) == true");
            } catch {}
        }

        // --- Factory.migrationExecutor vs MIG_EXEC ---
        if (MIG_EXEC != address(0)) {
            address factoryMigExec;
            try IFactoryDiag(FACTORY).migrationExecutor() returns (address v) {
                factoryMigExec = v;
            } catch {}
            if (factoryMigExec != address(0)) {
                _diagIf(
                    factoryMigExec != MIG_EXEC,
                    "Factory.migrationExecutor != expected MIG_EXEC - tokens will check wrong executor"
                );
                _okIf(factoryMigExec == MIG_EXEC, "Factory.migrationExecutor == MIG_EXEC");
            }
        }

        // --- FeeDistributor.beneficiaryRegistry vs REGISTRY ---
        if (FEE_DIST != address(0) && REGISTRY != address(0)) {
            try IFeeDistributorDiag(FEE_DIST).beneficiaryRegistry() returns (address value) {
                _diagIf(
                    value != REGISTRY,
                    "FeeDistributor.beneficiaryRegistry != LiquidRegistry - beneficiary payouts will be wrong"
                );
                _okIf(value == REGISTRY, "FeeDistributor.beneficiaryRegistry == LiquidRegistry");
            } catch {}
        }
    }

    // ---------------------------------------------------------------------------
    // Contract identity checks
    //
    // For each pointer address, call a function that is unique to that contract
    // type and cross-validate its return value against the same value sourced
    // independently from another contract. A wrong contract at that address will
    // either revert (DIAG: <error>) or return an inconsistent value (DIAG: mismatch).
    // ---------------------------------------------------------------------------

    function _contractIdentityChecks(
        address FACTORY,
        address ROUTER,
        address GUARD,
        address REGISTRY,
        address FEE_DIST,
        address MIG_EXEC
    ) private {
        console.log("");
        console.log("## Contract identity checks");

        // Canonical values sourced from Factory (ground truth where available)
        address canonicalPoolManager;
        address canonicalBaseToken;
        address canonicalRegistry;

        if (FACTORY != address(0)) {
            try IFactoryDiag(FACTORY).poolManager() returns (address v) {
                canonicalPoolManager = v;
            } catch {}
            try IFactoryDiag(FACTORY).baseToken() returns (address v) {
                canonicalBaseToken = v;
            } catch {}
            try IFactoryDiag(FACTORY).liquidRegistry() returns (address v) {
                canonicalRegistry = v;
            } catch {}
        }

        // --- GUARD: unique fn POOL_MANAGER() + RARE_TOKEN() ---
        // A non-Guard contract is very unlikely to expose both of these with the right values.
        if (GUARD != address(0)) {
            address guardPM;
            address guardRare;
            try IGuardDiag(GUARD).POOL_MANAGER() returns (address v) {
                guardPM = v;
            } catch {
                _diagIf(true, "GUARD: POOL_MANAGER() call failed - may not be a LiquidGuard contract");
            }
            try IGuardDiag(GUARD).RARE_TOKEN() returns (address v) {
                guardRare = v;
            } catch {
                _diagIf(true, "GUARD: RARE_TOKEN() call failed - may not be a LiquidGuard contract");
            }
            if (canonicalPoolManager != address(0) && guardPM != address(0)) {
                _diagIf(
                    guardPM != canonicalPoolManager,
                    "GUARD.POOL_MANAGER != Factory.poolManager - wrong contract or misconfigured"
                );
                _okIf(guardPM == canonicalPoolManager, "GUARD.POOL_MANAGER == Factory.poolManager");
            }
            if (canonicalBaseToken != address(0) && guardRare != address(0)) {
                _diagIf(
                    guardRare != canonicalBaseToken,
                    "GUARD.RARE_TOKEN != Factory.baseToken - wrong contract or misconfigured"
                );
                _okIf(guardRare == canonicalBaseToken, "GUARD.RARE_TOKEN == Factory.baseToken");
            }
        }

        // --- FEE_DIST: unique fn POOL_MANAGER() + RARE_TOKEN() + PROTOCOL_FEE_RECIPIENT() ---
        if (FEE_DIST != address(0)) {
            address distPM;
            address distRare;
            try IFeeDistributorDiag(FEE_DIST).POOL_MANAGER() returns (address v) {
                distPM = v;
            } catch {
                _diagIf(true, "FEE_DIST: POOL_MANAGER() call failed - may not be a FeeDistributor contract");
            }
            try IFeeDistributorDiag(FEE_DIST).RARE_TOKEN() returns (address v) {
                distRare = v;
            } catch {
                _diagIf(true, "FEE_DIST: RARE_TOKEN() call failed - may not be a FeeDistributor contract");
            }
            if (canonicalPoolManager != address(0) && distPM != address(0)) {
                _diagIf(
                    distPM != canonicalPoolManager,
                    "FEE_DIST.POOL_MANAGER != Factory.poolManager - wrong contract or misconfigured"
                );
                _okIf(distPM == canonicalPoolManager, "FEE_DIST.POOL_MANAGER == Factory.poolManager");
            }
            if (canonicalBaseToken != address(0) && distRare != address(0)) {
                _diagIf(
                    distRare != canonicalBaseToken,
                    "FEE_DIST.RARE_TOKEN != Factory.baseToken - wrong contract or misconfigured"
                );
                _okIf(distRare == canonicalBaseToken, "FEE_DIST.RARE_TOKEN == Factory.baseToken");
            }

            // Guard and FeeDistributor must agree on totalFeeBPS (Guard caches it from FeeDistributor at setFeeDistributor time)
            if (GUARD != address(0)) {
                uint16 guardFeeBPS;
                uint16 distFeeBPS;
                bool guardFeeOk;
                bool distFeeOk;
                try IGuardDiag(GUARD).totalFeeBPS() returns (uint16 v) {
                    guardFeeBPS = v;
                    guardFeeOk = true;
                } catch {}
                try IFeeDistributorDiag(FEE_DIST).totalFeeBPS() returns (uint16 v) {
                    distFeeBPS = v;
                    distFeeOk = true;
                } catch {}
                if (guardFeeOk && distFeeOk) {
                    _diagIf(
                        guardFeeBPS != distFeeBPS,
                        "GUARD.totalFeeBPS != FEE_DIST.totalFeeBPS - fee split mismatch, Guard may be stale"
                    );
                    _okIf(guardFeeBPS == distFeeBPS, "GUARD.totalFeeBPS == FEE_DIST.totalFeeBPS");
                }
            }
        }

        // --- REGISTRY: unique fn isWriter(address) ---
        // Call isWriter on an address we know must be a writer (Factory). Reverts or returns unexpected
        // type means the contract at this address is not a LiquidRegistry.
        if (REGISTRY != address(0) && FACTORY != address(0)) {
            try IRegistryDiag(REGISTRY).isWriter(FACTORY) returns (bool) {
                _okIf(true, "REGISTRY: isWriter() callable - consistent with LiquidRegistry interface");
            } catch {
                _diagIf(true, "REGISTRY: isWriter() call failed - may not be a LiquidRegistry contract");
            }
            // Also probe beneficiaryOf with zero address — should return address(0) not revert on a real registry
            try IRegistryDiag(REGISTRY).beneficiaryOf(address(0)) returns (address) {
                _okIf(true, "REGISTRY: beneficiaryOf() callable - consistent with LiquidRegistry interface");
            } catch {
                _diagIf(true, "REGISTRY: beneficiaryOf() call failed - may not be a LiquidRegistry contract");
            }
        }

        // --- ROUTER: unique fn universalRouter() + liquidRegistry() ---
        if (ROUTER != address(0)) {
            address routerUR;
            try IRouterDiag(ROUTER).universalRouter() returns (address v) {
                routerUR = v;
            } catch {
                _diagIf(true, "ROUTER: universalRouter() call failed - may not be a LiquidRouter contract");
            }
            if (routerUR == address(0)) {
                _diagIf(true, "ROUTER: universalRouter() returned address(0) - UniversalRouter not configured");
            } else {
                _okIf(true, "ROUTER: universalRouter() returned non-zero address");
            }
            if (canonicalRegistry != address(0)) {
                address routerReg;
                try IRouterDiag(ROUTER).liquidRegistry() returns (address v) {
                    routerReg = v;
                } catch {}
                if (routerReg != address(0)) {
                    _diagIf(
                        routerReg != canonicalRegistry,
                        "ROUTER: liquidRegistry() mismatch vs Factory - wrong contract or misconfigured"
                    );
                    _okIf(routerReg == canonicalRegistry, "ROUTER: liquidRegistry() == Factory.liquidRegistry");
                }
            }
        }

        // --- MIG_EXEC: unique fn protocolVault() + liquidRegistry() ---
        if (MIG_EXEC != address(0)) {
            address migVault;
            try IMigrationExecutorDiag(MIG_EXEC).protocolVault() returns (address v) {
                migVault = v;
            } catch {
                _diagIf(true, "MIG_EXEC: protocolVault() call failed - may not be a LiquidMigrationExecutor contract");
            }
            if (migVault == address(0)) {
                _diagIf(true, "MIG_EXEC: protocolVault() returned address(0) - vault not configured");
            } else {
                _okIf(true, "MIG_EXEC: protocolVault() returned non-zero address");
            }
            if (canonicalRegistry != address(0)) {
                address migReg;
                try IMigrationExecutorDiag(MIG_EXEC).liquidRegistry() returns (address v) {
                    migReg = v;
                } catch {}
                if (migReg != address(0)) {
                    _diagIf(
                        migReg != canonicalRegistry,
                        "MIG_EXEC: liquidRegistry() mismatch vs Factory - wrong contract or misconfigured"
                    );
                    _okIf(migReg == canonicalRegistry, "MIG_EXEC: liquidRegistry() == Factory.liquidRegistry");
                }
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Tick range + spacing sanity
    // ---------------------------------------------------------------------------

    function _tickRangeChecks(address FACTORY) private {
        console.log("");
        console.log("## Pool tick spacing checks");
        if (FACTORY == address(0)) {
            console.log("skipped (no Factory)");
            return;
        }

        int24 spacing;
        bool spacingOk;

        try IFactoryDiag(FACTORY).poolTickSpacing() returns (int24 v) {
            spacing = v;
            spacingOk = true;
        } catch {}

        if (!spacingOk) {
            console.log("could not read poolTickSpacing from Factory");
            return;
        }

        _diagIf(spacing <= 0, "poolTickSpacing <= 0 - invalid, pool creation will revert");
        _okIf(spacing > 0, "poolTickSpacing > 0");
    }

    // ---------------------------------------------------------------------------
    // RARE/ETH pool key existence check
    // ---------------------------------------------------------------------------

    function _rareEthPoolKeyCheck(address FEE_DIST, address FACTORY, bytes32 knownPoolId) private {
        console.log("");
        console.log("## RARE/ETH pool key check");
        if (FEE_DIST == address(0)) {
            console.log("skipped (no FeeDistributor)");
            return;
        }

        address c0;
        address c1;
        uint24 fee;
        int24 tickSpacing;
        address hook;
        try IFeeDistributorDiag(FEE_DIST).rareEthPoolKey() returns (
            address _c0, address _c1, uint24 _fee, int24 _ts, address _hook
        ) {
            c0 = _c0;
            c1 = _c1;
            fee = _fee;
            tickSpacing = _ts;
            hook = _hook;
        } catch {
            console.log("could not read rareEthPoolKey");
            return;
        }

        bool keyIsZero = c0 == address(0) && c1 == address(0) && fee == 0 && tickSpacing == 0 && hook == address(0);
        if (keyIsZero) {
            _diagIf(true, "rareEthPoolKey is all zeros - fee conversion will always fall back to RARE distribution");
            return;
        }

        // Compute PoolId = keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))
        bytes32 computedPoolId = keccak256(abi.encode(c0, c1, fee, tickSpacing, hook));
        console.log("computed poolId from rareEthPoolKey:");
        console.logBytes32(computedPoolId);

        // Compare against known pool ID from NetworkConfig (if available)
        if (knownPoolId != bytes32(0)) {
            console.log("known rareEthPoolId from NetworkConfig:");
            console.logBytes32(knownPoolId);
            _diagIf(
                computedPoolId != knownPoolId,
                "rareEthPoolKey produces a different poolId than NetworkConfig.rareEthPoolId - pool key parameters are wrong"
            );
            _okIf(computedPoolId == knownPoolId, "rareEthPoolKey poolId matches NetworkConfig.rareEthPoolId");
        }

        // Try to read slot0 from PoolManager to verify the pool exists on-chain
        address pm;
        if (FACTORY != address(0)) {
            try IFactoryDiag(FACTORY).poolManager() returns (address v) {
                pm = v;
            } catch {}
        }
        if (pm == address(0)) {
            try IFeeDistributorDiag(FEE_DIST).POOL_MANAGER() returns (address v) {
                pm = v;
            } catch {}
        }

        if (pm == address(0)) {
            console.log("cannot verify pool existence (no PoolManager address)");
            return;
        }

        // First try the computed ID from the pool key
        bool poolFound;
        try IPoolManagerDiag(pm).getSlot0(computedPoolId) returns (uint160 sqrtPrice, int24, uint24, uint24) {
            if (sqrtPrice != 0) {
                poolFound = true;
                _okIf(true, "rareEthPoolKey pool exists and is initialized (via computed poolId)");
            } else {
                _diagIf(
                    true,
                    "rareEthPoolKey pool sqrtPriceX96 == 0 - pool not initialized, conversion will fall back to RARE"
                );
            }
        } catch {}

        // If computed ID didn't find a pool but we have a known ID, check that instead
        if (!poolFound && knownPoolId != bytes32(0) && knownPoolId != computedPoolId) {
            try IPoolManagerDiag(pm).getSlot0(knownPoolId) returns (uint160 sqrtPrice, int24, uint24, uint24) {
                if (sqrtPrice != 0) {
                    _diagIf(
                        true,
                        "RARE/ETH pool exists at NetworkConfig.rareEthPoolId but NOT at the FeeDistributor's rareEthPoolKey - pool key is misconfigured"
                    );
                }
            } catch {}
        }

        if (!poolFound && knownPoolId == bytes32(0)) {
            _diagIf(true, "rareEthPoolKey pool not found on PoolManager - conversion swaps will fail");
        }
    }

    // ---------------------------------------------------------------------------
    // Owner consistency
    // ---------------------------------------------------------------------------

    function _ownerConsistencyCheck(
        address FACTORY,
        address ROUTER,
        address GUARD,
        address REGISTRY,
        address FEE_DIST,
        address MIG_EXEC
    ) private {
        console.log("");
        console.log("## Owner consistency");

        address[6] memory addrs = [FACTORY, ROUTER, GUARD, REGISTRY, FEE_DIST, MIG_EXEC];
        string[6] memory labels = ["Factory", "Router", "Guard", "Registry", "FeeDistributor", "MigrationExecutor"];
        address referenceOwner;
        string memory referenceLabel;
        bool referenceSet;
        bool allMatch = true;
        uint256 checked;

        for (uint256 i = 0; i < 6; i++) {
            if (addrs[i] == address(0)) continue;
            address ownerAddr;
            bool ok;
            try IFactoryDiag(addrs[i]).owner() returns (address v) {
                ownerAddr = v;
                ok = true;
            } catch {}
            if (!ok) continue;

            _emit(string.concat(labels[i], ".owner"), ownerAddr);
            checked++;

            if (!referenceSet) {
                referenceOwner = ownerAddr;
                referenceLabel = labels[i];
                referenceSet = true;
            } else if (ownerAddr != referenceOwner) {
                allMatch = false;
                _diagIf(
                    true,
                    string.concat(
                        labels[i], ".owner != ", referenceLabel, ".owner - ownership mismatch across contracts"
                    )
                );
            }
        }

        if (checked >= 2 && allMatch) {
            _okIf(true, "All contract owners match");
        }
    }
}
