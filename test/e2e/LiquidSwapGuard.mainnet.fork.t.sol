// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import {LiquidSwapGuard} from "liquid-editions/LiquidSwapGuard.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {LiquidRouterForkBase} from "liquid-editions-test/helpers/bases/LiquidRouterForkBase.sol";
import {DeployLiquidSwapGuard} from "script/deployers/DeployLiquidSwapGuard.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @notice IUniversalRouter for direct execute call
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

/**
 * @title LiquidSwapGuardMainnetForkTest
 * @notice Fork tests for LiquidSwapGuard: swap via LiquidRouter succeeds, direct UniversalRouter reverts.
 * @dev Run with: source .env && forge test --match-contract LiquidSwapGuardMainnetForkTest -vvv --fork-url $MAINNET_RPC_URL
 */
contract LiquidSwapGuardMainnetForkTest is LiquidRouterForkBase {
    LiquidSwapGuard public guard;
    LiquidInstant public liquidToken;

    bytes1 constant V4_SWAP = 0x10;
    uint8 constant SWAP_EXACT_IN = 0x07;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;
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

        address guardAddr = DeployLiquidSwapGuard.deploy(
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
        address tokenAddr = factory.createLiquidToken(
            tokenCreator,
            "ipfs://guard-fork-test",
            "Guard Fork Test Token",
            "GFT",
            minRare
        );
        liquidToken = LiquidInstant(payable(tokenAddr));
        vm.stopPrank();

        vm.prank(admin);
        router.registerToken(tokenAddr, tokenCreator);

        vm.deal(buyer, 10 ether);
    }

    function _buildExecuteParams(
        address liquidTokenAddress,
        uint256 ethForSwap,
        uint256 minTokensOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs, uint256 deadline) {
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
    ) internal view returns (bytes memory) {
        (bytes memory commands, bytes[] memory inputs, uint256 deadline) =
            _buildExecuteParams(liquidTokenAddress, ethForSwap, minTokensOut);
        return abi.encodeWithSignature(
            "execute(bytes,bytes[],uint256)",
            commands,
            inputs,
            deadline
        );
    }

    function _encodeSellRoute(
        address liquidTokenAddress,
        uint256 tokenAmount,
        uint256 minEthOut
    ) internal view returns (bytes memory) {
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
        bytes memory commands = abi.encodePacked(V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = v4SwapInput;
        uint256 deadline = block.timestamp + 1 hours;

        return abi.encodeWithSignature(
            "execute(bytes,bytes[],uint256)",
            commands,
            inputs,
            deadline
        );
    }

    function _ethForSwap(uint256 ethAmount) internal view returns (uint256) {
        return (ethAmount * (10000 - router.TOTAL_FEE_BPS())) / 10000;
    }

    function test_swapViaLiquidRouter_succeeds() public {

        uint256 ethAmount = 0.01 ether;
        uint256 ethForSwap = _ethForSwap(ethAmount);
        bytes memory routeData = _encodeBuyRoute(address(liquidToken), ethForSwap, 1);

        uint256 balanceBefore = liquidToken.balanceOf(buyer);

        vm.prank(buyer);
        uint256 tokensReceived = router.buy{value: ethAmount}(
            address(liquidToken),
            buyer,
            address(0),
            1,
            routeData,
            block.timestamp + 1 hours
        );

        assertGt(tokensReceived, 0, "Should receive tokens via LiquidRouter");
        assertEq(liquidToken.balanceOf(buyer) - balanceBefore, tokensReceived);
    }

    function test_Sell_LiquidToken_ViaRouter() public {

        // First buy tokens
        uint256 buyEth = 0.01 ether;
        uint256 ethForSwap = _ethForSwap(buyEth);
        bytes memory buyRoute = _encodeBuyRoute(address(liquidToken), ethForSwap, 1);
        vm.prank(buyer);
        router.buy{value: buyEth}(
            address(liquidToken),
            buyer,
            address(0),
            1,
            buyRoute,
            block.timestamp + 1 hours
        );

        uint256 tokensToSell = liquidToken.balanceOf(buyer) / 2;
        require(tokensToSell > 0, "No tokens to sell");

        uint256 ethBefore = buyer.balance;
        vm.startPrank(buyer);
        IERC20(liquidToken).approve(address(router), tokensToSell);
        bytes memory sellRoute = _encodeSellRoute(address(liquidToken), tokensToSell, 1);
        uint256 ethReceived = router.sell(
            address(liquidToken),
            tokensToSell,
            buyer,
            address(0),
            1,
            sellRoute,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        assertGt(ethReceived, 0, "Should receive ETH via LiquidRouter");
        assertGt(buyer.balance, ethBefore, "ETH balance should increase");
    }

    function test_BuySell_RoundTrip_ViaRouter() public {

        uint256 ethAmount = 0.005 ether;
        uint256 ethForSwap = _ethForSwap(ethAmount);
        bytes memory buyRoute = _encodeBuyRoute(address(liquidToken), ethForSwap, 1);

        vm.prank(buyer);
        uint256 tokensBought = router.buy{value: ethAmount}(
            address(liquidToken),
            buyer,
            address(0),
            1,
            buyRoute,
            block.timestamp + 1 hours
        );

        vm.startPrank(buyer);
        IERC20(liquidToken).approve(address(router), tokensBought);
        bytes memory sellRoute = _encodeSellRoute(address(liquidToken), tokensBought, 1);
        router.sell(
            address(liquidToken),
            tokensBought,
            buyer,
            address(0),
            1,
            sellRoute,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        assertEq(liquidToken.balanceOf(buyer), 0, "Should have sold all tokens");
    }

    function test_swapViaUniversalRouterDirectly_reverts() public {

        uint256 ethAmount = 0.01 ether;
        uint256 ethForSwap = _ethForSwap(ethAmount);
        (bytes memory commands, bytes[] memory inputs, uint256 deadline) =
            _buildExecuteParams(address(liquidToken), ethForSwap, 1);

        vm.deal(buyer, ethAmount);
        vm.prank(buyer);
        vm.expectRevert(); // Hook reverts with UnauthorizedCaller (buyer is not LiquidRouter)
        IUniversalRouter(config.uniswapUniversalRouter).execute{value: ethAmount}(
            commands,
            inputs,
            deadline
        );
    }
}
