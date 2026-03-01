// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {NetworkConfig} from "./config/NetworkConfig.sol";
import {MigratorParameters} from "liquid-editions/types/MigratorParameters.sol";
import {ILiquidGraduated} from "liquid-editions/interfaces/ILiquidGraduated.sol";

/// @notice Interface for factory with CCA auction support (createLiquidTokenWithAuction)
/// @dev Use this so the script compiles even when LiquidFactory only has createLiquidTokenMultiCurve.
///      Runtime: reverts if the deployed factory does not implement this function.
interface IFactoryWithAuction {
    function createLiquidTokenWithAuction(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        address _migrator,
        uint256 _auctionSupply,
        bytes calldata _auctionConfigData,
        bytes32 _salt
    ) external returns (address token, address auction);

    function predictGraduatedTokenAddress(bytes32 salt, address deployer) external view returns (address);
    function poolTickSpacing() external view returns (int24);
    function ccaFactory() external view returns (address);
    function protocolFeeRecipient() external view returns (address);
    function lbpStrategyFactory() external view returns (address);
    function liquidGraduatedImplementation() external view returns (address);
}

/// @notice Interface for FullRangeLBPStrategyFactory (salt mining validation)
interface IStrategyFactory {
    function getAddress(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt,
        address sender
    ) external view returns (address);
}

// CCA auction parameters struct (must match IContinuousClearingAuction.AuctionParameters)
struct AuctionParameters {
    address currency;
    address tokensRecipient;
    address fundsRecipient;
    uint64 startBlock;
    uint64 endBlock;
    uint64 claimBlock;
    uint256 tickSpacing;
    address validationHook;
    uint256 floorPrice;
    uint128 requiredCurrencyRaised;
    bytes auctionStepsData;
}

/**
 * @title CreateTokenWithAuction
 * @notice Creates a LiquidGraduated token (CCA auction launch) via the factory
 *
 * Prerequisites:
 * - LiquidFactory deployed with liquidGraduatedImplementation, ccaFactory, lbpStrategyFactory,
 *   and protocolFeeRecipient set (see DEPLOYMENT_GUIDE.md CCA section)
 * - Target chain has ccaFactory in NetworkConfig (e.g. mainnet)
 *
 * Environment Variables Required:
 * - DEPLOYER_PRIVATE_KEY: Private key for the transaction sender
 * - TOKEN_CREATOR: Address to receive creator launch reward
 * - TOKEN_URI: Metadata URI for the token
 * - TOKEN_NAME: Token name
 * - TOKEN_SYMBOL: Token symbol
 * - AUCTION_SUPPLY: Token amount sent to the auction (max 900e24 = 900K*1e18). Remainder (900K - AUCTION_SUPPLY) becomes LP at graduation.
 *
 * CCA recipients (set by factory):
 * - fundsRecipient: Set to MSG_SENDER (strategy address) - strategy receives raised currency for LP
 * - tokensRecipient: Set to protocolFeeRecipient - receives unsold auction tokens
 * - After auction ends, anyone calls strategy.migrate() which creates the pool at clearing price
 *
 * requiredCurrencyRaised: If set > 0 and not met by endBlock, the CCA does not "graduate". sweepCurrency() reverts
 * (raised currency stays in the auction for bidder refunds); bidders can exit to get their currency back.
 *
 * Environment Variables Optional:
 * - MIGRATOR_ADDRESS: Unused (kept for API compatibility). Migration via strategy.migrate().
 * - FACTORY_ADDRESS: Override factory (default: NetworkConfig.liquidFactory)
 * - CHAIN_ID: Chain ID (default: block.chainid)
 * - AUCTION_START_BLOCK: CCA start block (default: current block)
 * - AUCTION_DURATION_BLOCKS: Blocks until auction end (default: 10000)
 * - AUCTION_SALT: bytes32 salt for deterministic auction address. If not set, a valid salt is mined via FFI
 *                  (requires --ffi). The factory binds the salt to msg.sender (effectiveSalt = keccak256(msg.sender, salt)).
 * - RPC_URL: Override RPC for salt miner (e.g. RPC_URL=$ETH_SEPOLIA). Must match --rpc-url when mining.
 *
 * Usage (single command - mines salt then deploys):
 *   RPC_URL=$ETH_SEPOLIA forge script script/CreateTokenWithAuction.s.sol:CreateTokenWithAuction \
 *     --rpc-url $ETH_SEPOLIA --broadcast --ffi -vvv
 *
 * Usage (with pre-mined salt):
 *   AUCTION_SALT=0x... forge script script/CreateTokenWithAuction.s.sol:CreateTokenWithAuction \
 *     --rpc-url $ETH_SEPOLIA --broadcast -vvv
 *
 * Note: --ffi is required when AUCTION_SALT is not set (enables salt mining via scripts/mine-hook-salt.ts).
 *       Ensure FORK_URL, ETH_SEPOLIA, or ETH_MAINNET is set in .env for the miner's RPC.
 */
