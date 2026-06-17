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
import {ILiquidGuard} from "liquid-editions/interfaces/ILiquidGuard.sol";
import {LiquidGuard} from "liquid-editions/LiquidGuard.sol";
import {MockV4PoolManager} from "liquid-editions-test/helpers/MockV4PoolManager.sol";
import {MockERC20} from "liquid-editions-test/helpers/MockERC20.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";

contract LiquidFactoryUnitTest is Test {
    address public admin = makeAddr("admin");
    address public user1 = makeAddr("user1");

    MockV4PoolManager public poolManager;
    MockERC20 public baseToken;

    LiquidFactory public factory;
    LiquidMultiCurve public liquidImplementation;

    function _defaultSingleCurve() internal pure returns (Curve[] memory) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({tickLower: -180, tickUpper: 120000, numPositions: 1, shares: 1e18});
        return curves;
    }

    function _setValidPoolHook() internal {
        LiquidGuard guard = _deployLiquidGuardWithRequiredFlags();
        vm.prank(admin);
        guard.setFactory(address(factory));
        vm.prank(admin);
        factory.setPoolHooks(address(guard));
    }

    function setUp() public {
        poolManager = new MockV4PoolManager();
        baseToken = new MockERC20();
        factory = new LiquidFactory(admin, address(poolManager), address(0), 60);

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
        vm.skip(true);
    }

    function test_RevertWhen_InvalidTickRange_LowerGreaterThanUpper() public {
        vm.skip(true);
    }

    function test_RevertWhen_SetLpTickLower_InvalidTickSpacing() public {
        vm.skip(true);
    }

    function test_RevertWhen_SetLpTickUpper_InvalidTickSpacing() public {
        vm.skip(true);
    }

    function test_RevertWhen_Constructor_InvalidTickSpacing() public {
        vm.expectRevert(ILiquidFactory.InvalidTickSpacing.selector);
        new LiquidFactory(admin, address(poolManager), address(0), 0);
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
        MockSwapGuardForFactory mockGuard = new MockSwapGuardForFactory(admin, maliciousFactory);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidFactory.SwapGuardFactoryMismatch.selector, address(mockGuard), maliciousFactory, address(factory)
            )
        );
        factory.setPoolHooks(address(mockGuard));
    }

    function test_SetPoolHooks_SwallowsFailedGuardFactoryBinding_NoLongerAllowed() public {
        // This reproduces the prior silent-failure path: old code tried setFactory() and swallowed reverts.
        // With owner-only setFactory, a guard owned by another actor will not be bindable, and should be rejected.
        address attacker = makeAddr("attacker");
        MockSwapGuardForFactory mockGuard = new MockSwapGuardForFactory(attacker, address(0));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidFactory.SwapGuardFactoryMismatch.selector, address(mockGuard), address(0), address(factory)
            )
        );
        factory.setPoolHooks(address(mockGuard));
    }

    function test_CreateLiquidTokenMultiCurve_WithHookNotContract_Reverts() public {
        address notAContract = makeAddr("notAContract");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILiquidFactory.InvalidPoolHook.selector, notAContract));
        factory.setPoolHooks(notAContract);
    }

    function test_SetPoolHooks_WithNotContractAddress_Reverts() public {
        test_CreateLiquidTokenMultiCurve_WithHookNotContract_Reverts();
    }

    function test_CreateLiquidTokenMultiCurve_WithHookMissingRequiredFlags_Reverts() public {
        MockSwapGuardForFactory mockGuard = _deployMockSwapGuardForFactoryWithoutRequiredFlags();

        vm.prank(admin);
        factory.setPoolHooks(address(mockGuard));

        uint160 requiredFlags = _fullRequiredFlags();
        uint160 actualFlags = uint160(address(mockGuard)) & Hooks.ALL_HOOK_MASK;

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 1e15);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidFactory.PoolHookMissingFlags.selector, address(mockGuard), actualFlags, requiredFlags
            )
        );
        factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 1e15, curves);
    }

    function test_CreateLiquidTokenMultiCurve_WithHookNotGuard_Reverts() public {
        MockHookWithoutGuard mockHook = _deployMockHookWithoutGuardWithRequiredFlags();

        vm.prank(admin);
        factory.setPoolHooks(address(mockHook));

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 1e15);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ILiquidFactory.PoolHookNotGuard.selector, address(mockHook)));
        factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 1e15, curves);
    }

    function test_CreateLiquidTokenMultiCurve_WithHookFactoryMismatchAtCreate_Reverts() public {
        LiquidGuard validHook = _deployLiquidGuardWithRequiredFlags();
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
                ILiquidFactory.SwapGuardFactoryMismatch.selector, address(validHook), badFactory, address(factory)
            )
        );
        factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 1e15, curves);
    }

    function test_CreateLiquidTokenMultiCurve_WithNoHooks_RevertsPoolHooksNotSet() public {
        assertEq(factory.poolHooks(), address(0));

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 1e15);
        vm.prank(user1);
        vm.expectRevert(ILiquidFactory.PoolHooksNotSet.selector);
        factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 1e15, curves);
    }

    /// @dev Skipped: LiquidInitGuard is legacy and no longer satisfies the full 0x20CC flag
    ///      requirement. LiquidGuard is now the canonical hook for all factory launches.
    function test_CreateLiquidTokenMultiCurve_WithInitGuardOnly_Succeeds() public {
        vm.skip(true);
    }

    function test_CreateLiquidTokenMultiCurve_WithValidMultiCurveHook_Succeeds() public {
        LiquidGuard validHook = _deployLiquidGuardWithRequiredFlags();

        vm.prank(admin);
        validHook.setFactory(address(factory));

        vm.prank(admin);
        factory.setPoolHooks(address(validHook));

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 1e15);
        vm.prank(user1);
        address token = factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 1e15, curves);

        assertTrue(token != address(0));
        assertTrue(ILiquidGuard(address(validHook)).allowedInitializers(token));
    }

    // ============================================
    // setMaxTotalSupply / setCreatorLaunchReward
    // ============================================

    function test_DefaultSupplyParams() public view {
        assertEq(factory.maxTotalSupply(), 1_000_000e18);
        assertEq(factory.creatorLaunchReward(), 100_000e18);
    }

    function test_SetMaxTotalSupply_UpdatesValue() public {
        vm.prank(admin);
        factory.setMaxTotalSupply(2_000_000e18);
        assertEq(factory.maxTotalSupply(), 2_000_000e18);
    }

    function test_SetMaxTotalSupply_EmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit ILiquidFactory.MaxTotalSupplyUpdated(2_000_000e18);
        factory.setMaxTotalSupply(2_000_000e18);
    }

    function test_SetCreatorLaunchReward_UpdatesValue() public {
        vm.prank(admin);
        factory.setCreatorLaunchReward(50_000e18);
        assertEq(factory.creatorLaunchReward(), 50_000e18);
    }

    function test_SetCreatorLaunchReward_ZeroIsAllowed() public {
        vm.prank(admin);
        factory.setCreatorLaunchReward(0);
        assertEq(factory.creatorLaunchReward(), 0);
    }

    function test_SetCreatorLaunchReward_EmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit ILiquidFactory.CreatorLaunchRewardUpdated(50_000e18);
        factory.setCreatorLaunchReward(50_000e18);
    }

    // --- Access control ---

    function test_SetMaxTotalSupply_RevertsWhen_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.setMaxTotalSupply(2_000_000e18);
    }

    function test_SetCreatorLaunchReward_RevertsWhen_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.setCreatorLaunchReward(50_000e18);
    }

    // --- Invalid amount guards ---

    function test_SetMaxTotalSupply_RevertsWhen_Zero() public {
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidAmount.selector);
        factory.setMaxTotalSupply(0);
    }

    function test_SetMaxTotalSupply_RevertsWhen_EqualToCreatorReward() public {
        // Read first — vm.expectRevert must immediately precede the reverting call
        uint256 currentReward = factory.creatorLaunchReward();
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidAmount.selector);
        factory.setMaxTotalSupply(currentReward);
    }

    function test_SetMaxTotalSupply_RevertsWhen_LessThanCreatorReward() public {
        uint256 currentReward = factory.creatorLaunchReward();
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidAmount.selector);
        factory.setMaxTotalSupply(currentReward - 1);
    }

    function test_SetCreatorLaunchReward_RevertsWhen_EqualToMaxTotalSupply() public {
        uint256 currentMax = factory.maxTotalSupply();
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidAmount.selector);
        factory.setCreatorLaunchReward(currentMax);
    }

    function test_SetCreatorLaunchReward_RevertsWhen_GreaterThanMaxTotalSupply() public {
        uint256 currentMax = factory.maxTotalSupply();
        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidAmount.selector);
        factory.setCreatorLaunchReward(currentMax + 1);
    }

    // --- Cross-validation: setting one validates against the other ---

    function test_SetMaxTotalSupply_RevertsWhen_WouldViolateCrossCheck() public {
        // Set reward to 500K, then try to set supply to 400K (reward >= supply)
        vm.prank(admin);
        factory.setCreatorLaunchReward(500_000e18);

        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidAmount.selector);
        factory.setMaxTotalSupply(400_000e18);
    }

    function test_SetCreatorLaunchReward_RevertsWhen_WouldViolateCrossCheck() public {
        // Set supply to 500K, then try to set reward to 500K (reward >= supply)
        vm.prank(admin);
        factory.setMaxTotalSupply(500_000e18);

        vm.prank(admin);
        vm.expectRevert(ILiquidFactory.InvalidAmount.selector);
        factory.setCreatorLaunchReward(500_000e18);
    }

    // --- Token inherits factory values at launch ---

    function test_CreateLiquidTokenMultiCurve_LegacyPathStillUsesFactorySupplyParams() public {
        vm.prank(admin);
        factory.setMaxTotalSupply(2_000_000e18);
        vm.prank(admin);
        factory.setCreatorLaunchReward(200_000e18);

        _setValidPoolHook();

        Curve[] memory curves = _defaultSingleCurve();
        vm.prank(user1);
        baseToken.approve(address(factory), 0);
        vm.prank(user1);
        address tokenAddr = factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 0, curves);

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        assertEq(token.maxTotalSupply(), 2_000_000e18);
        assertEq(token.creatorLaunchReward(), 200_000e18);
        assertEq(token.poolLaunchSupply(), 1_800_000e18);
        assertEq(token.totalSupply(), 2_000_000e18);
        assertEq(token.balanceOf(user1), 200_000e18);
    }

    function test_CreateLiquidTokenMultiCurveWithSupply_LargerThanFactoryDefault_Succeeds() public {
        vm.prank(admin);
        factory.setCreatorLaunchReward(150_000e18);
        _setValidPoolHook();

        Curve[] memory curves = _defaultSingleCurve();
        vm.prank(user1);
        address tokenAddr =
            factory.createLiquidTokenMultiCurveWithSupply(user1, "uri", "Token", "TKN", 0, curves, 2_500_000e18);

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        assertEq(token.maxTotalSupply(), 2_500_000e18);
        assertEq(token.creatorLaunchReward(), 150_000e18);
        assertEq(token.poolLaunchSupply(), 2_350_000e18);
        assertEq(token.totalSupply(), 2_500_000e18);
        assertEq(token.balanceOf(user1), 150_000e18);
    }

    function test_CreateLiquidTokenMultiCurveWithSupply_SmallerThanFactoryDefault_Succeeds() public {
        vm.prank(admin);
        factory.setCreatorLaunchReward(100_000e18);
        _setValidPoolHook();

        Curve[] memory curves = _defaultSingleCurve();
        vm.prank(user1);
        address tokenAddr =
            factory.createLiquidTokenMultiCurveWithSupply(user1, "uri", "Token", "TKN", 0, curves, 400_000e18);

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        assertEq(token.maxTotalSupply(), 400_000e18);
        assertEq(token.creatorLaunchReward(), 100_000e18);
        assertEq(token.poolLaunchSupply(), 300_000e18);
        assertEq(token.totalSupply(), 400_000e18);
        assertEq(token.balanceOf(user1), 100_000e18);
    }

    function test_CreateLiquidTokenMultiCurveWithSupply_RevertsWhen_CustomSupplyNotGreaterThanCreatorReward() public {
        vm.prank(admin);
        factory.setCreatorLaunchReward(200_000e18);

        Curve[] memory curves = _defaultSingleCurve();
        vm.prank(user1);
        vm.expectRevert(ILiquidFactory.InvalidAmount.selector);
        factory.createLiquidTokenMultiCurveWithSupply(user1, "uri", "Token", "TKN", 0, curves, 200_000e18);
    }

    function test_LaunchedToken_WithZeroCreatorReward_AllTokensGoToPool() public {
        vm.prank(admin);
        factory.setCreatorLaunchReward(0);

        _setValidPoolHook();

        Curve[] memory curves = _defaultSingleCurve();
        vm.prank(user1);
        address tokenAddr = factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 0, curves);

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        assertEq(token.creatorLaunchReward(), 0);
        assertEq(token.poolLaunchSupply(), 1_000_000e18);
        assertEq(token.balanceOf(user1), 0, "creator should receive nothing when reward is zero");
        assertEq(token.totalSupply(), 1_000_000e18);
    }

    // ============================================
    // Creator delegation guard
    // ============================================

    function test_DelegateTokenCreation_ApprovesOperatorAndEmitsEvent() public {
        address operator = makeAddr("operator");

        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit ILiquidFactory.CreatorDelegateUpdated(user1, operator, true);
        factory.delegateTokenCreation(operator);

        assertTrue(factory.isCreatorDelegate(user1, operator));
    }

    function test_DelegateTokenCreation_RevertsWhen_OperatorIsZero() public {
        vm.prank(user1);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.delegateTokenCreation(address(0));
    }

    function test_RevokeTokenCreationDelegate_ClearsOperatorAndEmitsEvent() public {
        address operator = makeAddr("operator");

        vm.prank(user1);
        factory.delegateTokenCreation(operator);

        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit ILiquidFactory.CreatorDelegateUpdated(user1, operator, false);
        factory.revokeTokenCreationDelegate(operator);

        assertFalse(factory.isCreatorDelegate(user1, operator));
    }

    function test_RevokeTokenCreationDelegate_RevertsWhen_OperatorIsZero() public {
        vm.prank(user1);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.revokeTokenCreationDelegate(address(0));
    }

    function test_CreateLiquidTokenMultiCurve_RevertsAddressZeroWhen_CreatorIsZero() public {
        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.createLiquidTokenMultiCurve(address(0), "uri", "Token", "TKN", 0, curves);
    }

    function test_CreateLiquidTokenMultiCurveWithSupply_RevertsAddressZeroWhen_CreatorIsZero() public {
        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        vm.expectRevert(ILiquidFactory.AddressZero.selector);
        factory.createLiquidTokenMultiCurveWithSupply(address(0), "uri", "Token", "TKN", 0, curves, 2_000_000e18);
    }

    /// @dev Regression: createLiquidTokenMultiCurve must reject unapproved calls where _creator != msg.sender
    ///      to prevent an attacker from attributing a token to a victim's address.
    function test_CreateLiquidTokenMultiCurve_RevertsWhen_CreatorIsNotCallerOrDelegate() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(attacker);
        vm.expectRevert(ILiquidFactory.Unauthorized.selector);
        factory.createLiquidTokenMultiCurve(victim, "uri", "Token", "TKN", 0, curves);
    }

    function test_CreateLiquidTokenMultiCurve_AllowsApprovedDelegate() public {
        address operator = makeAddr("operator");
        _setValidPoolHook();

        vm.prank(user1);
        factory.delegateTokenCreation(operator);

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(operator);
        address tokenAddr = factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 0, curves);

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        assertEq(token.tokenCreator(), user1);
        assertEq(token.balanceOf(user1), factory.creatorLaunchReward());
        assertEq(token.balanceOf(operator), 0);
    }

    function test_CreateLiquidTokenMultiCurve_DelegateCanDeployThenCreatorCanRevoke() public {
        address operator = makeAddr("operator");
        _setValidPoolHook();

        vm.prank(user1);
        factory.delegateTokenCreation(operator);

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(operator);
        address tokenAddr = factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 0, curves);

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        assertEq(token.tokenCreator(), user1);

        vm.prank(user1);
        factory.revokeTokenCreationDelegate(operator);

        assertFalse(factory.isCreatorDelegate(user1, operator));

        vm.prank(operator);
        vm.expectRevert(ILiquidFactory.Unauthorized.selector);
        factory.createLiquidTokenMultiCurve(user1, "uri-2", "Token2", "TKN2", 0, curves);
    }

    function test_CreateLiquidTokenMultiCurveWithSupply_AllowsApprovedDelegate() public {
        address operator = makeAddr("operator");
        _setValidPoolHook();

        vm.prank(user1);
        factory.delegateTokenCreation(operator);

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(operator);
        address tokenAddr =
            factory.createLiquidTokenMultiCurveWithSupply(user1, "uri", "Token", "TKN", 0, curves, 2_000_000e18);

        LiquidMultiCurve token = LiquidMultiCurve(payable(tokenAddr));
        assertEq(token.tokenCreator(), user1);
        assertEq(token.maxTotalSupply(), 2_000_000e18);
        assertEq(token.balanceOf(user1), factory.creatorLaunchReward());
    }

    function test_CreateLiquidTokenMultiCurve_RevertsWhen_DelegateRevoked() public {
        address operator = makeAddr("operator");

        vm.prank(user1);
        factory.delegateTokenCreation(operator);

        vm.prank(user1);
        factory.revokeTokenCreationDelegate(operator);

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(operator);
        vm.expectRevert(ILiquidFactory.Unauthorized.selector);
        factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 0, curves);
    }

    function test_CreateLiquidTokenMultiCurve_ApprovedDelegatePaysInitialRareLiquidity() public {
        address operator = makeAddr("operator");
        uint256 initialRareLiquidity = 1e15;
        baseToken.mint(operator, 1000 ether);
        _setValidPoolHook();

        vm.prank(user1);
        factory.delegateTokenCreation(operator);

        Curve[] memory curves = _defaultSingleCurve();
        uint256 operatorRareBefore = baseToken.balanceOf(operator);

        vm.prank(operator);
        baseToken.approve(address(factory), initialRareLiquidity);
        vm.prank(operator);
        address tokenAddr =
            factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", initialRareLiquidity, curves);

        assertTrue(tokenAddr != address(0));
        assertEq(operatorRareBefore - baseToken.balanceOf(operator), initialRareLiquidity);
    }

    /// @dev Parked legacy Instant factory-path regression. The active multicurve guard is covered above.
    function test_CreateLiquidTokenInstant_RevertsWhen_CreatorIsNotCaller() public {
        vm.skip(true);
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
        LiquidGuard guard = _deployLiquidGuardWithRequiredFlags();
        vm.prank(admin);
        guard.setFactory(address(factory));
        vm.prank(admin);
        factory.setPoolHooks(address(guard));

        vm.prank(admin);
        factory.pause();

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 1e15);

        vm.prank(user1);
        vm.expectRevert();
        factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 1e15, curves);
    }

    function test_FactoryPauseAndUnpause_ResumesTokenCreation() public {
        LiquidGuard guard = _deployLiquidGuardWithRequiredFlags();
        vm.prank(admin);
        guard.setFactory(address(factory));
        vm.prank(admin);
        factory.setPoolHooks(address(guard));

        vm.prank(admin);
        factory.pause();

        Curve[] memory curves = _defaultSingleCurve();

        vm.prank(user1);
        baseToken.approve(address(factory), 2 * 1e15);
        vm.prank(user1);
        vm.expectRevert();
        factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 1e15, curves);

        vm.prank(admin);
        factory.unpause();

        vm.prank(user1);
        address token = factory.createLiquidTokenMultiCurve(user1, "uri", "Token", "TKN", 1e15, curves);
        assertTrue(token != address(0));
    }

    function _fullRequiredFlags() internal pure returns (uint160) {
        return Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG; // 0x20CC
    }

    function _deployMockSwapGuardForFactoryWithoutRequiredFlags()
        internal
        returns (MockSwapGuardForFactory memoryGuard)
    {
        uint160 requiredFlags = _fullRequiredFlags();

        for (uint256 i = 0; i < 512; i++) {
            MockSwapGuardForFactory candidate = new MockSwapGuardForFactory{salt: bytes32(i)}(admin, address(factory));
            uint160 actualFlags = uint160(address(candidate)) & Hooks.ALL_HOOK_MASK;
            if (
                (actualFlags & requiredFlags) != requiredFlags
                    && Hooks.isValidHookAddress(IHooks(address(candidate)), 0)
            ) {
                return candidate;
            }
        }

        revert("Could not find mock guard without required multicurve flags");
    }

    function _deployLiquidGuardWithRequiredFlags() internal returns (LiquidGuard guard) {
        address hookAddr = address(_fullRequiredFlags());
        address rareToken = makeAddr("rareToken");
        vm.prank(admin);
        deployCodeTo(
            "LiquidGuard.sol:LiquidGuard", abi.encode(IPoolManager(address(poolManager)), admin, rareToken), hookAddr
        );
        return LiquidGuard(hookAddr);
    }

    function _deployMockHookWithoutGuardWithRequiredFlags() internal returns (MockHookWithoutGuard mockHook) {
        address hookAddr = address(_fullRequiredFlags());
        deployCodeTo("LiquidFactory.unit.t.sol:MockHookWithoutGuard", "", hookAddr);
        return MockHookWithoutGuard(hookAddr);
    }
}

contract MockHookWithoutGuard is IHooks {
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
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

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
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

    function allowedInitializers(address) external pure override returns (bool) {
        return false;
    }

    function verifiedRouters(address) external pure override returns (bool) {
        return false;
    }

    function allowedCallers(address) external pure override returns (bool) {
        return false;
    }

    function addRouter(address) external pure override {
        revert("UNUSED");
    }

    function removeRouter(address) external pure override {
        revert("UNUSED");
    }

    function addCaller(address) external pure override {
        revert("UNUSED");
    }

    function removeCaller(address) external pure override {
        revert("UNUSED");
    }
}
