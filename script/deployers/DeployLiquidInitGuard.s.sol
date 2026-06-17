// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {NetworkConfig} from "../config/NetworkConfig.sol";

/**
 * @title DeployLiquidInitGuard
 * @notice Deploys LiquidInitGuard hook via CREATE2 with a mined salt.
 * @dev The hook address must have BEFORE_INITIALIZE_FLAG (bit 13) set (pattern: 0x2000).
 *      The script brute-forces salts until a valid address is found.
 *      Set LIQUID_INIT_GUARD_SALT in env to use a pre-mined salt.
 *
 *      CREATE2 addresses are computed against the Forge deterministic CREATE2 deployer
 *      (0x4e59b44847b379578588920cA78FbF26c0B4956C) which Forge routes `new Contract{salt}()`
 *      through during broadcast.
 *
 * Environment:
 *   DEPLOYER_PRIVATE_KEY - required for broadcast
 *   LIQUID_INIT_GUARD_SALT - optional, pre-mined salt (bytes32 hex) with 0x2000 pattern
 *   LIQUID_INIT_GUARD_OWNER - optional, defaults to deployer
 *
 * Usage:
 *   forge script script/deployers/DeployLiquidInitGuard.s.sol:DeployLiquidInitGuardScript \
 *     --rpc-url $RPC_URL --broadcast
 */
library DeployLiquidInitGuard {
    uint160 constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 constant REQUIRED_FLAGS = BEFORE_INITIALIZE_FLAG; // 0x2000
    uint160 constant ALL_HOOK_MASK = (1 << 14) - 1;

    /// @dev Forge deterministic CREATE2 deployer.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Deploy for broadcast (mines against Forge CREATE2 deployer)
    function deploy(
        IPoolManager poolManager,
        address owner,
        bytes32 salt
    ) internal returns (address guard) {
        return deploy(poolManager, owner, salt, CREATE2_DEPLOYER, false);
    }

    /// @notice Deploy for tests (mines valid address, skips constructor validation)
    function deployForTest(
        IPoolManager poolManager,
        address owner,
        bytes32 salt
    ) internal returns (address guard) {
        return deployForTest(poolManager, owner, salt, 0);
    }

    /// @notice Deploy for tests with a salt mining start offset to avoid CREATE2 collisions
    function deployForTest(
        IPoolManager poolManager,
        address owner,
        bytes32 salt,
        uint256 saltStartFrom
    ) internal returns (address guard) {
        return deploy(poolManager, owner, salt, CREATE2_DEPLOYER, true, saltStartFrom);
    }

    /// @notice Deploy with explicit CREATE2 factory address and skipValidation option.
    function deploy(
        IPoolManager poolManager,
        address owner,
        bytes32 salt,
        address create2Factory,
        bool skipValidation
    ) internal returns (address guard) {
        return deploy(poolManager, owner, salt, create2Factory, skipValidation, 0);
    }

    function deploy(
        IPoolManager poolManager,
        address owner,
        bytes32 salt,
        address create2Factory,
        bool skipValidation,
        uint256 saltStartFrom
    ) internal returns (address guard) {
        bytes memory creationCode = abi.encodePacked(
            type(LiquidInitGuard).creationCode,
            abi.encode(poolManager, owner, skipValidation)
        );
        bytes32 codeHash = keccak256(creationCode);

        if (salt == bytes32(0)) {
            salt = _mineSalt(codeHash, create2Factory, saltStartFrom);
            if (!skipValidation) {
                console.log("  Mined salt:");
                console.logBytes32(salt);
            }
        }

        address computed = _computeCreate2(salt, codeHash, create2Factory);
        uint160 lowBits = uint160(computed) & ALL_HOOK_MASK;
        require(
            lowBits == REQUIRED_FLAGS,
            "DeployLiquidInitGuard: address low 14 bits must be exactly BEFORE_INITIALIZE_FLAG (0x2000)"
        );

        LiquidInitGuard guardContract = new LiquidInitGuard{salt: salt}(
            poolManager,
            owner,
            skipValidation
        );
        guard = address(guardContract);

        console.log("LiquidInitGuard deployed at:");
        console.logAddress(guard);
        return guard;
    }

    /// @notice Deploy with explicit CREATE2 factory address (production, no skipValidation).
    function deploy(
        IPoolManager poolManager,
        address owner,
        bytes32 salt,
        address create2Factory
    ) internal returns (address guard) {
        console.log("=== Deploying LiquidInitGuard ===");
        console.log("  PoolManager:");
        console.logAddress(address(poolManager));
        console.log("  Owner:");
        console.logAddress(owner);

        return deploy(poolManager, owner, salt, create2Factory, false);
    }

    function _computeCreate2(bytes32 salt, bytes32 codeHash, address _factory) private pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), _factory, salt, codeHash)
                    )
                )
            )
        );
    }

    function _mineSalt(bytes32 codeHash, address _factory, uint256 startFrom) internal pure returns (bytes32) {
        uint256 begin = startFrom * 1_000_000;
        uint256 end = begin + 1_000_000;
        for (uint256 i = begin; i < end; i++) {
            bytes32 s = bytes32(i);
            address computed = _computeCreate2(s, codeHash, _factory);
            uint160 lowBits = uint160(computed) & ALL_HOOK_MASK;
            if (lowBits == REQUIRED_FLAGS) {
                return s;
            }
        }
        revert("DeployLiquidInitGuard: could not mine valid salt in 1M iterations");
    }
}

contract DeployLiquidInitGuardScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        uint256 chainId = block.chainid;
        NetworkConfig.Config memory network = NetworkConfig.getConfig(chainId);

        address owner;
        try vm.envAddress("LIQUID_INIT_GUARD_OWNER") returns (address _owner) {
            owner = _owner;
        } catch {
            owner = deployer;
        }

        bytes32 salt;
        try vm.envBytes32("LIQUID_INIT_GUARD_SALT") returns (bytes32 envSalt) {
            salt = envSalt;
            console.log("Using env LIQUID_INIT_GUARD_SALT");
        } catch {
            salt = bytes32(0);
        }

        vm.startBroadcast(deployerPrivateKey);

        address guardAddr = DeployLiquidInitGuard.deploy(
            IPoolManager(network.uniswapV4PoolManager),
            owner,
            salt
        );

        vm.stopBroadcast();

        console.log("");
        console.log("Post-deploy: call guard.setFactory(liquidFactory)");
        console.log("  Guard:");
        console.logAddress(guardAddr);
    }
}
