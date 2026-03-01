// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidFactory Unit Tests
 * @notice No fork; admin, setImplementation, setBaseToken, revert cases
 * @dev Uses MockV4PoolManager for unit testing without fork
 */

import "forge-std/Test.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {ILiquidSwapGuard} from "liquid-editions/interfaces/ILiquidSwapGuard.sol";
import {MockV4PoolManager} from "liquid-editions-test/helpers/MockV4PoolManager.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {LiquidSwapGuard} from "liquid-editions/LiquidSwapGuard.sol";
import {LiquidInitGuard} from "liquid-editions/LiquidInitGuard.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";

contract LiquidFactoryUnitTest is Test {
    address public admin = makeAddr("admin");
    address public user1 = makeAddr("user1");

    MockV4PoolManager public poolManager;
    MockERC20 public baseToken;

    LiquidFactory public factory;
    LiquidMultiCurve public liquidImplementation;

    function _defaultSingleCurve() internal view returns (Curve[] memory) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({
            tickLower: factory.lpTickLower(),
            tickUpper: factory.lpTickUpper(),
            numPositions: 1,
            shares: 1e18
        });
        return curves;
    }

    function setUp() public {
        poolManager = new MockV4PoolManager();
        baseToken = new MockERC20();
        factory = new LiquidFactory(
            admin,
            address(poolManager),
            -180,
            120000,
            address(0),
            60,
            1e15
        );

        vm.prank(admin);

        factory.setLiquidRegistry(address(1));

        liquidImplementation = new LiquidMultiCurve();
        vm.prank(admin);
        factory.setLiquidMultiCurveImplementation(address(liquidImplementation));
        vm.prank(admin);
        factory.setBaseToken(address(baseToken));

        baseToken.mint(admin, 1000 ether);
        baseToken.mint(user1, 1000 ether);
    }

    function test_RevertWhen_NonAdmin_SetImplementation() public {
        LiquidMultiCurve newImpl = new LiquidMultiCurve();
        vm.prank(user1);
        vm.expectRevert();
        factory.setLiquidMultiCurveImplementation(address(newImpl));
    }

    function test_RevertWhen_NonAdmin_SetBaseToken() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.setBaseToken(address(0x123));
    }

    function test_RevertWhen_UpdateImplementationToZero() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setLiquidMultiCurveImplementation(address(0));
    }

    function test_RevertWhen_SetBaseTokenZero() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setBaseToken(address(0));
    }

    function test_RevertWhen_InvalidTickRange_LowerEqualsUpper() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidTickRange.selector);
        factory.setLpTickLower(120000);
    }

    function test_RevertWhen_InvalidTickRange_LowerGreaterThanUpper() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidTickRange.selector);
        factory.setLpTickLower(120001);
    }

    function test_RevertWhen_SetLpTickLower_InvalidTickSpacing() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidTickSpacing.selector);
        factory.setLpTickLower(-200);
    }

    function test_RevertWhen_SetLpTickUpper_InvalidTickSpacing() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidTickSpacing.selector);
        factory.setLpTickUpper(120050);
    }

    function test_RevertWhen_Constructor_InvalidTickSpacing() public {
        vm.expectRevert(ILiquidFactory.InvalidTickSpacing.selector);
        new LiquidFactory(
            admin,
            address(poolManager),
            -200,
            120000,
            address(0),
            60,
            1e15
        );
    }

    function test_SetPoolManager_RevertsWhen_AddressZero() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.setPoolManager(address(0));
    }

    function testUpdateImplementation() public {
        LiquidMultiCurve newImpl = new LiquidMultiCurve();
        vm.prank(admin);
        factory.setLiquidMultiCurveImplementation(address(newImpl));
        assertEq(factory.liquidMultiCurveImplementation(), address(newImpl));
    }

    function testUpdateConfig() public {
        address newBaseToken = makeAddr("newBaseToken");
        vm.expectEmit(true, false, false, false);
        emit ILiquidFactory.BaseTokenUpdated(newBaseToken);
        vm.prank(admin);
        factory.setBaseToken(newBaseToken);
        assertEq(factory.baseToken(), newBaseToken);

        address newPoolManager = makeAddr("newPoolManager");
        vm.expectEmit(true, false, false, false);
        emit ILiquidFactory.PoolManagerUpdated(newPoolManager);
        vm.prank(admin);
        factory.setPoolManager(newPoolManager);
        assertEq(factory.poolManager(), newPoolManager);
    }

    function test_SetPoolHooks_WithGuardBoundToDifferentFactory_Reverts() public {
        address maliciousFactory = makeAddr("maliciousFactory");
        MockSwapGuardForFactory mockGuard = new MockSwapGuardForFactory(
            admin,
            maliciousFactory
        );

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidFactory.SwapGuardFactoryMismatch.selector,
                address(mockGuard),
                maliciousFactory,
                address(factory)
            )
        );
        factory.setPoolHooks(address(mockGuard));
    }

    function test_SetPoolHooks_SwallowsFailedGuardFactoryBinding_NoLongerAllowed() public {
        // This reproduces the prior silent-failure path: old code tried setFactory() and swallowed reverts.
        // With owner-only setFactory, a guard owned by another actor will not be bindable, and should be rejected.
        address attacker = makeAddr("attacker");
        MockSwapGuardForFactory mockGuard = new MockSwapGuardForFactory(
            attacker,
            address(0)
        );

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidFactory.SwapGuardFactoryMismatch.selector,
                address(mockGuard),
                address(0),
                address(factory)
            )
        );
        factory.setPoolHooks(address(mockGuard));
    }

    function test_CreateLiquidTokenMultiCurve_WithHookNotContract_Reverts() public {
        address notAContract = makeAddr("notAContract");

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidFactory.InvalidPoolHook.selector,
                notAContract
            )
        );
        factory.setPoolHooks(notAContract);
    }

    function test_SetPoolHooks_WithNotContractAddress_Reverts() public {
        test_CreateLiquidTokenMultiCurve_WithHookNotContract_Reverts();
    }

    function test_CreateLiquidTokenMultiCurve_WithHookMissingRequiredFlags_Reverts() public {
        MockSwapGuardForFactory mockGuard = _deployMockSwapGuardForFactoryWithoutRequiredFlags();

        vm.prank(admin);
        factory.setPoolHooks(address(mockGuard));

        uint160 requiredFlags = Hooks.BEFORE_INITIALIZE_FLAG;
        uint160 actualFlags = uint160(address(mockGuard)) & Hooks.ALL_HOOK_MASK;

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 1e15);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidFactory.PoolHookMissingFlags.selector,
                address(mockGuard),
                actualFlags,
                requiredFlags
            )
        );
        factory.createLiquidTokenMultiCurve(
            user1,
            "uri",
            "Token",
            "TKN",
            1e15,
            curves
        );
    }

    function test_CreateLiquidTokenMultiCurve_WithHookNotGuard_Reverts() public {
        MockHookWithoutGuard mockHook = _deployMockHookWithoutGuardWithRequiredFlags();

        vm.prank(admin);
        factory.setPoolHooks(address(mockHook));

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 1e15);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidFactory.PoolHookNotGuard.selector,
                address(mockHook)
            )
        );
        factory.createLiquidTokenMultiCurve(
            user1,
            "uri",
            "Token",
            "TKN",
            1e15,
            curves
        );
    }

    function test_CreateLiquidTokenMultiCurve_WithHookFactoryMismatchAtCreate_Reverts() public {
        LiquidSwapGuard validHook = _deployLiquidSwapGuardWithRequiredFlags();
        address badFactory = makeAddr("badFactory");

        vm.prank(admin);
        validHook.setFactory(address(factory));

        vm.prank(admin);
        factory.setPoolHooks(address(validHook));

        vm.prank(admin);
        validHook.setFactory(badFactory);

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 1e15);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidFactory.SwapGuardFactoryMismatch.selector,
                address(validHook),
                badFactory,
                address(factory)
            )
        );
        factory.createLiquidTokenMultiCurve(
            user1,
            "uri",
            "Token",
            "TKN",
            1e15,
            curves
        );
    }

    function test_CreateLiquidTokenMultiCurve_WithNoHooks_RevertsPoolHooksNotSet() public {
        assertEq(factory.poolHooks(), address(0));

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 1e15);
        vm.prank(user1);
        vm.expectRevert(ILiquidFactory.PoolHooksNotSet.selector);
        factory.createLiquidTokenMultiCurve(
            user1,
            "uri",
            "Token",
            "TKN",
            1e15,
            curves
        );
    }

    function test_CreateLiquidTokenMultiCurve_WithInitGuardOnly_Succeeds() public {
        LiquidInitGuard initGuard = _deployLiquidInitGuardWithRequiredFlags();

        vm.prank(admin);
        initGuard.setFactory(address(factory));

        vm.prank(admin);
        factory.setPoolHooks(address(initGuard));

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 1e15);

        vm.prank(user1);
        address token = factory.createLiquidTokenMultiCurve(
            user1,
            "uri",
            "Token",
            "TKN",
            1e15,
            curves
        );

        assertTrue(token != address(0));
        assertTrue(ILiquidSwapGuard(address(initGuard)).allowedInitializers(token));
    }

    function test_CreateLiquidTokenMultiCurve_WithValidMultiCurveHook_Succeeds() public {
        LiquidSwapGuard validHook = _deployLiquidSwapGuardWithRequiredFlags();

        vm.prank(admin);
        validHook.setFactory(address(factory));

        vm.prank(admin);
        factory.setPoolHooks(address(validHook));

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 1e15);
        vm.prank(user1);
        address token = factory.createLiquidTokenMultiCurve(
            user1,
            "uri",
            "Token",
            "TKN",
            1e15,
            curves
        );

        assertTrue(token != address(0));
        assertTrue(ILiquidSwapGuard(address(validHook)).allowedInitializers(token));
    }

    function test_RevertWhen_NonAdmin_Pause() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.pause();
    }

    function test_RevertWhen_NonAdmin_Unpause() public {
        vm.prank(admin);
        factory.pause();

        vm.prank(user1);
        vm.expectRevert();
        factory.unpause();
    }

    function test_FactoryPause_StopsTokenCreation() public {
        LiquidInitGuard initGuard = _deployLiquidInitGuardWithRequiredFlags();
        vm.prank(admin);
        initGuard.setFactory(address(factory));
        vm.prank(admin);
        factory.setPoolHooks(address(initGuard));

        vm.prank(admin);
        factory.pause();

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 1e15);

        vm.prank(user1);
        vm.expectRevert();
        factory.createLiquidTokenMultiCurve(
            user1,
            "uri",
            "Token",
            "TKN",
            1e15,
            curves
        );
    }

    function test_FactoryPauseAndUnpause_ResumesTokenCreation() public {
        LiquidInitGuard initGuard = _deployLiquidInitGuardWithRequiredFlags();
        vm.prank(admin);
        initGuard.setFactory(address(factory));
        vm.prank(admin);
        factory.setPoolHooks(address(initGuard));

        vm.prank(admin);
        factory.pause();

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 2 * 1e15);
        vm.prank(user1);
        vm.expectRevert();
        factory.createLiquidTokenMultiCurve(
            user1,
            "uri",
            "Token",
            "TKN",
            1e15,
            curves
        );

        vm.prank(admin);
        factory.unpause();

        vm.prank(user1);
        address token = factory.createLiquidTokenMultiCurve(
            user1,
            "uri",
            "Token",
            "TKN",
            1e15,
            curves
        );
        assertTrue(token != address(0));
    }

    function _deployMockSwapGuardForFactoryWithoutRequiredFlags()
        internal
        returns (MockSwapGuardForFactory memoryGuard)
    {
        uint160 requiredFlags = Hooks.BEFORE_INITIALIZE_FLAG;

        for (uint256 i = 0; i < 512; i++) {
            MockSwapGuardForFactory candidate = new MockSwapGuardForFactory{
                salt: bytes32(i)
            }(admin, address(factory));
            uint160 actualFlags = uint160(address(candidate)) & Hooks.ALL_HOOK_MASK;
            if (
                (actualFlags & requiredFlags) != requiredFlags &&
                Hooks.isValidHookAddress(IHooks(address(candidate)), 0)
            ) {
                return candidate;
            }
        }

        revert("Could not find mock guard without required multicurve flags");
    }

    function _deployLiquidSwapGuardWithRequiredFlags()
        internal
        returns (LiquidSwapGuard validHook)
    {
        uint160 requiredFlags = Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG;

        for (uint256 i = 0; i < 512; i++) {
            LiquidSwapGuard candidate = new LiquidSwapGuard{salt: bytes32(i)}(
                IPoolManager(address(poolManager)),
                admin,
                true
            );
            uint160 actualFlags = uint160(address(candidate)) & Hooks.ALL_HOOK_MASK;
            if (
                (actualFlags & requiredFlags) == requiredFlags &&
                Hooks.isValidHookAddress(IHooks(address(candidate)), 0)
            ) {
                return candidate;
            }
        }

        revert("Could not find guarded hook with required multicurve flags");
    }

    function _deployMockHookWithoutGuardWithRequiredFlags()
        internal
        returns (MockHookWithoutGuard mockHook)
    {
        uint160 requiredFlags = Hooks.BEFORE_INITIALIZE_FLAG;

        for (uint256 i = 0; i < 512; i++) {
            MockHookWithoutGuard candidate = new MockHookWithoutGuard{
                salt: bytes32(i)
            }();
            uint160 actualFlags = uint160(address(candidate)) & Hooks.ALL_HOOK_MASK;
            if (
                (actualFlags & requiredFlags) == requiredFlags &&
                Hooks.isValidHookAddress(IHooks(address(candidate)), 0)
            ) {
                return candidate;
            }
        }

        revert("Could not find non-guard hook with required multicurve flags");
    }

    function _deployLiquidInitGuardWithRequiredFlags()
        internal
        returns (LiquidInitGuard initGuard)
    {
        uint160 requiredFlags = Hooks.BEFORE_INITIALIZE_FLAG;

        for (uint256 i = 0; i < 512; i++) {
            LiquidInitGuard candidate = new LiquidInitGuard{salt: bytes32(i)}(
                IPoolManager(address(poolManager)),
                admin,
                true
            );
            uint160 actualFlags = uint160(address(candidate)) & Hooks.ALL_HOOK_MASK;
            if (
                (actualFlags & requiredFlags) == requiredFlags &&
                Hooks.isValidHookAddress(IHooks(address(candidate)), 0)
            ) {
                return candidate;
            }
        }

        revert("Could not find init guard with required flags");
    }
}

contract MockHookWithoutGuard is IHooks {
    function beforeInitialize(
        address,
        PoolKey calldata,
        uint160
    ) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}

contract MockSwapGuardForFactory is ILiquidSwapGuard {
    address public override factory;
    address public owner;

    constructor(address _owner, address _initialFactory) {
        owner = _owner;
        factory = _initialFactory;
    }

    function setFactory(address _factory) external override {
        if (msg.sender != owner) revert("NOT_OWNER");
        factory = _factory;
    }

    function addInitializer(address) external pure override {
        revert("UNUSED");
    }

    function removeInitializer(address) external pure override {
        revert("UNUSED");
    }

    function allowedInitializers(
        address
    ) external pure override returns (bool) {
        return false;
    }
}
