// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {AnvilForkTestBase, IStrategyFactory} from "liquid-editions-test/AnvilForkTestBase.sol";
import {LiquidGraduated} from "liquid-editions/LiquidGraduated.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AuctionParameters, IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {Bid} from "continuous-clearing-auction/libraries/BidLib.sol";
import {MigratorParameters} from "liquid-editions/types/MigratorParameters.sol";

/**
 * @title AnvilForkAuctionBase
 * @notice Abstract base for auction fork tests. Adds _createAuctionForTest and route encoders.
 *
 * ## How to run auction tests
 *   forge test --match-contract AnvilForkAuction --fork-url $MAINNET_RPC_URL --ffi
 *
 * ## Dependencies
 *   - --ffi: Required to mine a valid V4 hook salt when none is cached
 *   - scripts: Run `cd scripts && npm install` before first run
 *
 * ## Salt resolution (in order)
 *   1. AUCTION_HOOK_SALT in .env (must match REQUIRED_FLAGS for fork block 24_444_760)
 *   2. deployments/auction-hook-salt.hex (written by a previous successful run)
 *   3. FFI: scripts/mine-hook-salt.ts (run when 1–2 fail; requires --ffi)
 */
abstract contract AnvilForkAuctionBase is AnvilForkTestBase {
    uint256 constant AUCTION_TEST_FORK_BLOCK = 24_444_760;

    struct AuctionTestState {
        address graduatedToken;
        LiquidGraduated graduated;
        address auctionAddr;
        address strategyAddr;
        uint64 auctionStartBlock;
        uint64 auctionEndBlock;
        bytes32 validSalt;
    }

    function _getForkBlock() internal pure override returns (uint256) {
        return AUCTION_TEST_FORK_BLOCK;
    }

    function _encodeEthToRareRoute(
        uint256 ethAmount
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        address currencyIn = address(0);
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: config.rareToken,
            fee: ETH_RARE_POOL_FEE,
            tickSpacing: ETH_RARE_POOL_TICK_SPACING,
            hooks: address(0),
            hookData: bytes("")
        });
        bytes memory actions = abi.encodePacked(
            uint8(SWAP_EXACT_IN),
            uint8(SETTLE_ALL),
            uint8(TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        uint256 ethForSwap = (ethAmount * (10000 - 400)) / 10000;
        params[0] = abi.encode(
            currencyIn,
            path,
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: ethForSwap from calc fits uint128
            uint128(ethForSwap),
            uint128(1)
        );
        params[1] = abi.encode(currencyIn, type(uint128).max);
        params[2] = abi.encode(config.rareToken, uint128(1));
        bytes memory v4SwapInput = abi.encode(actions, params);
        commands = abi.encodePacked(V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = v4SwapInput;
    }

    function _encodeRareToEthRoute(
        uint256 rareAmount
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        address currencyIn = config.rareToken;
        address outputCurrency = address(0);
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: outputCurrency,
            fee: ETH_RARE_POOL_FEE,
            tickSpacing: ETH_RARE_POOL_TICK_SPACING,
            hooks: address(0),
            hookData: bytes("")
        });
        bytes memory actions = abi.encodePacked(
            uint8(SWAP_EXACT_IN),
            uint8(SETTLE_ALL),
            uint8(TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            currencyIn,
            path,
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: rareAmount from swap fits uint128
            uint128(rareAmount),
            uint128(1)
        );
        params[1] = abi.encode(currencyIn, type(uint128).max);
        params[2] = abi.encode(outputCurrency, uint128(1));
        bytes memory v4SwapInput = abi.encode(actions, params);
        commands = abi.encodePacked(V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = v4SwapInput;
    }

    // Helper struct to reduce stack depth in _createAuctionForTest
    struct AuctionSetupParams {
        uint256 auctionSupply;
        uint64 auctionStartBlock;
        uint64 auctionEndBlock;
        uint160 allHookMask;
        uint160 requiredFlags;
        address deployer;
        bytes configData;
        AuctionParameters auctionParams;
    }

    function _buildAuctionParams() internal view returns (AuctionSetupParams memory params) {
        params.auctionSupply = 900_000e18;
        params.auctionStartBlock = uint64(block.number);
        params.auctionEndBlock = uint64(block.number + 100);
        params.allHookMask = uint160((1 << 14) - 1);
        params.requiredFlags = uint160(1) << 13;
        params.deployer = tokenCreator;

        uint40 auctionDuration = 100;
        params.auctionParams = AuctionParameters({
            currency: config.rareToken,
            tokensRecipient: address(0),
            fundsRecipient: address(0),
            startBlock: params.auctionStartBlock,
            endBlock: params.auctionEndBlock,
            claimBlock: uint64(params.auctionEndBlock + 1),
            tickSpacing: 1e18,
            validationHook: address(0),
            floorPrice: 1e18,
            requiredCurrencyRaised: 0,
            auctionStepsData: abi.encodePacked(
                uint24(1e7 / auctionDuration),
                auctionDuration
            )
        });

        // Build config data
        AuctionParameters memory modifiedParams = params.auctionParams;
        modifiedParams.fundsRecipient = address(1);
        modifiedParams.tokensRecipient = config.protocolFeeRecipient;
        bytes memory auctionConfigData = abi.encode(modifiedParams);

        MigratorParameters memory migratorParams = MigratorParameters({
            migrationBlock: params.auctionParams.endBlock + 1,
            currency: config.rareToken,
            poolLPFee: 0,
            poolTickSpacing: factory.poolTickSpacing(),
            tokenSplit: 5e6,
            initializerFactory: config.ccaFactory,
            positionRecipient: config.protocolFeeRecipient,
            sweepBlock: params.auctionParams.endBlock + 1000,
            operator: config.protocolFeeRecipient,
            maxCurrencyAmountForLP: type(uint128).max
        });
        params.configData = abi.encode(migratorParams, auctionConfigData);
    }

    function _tryFindSaltFromEnv(
        AuctionSetupParams memory params
    ) internal view returns (bytes32 validSalt, bool found) {
        IStrategyFactory strategyFactory = IStrategyFactory(config.lbpStrategyFactory);
        string memory envSaltStr = vm.envOr("AUCTION_HOOK_SALT", string(""));
        if (bytes(envSaltStr).length == 0) return (bytes32(0), false);

        bytes32 envSalt = vm.parseBytes32(envSaltStr);
        address predictedToken = factory.predictGraduatedTokenAddress(envSalt, params.deployer);
        bytes32 effectiveSalt = keccak256(abi.encode(params.deployer, envSalt));
        address predictedHook = strategyFactory.getAddress(
            predictedToken,
            params.auctionSupply,
            params.configData,
            effectiveSalt,
            address(factory)
        );
        if ((uint160(predictedHook) & params.allHookMask) == params.requiredFlags) {
            return (envSalt, true);
        }
        return (bytes32(0), false);
    }

    function _tryFindSaltFromFile(
        AuctionSetupParams memory params
    ) internal view returns (bytes32 validSalt, bool found) {
        IStrategyFactory strategyFactory = IStrategyFactory(config.lbpStrategyFactory);
        // forge-lint: disable-next-line(unsafe-cheatcode) -- needed: read cached salt for fork tests
        try vm.readFile("deployments/auction-hook-salt.hex") returns (string memory savedSaltStr) {
            bytes memory input = bytes(savedSaltStr);
            if (input.length < 66) return (bytes32(0), false);

            bytes memory first66 = new bytes(66);
            for (uint256 i = 0; i < 66; i++) first66[i] = input[i];
            bytes32 fileSalt = vm.parseBytes32(string(first66));
            address predictedToken = factory.predictGraduatedTokenAddress(fileSalt, params.deployer);
            bytes32 fileEffectiveSalt = keccak256(abi.encode(params.deployer, fileSalt));
            address predictedHook = strategyFactory.getAddress(
                predictedToken,
                params.auctionSupply,
                params.configData,
                fileEffectiveSalt,
                address(factory)
            );
            if ((uint160(predictedHook) & params.allHookMask) == params.requiredFlags) {
                return (fileSalt, true);
            }
        } catch {}
        return (bytes32(0), false);
    }

    function _tryMineSaltViaFFI(
        AuctionSetupParams memory params
    ) internal returns (bytes32 validSalt, bool found) {
        IStrategyFactory strategyFactory = IStrategyFactory(config.lbpStrategyFactory);
        // forge-lint: disable-next-line(unsafe-cheatcode) -- needed: write config for FFI salt mining
        vm.writeFile("deployments/tmp-auction-config.hex", vm.toString(params.configData));
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/tmp-auction-config.hex");

        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = string.concat(
            "cd ", vm.projectRoot(),
            '/scripts && FORK_URL="', forkUrlForFFI,
            '" npx ts-node mine-hook-salt.ts --ffi ',
            vm.toString(config.lbpStrategyFactory), " ",
            vm.toString(address(factory)), " ",
            vm.toString(factory.liquidGraduatedImplementation()), " ",
            vm.toString(params.auctionSupply), " ",
            "--config-file ", configPath,
            " --deployer ", vm.toString(params.deployer)
        );

        // forge-lint: disable-next-line(unsafe-cheatcode) -- needed: FFI to mine hook salt for fork tests
        try vm.ffi(inputs) returns (bytes memory result) {
            if (result.length == 32) {
                assembly { validSalt := mload(add(result, 32)) }
            } else if (result.length >= 66) {
                bytes memory saltBytes = new bytes(66);
                for (uint i = 0; i < 66; i++) saltBytes[i] = result[i];
                validSalt = vm.parseBytes32(string(saltBytes));
            } else {
                return (bytes32(0), false);
            }

            address predictedToken = factory.predictGraduatedTokenAddress(validSalt, params.deployer);
            bytes32 ffiEffectiveSalt = keccak256(abi.encode(params.deployer, validSalt));
            address predictedHook = strategyFactory.getAddress(
                predictedToken,
                params.auctionSupply,
                params.configData,
                ffiEffectiveSalt,
                address(factory)
            );
            if ((uint160(predictedHook) & params.allHookMask) == params.requiredFlags) {
                // forge-lint: disable-next-line(unsafe-cheatcode) -- needed: cache salt for future runs
                vm.writeFile("deployments/auction-hook-salt.hex", vm.toString(validSalt));
                return (validSalt, true);
            }
        } catch {}
        return (bytes32(0), false);
    }

    function _createAuctionForTest()
        internal
        returns (AuctionTestState memory state, bool success)
    {
        if (block.chainid != 1 || address(auctioneer) == address(0)) {
            return (state, false);
        }

        AuctionSetupParams memory params = _buildAuctionParams();
        bytes32 validSalt;
        bool found;

        // Try finding salt from env, file, or FFI
        (validSalt, found) = _tryFindSaltFromEnv(params);
        if (!found) (validSalt, found) = _tryFindSaltFromFile(params);
        if (!found) (validSalt, found) = _tryMineSaltViaFFI(params);
        if (!found) return (state, false);

        // Create the auction
        vm.startPrank(tokenCreator);
        IERC20(config.rareToken).approve(address(factory), 1000 ether);
        (address graduatedToken, address auctionAddr) = factory.createLiquidTokenWithAuction(
            tokenCreator,
            "ipfs://test-graduated",
            "Test Graduated Token",
            "TGT",
            address(auctioneer),
            params.auctionSupply,
            abi.encode(params.auctionParams),
            validSalt
        );
        vm.stopPrank();

        vm.prank(admin);
        auctioneer.setBeneficiary(graduatedToken, tokenCreator);

        state = AuctionTestState({
            graduatedToken: graduatedToken,
            graduated: LiquidGraduated(payable(graduatedToken)),
            auctionAddr: auctionAddr,
            strategyAddr: LiquidGraduated(payable(graduatedToken)).strategy(),
            auctionStartBlock: params.auctionStartBlock,
            auctionEndBlock: params.auctionEndBlock,
            validSalt: validSalt
        });
        return (state, true);
    }

    /// @notice Place multiple bids; returns bid IDs. Reduces stack depth in MultiBid test.
    function _placeMultiBids(
        address graduatedToken,
        address auctionAddr,
        uint64 auctionStartBlock,
        uint64 auctionEndBlock,
        uint64[] memory blockOffsets,
        uint256[] memory ethAmounts,
        address[] memory bidders,
        uint256[] memory maxPrices
    ) internal returns (uint256[] memory bidIds) {
        IContinuousClearingAuction cca = IContinuousClearingAuction(
            auctionAddr
        );
        uint256 floorPrice = cca.floorPrice();
        bidIds = new uint256[](10);
        uint256 lastBlockRolled = type(uint64).max;
        for (uint256 i = 0; i < 10; i++) {
            uint64 targetBlock = auctionStartBlock + blockOffsets[i];
            if (targetBlock != lastBlockRolled) {
                vm.roll(targetBlock);
                lastBlockRolled = targetBlock;
            }
            uint256 prevTick = maxPrices[i] > 0 ? floorPrice : 0;
            vm.prank(bidders[i]);
            bidIds[i] = auctioneer.bid{value: ethAmounts[i]}(
                address(0),
                0,
                graduatedToken,
                maxPrices[i],
                bidders[i],
                address(0),
                prevTick,
                1,
                block.timestamp + 1 hours
            );
        }
        vm.roll(auctionEndBlock + 1);
    }

    /// @notice Exit and claim all bids; returns (total, perBid). Reduces stack depth.
    function _exitAndClaimMultiBids(
        address graduatedToken,
        address auctionAddr,
        uint256[] memory bidIds,
        address[] memory bidders,
        uint256 clearingPrice
    ) internal returns (uint256 total, uint256[] memory perBid) {
        IContinuousClearingAuction cca = IContinuousClearingAuction(
            auctionAddr
        );
        perBid = new uint256[](10);
        total = 0;
        for (uint256 i = 0; i < 10; i++) {
            address bidder = bidders[i];
            uint256 bidId = bidIds[i];
            vm.prank(bidder);
            IERC20(config.rareToken).approve(address(auctioneer), 50e21);
            (bytes memory exitCommands, bytes[] memory exitInputs) = _encodeRareToEthRoute(
                50e21
            );
            Bid memory bid = cca.bids(bidId);
            if (bid.maxPrice < clearingPrice) {
                vm.prank(bidder);
                auctioneer.exitPartialBidToETH(
                    graduatedToken,
                    bidId,
                    bid.startBlock,
                    0,
                    bidder,
                    0, // minEthOut: accept any amount in tests
                    exitCommands,
                    exitInputs,
                    block.timestamp + 1 hours
                );
            } else {
                vm.prank(bidder);
                auctioneer.exitBidToETH(
                    graduatedToken,
                    bidId,
                    bidder,
                    0, // minEthOut: accept any amount in tests
                    exitCommands,
                    exitInputs,
                    block.timestamp + 1 hours
                );
            }
            uint256 tokensBefore = IERC20(graduatedToken).balanceOf(bidder);
            vm.prank(bidder);
            auctioneer.claimAuctionTokens(graduatedToken, bidId);
            uint256 tokensAfter = IERC20(graduatedToken).balanceOf(bidder);
            perBid[i] = tokensAfter - tokensBefore;
            total += perBid[i];
        }
    }

    /// @notice Post-migration: register token, buy, sell. Reduces stack depth.
    function _postMigrationRouterTrading(
        address graduatedToken,
        address tokenCreator
    ) internal {
        vm.prank(admin);
        router.registerToken(graduatedToken, tokenCreator);
        address trader = makeAddr("postAuctionTrader");
        vm.deal(trader, 0.5 ether);
        LiquidGraduated graduated = LiquidGraduated(payable(graduatedToken));
        address poolHooks = graduated.snapshotPoolHooks();
        uint256 buyEthAmount = 0.02 ether;
        uint256 ethForSwap = _ethForSwap(buyEthAmount);
        (bytes memory buyCommands, bytes[] memory buyInputs) = _encodeBuyRouteWithHooks(
            graduatedToken,
            poolHooks,
            ethForSwap,
            1
        );
        vm.prank(trader);
        uint256 tokensBought = router.buy{value: buyEthAmount}(
            graduatedToken,
            trader,
            address(0),
            1,
            buyCommands,
            buyInputs,
            block.timestamp + 1 hours
        );
        assertGt(tokensBought, 0, "Trader should receive tokens");
        uint256 tokensToSell = IERC20(graduatedToken).balanceOf(trader) / 2;
        if (tokensToSell > 0) {
            vm.prank(trader);
            IERC20(graduatedToken).approve(address(router), tokensToSell);
            (bytes memory sellCommands, bytes[] memory sellInputs) = _encodeSellRouteWithHooks(
                graduatedToken,
                poolHooks,
                tokensToSell,
                1
            );
            uint256 ethBefore = trader.balance;
            vm.prank(trader);
            uint256 ethReceived = router.sell(
                graduatedToken,
                tokensToSell,
                trader,
                address(0),
                1,
                sellCommands,
                sellInputs,
                block.timestamp + 1 hours
            );
            assertGt(ethReceived, 0, "Trader should receive ETH");
            assertGt(trader.balance, ethBefore, "Trader ETH should increase");
        }
    }
}
