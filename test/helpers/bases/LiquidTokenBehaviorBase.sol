// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title LiquidTokenBehaviorBase
 * @notice Abstract base test for shared ILiquid behavior across LiquidInstant, LiquidMultiCurve, LiquidGraduated.
 * @dev Concrete subcontracts override _deployFactory(), _deployToken(), _poolLive(), _tokenName(), _tokenSymbol().
 *      Tests that require a live pool are gated by _poolLive().
 */

import "forge-std/Test.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {LiquidFactory} from "liquid-editions/LiquidFactory.sol";
import {MockRARE} from "liquid-editions-test/helpers/MockRARE.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";

/// @notice Mock render contract for metadata tests
contract MockRenderContractBehavior {
    string public returnValue;
    bool public shouldRevert;
    bool public shouldReturnEmpty;

    function setReturnValue(string memory _value) external {
        returnValue = _value;
    }

    function setShouldRevert(bool _should) external {
        shouldRevert = _should;
    }

    function setShouldReturnEmpty(bool _should) external {
        shouldReturnEmpty = _should;
    }

    function tokenURI() external view returns (string memory) {
        if (shouldRevert) revert("Render contract error");
        if (shouldReturnEmpty) return "";
        return returnValue;
    }

    function tokenURI(uint256) external view returns (string memory) {
        if (shouldRevert) revert("Render contract error");
        if (shouldReturnEmpty) return "";
        return returnValue;
    }
}

