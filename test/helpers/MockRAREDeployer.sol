// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";

/// @title Mock RARE Deployer for testing
/// @dev Deploys MockRARE at deterministic addresses via CREATE2 for address-ordering tests
contract MockRAREDeployer {
    function deployMockRARE(bytes32 salt) external returns (address) {
        bytes memory bytecode = type(MockRARE).creationCode;
        address rare;
        assembly {
            rare := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(rare) {
                revert(0, 0)
            }
        }
        return rare;
    }
}
