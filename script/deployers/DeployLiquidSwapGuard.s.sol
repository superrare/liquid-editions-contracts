// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {LiquidSwapGuard} from "liquid-editions/LiquidSwapGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {NetworkConfig} from "../config/NetworkConfig.sol";

/**
 * @title DeployLiquidSwapGuard
 * @notice Deploys LiquidSwapGuard hook via CREATE2 with a mined salt.
 * @dev The hook address must have BEFORE_SWAP_FLAG (bit 7) set. The script brute-forces
 *      salts until a valid address is found. Set LIQUID_SWAP_GUARD_SALT in env to use a
 *      pre-mined salt (e.g. from scripts/mine-liquid-swap-guard-salt.ts).
 *
 *      CREATE2 addresses are computed against the Forge deterministic CREATE2 deployer
 *      (0x4e59b44847b379578588920cA78FbF26c0B4956C) which Forge routes `new Contract{salt}()`
 *      through during broadcast.
 *
 * Environment:
 *   DEPLOYER_PRIVATE_KEY - required for broadcast
 *   LIQUID_SWAP_GUARD_SALT - optional, pre-mined salt (bytes32 hex)
 *   LIQUID_SWAP_GUARD_OWNER - optional, defaults to deployer
 *
 * Usage:
 *   forge script script/deployers/DeployLiquidSwapGuard.s.sol:DeployLiquidSwapGuardScript \
 *     --rpc-url $RPC_URL --broadcast
 */
library DeployLiquidSwapGuard {
    uint160 constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 constant ALL_HOOK_MASK = (1 << 14) - 1;

    /// @dev Forge deterministic CREATE2 deployer. Forge routes `new Contract{salt}()` through
    ///      this factory during broadcast, so salt mining must use this address.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Deploy for broadcast (mines against Forge CREATE2 deployer)
    function deploy(
        IPoolManager poolManager,
        address owner,
        bytes32 salt
    ) internal returns (address guard) {
        return deploy(poolManager, owner, salt, CREATE2_DEPLOYER);
    }

    /// @notice Deploy with explicit CREATE2 factory address.
    /// @dev In tests (no broadcast), pass `address(this)` since `new Contract{salt}()` deploys
    ///      from the calling contract. In broadcast, use the 3-arg overload which uses CREATE2_DEPLOYER.
    function deploy(
        IPoolManager poolManager,
        address owner,
        bytes32 salt,
        address create2Factory
    ) internal returns (address guard) {
        console.log("=== Deploying LiquidSwapGuard ===");
        console.log("  PoolManager:");
        console.logAddress(address(poolManager));
        console.log("  Owner:");
        console.logAddress(owner);

        bytes memory creationCode = abi.encodePacked(
            type(LiquidSwapGuard).creationCode,
            abi.encode(poolManager, owner, false)
        );
        bytes32 codeHash = keccak256(creationCode);

        if (salt == bytes32(0)) {
            salt = _mineSalt(codeHash, create2Factory);
            console.log("  Mined salt:");
            console.logBytes32(salt);
        }

        address computed = _computeCreate2(salt, codeHash, create2Factory);

        uint160 lowBits = uint160(computed) & ALL_HOOK_MASK;
        require(
            lowBits == BEFORE_SWAP_FLAG,
            "DeployLiquidSwapGuard: address must have exactly BEFORE_SWAP_FLAG in low 14 bits"
        );

        LiquidSwapGuard guardContract = new LiquidSwapGuard{salt: salt}(
            poolManager,
            owner,
            false
        );
        guard = address(guardContract);

        console.log("LiquidSwapGuard deployed at:");
        console.logAddress(guard);
        return guard;
    }

    function _computeCreate2(bytes32 salt, bytes32 codeHash, address factory) private pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), factory, salt, codeHash)
                    )
                )
            )
        );
    }

    function _mineSalt(bytes32 codeHash, address factory) internal pure returns (bytes32) {
        for (uint256 i = 0; i < 1_000_000; i++) {
            bytes32 s = bytes32(i);
            address computed = _computeCreate2(s, codeHash, factory);
            uint160 lowBits = uint160(computed) & ALL_HOOK_MASK;
            if (lowBits == BEFORE_SWAP_FLAG) {
                return s;
            }
        }
        revert("DeployLiquidSwapGuard: could not mine valid salt in 1M iterations");
    }
}

contract DeployLiquidSwapGuardScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        uint256 chainId = block.chainid;
        NetworkConfig.Config memory network = NetworkConfig.getConfig(chainId);

        address owner;
        try vm.envAddress("LIQUID_SWAP_GUARD_OWNER") returns (address _owner) {
            owner = _owner;
        } catch {
            owner = deployer;
        }

        bytes32 salt;
        try vm.envBytes32("LIQUID_SWAP_GUARD_SALT") returns (bytes32 envSalt) {
            salt = envSalt;
            console.log("Using env LIQUID_SWAP_GUARD_SALT");
        } catch {
            salt = bytes32(0);
        }

        vm.startBroadcast(deployerPrivateKey);

        address guardAddr = DeployLiquidSwapGuard.deploy(
            IPoolManager(network.uniswapV4PoolManager),
            owner,
            salt
        );

        vm.stopBroadcast();

        console.log("");
        console.log("Post-deploy: call guard.addRouter(universalRouter) and guard.addCaller(liquidRouter)");
        console.log("  Guard:");
        console.logAddress(guardAddr);
        console.log("  Universal Router:");
        console.logAddress(network.uniswapUniversalRouter);
        console.log("  Liquid Router:");
        console.logAddress(network.liquid.router);
    }
}
