// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {AnvilForkTestBase} from "liquid-editions-test/AnvilForkTestBase.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {FeeDistributor} from "liquid-editions/FeeDistributor.sol";
import {DeployLiquidGuard} from "script/deployers/DeployLiquidGuard.s.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Vm} from "forge-std/Test.sol";

contract LiquidGuardMainnetForkTest is AnvilForkTestBase {
    uint16 constant TEST_FEE_BPS = 400;
    bytes32 constant FEE_CONVERTED_TOPIC =
        keccak256("FeeConvertedAndDistributed(address,address,uint256,uint256,uint256,uint256)");
    bytes32 constant FEE_DISTRIBUTED_IN_RARE_TOPIC =
        keccak256("FeeDistributedInRare(address,address,uint256,uint256,uint256,bytes32)");
    bytes32 constant REASON_CONVERSION_OFF = bytes32("CONVERSION_OFF");
    bytes32 constant REASON_NO_KEY = bytes32("NO_KEY");
    bytes32 constant REASON_CONVERT_FAIL = bytes32("CONVERT_FAIL");

    LiquidGuard public guard;
    FeeDistributor public distributor;
    bool public rareEthPoolKeyConfigured;

    struct FeeBalanceSnapshot {
        uint256 protocolRare;
        uint256 beneficiaryRare;
        uint256 protocolEth;
        uint256 beneficiaryEth;
    }

    struct FeeEvents {
        bool sawConverted;
        bool sawRare;
        uint256 convertedRareIn;
        uint256 convertedEthOut;
        uint256 convertedEthBeneficiary;
        uint256 convertedEthProtocol;
        uint256 distributedRareTotal;
        uint256 distributedRareBeneficiary;
        uint256 distributedRareProtocol;
        bytes32 distributedRareReason;
    }

    function _configureFactory() internal override {
        super._configureFactory();

        if (protocolFeeRecipient != address(0)) {
            factory.setProtocolFeeRecipient(protocolFeeRecipient);
        }

        address guardAddr = DeployLiquidGuard.deployForTest(
            IPoolManager(config.uniswapV4PoolManager),
            admin,
            config.rareToken,
            bytes32(0)
        );
        guard = LiquidGuard(guardAddr);
        guard.setFactory(address(factory));
        factory.setPoolHooks(address(guard));
    }

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        distributor = new FeeDistributor(
            admin,
            config.uniswapV4PoolManager,
            config.rareToken,
            protocolFeeRecipient,
            5000,
            TEST_FEE_BPS
        );

        vm.startPrank(admin);
        distributor.setHookApproval(address(guard), true);
        distributor.setBeneficiaryRegistry(factory.liquidRegistry());

        guard.setFeeDistributor(address(distributor));
        rareEthPoolKeyConfigured = _trySetRareEthPoolKey();
        vm.stopPrank();
    }

    function test_Buy_FeeSkim_DistributesInRare_WhenConversionDisabled() public {
        vm.prank(admin);
        distributor.setConversionEnabled(false);

        address beneficiary = ILiquidRegistry(router.liquidRegistry()).beneficiaryOf(address(liquidToken));
        FeeBalanceSnapshot memory before = _snapshotFeeBalances(
            protocolFeeRecipient,
            beneficiary
        );

        vm.recordLogs();
        uint256 tokensReceived = _doBuy(buyer, address(liquidToken), buyer, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        FeeBalanceSnapshot memory afterSnapshot = _snapshotFeeBalances(
            protocolFeeRecipient,
            beneficiary
        );
        FeeEvents memory events = _findFeeEvents(
            logs,
            address(liquidToken),
            beneficiary
        );

        assertGt(tokensReceived, 0, "Buy should return tokens");
        assertTrue(events.sawRare, "Expected FeeDistributedInRare when conversion disabled");
        assertFalse(events.sawConverted, "Expected only legacy-rare distribution");
        assertEq(
            events.distributedRareReason,
            REASON_CONVERSION_OFF,
            "Expected conversion-off fallback reason"
        );

        FeeBalanceSnapshot memory delta = _feeDelta(before, afterSnapshot);
        assertEq(
            _sumEth(delta),
            0,
            "Fallback-to-RARE path should not move ETH"
        );
        assertGt(_sumRare(delta), 0, "Fee capture should move RARE on fallback path");
        assertGt(
            delta.protocolRare + delta.beneficiaryRare,
            0,
            "Protocol or beneficiary RARE balance should increase"
        );
        assertEq(events.distributedRareTotal, _sumRare(delta));
    }

    function test_BuyAndSell_FeeSkims_AppliesBeforeAndAfterSwapPathCoverage() public {
        vm.prank(admin);
        distributor.setConversionEnabled(false);

        address beneficiary = ILiquidRegistry(router.liquidRegistry()).beneficiaryOf(address(liquidToken));
        FeeBalanceSnapshot memory before = _snapshotFeeBalances(
            protocolFeeRecipient,
            beneficiary
        );

        vm.recordLogs();
        uint256 tokensBought = _doBuy(buyer, address(liquidToken), buyer, 2 ether);
        Vm.Log[] memory buyLogs = vm.getRecordedLogs();
        FeeEvents memory buyEvents = _findFeeEvents(
            buyLogs,
            address(liquidToken),
            beneficiary
        );

        require(tokensBought > 0, "No tokens bought");
        uint256 sellAmount = liquidToken.balanceOf(buyer) / 2;
        require(sellAmount > 0, "No tokens to sell");

        vm.recordLogs();
        uint256 ethReceived = _doSell(
            buyer,
            address(liquidToken),
            sellAmount,
            buyer
        );
        Vm.Log[] memory sellLogs = vm.getRecordedLogs();
        FeeEvents memory sellEvents = _findFeeEvents(
            sellLogs,
            address(liquidToken),
            beneficiary
        );

        FeeBalanceSnapshot memory afterSnapshot = _snapshotFeeBalances(
            protocolFeeRecipient,
            beneficiary
        );
        FeeBalanceSnapshot memory delta = _feeDelta(before, afterSnapshot);

        assertGt(ethReceived, 0, "Sell should return ETH");
        assertFalse(
            buyEvents.sawConverted,
            "Stale path is expected while capture is disabled at router level"
        );
        assertFalse(
            sellEvents.sawConverted,
            "Stale path is expected while capture is disabled at router level"
        );
        assertTrue(
            buyEvents.sawRare,
            "Buy path should emit fee accounting event"
        );
        assertTrue(
            sellEvents.sawRare,
            "Sell path should emit fee accounting event"
        );
        assertGt(
            _sumRare(delta),
            0,
            "Combined buy+sell should accrue protocol+beneficiary RARE"
        );
        assertEq(_sumEth(delta), 0, "Fallback path should keep ETH balances unchanged");
    }

    function test_FeeCapture_Skipped_WhenTotalFeeBpsZero() public {
        // Deploy new distributor with 0 fee and wire it up
        FeeDistributor zeroFeeDistributor = new FeeDistributor(
            admin,
            config.uniswapV4PoolManager,
            config.rareToken,
            protocolFeeRecipient,
            5000,
            0 // zero fee
        );
        vm.startPrank(admin);
        zeroFeeDistributor.setHookApproval(address(guard), true);
        zeroFeeDistributor.setBeneficiaryRegistry(factory.liquidRegistry());
        guard.setFeeDistributor(address(zeroFeeDistributor));
        vm.stopPrank();

        address beneficiary = ILiquidRegistry(router.liquidRegistry()).beneficiaryOf(address(liquidToken));
        FeeBalanceSnapshot memory before = _snapshotFeeBalances(
            protocolFeeRecipient,
            beneficiary
        );

        vm.recordLogs();
        uint256 tokensReceived = _doBuy(buyer, address(liquidToken), buyer, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        FeeEvents memory events = _findFeeEvents(
            logs,
            address(liquidToken),
            beneficiary
        );

        assertGt(tokensReceived, 0, "Buy should still execute");
        assertFalse(events.sawConverted, "No conversion should happen");
        assertFalse(events.sawRare, "No fee collection should happen");

        FeeBalanceSnapshot memory afterSnapshot = _snapshotFeeBalances(
            protocolFeeRecipient,
            beneficiary
        );
        FeeBalanceSnapshot memory delta = _feeDelta(before, afterSnapshot);
        assertEq(_sumRare(delta), 0, "Fee is disabled in guard, no RARE capture");
        assertEq(_sumEth(delta), 0, "Fee is disabled in guard, no ETH conversion");
    }

    /// @notice Fork test: attacker's direct pm.initialize() via unlock reverts (real PoolManager)
    /// @dev Verifies pool pre-initialization DoS protection: attacker cannot front-run token deployment
    function test_AttackerPreInitialize_RevertsViaRealPoolManager() public {
        address predictedToken = vm.computeCreateAddress(
            address(factory),
            vm.getNonce(address(factory))
        );

        (Currency currency0, Currency currency1) = config.rareToken < predictedToken
            ? (Currency.wrap(config.rareToken), Currency.wrap(predictedToken))
            : (Currency.wrap(predictedToken), Currency.wrap(config.rareToken));

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(guard))
        });

        uint160 hostilePrice = TickMath.getSqrtPriceAtTick(10000);

        AttackerInitializer attackerContract = new AttackerInitializer(
            IPoolManager(config.uniswapV4PoolManager)
        );

        vm.expectRevert();
        attackerContract.tryInitialize(poolKey, hostilePrice);
    }

    function test_ConversionPath_OrStaleFallback() public {
        if (!rareEthPoolKeyConfigured) {
            vm.skip(true);
            return;
        }

        address beneficiary = ILiquidRegistry(router.liquidRegistry()).beneficiaryOf(address(liquidToken));
        FeeBalanceSnapshot memory before = _snapshotFeeBalances(
            protocolFeeRecipient,
            beneficiary
        );

        vm.recordLogs();
        uint256 tokensReceived = _doBuy(buyer, address(liquidToken), buyer, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        FeeBalanceSnapshot memory afterSnapshot = _snapshotFeeBalances(
            protocolFeeRecipient,
            beneficiary
        );
        FeeEvents memory events = _findFeeEvents(
            logs,
            address(liquidToken),
            beneficiary
        );

        assertGt(tokensReceived, 0, "Buy should execute");

        FeeBalanceSnapshot memory delta = _feeDelta(before, afterSnapshot);
        uint256 rareDelta = _sumRare(delta);
        uint256 ethDelta = _sumEth(delta);

        if (events.sawConverted) {
            assertFalse(
                events.sawRare,
                "Converted and legacy path should be mutually exclusive"
            );
            assertGt(ethDelta, 0, "Conversion path should move ETH");
            assertEq(rareDelta, 0, "Conversion path should not move RARE");
            assertGt(
                events.convertedRareIn,
                0,
                "Expected a non-zero converted rare amount"
            );
        } else {
            assertTrue(
                events.sawRare,
                "Expected either conversion or stale fallback event"
            );
            assertEq(
                ethDelta,
                0,
                "Fallback should not move ETH"
            );
            assertGt(rareDelta, 0, "Fallback should move RARE");
            assertTrue(
                events.distributedRareReason == REASON_CONVERSION_OFF ||
                    events.distributedRareReason == REASON_CONVERT_FAIL ||
                    events.distributedRareReason == REASON_NO_KEY,
                "Fallback should use known reason code"
            );
            assertEq(events.distributedRareTotal, rareDelta);
        }
    }

    function _snapshotFeeBalances(
        address protocolRecipient,
        address beneficiary
    ) internal view returns (FeeBalanceSnapshot memory balances) {
        balances.protocolRare = IERC20(config.rareToken).balanceOf(
            protocolRecipient
        );
        balances.beneficiaryRare = IERC20(config.rareToken).balanceOf(
            beneficiary
        );
        balances.protocolEth = protocolRecipient.balance;
        balances.beneficiaryEth = beneficiary.balance;
    }

    function _feeDelta(
        FeeBalanceSnapshot memory before,
        FeeBalanceSnapshot memory afterSnapshot
    ) internal pure returns (FeeBalanceSnapshot memory delta) {
        delta.protocolRare = afterSnapshot.protocolRare - before.protocolRare;
        delta.beneficiaryRare = afterSnapshot.beneficiaryRare - before.beneficiaryRare;
        delta.protocolEth = afterSnapshot.protocolEth - before.protocolEth;
        delta.beneficiaryEth = afterSnapshot.beneficiaryEth - before.beneficiaryEth;
    }

    function _sumRare(
        FeeBalanceSnapshot memory balances
    ) internal pure returns (uint256 total) {
        return balances.protocolRare + balances.beneficiaryRare;
    }

    function _sumEth(
        FeeBalanceSnapshot memory balances
    ) internal pure returns (uint256 total) {
        return balances.protocolEth + balances.beneficiaryEth;
    }

    function _findFeeEvents(
        Vm.Log[] memory logs,
        address liquidTokenAddress,
        address beneficiary
    ) internal view returns (FeeEvents memory events) {
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(distributor)) {
                continue;
            }
            if (log.topics.length < 3) {
                continue;
            }

            address eventToken = address(uint160(uint256(log.topics[1])));
            address eventBeneficiary = address(uint160(uint256(log.topics[2])));
            if (
                eventToken != liquidTokenAddress ||
                eventBeneficiary != beneficiary
            ) {
                continue;
            }

            if (log.topics[0] == FEE_CONVERTED_TOPIC) {
                if (
                    log.data.length ==
                    128 &&
                    events.convertedRareIn == 0 &&
                    events.convertedEthOut == 0
                ) {
                    (
                        events.convertedRareIn,
                        events.convertedEthOut,
                        events.convertedEthBeneficiary,
                        events.convertedEthProtocol
                    ) = abi.decode(
                        log.data,
                        (uint256, uint256, uint256, uint256)
                    );
                }
                events.sawConverted = true;
            } else if (log.topics[0] == FEE_DISTRIBUTED_IN_RARE_TOPIC) {
                if (
                    log.data.length ==
                    128 &&
                    events.distributedRareTotal == 0 &&
                    events.distributedRareBeneficiary == 0
                ) {
                    (
                        events.distributedRareTotal,
                        events.distributedRareBeneficiary,
                        events.distributedRareProtocol,
                        events.distributedRareReason
                    ) = abi.decode(
                        log.data,
                        (uint256, uint256, uint256, bytes32)
                    );
                }
                events.sawRare = true;
            }
        }
    }

    function _trySetRareEthPoolKey() internal returns (bool) {
        if (
            config.rareEthPoolId == bytes32(0) ||
            config.uniswapV4PositionManager == address(0)
        ) {
            return false;
        }

        bytes25 poolId = bytes25(config.rareEthPoolId);
        (bool ok, bytes memory data) = config.uniswapV4PositionManager.staticcall(
            abi.encodeWithSignature("poolKeys(bytes25)", poolId)
        );
        if (!ok || data.length < 160) {
            return false;
        }

        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = abi
            .decode(data, (Currency, Currency, uint24, int24, IHooks));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });

        distributor.setRareEthPoolKey(key);
        return true;
    }
}

/// @notice Attacker contract: calls pm.initialize() from unlock callback (simulates front-run)
contract AttackerInitializer is IUnlockCallback {
    IPoolManager public immutable POOL_MANAGER;

    constructor(IPoolManager _poolManager) {
        POOL_MANAGER = _poolManager;
    }

    function tryInitialize(
        PoolKey memory poolKey,
        uint160 sqrtPriceX96
    ) external {
        POOL_MANAGER.unlock(abi.encode(poolKey, sqrtPriceX96));
    }

    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "only pool manager");
        (PoolKey memory poolKey, uint160 sqrtPriceX96) = abi.decode(
            data,
            (PoolKey, uint160)
        );
        POOL_MANAGER.initialize(poolKey, sqrtPriceX96);
        return "";
    }
}
