// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {NetworkConfig} from "script/config/NetworkConfig.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";

/// @notice Shared base for Liquid bonding and rarBurn fork tests
abstract contract LiquidBondingForkBase is Test {
    NetworkConfig.Config internal config;

    address public admin = makeAddr("admin");
    address public tokenCreator = makeAddr("tokenCreator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public buyer1 = makeAddr("buyer1");
    address public buyer2 = makeAddr("buyer2");
    address public buyer3 = makeAddr("buyer3");

    struct TickConfig {
        string name;
        int24 tickLower;
        int24 tickUpper;
        string description;
    }

    TickConfig[] public tickConfigs;

    MockRARE public mockRARE;

    function setUp() public virtual {
        string memory forkUrl = vm.envOr(
            "FORK_URL",
            string("https://mainnet.base.org")
        );
        vm.createSelectFork(forkUrl);

        config = NetworkConfig.getConfig(block.chainid);

        vm.deal(admin, 1000 ether);
        vm.deal(tokenCreator, 1000 ether);
        vm.deal(protocolFeeRecipient, 1000 ether);
        vm.deal(buyer1, 1000 ether);
        vm.deal(buyer2, 1000 ether);
        vm.deal(buyer3, 1000 ether);

        mockRARE = new MockRARE();
        mockRARE.mint(admin, 10_000_000 ether);
        mockRARE.mint(tokenCreator, 10_000_000 ether);
        mockRARE.mint(buyer1, 10_000_000 ether);
        mockRARE.mint(buyer2, 10_000_000 ether);
        mockRARE.mint(buyer3, 10_000_000 ether);

        _initializeTickConfigs();
    }

    function _initializeTickConfigs() internal {
        tickConfigs.push(
            TickConfig({
                name: "Default_Wide",
                tickLower: -180,
                tickUpper: 120000,
                description: "Current default configuration with bonding curve range"
            })
        );
        tickConfigs.push(
            TickConfig({
                name: "Narrow_Steep",
                tickLower: -49980,
                tickUpper: 50040,
                description: "Narrower range creating steeper bonding curve"
            })
        );
        tickConfigs.push(
            TickConfig({
                name: "VeryNarrow_VerySteep",
                tickLower: -9960,
                tickUpper: 10020,
                description: "Very narrow range creating very steep bonding curve"
            })
        );
        tickConfigs.push(
            TickConfig({
                name: "Asymmetric_High",
                tickLower: -30000,
                tickUpper: 100020,
                description: "Asymmetric range favoring higher price movements"
            })
        );
        tickConfigs.push(
            TickConfig({
                name: "Asymmetric_Low",
                tickLower: -99960,
                tickUpper: 30000,
                description: "Asymmetric range favoring lower price movements"
            })
        );
    }

    function _deployLiquidWithTicks(
        int24 tickLower,
        int24 tickUpper
    ) internal returns (LiquidFactory) {
        vm.startPrank(admin);

        LiquidFactory tempFactory = new LiquidFactory(
            admin,
            config.weth,
            config.uniswapV4PoolManager,
            tickLower,
            tickUpper,
            config.uniswapV4Quoter,
            address(0),
            60,
            300,
            1e15
        );
        tempFactory.setLiquidRouter(address(1));

        LiquidInstant liquidImplementation = new LiquidInstant();
        tempFactory.setImplementation(address(liquidImplementation));
        tempFactory.setBaseToken(address(mockRARE));

        vm.stopPrank();

        return tempFactory;
    }

    function _formatTokens(uint256 amount) internal pure returns (string memory) {
        if (amount >= 1e18) {
            return string(abi.encodePacked(vm.toString(amount / 1e18), ".00"));
        } else if (amount >= 1e15) {
            return string(abi.encodePacked("0.00", vm.toString(amount / 1e15)));
        } else {
            return string(abi.encodePacked("0.000", vm.toString(amount / 1e12)));
        }
    }

    function _computePoolId(
        address rareToken,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) internal pure returns (bytes32) {
        Currency ethC = Currency.wrap(address(0));
        Currency rareC = Currency.wrap(rareToken);

        bool ethIs0 = uint160(address(0)) < uint160(rareToken);
        PoolKey memory key = PoolKey({
            currency0: ethIs0 ? ethC : rareC,
            currency1: ethIs0 ? rareC : ethC,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        return PoolId.unwrap(PoolIdLibrary.toId(key));
    }
}