abstract contract LiquidTokenBehaviorBase is Test {
    ILiquid public token;
    LiquidFactory public factory;
    MockRARE public mockRARE;

    address public admin;
    address public tokenCreator;
    address public user1;

    /// @dev Deploy factory + mock RARE. Subclass creates fork, deploys factory, sets implementations.
    function _deployFactory()
        internal
        virtual
        returns (LiquidFactory, MockRARE);

    /// @dev Deploy a token via the factory. Returns the token cast to ILiquid.
    function _deployToken() internal virtual returns (ILiquid);

    /// @dev Whether the token's pool is live (for data-surface tests).
    function _poolLive() internal virtual returns (bool);

    /// @dev Whether quotes (quoteBuy/quoteSell) are supported.
    ///      Defaults to _poolLive(). Override to false when the mock setup can't
    ///      initialize a V4 pool with the token's actual poolKey (e.g. LiquidGraduated
    ///      where the clone address lacks valid V4 hook flag bits).
    function _quotesSupported() internal virtual returns (bool) {
        return _poolLive();
    }

    /// @dev The token name passed during creation.
    function _tokenName() internal virtual returns (string memory);

    /// @dev The token symbol passed during creation.
    function _tokenSymbol() internal virtual returns (string memory);

    /// @dev The token URI passed during creation.
    function _tokenUri() internal virtual returns (string memory);

    function setUp() public virtual {
        admin = makeAddr("admin");
        tokenCreator = makeAddr("tokenCreator");
        user1 = makeAddr("user1");

        vm.deal(admin, 100 ether);
        vm.deal(tokenCreator, 100 ether);
        vm.deal(user1, 100 ether);

        (factory, mockRARE) = _deployFactory();
        token = _deployToken();
    }

    // ============================================
    // SECTION A: Post-Initialization Invariants
    // ============================================

    function test_PostInit_CorrectTotalSupply() public view {
        assertEq(
            IERC20(address(token)).totalSupply(),
            token.MAX_TOTAL_SUPPLY(),
            "totalSupply should equal MAX_TOTAL_SUPPLY"
        );
    }

    function test_PostInit_CreatorGetsLaunchReward() public view {
        assertEq(
            IERC20(address(token)).balanceOf(tokenCreator),
            100_000e18,
            "creator should receive 100k launch reward"
        );
    }

    function test_PostInit_FactoryAndBaseTokenSet() public view {
        assertEq(token.factory(), address(factory), "factory mismatch");
        assertEq(token.baseToken(), address(mockRARE), "baseToken mismatch");
        assertEq(token.tokenCreator(), tokenCreator, "tokenCreator mismatch");
    }

    function test_Initialize_RevertsWhen_CalledTwice() public {
        vm.expectRevert();
        ILiquidInitializable(address(token)).initialize(
            tokenCreator,
            "ipfs://dup",
            "Dup",
            "DUP",
            1e15
        );
    }

    // ============================================
    // SECTION B: Unlock Callback Access Control
    // ============================================

    function test_UnlockCallback_RevertsWhen_CallerNotPoolManager() public {
        // Encode a QUOTE_SWAP_BUY action (action=1 across all variants)
        bytes memory data = abi.encode(uint8(1), abi.encode(uint256(1e18)));

        vm.expectRevert(ILiquid.OnlyPoolManager.selector);
        vm.prank(user1);
        IUnlockCallback(address(token)).unlockCallback(data);
    }

    function test_UnlockCallback_RevertsWhen_UnlockNotExpected() public {
        address poolManagerAddr = token.poolManager();
        bytes memory data = abi.encode(uint8(1), abi.encode(uint256(1e18)));

        vm.expectRevert(ILiquid.UnexpectedUnlock.selector);
        vm.prank(poolManagerAddr);
        IUnlockCallback(address(token)).unlockCallback(data);
    }

    // ============================================
    // SECTION C: ERC20 Metadata + Transfer Behavior
    // ============================================

    function test_ERC20_NameAndSymbol() public {
        assertEq(
            IERC20Metadata(address(token)).name(),
            _tokenName(),
            "name mismatch"
        );
        assertEq(
            IERC20Metadata(address(token)).symbol(),
            _tokenSymbol(),
            "symbol mismatch"
        );
    }

    function test_Transfer_UpdatesBalances() public {
        uint256 amount = 1000e18;
        uint256 creatorBefore = IERC20(address(token)).balanceOf(tokenCreator);
        uint256 user1Before = IERC20(address(token)).balanceOf(user1);

        vm.prank(tokenCreator);
        IERC20(address(token)).transfer(user1, amount);

        assertEq(
            IERC20(address(token)).balanceOf(tokenCreator),
            creatorBefore - amount
        );
        assertEq(IERC20(address(token)).balanceOf(user1), user1Before + amount);
    }

    function test_Transfer_EmitsLiquidTransfer() public {
        uint256 amount = 1000e18;
        uint256 creatorBefore = IERC20(address(token)).balanceOf(tokenCreator);
        uint256 user1Before = IERC20(address(token)).balanceOf(user1);
        uint256 supplyBefore = IERC20(address(token)).totalSupply();

        vm.expectEmit(true, true, false, true);
        emit ILiquid.LiquidTransfer(
            tokenCreator,
            user1,
            amount,
            creatorBefore - amount,
            user1Before + amount,
            supplyBefore
        );

        vm.prank(tokenCreator);
        IERC20(address(token)).transfer(user1, amount);
    }

    function test_Burn_ReducesSupplyAndBalance() public {
        uint256 burnAmount = 1000e18;
        uint256 supplyBefore = IERC20(address(token)).totalSupply();
        uint256 balanceBefore = IERC20(address(token)).balanceOf(tokenCreator);

        vm.prank(tokenCreator);
        token.burn(burnAmount);

        assertEq(
            IERC20(address(token)).totalSupply(),
            supplyBefore - burnAmount
        );
        assertEq(
            IERC20(address(token)).balanceOf(tokenCreator),
            balanceBefore - burnAmount
        );
    }

    function test_Burn_EmitsLiquidTransfer() public {
        uint256 burnAmount = 1000e18;
        uint256 balanceBefore = IERC20(address(token)).balanceOf(tokenCreator);
        uint256 supplyBefore = IERC20(address(token)).totalSupply();

        vm.expectEmit(true, true, false, true);
        emit ILiquid.LiquidTransfer(
            tokenCreator,
            address(0),
            burnAmount,
            balanceBefore - burnAmount,
            0,
            supplyBefore - burnAmount
        );

        vm.prank(tokenCreator);
        token.burn(burnAmount);
    }

    function test_Burn_RevertsWhen_InsufficientBalance() public {
        uint256 balance = IERC20(address(token)).balanceOf(tokenCreator);

        vm.expectRevert();
        vm.prank(tokenCreator);
        token.burn(balance + 1);
    }

    // ============================================
    // SECTION D: Metadata / Render Contract
    // ============================================

    function test_TokenURI_ReturnsStoredURI_WhenNoRenderContract() public {
        assertEq(token.tokenURI(), _tokenUri());
    }

    function test_TokenURI_UsesRenderContract_WhenSet() public {
        MockRenderContractBehavior rc = new MockRenderContractBehavior();
        rc.setReturnValue("ipfs://render-uri");

        vm.prank(tokenCreator);
        token.setRenderContract(address(rc));

        assertEq(token.tokenURI(), "ipfs://render-uri");
    }

    function test_TokenURI_FallsBackToStoredURI_WhenRenderReverts() public {
        MockRenderContractBehavior rc = new MockRenderContractBehavior();
        rc.setShouldRevert(true);

        vm.prank(tokenCreator);
        token.setRenderContract(address(rc));

        assertEq(token.tokenURI(), _tokenUri());
    }

    function test_SetRenderContract_RevertsWhen_CallerNotCreator() public {
        MockRenderContractBehavior rc = new MockRenderContractBehavior();

        vm.expectRevert(ILiquid.NotTokenCreator.selector);
        vm.prank(user1);
        token.setRenderContract(address(rc));
    }

    // ============================================
    // SECTION E: Data-Surface APIs (pool-live gated)
    // ============================================

    function test_GetCurrentPrice_ReturnsNonZero() public {
        if (!_poolLive()) return;

        (uint256 rarePerToken, uint256 tokenPerRare) = token.getCurrentPrice();
        assertTrue(rarePerToken > 0, "rarePerToken should be > 0");
        assertTrue(tokenPerRare > 0, "tokenPerRare should be > 0");
    }

    function test_GetMarketState_ReturnsNonZero() public {
        if (!_poolLive()) return;

        (
            uint256 rarePerToken,
            ,
            uint160 sqrtPriceX96,
            ,
            ,
            uint256 currentSupply
        ) = token.getMarketState();

        assertTrue(rarePerToken > 0, "rarePerToken should be > 0");
        assertTrue(sqrtPriceX96 > 0, "sqrtPriceX96 should be > 0");
        assertEq(
            currentSupply,
            token.MAX_TOTAL_SUPPLY(),
            "supply should equal MAX"
        );
    }

    function test_QuoteBuy_ReturnsPositive() public {
        if (!_quotesSupported()) return;

        (uint256 liquidOut, ) = token.quoteBuy(10e18);
        assertTrue(liquidOut > 0, "quoteBuy output should be > 0");
    }

    function test_QuoteSell_ReturnsPositive() public {
        if (!_quotesSupported()) return;

        (uint256 rareOut, ) = token.quoteSell(1000e18);
        assertTrue(rareOut > 0, "quoteSell output should be > 0");
    }
}

/// @dev Minimal interface to call initialize() on any Liquid variant
interface ILiquidInitializable {
    function initialize(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _minRequiredRareLiquidity
    ) external;
}
