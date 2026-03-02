// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";
import {FeeDistributor} from "liquid-editions/FeeDistributor.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {LiquidSwapGuard} from "liquid-editions/LiquidSwapGuard.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {LiquidAuctioneer} from "liquid-editions/LiquidAuctioneer.sol";
import {LiquidRouter} from "liquid-editions/LiquidRouter.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidMigrationExecutor} from "liquid-editions/LiquidMigrationExecutor.sol";

/**
 * @title DeployLiquidSystemReconcile
 * @notice Shared wiring helpers for DeployLiquidSystem when components are redeployed/partially deployed.
 */
library DeployLiquidSystemReconcile {
    function reconcileFeeDistributorBeneficiaryRegistry(
        address owner,
        FeeDistributor feeDistributor,
        LiquidRegistry liquidRegistry
    ) internal {
        if (
            address(feeDistributor) == address(0) ||
            address(liquidRegistry) == address(0)
        ) {
            return;
        }

        if (feeDistributor.owner() != owner) {
            console.log(
                "  Warning: FeeDistributor owner is different; skip beneficiaryRegistry wiring."
            );
            return;
        }

        try feeDistributor.setBeneficiaryRegistry(address(liquidRegistry)) {
            console.log(
                "  Shared FeeDistributor beneficiaryRegistry -> sharedLiquidRegistry"
            );
        } catch {
            console.log(
                "  Warning: Failed to set beneficiaryRegistry on shared FeeDistributor automatically."
            );
        }
    }

    function reconcileLiquidGuardFeeDistributor(
        address owner,
        LiquidGuard liquidGuard,
        FeeDistributor feeDistributor
    ) internal {
        if (address(liquidGuard) == address(0) || address(feeDistributor) == address(0)) {
            return;
        }

        if (liquidGuard.owner() != owner) {
            console.log(
                "  Warning: LiquidGuard owner is different; skip fee distributor rewire."
            );
            return;
        }

        try liquidGuard.feeDistributor() returns (address currentFeeDistributor) {
            if (currentFeeDistributor != address(feeDistributor)) {
                liquidGuard.setFeeDistributor(address(feeDistributor));
                console.log("  LiquidGuard.feeDistributor updated.");
            } else {
                console.log("  LiquidGuard.feeDistributor already up to date.");
            }
        } catch {
            console.log(
                "  Warning: Could not read or set LiquidGuard.feeDistributor()."
            );
            return;
        }

        try feeDistributor.approvedHooks(address(liquidGuard)) returns (bool approved) {
            if (!approved) {
                feeDistributor.setHookApproval(address(liquidGuard), true);
                console.log("  FeeDistributor approved for LiquidGuard.");
            }
        } catch {
            console.log(
                "  Warning: Could not verify or set FeeDistributor hook approval for LiquidGuard."
            );
        }
    }

    function reconcileLiquidGuardFactory(
        address owner,
        LiquidGuard liquidGuard,
        address expectedFactory
    ) internal {
        if (address(liquidGuard) == address(0) || expectedFactory == address(0)) {
            return;
        }

        if (liquidGuard.owner() != owner) {
            console.log(
                "  Warning: LiquidGuard owner is different; skip factory rewire."
            );
            return;
        }

        try liquidGuard.factory() returns (address currentFactory) {
            if (currentFactory != expectedFactory) {
                liquidGuard.setFactory(expectedFactory);
                console.log("  LiquidGuard.factory updated.");
            }
        } catch {
            console.log(
                "  Warning: Could not read or set LiquidGuard.factory()."
            );
        }
    }

    function reconcileLiquidSwapGuardFactory(
        address owner,
        LiquidSwapGuard liquidSwapGuard,
        address expectedFactory
    ) internal {
        if (address(liquidSwapGuard) == address(0) || expectedFactory == address(0)) {
            return;
        }

        if (liquidSwapGuard.owner() != owner) {
            console.log(
                "  Warning: LiquidSwapGuard owner is different; skip factory rewire."
            );
            return;
        }

        try liquidSwapGuard.factory() returns (address currentFactory) {
            if (currentFactory != expectedFactory) {
                liquidSwapGuard.setFactory(expectedFactory);
                console.log("  LiquidSwapGuard.factory updated.");
            }
        } catch {
            console.log(
                "  Warning: Could not read or set LiquidSwapGuard.factory()."
            );
        }
    }

    function reconcileLiquidInitGuardFactory(
        address owner,
        LiquidInitGuard liquidInitGuard,
        address expectedFactory
    ) internal {
        if (address(liquidInitGuard) == address(0) || expectedFactory == address(0)) {
            return;
        }

        if (liquidInitGuard.owner() != owner) {
            console.log(
                "  Warning: LiquidInitGuard owner is different; skip factory rewire."
            );
            return;
        }

        try liquidInitGuard.factory() returns (address currentFactory) {
            if (currentFactory != expectedFactory) {
                liquidInitGuard.setFactory(expectedFactory);
                console.log("  LiquidInitGuard.factory updated.");
            }
        } catch {
            console.log(
                "  Warning: Could not read or set LiquidInitGuard.factory()."
            );
        }
    }

    function reconcileAuctioneerModules(
        address owner,
        LiquidAuctioneer auctioneer,
        address protocolFeeRecipient,
        LiquidRegistry liquidRegistry
    ) internal {
        if (address(auctioneer) == address(0)) {
            return;
        }

        if (auctioneer.owner() != owner) {
            console.log(
                "  Warning: Auctioneer owner is different; skip module rewiring."
            );
            return;
        }

        if (protocolFeeRecipient != address(0)) {
            try auctioneer.protocolFeeRecipient() returns (address current) {
                if (current != protocolFeeRecipient) {
                    auctioneer.setProtocolFeeRecipient(protocolFeeRecipient);
                    console.log("  Auctioneer.protocolFeeRecipient updated.");
                }
            } catch {
                console.log(
                    "  Warning: Could not read or set Auctioneer.protocolFeeRecipient()."
                );
            }
        }

        if (address(liquidRegistry) != address(0)) {
            try auctioneer.liquidRegistry() returns (address currentRegistry) {
                if (currentRegistry != address(liquidRegistry)) {
                    auctioneer.setLiquidRegistry(address(liquidRegistry));
                    console.log("  Auctioneer.liquidRegistry updated.");
                }
            } catch {
                console.log(
                    "  Warning: Could not read or set Auctioneer.liquidRegistry()."
                );
            }
        }
    }

    function reconcileRouterRegistry(
        address owner,
        LiquidRouter router,
        LiquidRegistry liquidRegistry
    ) internal {
        if (address(router) == address(0) || address(liquidRegistry) == address(0)) {
            return;
        }

        if (router.owner() != owner) {
            console.log(
                "  Warning: Router owner is different; skip liquidRegistry reconnection."
            );
            return;
        }

        try router.liquidRegistry() returns (address currentRegistry) {
            if (currentRegistry != address(liquidRegistry)) {
                router.setLiquidRegistry(address(liquidRegistry));
                console.log("  Router.liquidRegistry updated.");
            }
        } catch {
            console.log(
                "  Warning: Could not read or set Router.liquidRegistry()."
            );
        }
    }

    function reconcileFactoryMigrationExecutor(
        address owner,
        LiquidFactory factory,
        address expectedMigrationExecutor
    ) internal {
        if (address(factory) == address(0) || expectedMigrationExecutor == address(0)) {
            return;
        }

        if (factory.owner() != owner) {
            console.log(
                "  Warning: Factory owner is different; skip migrationExecutor wiring."
            );
            return;
        }

        try factory.migrationExecutor() returns (address currentMigrationExecutor) {
            if (currentMigrationExecutor != expectedMigrationExecutor) {
                factory.setMigrationExecutor(expectedMigrationExecutor);
                console.log("  Factory.migrationExecutor updated.");
            } else {
                console.log("  Factory.migrationExecutor already up to date.");
            }
        } catch {
            console.log(
                "  Warning: Could not read or set Factory.migrationExecutor()."
            );
        }
    }

    function reconcileMigrationExecutorRegistry(
        address owner,
        LiquidMigrationExecutor migrationExecutor,
        LiquidRegistry liquidRegistry
    ) internal {
        if (
            address(migrationExecutor) == address(0) ||
            address(liquidRegistry) == address(0)
        ) {
            return;
        }

        if (migrationExecutor.owner() != owner) {
            console.log(
                "  Warning: MigrationExecutor owner is different; skip liquidRegistry rewiring."
            );
            return;
        }

        try migrationExecutor.liquidRegistry() returns (address currentRegistry) {
            if (currentRegistry != address(liquidRegistry)) {
                migrationExecutor.setLiquidRegistry(address(liquidRegistry));
                console.log("  MigrationExecutor.liquidRegistry updated.");
            } else {
                console.log("  MigrationExecutor.liquidRegistry already up to date.");
            }
        } catch {
            console.log(
                "  Warning: Could not read or set MigrationExecutor.liquidRegistry()."
            );
        }
    }

    function ensureRegistryWriter(
        LiquidRegistry liquidRegistry,
        address moduleAddress,
        string memory moduleName
    ) internal {
        if (moduleAddress == address(0) || address(liquidRegistry) == address(0)) {
            return;
        }

        if (liquidRegistry.isWriter(moduleAddress)) {
            return;
        }

        try liquidRegistry.setWriter(moduleAddress, true) {
            console.log("  registry writer assigned to ");
            console.log(moduleName);
        } catch {
            console.log(
                "  Warning: Could not assign registry writer automatically; check owner permissions."
            );
        }
    }
}
