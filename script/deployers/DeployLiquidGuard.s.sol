// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {NetworkConfig} from "../config/NetworkConfig.sol";

/**
 * @title DeployLiquidGuard
 * @notice Deploys LiquidGuard hook via CREATE2 with a mined salt.
 * @dev The hook address must have the following bits in its lowest 14 bits: 0x20CC
 *        Bit 13 (0x2000): BEFORE_INITIALIZE
 *        Bit  7 (0x0080): BEFORE_SWAP
 *        Bit  6 (0x0040): AFTER_SWAP
 *        Bit  3 (0x0008): BEFORE_SWAP_RETURNS_DELTA
 *        Bit  2 (0x0004): AFTER_SWAP_RETURNS_DELTA
 *
 *      The script brute-forces salts until a valid address is found.
 *      Set LIQUID_GUARD_SALT in env to use a pre-mined salt.
 *
 *      CREATE2 addresses are computed against the Forge deterministic CREATE2 deployer
 *      (0x4e59b44847b379578588920cA78FbF26c0B4956C).
 *
 * Environment:
 *   DEPLOYER_PRIVATE_KEY       - required for broadcast
 *   LIQUID_GUARD_SALT          - optional, pre-mined salt (bytes32 hex) with 0x20CC pattern
 *   LIQUID_GUARD_OWNER         - optional, defaults to deployer
 *
 * Usage:
 *   forge script script/deployers/DeployLiquidGuard.s.sol:DeployLiquidGuardScript \
 *     --rpc-url $RPC_URL --broadcast
 */
library DeployLiquidGuard {
    uint160 constant BEFORE_INITIALIZE_FLAG = 1 << 13; // 0x2000
    uint160 constant BEFORE_SWAP_FLAG = 1 << 7; // 0x0080
    uint160 constant AFTER_SWAP_FLAG = 1 << 6; // 0x0040
    uint160 constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3; // 0x0008
    uint160 constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2; // 0x0004

    uint160 constant REQUIRED_FLAGS =
        BEFORE_INITIALIZE_FLAG |
            BEFORE_SWAP_FLAG |
            AFTER_SWAP_FLAG |
            BEFORE_SWAP_RETURNS_DELTA_FLAG |
            AFTER_SWAP_RETURNS_DELTA_FLAG; // 0x20CC

    uint160 constant ALL_HOOK_MASK = (1 << 14) - 1;

    /// @dev Forge deterministic CREATE2 deployer.
    address constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Deploy for broadcast (mines against Forge CREATE2 deployer)
    function deploy(
        IPoolManager poolManager,
        address owner,
        address rareToken,
        bytes32 salt
    ) internal returns (address guard) {
        return
            deploy(
                poolManager,
                owner,
                rareToken,
                salt,
                CREATE2_DEPLOYER,
                0
            );
    }

    /// @notice Deploy for tests (mines valid address with constructor hook validation)
    function deployForTest(
        IPoolManager poolManager,
        address owner,
        address rareToken,
        bytes32 salt
    ) internal returns (address guard) {
        return deployForTest(poolManager, owner, rareToken, salt, 0);
    }

    /// @notice Deploy for tests with a salt mining start offset to avoid CREATE2 collisions
    function deployForTest(
        IPoolManager poolManager,
        address owner,
        address rareToken,
        bytes32 salt,
        uint256 saltStartFrom
    ) internal returns (address guard) {
        return
            deploy(
                poolManager,
                owner,
                rareToken,
                salt,
                CREATE2_DEPLOYER,
                saltStartFrom
            );
    }

    /// @notice Deploy with explicit CREATE2 factory address.
    function deploy(
        IPoolManager poolManager,
        address owner,
        address rareToken,
        bytes32 salt,
        address create2Factory
    ) internal returns (address guard) {
        console.log("=== Deploying LiquidGuard ===");
        console.log("  PoolManager:");
        console.logAddress(address(poolManager));
        console.log("  Owner:");
        console.logAddress(owner);
        console.log("  RareToken:");
        console.logAddress(rareToken);

        return
            deploy(poolManager, owner, rareToken, salt, create2Factory, 0);
    }

    function deploy(
        IPoolManager poolManager,
        address owner,
        address rareToken,
        bytes32 salt,
        address create2Factory,
        uint256 saltStartFrom
    ) internal returns (address guard) {
        bytes memory creationCode = abi.encodePacked(
            type(LiquidGuard).creationCode,
            abi.encode(poolManager, owner, rareToken)
        );
        bytes32 codeHash = keccak256(creationCode);

        if (salt == bytes32(0)) {
            salt = _mineSalt(codeHash, create2Factory, saltStartFrom);
            console.log("  Mined salt:");
            console.logBytes32(salt);
        }

        address computed = _computeCreate2(salt, codeHash, create2Factory);
        uint160 lowBits = uint160(computed) & ALL_HOOK_MASK;
        require(
            lowBits == REQUIRED_FLAGS,
            "DeployLiquidGuard: address low 14 bits must be exactly 0x20CC"
        );

        LiquidGuard guardContract = new LiquidGuard{salt: salt}(
            poolManager,
            owner,
            rareToken
        );
        guard = address(guardContract);

        require(
            guard == computed,
            "DeployLiquidGuard: deployed address does not match computed CREATE2 address"
        );

        console.log("LiquidGuard deployed at:");
        console.logAddress(guard);
        return guard;
    }

    function _computeCreate2(
        bytes32 salt,
        bytes32 codeHash,
        address _factory
    ) private pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                _factory,
                                salt,
                                codeHash
                            )
                        )
                    )
                )
            );
    }

    function _mineSalt(
        bytes32 codeHash,
        address _factory,
        uint256 startFrom
    ) internal pure returns (bytes32) {
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
        revert("DeployLiquidGuard: could not mine valid salt in 1M iterations");
    }
}

contract DeployLiquidGuardScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        uint256 chainId = block.chainid;
        NetworkConfig.Config memory network = NetworkConfig.getConfig(chainId);

        address owner;
        try vm.envAddress("LIQUID_GUARD_OWNER") returns (address _owner) {
            owner = _owner;
        } catch {
            owner = deployer;
        }

        bytes32 salt;
        try vm.envBytes32("LIQUID_GUARD_SALT") returns (bytes32 envSalt) {
            salt = envSalt;
            console.log("Using env LIQUID_GUARD_SALT");
        } catch {
            salt = bytes32(0);
        }

        vm.startBroadcast(deployerPrivateKey);

        address guardAddr = DeployLiquidGuard.deploy(
            IPoolManager(network.uniswapV4PoolManager),
            owner,
            network.rareToken,
            salt
        );

        vm.stopBroadcast();

        console.log("");
        console.log("Post-deploy steps:");
        console.log("  1. call guard.setFeeDistributor(feeDistributor)");
        console.log("  2. call guard.setFactory(liquidFactory)");
        console.log("  3. call feeDistributor.setHookApproval(guard, true)");
        console.log("  Guard:");
        console.logAddress(guardAddr);
    }
}
