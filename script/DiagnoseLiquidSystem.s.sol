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
    function protocolFeeRecipient() external view returns (address);
    function ccaFactory() external view returns (address);
    function lbpStrategyFactory() external view returns (address);
    function liquidInstantImplementation() external view returns (address);
    function liquidMultiCurveImplementation() external view returns (address);
    function liquidGraduatedImplementation() external view returns (address);
    function minRareLiquidityWei() external view returns (uint256);
    function lpTickLower() external view returns (int24);
    function lpTickUpper() external view returns (int24);
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
    function poolKey() external view returns (
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    );
}

/**
 * @title DiagnoseLiquidSystem
 * @notice Read-only runbook script for quick deployment state checks.
 *
 * Addresses resolve from environment variables first, then fallback to NetworkConfig by chain.
 */
contract DiagnoseLiquidSystem is Script {
    function run() external view {
        uint256 chainId = block.chainid;
        try vm.envUint("CHAIN_ID") returns (uint256 configured) {
            chainId = configured;
        } catch {}

        NetworkConfig.Config memory cfg = NetworkConfig.getConfig(chainId);
        bool hasConfig = cfg.liquid.factory != address(0)
            || cfg.liquid.router != address(0)
            || cfg.liquid.liquidGuard != address(0)
            || cfg.liquid.liquidRegistry != address(0)
            || cfg.liquid.feeDistributor != address(0)
            || cfg.liquid.migrationExecutor != address(0);

        if (!hasConfig) {
            console.log("WARN: NetworkConfig unsupported for chain id; env-only mode only.");
        }

        address FACTORY = _resolveWithAlias("FACTORY", "LIQUID_FACTORY", cfg.liquid.factory);
        address ROUTER = _resolveWithAlias("ROUTER", "LIQUID_ROUTER", cfg.liquid.router);
        address GUARD = _resolveWithAlias("GUARD", "LIQUID_GUARD", cfg.liquid.liquidGuard);
        address REGISTRY = _resolveWithAlias("REGISTRY", "LIQUID_REGISTRY", cfg.liquid.liquidRegistry);
        address FEE_DISTRIBUTOR = _resolveWithAlias("FEE_DISTRIBUTOR", "", cfg.liquid.feeDistributor);
        address MIG_EXEC = _resolveWithAlias("MIG_EXEC", "MIGRATION_EXECUTOR", cfg.liquid.migrationExecutor);
        address TOKEN = _resolveWithAlias("TOKEN", "", address(0));
        address RARE = _resolveWithAlias("RARE", "RARE_TOKEN", cfg.rareToken);
        address USDC = _resolveWithAlias("USDC", "", cfg.usdc);

        console.log("");
        console.log("== Liquid Recovery Diagnostics ==");
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
        _emit("FEE_DISTRIBUTOR", FEE_DISTRIBUTOR);
        _emit("MIG_EXEC", MIG_EXEC);
        _emit("TOKEN", TOKEN);

        _factory(FACTORY);
        _router(ROUTER, RARE, USDC);
        _guard(GUARD);
        _registry(REGISTRY, FACTORY, GUARD);
        _feeDistributor(FEE_DISTRIBUTOR, GUARD);
        _migrationExec(MIG_EXEC, GUARD, ROUTER);
        _token(TOKEN);
        _derivedChecks(FACTORY, ROUTER, GUARD, REGISTRY, FEE_DISTRIBUTOR, MIG_EXEC);
    }

    function _emit(string memory label, address target) private pure {
        console.log(label);
        if (target == address(0)) {
            console.log("<missing>");
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

    function _resolveWithAlias(
        string memory key,
        string memory aliasKey,
        address fallbackAddress
    ) private view returns (address resolved) {
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

    function _factory(address target) private view {
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
        } catch {
            console.log("paused: <error>");
        }

        try f.poolHooks() returns (address value) {
            _emit("poolHooks", value);
        } catch {
            console.log("poolHooks: <error>");
        }

        try f.liquidRegistry() returns (address value) {
            _emit("liquidRegistry", value);
        } catch {
            console.log("liquidRegistry: <error>");
        }

        try f.migrationExecutor() returns (address value) {
            _emit("migrationExecutor", value);
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
        } catch {
            console.log("baseToken: <error>");
        }

        try f.protocolFeeRecipient() returns (address value) {
            _emit("protocolFeeRecipient", value);
        } catch {
            console.log("protocolFeeRecipient: <error>");
        }

        try f.ccaFactory() returns (address value) {
            _emit("ccaFactory", value);
        } catch {
            console.log("ccaFactory: <error>");
        }

        try f.lbpStrategyFactory() returns (address value) {
            _emit("lbpStrategyFactory", value);
        } catch {
            console.log("lbpStrategyFactory: <error>");
        }

        try f.liquidInstantImplementation() returns (address value) {
            _emit("liquidInstantImplementation", value);
        } catch {
            console.log("liquidInstantImplementation: <error>");
        }

        try f.liquidMultiCurveImplementation() returns (address value) {
            _emit("liquidMultiCurveImplementation", value);
        } catch {
            console.log("liquidMultiCurveImplementation: <error>");
        }

        try f.liquidGraduatedImplementation() returns (address value) {
            _emit("liquidGraduatedImplementation", value);
        } catch {
            console.log("liquidGraduatedImplementation: <error>");
        }

        try f.minRareLiquidityWei() returns (uint256 value) {
            console.log("minRareLiquidityWei");
            console.logUint(value);
        } catch {
            console.log("minRareLiquidityWei: <error>");
        }

        try f.lpTickLower() returns (int24 value) {
            _emitInt24("lpTickLower", value);
        } catch {
            console.log("lpTickLower: <error>");
        }

        try f.lpTickUpper() returns (int24 value) {
            _emitInt24("lpTickUpper", value);
        } catch {
            console.log("lpTickUpper: <error>");
        }

        try f.poolTickSpacing() returns (int24 value) {
            _emitInt24("poolTickSpacing", value);
        } catch {
            console.log("poolTickSpacing: <error>");
        }
    }

    function _router(address target, address rare, address usdc) private view {
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
            } catch {
                console.log("isCurrencyWhitelisted(rare): <error>");
            }
        }

        if (usdc != address(0)) {
            try r.isCurrencyWhitelisted(usdc) returns (bool value) {
                _emitBool("isCurrencyWhitelisted(usdc)", value);
            } catch {
                console.log("isCurrencyWhitelisted(usdc): <error>");
            }
        }
    }

    function _guard(address target) private view {
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

        try g.paused() returns (bool value) {
            _emitBool("paused", value);
        } catch {
            console.log("paused: <error>");
        }

        try g.factory() returns (address value) {
            _emit("factory", value);
        } catch {
            console.log("factory: <error>");
        }

        try g.feeDistributor() returns (address value) {
            _emit("feeDistributor", value);
        } catch {
            console.log("feeDistributor: <error>");
        }

        try g.totalFeeBPS() returns (uint16 value) {
            console.log("totalFeeBPS");
            console.logUint(value);
        } catch {
            console.log("totalFeeBPS: <error>");
        }
    }

    function _feeDistributor(address target, address guard) private view {
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

        try d.rareEthPoolKey() returns (
            address c0,
            address c1,
            uint24 fee,
            int24 tickSpacing,
            address hook
        ) {
            _emit("rareEthPoolKey.currency0", c0);
            _emit("rareEthPoolKey.currency1", c1);
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
            } catch {
                console.log("approvedHooks(guard): <error>");
            }
        }
    }

    function _registry(address target, address factory, address guard) private view {
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
            } catch {
                console.log("isWriter(factory): <error>");
            }
        }

        if (guard != address(0)) {
            try r.isWriter(guard) returns (bool value) {
                _emitBool("isWriter(guard)", value);
            } catch {
                console.log("isWriter(guard): <error>");
            }
        }
    }

    function _migrationExec(address target, address guard, address router) private view {
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
            } catch {
                console.log("approvedHooks(guard): <error>");
            }
        }

        if (router != address(0)) {
            try m.approvedHooks(router) returns (bool value) {
                _emitBool("approvedHooks(router)", value);
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
        if (target == address(0)) {
            return;
        }

        console.log("");
        console.log("## Token");
        try ITokenDiag(target).poolKey() returns (
            address currency0,
            address currency1,
            uint24 fee,
            int24 tickSpacing,
            address hook
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

    function _derivedChecks(
        address FACTORY,
        address ROUTER,
        address GUARD,
        address REGISTRY,
        address FEE_DISTRIBUTOR,
        address MIG_EXEC
    ) private view {
        console.log("");
        console.log("## Derived wiring checks");

        if (FACTORY == address(0) || GUARD == address(0)) {
            console.log("DIAG skipped: Factory and Guard both required for coupling checks.");
            return;
        }

        address factoryHooks;
        address routerRegistry;
        address factoryRegistry;
        address guardFactory;
        bool guardWritesFactory;

        try IFactoryDiag(FACTORY).poolHooks() returns (address value) {
            factoryHooks = value;
        } catch {}
        try IRouterDiag(ROUTER).liquidRegistry() returns (address value) {
            routerRegistry = value;
        } catch {}
        try IFactoryDiag(FACTORY).liquidRegistry() returns (address value) {
            factoryRegistry = value;
        } catch {}
        try IGuardDiag(GUARD).factory() returns (address value) {
            guardFactory = value;
        } catch {}
        try IRegistryDiag(REGISTRY).isWriter(FACTORY) returns (bool value) {
            guardWritesFactory = value;
        } catch {}

        if (factoryHooks != address(0) && factoryHooks != GUARD) {
            _emitString("DIAG", "Factory.poolHooks() != LiquidGuard");
        } else if (factoryHooks == GUARD) {
            _emitString("OK", "Factory.poolHooks() == LiquidGuard");
        }

        if (routerRegistry != address(0) && factoryRegistry != address(0) && routerRegistry != factoryRegistry) {
            _emitString("DIAG", "Router/Factory liquidRegistry mismatch");
        } else if (routerRegistry != address(0) && factoryRegistry != address(0)) {
            _emitString("OK", "Router/Factory liquidRegistry match");
        }

        if (guardFactory != address(0) && guardFactory != FACTORY) {
            _emitString("DIAG", "LiquidGuard.factory() != Factory");
        } else if (guardFactory == FACTORY) {
            _emitString("OK", "LiquidGuard.factory() == Factory");
        }

        if (REGISTRY != address(0) && FACTORY != address(0) && !guardWritesFactory) {
            _emitString("DIAG", "Registry.isWriter(Factory) == false");
        } else if (REGISTRY != address(0) && FACTORY != address(0) && guardWritesFactory) {
            _emitString("OK", "Registry.isWriter(Factory) == true");
        }

        if (GUARD != address(0) && FEE_DISTRIBUTOR != address(0) && MIG_EXEC != address(0)) {
            address distViaGuard;
            try IGuardDiag(GUARD).feeDistributor() returns (address value) {
                distViaGuard = value;
            } catch {}
            if (distViaGuard != address(0) && distViaGuard != FEE_DISTRIBUTOR) {
                _emitString("DIAG", "Guard feeDistributor != configured FeeDistributor");
            }
        }
    }
}
