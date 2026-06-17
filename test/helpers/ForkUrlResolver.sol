// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";

library ForkUrlResolver {
    function requireForkUrl(Vm vm) internal view returns (string memory forkUrl) {
        forkUrl = vm.envOr("FORK_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            revert("MissingForkUrl: please set FORK_URL in .env");
        }
    }
}
