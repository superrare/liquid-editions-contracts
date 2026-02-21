// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import {LiquidSwapGuard} from "liquid-editions/LiquidSwapGuard.sol";
import {LiquidMultiCurve} from "liquid-editions/LiquidMultiCurve.sol";
import {RoutePolicy} from "liquid-editions/RoutePolicy.sol";
import {LiquidRouterForkBase} from "liquid-editions-test/helpers/bases/LiquidRouterForkBase.sol";
import {DeployLiquidSwapGuard} from "script/deployers/DeployLiquidSwapGuard.s.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @notice IUniversalRouter for direct execute call
interface IUniversalRouter {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}

/**
 * @title LiquidSwapGuardMainnetForkTest
 * @notice Fork tests for LiquidSwapGuard: swap via LiquidRouter succeeds, direct UniversalRouter reverts.
 * @dev Run with: source .env && forge test --match-contract LiquidSwapGuardMainnetForkTest -vvv --fork-url $MAINNET_RPC_URL
 */
contract LiquidSwapGuardMainnetForkTest is LiquidRouterForkBase {
    LiquidSwapGuard public guard;
    LiquidMultiCurve public liquidToken;

    uint8 constant ALLOW_REVERT_FLAG = 0x80;
    bytes1 constant V4_SWAP = 0x10;
    bytes1 constant WRAP_ETH = 0x0b;
    uint8 constant SWAP_EXACT_IN = 0x07;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;
    address constant ROUTER_ADDRESS =
        address(0x0000000000000000000000000000000000000002);
    uint24 constant ETH_RARE_POOL_FEE = 3000;
    int24 constant ETH_RARE_POOL_TICK_SPACING = 60;

    struct PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    function _configureFactory() internal override {
        factory.setCcaFactory(config.ccaFactory);
        factory.setLbpStrategyFactory(config.lbpStrategyFactory);
        factory.setPositionManager(config.uniswapV4PositionManager);
        factory.setProtocolFeeRecipient(protocolFeeRecipient);

        address guardAddr = DeployLiquidSwapGuard.deployForTest(
            IPoolManager(config.uniswapV4PoolManager),
            admin,
            bytes32(0)
        );
        guard = LiquidSwapGuard(guardAddr);
        guard.addRouter(config.uniswapUniversalRouter);
        factory.setPoolHooks(address(guard));
    }

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        guard.addCaller(address(router));

        vm.startPrank(tokenCreator);
        uint256 minRare = factory.minRareLiquidityWei();
        IERC20(config.rareToken).approve(address(factory), minRare);
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({
            tickLower: factory.lpTickLower(),
            tickUpper: factory.lpTickUpper(),
            numPositions: 1,
            shares: 1e18
        });
        address tokenAddr = factory.createLiquidTokenMultiCurve(
            tokenCreator,
            "ipfs://guard-fork-test",
            "Guard Fork Test Token",
            "GFT",
            minRare,
            curves
        );
        liquidToken = LiquidMultiCurve(payable(tokenAddr));
        vm.stopPrank();

        vm.prank(admin);
        router.registerToken(tokenAddr, tokenCreator);

        vm.deal(buyer, 10 ether);
    }

    function _buildExecuteParams(
        address liquidTokenAddress,
        uint256 ethForSwap,
        uint256 minTokensOut
    )
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs, uint256 deadline)
    {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: config.rareToken,
            fee: ETH_RARE_POOL_FEE,
            tickSpacing: ETH_RARE_POOL_TICK_SPACING,
            hooks: address(0),
            hookData: bytes("")
        });
        path[1] = PathKey({
            intermediateCurrency: liquidTokenAddress,
            fee: 0,
            tickSpacing: 60,
            hooks: address(guard),
            hookData: bytes("")
        });

        bytes memory actions = abi.encodePacked(
            uint8(SWAP_EXACT_IN),
            uint8(SETTLE_ALL),
            uint8(TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            address(0),
            path,
            uint128(ethForSwap),
            uint128(minTokensOut)
        );
        params[1] = abi.encode(address(0), type(uint128).max);
        params[2] = abi.encode(liquidTokenAddress, uint128(minTokensOut));

        bytes memory v4SwapInput = abi.encode(actions, params);
        commands = abi.encodePacked(V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = v4SwapInput;
        deadline = block.timestamp + 1 hours;
    }

    function _encodeBuyRoute(
        address liquidTokenAddress,
        uint256 ethForSwap,
        uint256 minTokensOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        (commands, inputs, ) = _buildExecuteParams(
            liquidTokenAddress,
            ethForSwap,
            minTokensOut
        );
    }

    function _encodeSellRoute(
        address liquidTokenAddress,
        uint256 tokenAmount,
        uint256 minEthOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        address outputCurrency = address(0);
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: config.rareToken,
            fee: 0,
            tickSpacing: 60,
            hooks: address(guard),
            hookData: bytes("")
        });
        path[1] = PathKey({
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
        bytes memory structData = abi.encode(
            liquidTokenAddress,
            path,
            uint128(tokenAmount),
            uint128(minEthOut)
        );
        params[0] = abi.encodePacked(uint256(0x20), structData);
        params[1] = abi.encode(liquidTokenAddress, type(uint128).max);
        params[2] = abi.encode(outputCurrency, uint128(minEthOut));

        bytes memory v4SwapInput = abi.encode(actions, params);
        commands = abi.encodePacked(V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = v4SwapInput;
    }

    function _ethForSwap(uint256 ethAmount) internal view returns (uint256) {
        return (ethAmount * (10000 - router.TOTAL_FEE_BPS())) / 10000;
    }

    function _appendWrapEth(
        bytes memory commands,
        bytes[] memory inputs,
        bool allowRevert
    )
        internal
        pure
        returns (bytes memory nextCommands, bytes[] memory nextInputs)
    {
        bytes1 wrapCommand = allowRevert
            ? bytes1(uint8(WRAP_ETH) | ALLOW_REVERT_FLAG)
            : WRAP_ETH;

        nextCommands = abi.encodePacked(commands, wrapCommand);
        nextInputs = new bytes[](inputs.length + 1);
        for (uint256 i; i < inputs.length; i++) {
            nextInputs[i] = inputs[i];
        }

        // Intentionally impossible amount so WRAP_ETH fails if executed.
        nextInputs[inputs.length] = abi.encode(
            ROUTER_ADDRESS,
            type(uint256).max
        );
    }

    function test_swapViaLiquidRouter_succeeds() public {
        uint256 ethAmount = 0.01 ether;
        uint256 ethForSwap = _ethForSwap(ethAmount);
        (bytes memory commands, bytes[] memory inputs) = _encodeBuyRoute(
            address(liquidToken),
            ethForSwap,
            1
        );

        uint256 balanceBefore = liquidToken.balanceOf(buyer);

        vm.prank(buyer);
        uint256 tokensReceived = router.buy{value: ethAmount}(
            address(liquidToken),
            buyer,
            address(0),
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );

        assertGt(tokensReceived, 0, "Should receive tokens via LiquidRouter");
        assertEq(liquidToken.balanceOf(buyer) - balanceBefore, tokensReceived);
    }

    function test_Sell_LiquidToken_ViaRouter() public {
        // First buy tokens
        uint256 buyEth = 0.01 ether;
        uint256 ethForSwap = _ethForSwap(buyEth);
        (bytes memory buyCommands, bytes[] memory buyInputs) = _encodeBuyRoute(
            address(liquidToken),
            ethForSwap,
            1
        );
        vm.prank(buyer);
        router.buy{value: buyEth}(
            address(liquidToken),
            buyer,
            address(0),
            1,
            buyCommands,
            buyInputs,
            block.timestamp + 1 hours
        );

        uint256 tokensToSell = liquidToken.balanceOf(buyer) / 2;
        require(tokensToSell > 0, "No tokens to sell");

        uint256 ethBefore = buyer.balance;
        vm.startPrank(buyer);
        IERC20(liquidToken).approve(address(router), tokensToSell);
        (
            bytes memory sellCommands,
            bytes[] memory sellInputs
        ) = _encodeSellRoute(address(liquidToken), tokensToSell, 1);
        uint256 ethReceived = router.sell(
            address(liquidToken),
            tokensToSell,
            buyer,
            address(0),
            1,
            sellCommands,
            sellInputs,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        assertGt(ethReceived, 0, "Should receive ETH via LiquidRouter");
        assertGt(buyer.balance, ethBefore, "ETH balance should increase");
    }

    function test_BuySell_RoundTrip_ViaRouter() public {
        uint256 ethAmount = 0.005 ether;
        uint256 ethForSwap = _ethForSwap(ethAmount);
        (bytes memory buyCommands, bytes[] memory buyInputs) = _encodeBuyRoute(
            address(liquidToken),
            ethForSwap,
            1
        );

        vm.prank(buyer);
        uint256 tokensBought = router.buy{value: ethAmount}(
            address(liquidToken),
            buyer,
            address(0),
            1,
            buyCommands,
            buyInputs,
            block.timestamp + 1 hours
        );

        vm.startPrank(buyer);
        IERC20(liquidToken).approve(address(router), tokensBought);
        (
            bytes memory sellCommands,
            bytes[] memory sellInputs
        ) = _encodeSellRoute(address(liquidToken), tokensBought, 1);
        router.sell(
            address(liquidToken),
            tokensBought,
            buyer,
            address(0),
            1,
            sellCommands,
            sellInputs,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        assertEq(
            liquidToken.balanceOf(buyer),
            0,
            "Should have sold all tokens"
        );
    }

    function test_swapViaUniversalRouterDirectly_reverts() public {
        uint256 ethAmount = 0.01 ether;
        uint256 ethForSwap = _ethForSwap(ethAmount);
        (
            bytes memory commands,
            bytes[] memory inputs,
            uint256 deadline
        ) = _buildExecuteParams(address(liquidToken), ethForSwap, 1);

        vm.deal(buyer, ethAmount);
        vm.prank(buyer);
        vm.expectRevert(); // Hook reverts with UnauthorizedCaller (buyer is not LiquidRouter)
        IUniversalRouter(config.uniswapUniversalRouter).execute{
            value: ethAmount
        }(commands, inputs, deadline);
    }

    function test_buyWithFailingTrailingWrapWithoutAllowRevert_reverts()
        public
    {
        uint256 ethAmount = 0.01 ether;
        uint256 ethForSwap = _ethForSwap(ethAmount);
        (
            bytes memory baseCommands,
            bytes[] memory baseInputs
        ) = _encodeBuyRoute(address(liquidToken), ethForSwap, 1);
        (bytes memory commands, bytes[] memory inputs) = _appendWrapEth(
            baseCommands,
            baseInputs,
            false
        );

        vm.prank(buyer);
        vm.expectRevert();
        router.buy{value: ethAmount}(
            address(liquidToken),
            buyer,
            address(0),
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function test_buyWithFailingTrailingWrapAllowRevert_revertsInRoutePolicy()
        public
    {
        uint256 ethAmount = 0.01 ether;
        uint256 ethForSwap = _ethForSwap(ethAmount);
        (
            bytes memory baseCommands,
            bytes[] memory baseInputs
        ) = _encodeBuyRoute(address(liquidToken), ethForSwap, 1);
        (bytes memory commands, bytes[] memory inputs) = _appendWrapEth(
            baseCommands,
            baseInputs,
            true
        );

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                RoutePolicy.DisallowedCommandFlags.selector,
                bytes1(uint8(WRAP_ETH) | ALLOW_REVERT_FLAG)
            )
        );
        router.buy{value: ethAmount}(
            address(liquidToken),
            buyer,
            address(0),
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
    }

    function test_buyBaselineRoute_andLooseMinOut_succeeds() public {
        uint256 ethAmount = 0.01 ether;
        uint256 ethForSwap = _ethForSwap(ethAmount);
        (bytes memory commands, bytes[] memory inputs) = _encodeBuyRoute(
            address(liquidToken),
            ethForSwap,
            1
        );
        vm.prank(buyer);
        uint256 bought = router.buy{value: ethAmount}(
            address(liquidToken),
            buyer,
            address(0),
            1,
            commands,
            inputs,
            block.timestamp + 1 hours
        );
        assertGt(bought, 0);
    }

    /// @notice Fork test: attacker's direct pm.initialize() via unlock reverts (real PoolManager)
    /// @dev Verifies pool pre-initialization DoS protection: attacker cannot front-run token deployment
    function test_AttackerPreInitialize_RevertsViaRealPoolManager() public {
        // Predict next clone address (Clones.clone uses CREATE; nonce determines address)
        address predictedToken = vm.computeCreateAddress(
            address(factory),
            vm.getNonce(address(factory))
        );

        // Build PoolKey same as LiquidMultiCurve would (currencies sorted by address, guard as hooks)
        (Currency currency0, Currency currency1) = config.rareToken <
            predictedToken
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

        // Deploy attacker contract that will call pm.initialize() from unlock callback
        AttackerInitializer attackerContract = new AttackerInitializer(
            IPoolManager(config.uniswapV4PoolManager)
        );

        // Attacker tries to pre-initialize - should revert (hook rejects with UnauthorizedInitializer;
        // PoolManager may wrap the revert as WrappedError)
        vm.expectRevert();
        attackerContract.tryInitialize(poolKey, hostilePrice);
    }
}

/// @notice Attacker contract: calls pm.initialize() from unlock callback (simulates front-run)
contract AttackerInitializer is IUnlockCallback {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function tryInitialize(
        PoolKey memory poolKey,
        uint160 sqrtPriceX96
    ) external {
        poolManager.unlock(abi.encode(poolKey, sqrtPriceX96));
    }

    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "only pool manager");
        (PoolKey memory poolKey, uint160 sqrtPriceX96) = abi.decode(
            data,
            (PoolKey, uint160)
        );
        poolManager.initialize(poolKey, sqrtPriceX96);
        return "";
    }
}