contract CreateTokenWithAuction is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenCreator = vm.envAddress("TOKEN_CREATOR");
        string memory tokenURI = vm.envString("TOKEN_URI");
        string memory tokenName = vm.envString("TOKEN_NAME");
        string memory tokenSymbol = vm.envString("TOKEN_SYMBOL");
        uint256 auctionSupply = vm.envUint("AUCTION_SUPPLY");

        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _chainId) {
            chainId = _chainId;
        } catch {
            chainId = block.chainid;
        }
        NetworkConfig.Config memory config = NetworkConfig.getConfig(chainId);

        address migrator;
        try vm.envAddress("MIGRATOR_ADDRESS") returns (address _m) {
            migrator = _m;
        } catch {
            migrator = config.liquid.auctioneer;
        }
        require(
            migrator != address(0),
            "MIGRATOR_ADDRESS or NetworkConfig.liquidAuctioneer required"
        );
        address factoryAddress;
        try vm.envAddress("FACTORY_ADDRESS") returns (address _f) {
            factoryAddress = _f;
        } catch {
            factoryAddress = config.liquid.factory;
        }
        require(
            factoryAddress != address(0),
            "FACTORY_ADDRESS or NetworkConfig.liquidFactory required"
        );
        require(
            config.ccaFactory != address(0),
            "Chain has no ccaFactory in NetworkConfig"
        );
        require(
            config.rareToken != address(0),
            "Chain has no rareToken in NetworkConfig (auction currency)"
        );

        uint64 startBlock = uint64(block.number);
        try vm.envUint("AUCTION_START_BLOCK") returns (uint256 b) {
            require(b <= type(uint64).max, "AUCTION_START_BLOCK too large");
            // forge-lint: disable-next-line(unsafe-typecast) -- b validated <= uint64.max above
            startBlock = uint64(b);
        } catch {}
        uint256 durationBlocks = vm.envOr(
            "AUCTION_DURATION_BLOCKS",
            uint256(10000)
        );
        // forge-lint: disable-next-line(unsafe-typecast) -- startBlock + durationBlocks fits uint64
        uint64 endBlock = uint64(startBlock + durationBlocks);
        uint64 claimBlock = endBlock + 1;

        bytes32 salt;
        bool saltProvided;
        try vm.envBytes32("AUCTION_SALT") returns (bytes32 s) {
            salt = s;
            saltProvided = true;
        } catch {
            saltProvided = false;
        }

        // CCA StepStorage requires non-empty auctionStepsData where sum(mps*blockDelta)==1e7 and sum(blockDelta)==duration
        uint256 mpsConstant = 1e7; // ConstantsLib.MPS
        // forge-lint: disable-next-line(unsafe-typecast) -- mpsConstant / durationBlocks fits uint24
        uint24 stepMps = uint24(mpsConstant / durationBlocks);
        // forge-lint: disable-next-line(unsafe-typecast) -- durationBlocks fits uint40
        uint40 stepBlockDelta = uint40(durationBlocks);
        bytes memory auctionStepsData = abi.encodePacked(
            stepMps,
            stepBlockDelta
        );

        // CCA TickStorage: floorPrice must be != 0 and >= type(uint32).max + 1; and at a tick boundary (multiple of tickSpacing)
        uint256 tickSpacing = 1e18;
        uint256 floorPrice = tickSpacing; // 1e18 >= MIN_FLOOR_PRICE and divisible by tickSpacing

        AuctionParameters memory params = AuctionParameters({
            currency: config.rareToken,
            tokensRecipient: tokenCreator,
            fundsRecipient: migrator,
            startBlock: startBlock,
            endBlock: endBlock,
            claimBlock: claimBlock,
            tickSpacing: tickSpacing,
            validationHook: address(0),
            floorPrice: floorPrice,
            requiredCurrencyRaised: 0,
            auctionStepsData: auctionStepsData
        });
        bytes memory auctionConfigData = abi.encode(params);

        // Mine salt via FFI when not provided (requires --ffi)
        if (!saltProvided) {
            address deployer = vm.addr(deployerPrivateKey);
            salt = _mineSalt(
                factoryAddress,
                deployer,
                auctionSupply,
                params,
                config,
                chainId
            );
            console.log("Mined salt:", vm.toString(salt));
        }

        console.log("Creating LiquidGraduated (CCA) token...");
        console.log("Factory:", factoryAddress);
        console.log("Creator:", tokenCreator);
        console.log("Migrator:", migrator);
        console.log("Auction supply:", auctionSupply);
        console.log("Start block:", startBlock);
        console.log("End block:", endBlock);

        vm.startBroadcast(deployerPrivateKey);
        (address token, address auction) = IFactoryWithAuction(factoryAddress)
            .createLiquidTokenWithAuction(
                tokenCreator,
                tokenURI,
                tokenName,
                tokenSymbol,
                migrator,
                auctionSupply,
                auctionConfigData,
                salt
            );
        vm.stopBroadcast();

        console.log("LiquidGraduated token:", token);
        console.log("LBP strategy:", ILiquidGraduated(token).strategy());
        console.log("CCA auction:", auction);
    }

    /// @notice Mines a valid V4 hook salt via FFI (scripts/mine-hook-salt.ts)
    /// @dev Requires --ffi. Builds configData to match factory's createLiquidTokenWithAuction.
    function _mineSalt(
        address factoryAddress,
        address deployer,
        uint256 auctionSupply,
        AuctionParameters memory params,
        NetworkConfig.Config memory config,
        uint256 chainId
    ) internal returns (bytes32 validSalt) {
        IFactoryWithAuction factory = IFactoryWithAuction(factoryAddress);

        require(
            factory.lbpStrategyFactory() != address(0),
            "Factory not configured for Graduated tokens. Run setLbpStrategyFactory, setCcaFactory, setProtocolFeeRecipient on the factory first."
        );
        require(
            factory.ccaFactory() != address(0),
            "Factory not configured for Graduated tokens. Run setCcaFactory on the factory first."
        );
        require(
            factory.protocolFeeRecipient() != address(0),
            "Factory not configured for Graduated tokens. Run setProtocolFeeRecipient on the factory first."
        );

        // Apply factory overrides (must match LiquidFactory.createLiquidTokenWithAuction)
        params.fundsRecipient = address(1);
        if (params.tokensRecipient == address(0)) {
            params.tokensRecipient = factory.protocolFeeRecipient();
        }
        bytes memory auctionParamsEncoded = abi.encode(params);

        MigratorParameters memory migratorParams = MigratorParameters({
            migrationBlock: params.endBlock + 1,
            currency: config.rareToken,
            poolLPFee: 0,
            poolTickSpacing: factory.poolTickSpacing(),
            tokenSplit: 5e6,
            initializerFactory: factory.ccaFactory(),
            positionRecipient: factory.protocolFeeRecipient(),
            sweepBlock: params.endBlock + 1000,
            operator: factory.protocolFeeRecipient(),
            maxCurrencyAmountForLP: type(uint128).max
        });
        bytes memory configData = abi.encode(migratorParams, auctionParamsEncoded);

        // Resolve RPC URL for miner (must match deployment chain)
        string memory rpcUrl = _getRpcUrlForMiner(chainId);

        // Write config to temp file for FFI
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/tmp-auction-config.hex");
        // forge-lint: disable-next-line(unsafe-cheatcode) -- needed: write config for FFI salt mining
        vm.writeFile("deployments/tmp-auction-config.hex", vm.toString(configData));

        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = string.concat(
            "cd ",
            vm.projectRoot(),
            '/scripts && FORK_URL="',
            rpcUrl,
            '" npx ts-node mine-hook-salt.ts --ffi ',
            vm.toString(factory.lbpStrategyFactory()),
            " ",
            vm.toString(factoryAddress),
            " ",
            vm.toString(factory.liquidGraduatedImplementation()),
            " ",
            vm.toString(auctionSupply),
            " --config-file ",
            configPath,
            " --deployer ",
            vm.toString(deployer)
        );

        // forge-lint: disable-next-line(unsafe-cheatcode) -- needed: FFI to mine hook salt
        bytes memory result = vm.ffi(inputs);

        if (result.length >= 32) {
            if (result.length == 32) {
                assembly {
                    validSalt := mload(add(result, 32))
                }
            } else if (result.length >= 66) {
                bytes memory saltBytes = new bytes(66);
                for (uint256 i = 0; i < 66; i++) {
                    saltBytes[i] = result[i];
                }
                validSalt = vm.parseBytes32(string(saltBytes));
            }
        }
        require(uint256(validSalt) != 0, "Salt mining failed or returned zero");

        // Verify mined salt produces valid hook
        address predictedToken = factory.predictGraduatedTokenAddress(validSalt, deployer);
        bytes32 effectiveSalt = keccak256(abi.encode(deployer, validSalt));
        address predictedHook = IStrategyFactory(factory.lbpStrategyFactory()).getAddress(
            predictedToken,
            auctionSupply,
            configData,
            effectiveSalt,
            factoryAddress
        );
        uint160 requiredFlags = uint160(1 << 13);
        require(
            (uint160(predictedHook) & ((1 << 14) - 1)) == requiredFlags,
            "Mined salt did not produce valid hook address"
        );

        return validSalt;
    }

    /// @notice Resolve RPC URL for miner. RPC_URL (when set) overrides chain-specific defaults.
    function _getRpcUrlForMiner(uint256 chainId) internal view returns (string memory) {
        // Explicit pass-through from call: RPC_URL=$ETH_SEPOLIA forge script ...
        try vm.envString("RPC_URL") returns (string memory url) {
            if (bytes(url).length > 0) return url;
        } catch {}
        if (chainId == 11155111) {
            try vm.envString("ETH_SEPOLIA") returns (string memory url) {
                if (bytes(url).length > 0) return url;
            } catch {}
        } else if (chainId == 1) {
            try vm.envString("FORK_URL") returns (string memory url) {
                if (bytes(url).length > 0) return url;
            } catch {}
            try vm.envString("ETH_MAINNET") returns (string memory url) {
                if (bytes(url).length > 0) return url;
            } catch {}
            try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
                if (bytes(url).length > 0) return url;
            } catch {}
        }
        revert(
            string.concat(
                "Set RPC_URL or chain-specific RPC in .env for salt mining. Example: RPC_URL=$ETH_SEPOLIA forge script ... ChainId: ",
                vm.toString(chainId)
            )
        );
    }
}
