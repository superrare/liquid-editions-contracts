// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {DeployLiquidSystemReconcile} from "../../script/deployers/DeployLiquidSystemReconcile.s.sol";
import {FeeDistributor} from "liquid-editions/FeeDistributor.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidRegistry} from "liquid-editions/LiquidRegistry.sol";

contract MockRegistry {}

contract MockFactory {
    address public owner;
    address public liquidRegistry;
    uint256 public setLiquidRegistryCalls;

    constructor(address _owner) {
        owner = _owner;
    }

    function setLiquidRegistry(address _liquidRegistry) external {
        require(msg.sender == owner, "not owner");
        liquidRegistry = _liquidRegistry;
        setLiquidRegistryCalls++;
    }
}

contract MockFeeDistributor {
    address public owner;
    address public beneficiaryRegistry;
    uint256 public setBeneficiaryRegistryCalls;

    constructor(address _owner) {
        owner = _owner;
    }

    function setBeneficiaryRegistry(address _beneficiaryRegistry) external {
        require(msg.sender == owner, "not owner");
        beneficiaryRegistry = _beneficiaryRegistry;
        setBeneficiaryRegistryCalls++;
    }
}

contract DeployLiquidSystemReconcileUnitTest is Test {
    function test_ReconcileFactoryLiquidRegistry_SkipsWhenAlreadyConfigured() public {
        MockRegistry registry = new MockRegistry();
        MockFactory factory = new MockFactory(address(this));
        factory.setLiquidRegistry(address(registry));

        DeployLiquidSystemReconcile.reconcileFactoryLiquidRegistry(
            address(this),
            LiquidFactory(address(factory)),
            LiquidRegistry(address(registry))
        );

        assertEq(factory.liquidRegistry(), address(registry));
        assertEq(factory.setLiquidRegistryCalls(), 1);
    }

    function test_ReconcileFactoryLiquidRegistry_UpdatesWhenMismatched() public {
        MockRegistry registry = new MockRegistry();
        MockRegistry oldRegistry = new MockRegistry();
        MockFactory factory = new MockFactory(address(this));
        factory.setLiquidRegistry(address(oldRegistry));

        DeployLiquidSystemReconcile.reconcileFactoryLiquidRegistry(
            address(this),
            LiquidFactory(address(factory)),
            LiquidRegistry(address(registry))
        );

        assertEq(factory.liquidRegistry(), address(registry));
        assertEq(factory.setLiquidRegistryCalls(), 2);
    }

    function test_ReconcileFeeDistributorBeneficiaryRegistry_SkipsWhenAlreadyConfigured()
        public
    {
        MockRegistry registry = new MockRegistry();
        MockFeeDistributor feeDistributor = new MockFeeDistributor(address(this));
        feeDistributor.setBeneficiaryRegistry(address(registry));

        DeployLiquidSystemReconcile.reconcileFeeDistributorBeneficiaryRegistry(
            address(this),
            FeeDistributor(payable(address(feeDistributor))),
            LiquidRegistry(address(registry))
        );

        assertEq(feeDistributor.beneficiaryRegistry(), address(registry));
        assertEq(feeDistributor.setBeneficiaryRegistryCalls(), 1);
    }

    function test_ReconcileFeeDistributorBeneficiaryRegistry_UpdatesWhenMismatched()
        public
    {
        MockRegistry registry = new MockRegistry();
        MockRegistry oldRegistry = new MockRegistry();
        MockFeeDistributor feeDistributor = new MockFeeDistributor(address(this));
        feeDistributor.setBeneficiaryRegistry(address(oldRegistry));

        DeployLiquidSystemReconcile.reconcileFeeDistributorBeneficiaryRegistry(
            address(this),
            FeeDistributor(payable(address(feeDistributor))),
            LiquidRegistry(address(registry))
        );

        assertEq(feeDistributor.beneficiaryRegistry(), address(registry));
        assertEq(feeDistributor.setBeneficiaryRegistryCalls(), 2);
    }
}
