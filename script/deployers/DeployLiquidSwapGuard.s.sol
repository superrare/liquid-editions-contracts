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
 * @dev The hook address must have both BEFORE_SWAP_FLAG (bit 7) and BEFORE_INITIALIZE_FLAG (bit 13)
 *      set (pattern: 0x2080). The script brute-forces salts until a valid address is found.
 *      Set LIQUID_SWAP_GUARD_SALT in env to use a pre-mined salt.
 *
 *      CREATE2 addresses are computed against the Forge deterministic CREATE2 deployer
 *      (0x4e59b44847b379578588920cA78FbF26c0B4956C) which Forge routes `new Contract{salt}()`
 *      through during broadcast.
 *
 * Environment:
 *   DEPLOYER_PRIVATE_KEY - required for broadcast
 *   LIQUID_SWAP_GUARD_SALT - optional, pre-mined salt (bytes32 hex) with 0x2080 pattern
 *   LIQUID_SWAP_GUARD_OWNER - optional, defaults to deployer
 *
 * Usage:
 *   forge script script/deployers/DeployLiquidSwapGuard.s.sol:DeployLiquidSwapGuardScript \
 *     --rpc-url $RPC_URL --broadcast
 */
library DeployLiquidSwapGuard {
    uint160 constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 constant REQUIRED_FLAGS = BEFORE_SWAP_FLAG | BEFORE_INITIALIZE_FLAG; // 0x2080
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
        return deploy(poolManager, owner, salt, CREATE2_DEPLOYER, false);
    }

    /// @notice Deploy for tests (mines valid address, skips constructor validation)
    /// @dev Uses CREATE2_DEPLOYER - same as production - so mined address is valid for PoolManager
    function deployForTest(
        IPoolManager poolManager,
        address owner,
        bytes32 salt
    ) internal returns (address guard) {
        return deploy(poolManager, owner, salt, CREATE2_DEPLOYER, true);
    }

    /// @notice Deploy with explicit CREATE2 factory address and skipValidation option.
    /// @dev In tests, use skipValidation=true to bypass hook address validation.
    ///      In production, use skipValidation=false and mine a salt with REQUIRED_FLAGS.
    function deploy(
        IPoolManager poolManager,
        address owner,
        bytes32 salt,
        address create2Factory,
        bool skipValidation
    ) internal returns (address guard) {
        bytes memory creationCode = abi.encodePacked(
            type(LiquidSwapGuard).creationCode,
            abi.encode(poolManager, owner, skipValidation)
        );
        bytes32 codeHash = keccak256(creationCode);

        // Always mine for valid address when salt not provided - PoolManager requires correct hook bits
        if (salt == bytes32(0)) {
            salt = _mineSalt(codeHash, create2Factory);
            if (!skipValidation) {
                console.log("  Mined salt:");
                console.logBytes32(salt);
            }
        }

        // Validate address has required hook bits (PoolManager will reject otherwise)
        address computed = _computeCreate2(salt, codeHash, create2Factory);
        uint160 lowBits = uint160(computed) & ALL_HOOK_MASK;
        require(
            lowBits == REQUIRED_FLAGS,
            "DeployLiquidSwapGuard: address must have BEFORE_SWAP_FLAG and BEFORE_INITIALIZE_FLAG in low 14 bits (0x2080)"
        );

        LiquidSwapGuard guardContract = new LiquidSwapGuard{salt: salt}(
            poolManager,
            owner,
            skipValidation
        );
        guard = address(guardContract);

        console.log("LiquidSwapGuard deployed at:");
        console.logAddress(guard);
        return guard;
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

        return deploy(poolManager, owner, salt, create2Factory, false);
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
            if (lowBits == REQUIRED_FLAGS) {
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
