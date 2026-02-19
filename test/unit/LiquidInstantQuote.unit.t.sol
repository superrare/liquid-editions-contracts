// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {MockV4Quoter} from "liquid-editions-test/helpers/MockV4Quoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract MockV4PoolManagerNoQuoteRevert {
    bytes public lastUnlockData;

    function unlock(bytes calldata data) external returns (bytes memory) {
        lastUnlockData = data;
        LiquidInstant.UnlockContext memory ctx = abi.decode(
            data,
            (LiquidInstant.UnlockContext)
        );

        if (
            ctx.action == LiquidInstant.UnlockAction.QUOTE_SWAP_BUY ||
            ctx.action == LiquidInstant.UnlockAction.QUOTE_SWAP_SELL
        ) {
            return "";
        }

        if (msg.sender.code.length > 0) {
            return IUnlockCallback(msg.sender).unlockCallback(data);
        }
        return "";
    }

    function swap(
        PoolKey memory,
        IPoolManager.SwapParams memory,
        bytes memory
    ) external pure returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function settle() external payable returns (uint256) {
        return 0;
    }

    function sync(Currency) external {}

    function take(Currency, address, uint256) external {}

    function modifyLiquidity(
        PoolKey memory,
        IPoolManager.ModifyLiquidityParams memory,
        bytes calldata
    ) external pure returns (BalanceDelta, BalanceDelta) {
        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function initialize(PoolKey memory, uint160) external pure returns (int24) {
        return 0;
    }

    function getSlot0(
        bytes32
    )
        external
        pure
        returns (uint160, int24, uint24, uint24)
    {
        return (79228162514264337593543950336, 0, 0, 0);
    }

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(
            uint256(79228162514264337593543950336) << 24
        );
    }
}

contract LiquidInstantQuoteUnitTest is Test {
    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");

    LiquidFactory public factory;
    LiquidInstant public liquidImpl;
    LiquidInstant public token;
    MockRARE public mockRARE;
    MockV4PoolManagerNoQuoteRevert public poolManager;
    MockV4Quoter public mockQuoter;

    function setUp() public {
        mockRARE = new MockRARE();
        poolManager = new MockV4PoolManagerNoQuoteRevert();
        mockQuoter = new MockV4Quoter();

        liquidImpl = new LiquidInstant();
        factory = new LiquidFactory(
            admin,
            address(0xBEEF),
            address(poolManager),
            -180,
            120000,
            address(mockQuoter),
            address(0),
            60,
            300,
            1e15
        );
        vm.prank(admin);
        factory.setLiquidRouter(address(1));

        vm.startPrank(admin);
        factory.setImplementation(address(liquidImpl));
        factory.setBaseToken(address(mockRARE));
        vm.stopPrank();

        mockRARE.mint(tokenCreator, 10_000_000 ether);

        vm.startPrank(tokenCreator);
        IERC20(mockRARE).approve(address(factory), 0.001 ether);
        address tokenAddress = factory.createLiquidToken(
            tokenCreator,
            "ipfs://unit",
            "Unit Test Token",
            "UNIT",
            0.001 ether
        );
        vm.stopPrank();

        token = LiquidInstant(payable(tokenAddress));
    }

    function test_QuoteBuy_RevertsWith_QuoteSimulationDidNotRevert_WhenPoolManagerDoesNotRevert()
        public
    {
        vm.expectRevert(ILiquid.QuoteSimulationDidNotRevert.selector);
        token.quoteBuy(1 ether);
    }

    function test_QuoteSell_RevertsWith_QuoteSimulationDidNotRevert_WhenPoolManagerDoesNotRevert()
        public
    {
        vm.expectRevert(ILiquid.QuoteSimulationDidNotRevert.selector);
        token.quoteSell(1_000 ether);
    }
}
