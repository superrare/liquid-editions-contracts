// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiquidGraduated} from "liquid-editions/interfaces/ILiquidGraduated.sol";
import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {ILiquidAuctioneer} from "liquid-editions/interfaces/ILiquidAuctioneer.sol";
import {IPermit2} from "liquid-editions/interfaces/IPermit2.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {RoutePolicy} from "liquid-editions/RoutePolicy.sol";

/// @title LiquidAuctioneer
/// @notice Router for CCA auction interactions: bid, exit/claim, trigger graduation
/// @dev Bid ownership is non-custodial (bidOwner = user).
contract LiquidAuctioneer is
    ILiquidAuctioneer,
    ReentrancyGuard,
    Ownable,
    Pausable
{
    error CommandInputLengthMismatch();

    using SafeERC20 for IERC20;

    address private _protocolFeeRecipient;
    uint16 private _ethFeeBps;
    ILiquidRegistry private _liquidRegistry;
    address private constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address public universalRouter;
    /// @dev RARE token address (base token for pools)
    address public immutable BASE_TOKEN;
    /// @dev canonical wrapped native token for this chain
    address public immutable WETH;

    

    struct TokenRoute {
        RouteKind kind;
        uint24 v4Fee;
        int24 v4TickSpacing;
        address v4Hooks;
        bytes v3Path;
        address[] v2Path;
    }

    mapping(address => TokenRoute) private tokenToRareRoutes;

    address private constant MSG_SENDER =
        address(0x0000000000000000000000000000000000000001);
    address private constant ROUTER_ADDRESS =
        address(0x0000000000000000000000000000000000000002);
    uint8 private constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint8 private constant CMD_V2_SWAP_EXACT_IN = 0x08;
    uint8 private constant CMD_WRAP_ETH = 0x0b;
    uint8 private constant CMD_V4_SWAP = 0x10;
    uint8 private constant V4_SWAP_EXACT_IN = 0x07;
    uint8 private constant V4_SETTLE_ALL = 0x0c;
    uint8 private constant V4_TAKE_ALL = 0x0f;

    struct V4PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    /// @notice Creates LiquidAuctioneer with direct protocol fee configuration.
    /// @param _owner Owner address
    /// @param _universalRouter Uniswap Universal Router for swaps
    /// @param protocolFeeRecipient_ Address to receive ETH fees from native ETH bids
    /// @param _liquidRegistryAddress LiquidRegistry module address
    /// @param _baseToken RARE token address
    /// @param _weth canonical wrapped native token for this chain
    /// @param ethFeeBps_ Fee in basis points for native ETH bids (e.g. 400 = 4%). Use 0 for no fee.
    constructor(
        address _owner,
        address _universalRouter,
        address protocolFeeRecipient_,
        address _liquidRegistryAddress,
        address _baseToken,
        address _weth,
        uint16 ethFeeBps_
    ) Ownable(_owner) {
        if (
            _owner == address(0) ||
            _universalRouter == address(0) ||
            _baseToken == address(0) ||
            _weth == address(0) ||
            _liquidRegistryAddress == address(0)
        ) {
            revert ILiquidRouter.AddressZero();
        }
        if (_universalRouter.code.length == 0) {
            revert ILiquidRouter.InvalidModule();
        }
        if (ethFeeBps_ > 10_000) revert ILiquidRouter.InvalidAmount();

        BASE_TOKEN = _baseToken;
        WETH = _weth;
        _protocolFeeRecipient = protocolFeeRecipient_ != address(0)
            ? protocolFeeRecipient_
            : _owner;
        _ethFeeBps = ethFeeBps_;

        _initContract(
            _universalRouter,
            ILiquidRegistry(_liquidRegistryAddress)
        );
    }

    /// @notice Read the protocol fee recipient (receives ETH fees from native ETH bids).
    function protocolFeeRecipient() external view returns (address) {
        return _protocolFeeRecipient;
    }

    /// @notice Read the ETH fee in basis points for native ETH bids.
    function ethFeeBps() external view returns (uint16) {
        return _ethFeeBps;
    }

    /// @notice Read the active liquid registry contract address.
    function liquidRegistry() external view returns (address) {
        return address(_liquidRegistry);
    }

    /// @notice Initialize core auctioneer module pointers and seed default native-ETH route behavior.
    /// @dev Called from constructor after constructor args are validated.
    ///      Establishes default `address(0)` -> RARE route for ETH bids with safe, conservative defaults.
    ///      Reverts are intentionally hard because an uninitialized auctioneer has undefined routing state.
    function _initContract(
        address _universalRouter,
        ILiquidRegistry liquidRegistryModule
    ) internal {
        if (
            _universalRouter == address(0) ||
            address(liquidRegistryModule) == address(0)
        ) revert ILiquidRouter.AddressZero();

        universalRouter = _universalRouter;
        _liquidRegistry = liquidRegistryModule;

        // Safe default native ETH -> RARE route; owner can override via route setters.
        TokenRoute storage nativeRoute = tokenToRareRoutes[address(0)];
        nativeRoute.kind = RouteKind.V4_SINGLE;
        nativeRoute.v4Fee = 3000;
        nativeRoute.v4TickSpacing = 60;
        nativeRoute.v4Hooks = address(0);
    }

    /// @notice Update protocol fee recipient (receives ETH fees from native ETH bids).
    function setProtocolFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert ILiquidRouter.AddressZero();
        address old = _protocolFeeRecipient;
        _protocolFeeRecipient = _recipient;
        emit ProtocolFeeRecipientUpdated(old, _recipient);
    }

    /// @notice Update ETH fee in basis points for native ETH bids (0 = no fee).
    function setEthFeeBps(uint16 _bps) external onlyOwner {
        if (_bps > 10_000) revert ILiquidRouter.InvalidAmount();
        _ethFeeBps = _bps;
    }

    /// @notice Update liquid registry pointer.
    function setLiquidRegistry(
        address liquidRegistryAddress
    ) external onlyOwner {
        if (liquidRegistryAddress == address(0))
            revert ILiquidRouter.AddressZero();
        if (liquidRegistryAddress.code.length == 0) {
            revert ILiquidRouter.InvalidModule();
        }
        address old = address(_liquidRegistry);
        _liquidRegistry = ILiquidRegistry(liquidRegistryAddress);
        emit LiquidRegistryUpdated(old, liquidRegistryAddress);
    }

    /// @notice Reverts if liquidToken is not registered in the LiquidRegistry
    /// @dev Security check to ensure only valid Liquid tokens can be bid on
    /// @param liquidToken The token address to check
    function _requireRegistered(address liquidToken) internal view {
        if (!_liquidRegistry.isRegistered(liquidToken)) {
            revert ILiquidAuctioneer.UnregisteredToken(liquidToken);
        }
    }

    // Errors defined in ILiquidAuctioneer interface

    /// @notice Bid on a CCA auction using a configured preset token->RARE route
    /// @dev This function supports three distinct bid paths:
    ///
///      **Path 1: Native ETH (tokenIn = address(0))**
///      - Deducts fee from ETH input (based on ethFeeBps)
///      - Sends fee to protocolFeeRecipient
///      - Swaps remaining ETH to RARE via Universal Router
///      - Submits RARE bid to auction
    ///
    ///      **Path 2: BASE_TOKEN (tokenIn = BASE_TOKEN)**
    ///      - Optimized path: user provides RARE directly (no swap needed)
    ///      - No fees deducted (fees only apply to ETH input)
    ///      - Sets up Permit2 approvals for auction to pull RARE
    ///      - Submits RARE bid to auction
    ///
    ///      **Path 3: Other ERC20 tokens**
    ///      - Pulls tokens from user (with fee-on-transfer check)
    ///      - Swaps tokens to RARE via Universal Router (no fee deduction)
    ///      - Sets up Permit2 approvals for auction to pull RARE
    ///      - Submits RARE bid to auction
    ///
    ///      Balance tracking: Uses balance deltas to measure swap outputs and prevent accounting errors.
    ///      For V4 single-hop swaps, tokens must be held by contract before swap (contractFunds = true).
    ///      For V2/V3 swaps, Permit2 pull pattern is used (contractFunds = false).
    /// @param liquidToken The LiquidGraduated token (auction must not be graduated)
    /// @param tokenIn Input token (address(0) for native ETH, BASE_TOKEN for direct RARE, or other ERC20)
    /// @param amountIn Input amount for ERC20 bids (ignored for native ETH bids - uses msg.value)
    /// @param maxPrice Maximum price willing to pay (0 = accept any price, uses auction MAX_BID_PRICE)
    /// @param bidOwner Address that will own the bid and receive filled tokens
    /// @param prevTickPrice Previous tick price for CCA (use floorPrice when maxPrice=0)
    /// @param minRareOut Minimum RARE amount to bid (slippage protection for swap)
    /// @param deadline Swap deadline timestamp
    /// @return bidId The CCA bid ID (used for exit/claim operations)
    function bid(
        address tokenIn,
        uint256 amountIn,
        address liquidToken,
        uint256 maxPrice,
        address bidOwner,
        uint256 prevTickPrice,
        uint256 minRareOut,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused returns (uint256 bidId) {
        if (liquidToken == address(0) || bidOwner == address(0))
            revert ILiquidRouter.AddressZero();
        _requireRegistered(liquidToken);
        if (minRareOut == 0) revert ILiquidRouter.InvalidAmount();

        if (tokenIn == BASE_TOKEN) {
            return _bidDirectRare(amountIn, liquidToken, maxPrice, bidOwner, prevTickPrice, minRareOut);
        }

        return _bidViaSwap(tokenIn, amountIn, liquidToken, maxPrice, bidOwner, prevTickPrice, minRareOut, deadline);
    }

    /// @dev PATH 2: Direct RARE bid (no swap needed)
    function _bidDirectRare(
        uint256 amountIn,
        address liquidToken,
        uint256 maxPrice,
        address bidOwner,
        uint256 prevTickPrice,
        uint256 minRareOut
    ) internal returns (uint256 bidId) {
        if (msg.value != 0) revert ILiquidRouter.InvalidAmount();
        if (amountIn == 0) revert ILiquidRouter.InvalidAmount();

        uint256 tokenBalanceBeforeRare = IERC20(BASE_TOKEN).balanceOf(address(this));
        IERC20(BASE_TOKEN).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 tokenBalanceAfterRare = IERC20(BASE_TOKEN).balanceOf(address(this));
        if (tokenBalanceAfterRare < tokenBalanceBeforeRare) {
            revert ILiquidAuctioneer.UnexpectedTokenBalance();
        }
        uint256 rareAmountInput = tokenBalanceAfterRare - tokenBalanceBeforeRare;
        if (rareAmountInput < minRareOut) revert SlippageExceeded();

        address auctionRareIn = ILiquidGraduated(liquidToken).auctionAddress();
        IERC20(BASE_TOKEN).forceApprove(PERMIT2, rareAmountInput);
        IPermit2(PERMIT2).approve(
            BASE_TOKEN,
            auctionRareIn,
            uint160(rareAmountInput),
            uint48(block.timestamp + 1 hours)
        );
        bidId = _submitBid(auctionRareIn, maxPrice, rareAmountInput, bidOwner, prevTickPrice);

        IERC20(BASE_TOKEN).forceApprove(PERMIT2, 0);
        IPermit2(PERMIT2).approve(BASE_TOKEN, auctionRareIn, 0, 0);
    }

    /// @dev PATH 1 (native ETH) and PATH 3 (ERC20): swap to RARE then bid
    function _bidViaSwap(
        address tokenIn,
        uint256 amountIn,
        address liquidToken,
        uint256 maxPrice,
        address bidOwner,
        uint256 prevTickPrice,
        uint256 minRareOut,
        uint256 deadline
    ) internal returns (uint256 bidId) {
        uint256 fee;
        uint256 swapAmountIn;
        uint256 ethBalanceBefore = address(this).balance;

        if (tokenIn == address(0)) {
            if (msg.value == 0) revert ILiquidRouter.InvalidAmount();
            fee = _calculateFee(msg.value, _ethFeeBps);
            swapAmountIn = msg.value - fee;
            ethBalanceBefore = address(this).balance - msg.value;
        } else {
            if (msg.value != 0) revert ILiquidRouter.InvalidAmount();
            if (amountIn == 0) revert ILiquidRouter.InvalidAmount();
            swapAmountIn = amountIn;
        }

        uint256 rareAmount = _swapToRare(tokenIn, amountIn, swapAmountIn, minRareOut, deadline);

        if (
            tokenIn == address(0) &&
            address(this).balance > ethBalanceBefore + fee
        ) {
            revert ILiquidAuctioneer.UnexpectedEthRefund();
        }

        address auction = ILiquidGraduated(liquidToken).auctionAddress();
        IERC20(BASE_TOKEN).forceApprove(PERMIT2, rareAmount);
        IPermit2(PERMIT2).approve(
            BASE_TOKEN,
            auction,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint160(rareAmount),
            uint48(block.timestamp + 1 hours)
        );
        bidId = _submitBid(auction, maxPrice, rareAmount, bidOwner, prevTickPrice);

        IERC20(BASE_TOKEN).forceApprove(PERMIT2, 0);
        IPermit2(PERMIT2).approve(BASE_TOKEN, auction, 0, 0);

        if (fee > 0) {
            _sendEthFee(fee);
        }
    }

    /// @dev Execute swap (tokenIn -> RARE) and return RARE received. Handles V4 contract-funds path.
    function _swapToRare(
        address tokenIn,
        uint256 amountIn,
        uint256 swapAmountIn,
        uint256 minRareOut,
        uint256 deadline
    ) internal returns (uint256 rareAmount) {
        (bytes memory commands, bytes[] memory inputs) = _buildTokenToRareRoute(
            tokenIn,
            swapAmountIn,
            minRareOut
        );
        bool contractFunds = _isContractFundsSwap(tokenIn);
        uint256 tokenBalanceBefore;

        if (contractFunds) {
            tokenBalanceBefore = IERC20(tokenIn).balanceOf(address(this));
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            uint256 tokenBalanceAfter = IERC20(tokenIn).balanceOf(address(this));
            if (tokenBalanceAfter < tokenBalanceBefore) {
                revert ILiquidAuctioneer.UnexpectedTokenBalance();
            }
            swapAmountIn = tokenBalanceAfter - tokenBalanceBefore;
            if (swapAmountIn != amountIn) {
                revert ILiquidAuctioneer.UnexpectedTokenBalance();
            }
            tokenBalanceBefore = tokenBalanceAfter;
        }

        uint256 rareBalanceBefore = IERC20(BASE_TOKEN).balanceOf(address(this));
        if (contractFunds) {
            IERC20(tokenIn).forceApprove(PERMIT2, swapAmountIn);
            IPermit2(PERMIT2).approve(
                tokenIn,
                universalRouter,
                uint160(
                    swapAmountIn > type(uint160).max
                        ? type(uint160).max
                        : swapAmountIn
                ),
                uint48(block.timestamp + 1 hours)
            );
        }
        _executeSwap(
            universalRouter,
            tokenIn == address(0) ? swapAmountIn : 0,
            commands,
            inputs,
            deadline,
            false
        );
        if (contractFunds) {
            if (
                IERC20(tokenIn).balanceOf(address(this)) !=
                tokenBalanceBefore - swapAmountIn
            ) {
                revert ILiquidAuctioneer.UnexpectedTokenBalance();
            }
            IERC20(tokenIn).forceApprove(PERMIT2, 0);
            IPermit2(PERMIT2).approve(tokenIn, universalRouter, 0, 0);
        }

        rareAmount = IERC20(BASE_TOKEN).balanceOf(address(this)) - rareBalanceBefore;
        if (rareAmount < minRareOut) revert SlippageExceeded();
    }

    /// @notice Configure a token->RARE route as a single-hop Uniswap V4 path.
    /// @dev The configured route is used by `bid()` whenever `tokenIn` matches this entry.
    ///      The route is intentionally treated as immutable until explicitly replaced.
    ///      We do not validate the hook contract shape here; route runtime failures will surface at swap time.
    /// @param tokenIn The token being sold into RARE (`address(0)` for native ETH)
    /// @param fee Uniswap V4 pool fee for the single-hop path
    /// @param tickSpacing Tick spacing required by the target V4 pool
    /// @param hooks Hook address to use on the V4 swap path (can be zero for no hook)
    function setTokenRouteV4(
        address tokenIn,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) external onlyOwner {
        if (tickSpacing <= 0) revert InvalidPresetRoute();
        TokenRoute storage route = tokenToRareRoutes[tokenIn];
        route.kind = RouteKind.V4_SINGLE;
        route.v4Fee = fee;
        route.v4TickSpacing = tickSpacing;
        route.v4Hooks = hooks;
        delete route.v3Path;
        delete route.v2Path;
        emit TokenRouteUpdated(tokenIn, RouteKind.V4_SINGLE);
    }

    /// @notice Configure a token->RARE route via a Uniswap V3 path.
    /// @dev Path is validated against expected start/end tokens (`tokenIn` and BASE_TOKEN).
    ///      This route supports multi-hop paths where each hop is encoded in `path`.
    /// @param tokenIn The token being sold into RARE (`address(0)` for native ETH)
    /// @param path Encoded Uniswap V3 path data (token + fee sequence)
    function setTokenRouteV3(
        address tokenIn,
        bytes calldata path
    ) external onlyOwner {
        if (!_isValidV3Path(tokenIn, path)) revert InvalidPresetRoute();
        TokenRoute storage route = tokenToRareRoutes[tokenIn];
        route.kind = RouteKind.V3_PATH;
        route.v3Path = path;
        delete route.v2Path;
        emit TokenRouteUpdated(tokenIn, RouteKind.V3_PATH);
    }

    /// @notice Configure a token->RARE route via a Uniswap V2 path.
    /// @dev Path is validated for endpoint correctness and non-zero addresses.
    ///      A call to `bid()` with this preset uses a V2 path and requires Permit2 pull flow.
    /// @param tokenIn The token being sold into RARE (`address(0)` for native ETH)
    /// @param path Ordered list of tokens for the V2 route (first token must be `tokenIn`, last must be BASE_TOKEN)
    function setTokenRouteV2(
        address tokenIn,
        address[] calldata path
    ) external onlyOwner {
        address expectedIn = tokenIn == address(0) ? WETH : tokenIn;
        if (!_isValidV2Path(expectedIn, path)) revert InvalidPresetRoute();
        TokenRoute storage route = tokenToRareRoutes[tokenIn];
        route.kind = RouteKind.V2_PATH;
        delete route.v2Path;
        for (uint256 i; i < path.length; ) {
            route.v2Path.push(path[i]);
            unchecked {
                ++i;
            }
        }
        delete route.v3Path;
        emit TokenRouteUpdated(tokenIn, RouteKind.V2_PATH);
    }

    /// @notice Clear a token->RARE preset route.
    /// @dev Removes all routing configuration for `tokenIn`; bids for this token will fail
    ///      until a new preset is configured.
    /// @param tokenIn The token to reset routing for (`address(0)` for native ETH)
    function removeTokenRoute(address tokenIn) external onlyOwner {
        delete tokenToRareRoutes[tokenIn];
        emit TokenRouteUpdated(tokenIn, RouteKind.NONE);
    }

    /// @notice Update the Universal Router used by `bid()` and exit flows.
    /// @dev Router address is used for all non-V4 swap legs and refund-to-ETH swaps.
    ///      Use `pause()` when rotating this value if required by governance.
    /// @param _universalRouter New Universal Router address
    function setUniversalRouter(address _universalRouter) external onlyOwner {
        if (_universalRouter == address(0)) revert ILiquidRouter.AddressZero();
        if (_universalRouter.code.length == 0) {
            revert ILiquidRouter.InvalidModule();
        }
        address oldRouter = universalRouter;
        universalRouter = _universalRouter;
        emit UniversalRouterUpdated(oldRouter, _universalRouter);
    }

    /// @notice Return the configured V2 token path for `tokenIn` bids.
    /// @param tokenIn Token used as source in preset route lookup (`address(0)` for native ETH)
    /// @return The raw V2 path (possibly empty if preset is not V2 or unset)
    function getTokenToRareV2Path(
        address tokenIn
    ) external view returns (address[] memory) {
        return tokenToRareRoutes[tokenIn].v2Path;
    }

    /// @notice Builds Universal Router commands/inputs for tokenIn -> RARE swap
    /// @dev Routes through configured preset (V4_SINGLE, V3_PATH, or V2_PATH).
    ///      For native ETH, prepends WRAP_ETH command. Handles both native ETH and ERC20 inputs.
    /// @param tokenIn Input token (address(0) for native ETH)
    /// @param amountIn Input amount
    /// @param minRareOut Minimum RARE output (slippage protection)
    /// @return commands Encoded Universal Router command bytes
    /// @return inputs Encoded Universal Router command inputs
    function _buildTokenToRareRoute(
        address tokenIn,
        uint256 amountIn,
        uint256 minRareOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        TokenRoute storage route = tokenToRareRoutes[tokenIn];
        if (route.kind == RouteKind.V4_SINGLE) {
            return
                _encodeV4TokenToRareRoute(tokenIn, amountIn, minRareOut, route);
        }
        if (route.kind == RouteKind.V3_PATH) {
            if (route.v3Path.length == 0) revert InvalidPresetRoute();
            if (tokenIn == address(0)) {
                commands = abi.encodePacked(CMD_WRAP_ETH, CMD_V3_SWAP_EXACT_IN);
                inputs = new bytes[](2);
                inputs[0] = abi.encode(ROUTER_ADDRESS, amountIn);
                inputs[1] = abi.encode(
                    MSG_SENDER,
                    amountIn,
                    minRareOut,
                    route.v3Path,
                    false
                );
            } else {
                commands = abi.encodePacked(CMD_V3_SWAP_EXACT_IN);
                inputs = new bytes[](1);
                inputs[0] = abi.encode(
                    MSG_SENDER,
                    amountIn,
                    minRareOut,
                    route.v3Path,
                    true
                );
            }
            return (commands, inputs);
        }
        if (route.kind == RouteKind.V2_PATH) {
            if (route.v2Path.length == 0) revert InvalidPresetRoute();
            if (tokenIn == address(0)) {
                commands = abi.encodePacked(CMD_WRAP_ETH, CMD_V2_SWAP_EXACT_IN);
                inputs = new bytes[](2);
                inputs[0] = abi.encode(ROUTER_ADDRESS, amountIn);
                inputs[1] = abi.encode(
                    MSG_SENDER,
                    amountIn,
                    minRareOut,
                    route.v2Path,
                    false
                );
            } else {
                commands = abi.encodePacked(CMD_V2_SWAP_EXACT_IN);
                inputs = new bytes[](1);
                inputs[0] = abi.encode(
                    MSG_SENDER,
                    amountIn,
                    minRareOut,
                    route.v2Path,
                    true
                );
            }
            return (commands, inputs);
        }
        revert InvalidPresetRoute();
    }

    /// @notice Encodes V4 swap route for tokenIn -> RARE via Universal Router
    /// @dev Creates a single-hop V4 swap path (tokenIn -> BASE_TOKEN) with configured pool parameters.
    ///      Uses SWAP_EXACT_IN, SETTLE_ALL, and TAKE_ALL actions. Handles native ETH (address(0)) as currencyIn.
    /// @param tokenIn Input token (address(0) for native ETH)
    /// @param amountIn Input amount
    /// @param minRareOut Minimum RARE output (slippage protection)
    /// @param route TokenRoute storage reference with V4 pool parameters
    /// @return commands Encoded Universal Router command bytes (CMD_V4_SWAP)
    /// @return inputs Encoded Universal Router command inputs (actions + params)
    function _encodeV4TokenToRareRoute(
        address tokenIn,
        uint256 amountIn,
        uint256 minRareOut,
        TokenRoute storage route
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        address currencyIn = tokenIn == address(0) ? address(0) : tokenIn;
        V4PathKey[] memory path = new V4PathKey[](1);
        path[0] = V4PathKey({
            intermediateCurrency: BASE_TOKEN,
            fee: route.v4Fee,
            tickSpacing: route.v4TickSpacing,
            hooks: route.v4Hooks,
            hookData: bytes("")
        });

        bytes memory actions = abi.encodePacked(
            bytes1(V4_SWAP_EXACT_IN),
            bytes1(V4_SETTLE_ALL),
            bytes1(V4_TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            currencyIn,
            path,
            _toUint128(amountIn),
            _toUint128(minRareOut)
        );
        params[1] = abi.encode(currencyIn, type(uint128).max);
        params[2] = abi.encode(BASE_TOKEN, _toUint128(minRareOut));

        commands = abi.encodePacked(CMD_V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    /// @notice Validates a Uniswap V3 path format
    /// @dev V3 path format: token(20 bytes) + [fee(3 bytes) + token(20 bytes)] * n hops.
    ///      Checks path length, format, and that it starts with expectedInput and ends with BASE_TOKEN.
    ///      For native ETH input, expects WETH as first token.
    /// @param tokenIn Input token (address(0) for native ETH)
    /// @param path Encoded V3 path bytes
    /// @return True if path is valid
    function _isValidV3Path(
        address tokenIn,
        bytes calldata path
    ) internal view returns (bool) {
        // V3 path is token(20) + [fee(3) + token(20)] * n
        if (path.length < 43) return false;
        if ((path.length - 20) % 23 != 0) return false;
        address firstToken;
        address lastToken;
        assembly {
            firstToken := shr(96, calldataload(path.offset))
            lastToken := shr(
                96,
                calldataload(add(path.offset, sub(path.length, 20)))
            )
        }
        address expectedInput = tokenIn == address(0) ? WETH : tokenIn;
        return firstToken == expectedInput && lastToken == BASE_TOKEN;
    }

    /// @notice Validates a Uniswap V2 path format
    /// @dev Checks that path has at least 2 tokens, starts with expectedInput, ends with BASE_TOKEN,
    ///      and contains no zero addresses.
    /// @param expectedInput Expected first token in path (WETH for native ETH, tokenIn for ERC20)
    /// @param path Array of token addresses representing the swap path
    /// @return True if path is valid
    function _isValidV2Path(
        address expectedInput,
        address[] calldata path
    ) internal view returns (bool) {
        if (path.length < 2) return false;
        if (path[0] != expectedInput || path[path.length - 1] != BASE_TOKEN) {
            return false;
        }
        for (uint256 i; i < path.length; ) {
            if (path[i] == address(0)) return false;
            unchecked {
                ++i;
            }
        }
        return true;
    }

    /// @notice Submits a bid to the CCA auction
    /// @dev When maxPrice is 0 (accept any), uses auction's MAX_BID_PRICE and floorPrice for prevTickPrice
    /// @param auction CCA auction address
    /// @param maxPrice Maximum price (0 = accept any)
    /// @param amount RARE amount to bid
    /// @param owner_ Bid owner (receives filled tokens)
    /// @param prevTickPrice Previous tick for CCA (use floorPrice when maxPrice=0)
    /// @return The bid ID
    function _submitBid(
        address auction,
        uint256 maxPrice,
        uint256 amount,
        address owner_,
        uint256 prevTickPrice
    ) internal returns (uint256) {
        // CCA requires maxPrice > clearingPrice. When maxPrice is 0 (accept any),
        // use MAX_BID_PRICE rounded to tick; use floorPrice as prevTickPrice
        uint256 effectiveMaxPrice;
        uint256 effectivePrevTickPrice;
        if (maxPrice == 0) {
            (
                effectiveMaxPrice,
                effectivePrevTickPrice
            ) = _auctionMaxBidPriceAndFloor(auction);
        } else {
            effectiveMaxPrice = maxPrice;
            effectivePrevTickPrice = prevTickPrice;
        }

        // Call CCA submitBid (low-level to handle different CCA interfaces)
        (bool ok, bytes memory data) = auction.call(
            abi.encodeWithSignature(
                "submitBid(uint256,uint128,address,uint256,bytes)",
                effectiveMaxPrice,
                amount > type(uint128).max
                    ? type(uint128).max
                    : _toUint128(amount),
                owner_,
                effectivePrevTickPrice,
                ""
            )
        );
        if (!ok) _revertBytes(data);
        return abi.decode(data, (uint256));
    }

    /// @notice Checks if swap should use contract-held funds vs Permit2 pull pattern
    /// @dev Universal Router supports two token transfer patterns:
    ///      - **Contract-held funds**: V4 single-hop swaps require tokens to be held by this contract
    ///        before swap execution. We pull tokens from user first, then Universal Router pulls from us.
    ///      - **Permit2 pull**: V2/V3 swaps use Permit2's pull pattern where Universal Router pulls
    ///        directly from user's Permit2 allowance. More gas-efficient for multi-hop routes.
    ///      Native ETH never uses contract funds (sent via msg.value).
    /// @param tokenIn Input token (address(0) for native ETH)
    /// @return True if swap requires contract-held funds (V4_SINGLE route), false for Permit2 pull (V2/V3 routes)
    function _isContractFundsSwap(
        address tokenIn
    ) internal view returns (bool) {
        if (tokenIn == address(0)) return false;

        TokenRoute storage route = tokenToRareRoutes[tokenIn];
        return route.kind == RouteKind.V4_SINGLE;
    }

    /// @notice Returns (maxValidPrice, floorPrice) for "accept any price" bids
    /// @dev When maxPrice is 0, calculates valid max price from auction's MAX_BID_PRICE rounded down to tick boundary.
    ///      Uses floorPrice as prevTickPrice since it's always an initialized tick. Reverts if auction calls fail.
    /// @param auction CCA auction address
    /// @return maxValidPrice MAX_BID_PRICE rounded down to tickSpacing boundary
    /// @return floorPrice_ Auction's floorPrice (always an initialized tick)
    function _auctionMaxBidPriceAndFloor(
        address auction
    ) internal view returns (uint256 maxValidPrice, uint256 floorPrice_) {
        // Read MAX_BID_PRICE from auction
        (bool ok, bytes memory data) = auction.staticcall(
            abi.encodeWithSignature("MAX_BID_PRICE()")
        );
        if (!ok || data.length < 32) revert NotGraduated();
        uint256 maxBidPrice = abi.decode(data, (uint256));

        // Round maxPrice down to tick boundary (CCA requirement)
        (ok, data) = auction.staticcall(
            abi.encodeWithSignature("tickSpacing()")
        );
        if (!ok || data.length < 32) revert NotGraduated();
        uint256 tickSpacing = abi.decode(data, (uint256));
        if (tickSpacing == 0) revert NotGraduated();
        maxValidPrice = maxBidPrice - (maxBidPrice % tickSpacing);

        // floorPrice is always an initialized tick - use as prevTickPrice
        (ok, data) = auction.staticcall(
            abi.encodeWithSignature("floorPrice()")
        );
        if (!ok || data.length < 32) revert NotGraduated();
        floorPrice_ = abi.decode(data, (uint256));
    }

    /// @notice Reverts with the given bytes as revert reason
    /// @param data Revert payload (selector + args)
    function _revertBytes(bytes memory data) internal pure {
        if (data.length > 0) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        revert ILiquidAuctioneer.CallFailed();
    }

    /// @notice Execute a Universal Router route.
    /// @param _universalRouter Address of Uniswap Universal Router.
    /// @param ethValue ETH value for the swap call.
    /// @param commands Encoded Universal Router command bytes.
    /// @param inputs Encoded inputs for each command.
    /// @param deadline Swap deadline timestamp.
    /// @param expectsEthOutput Whether the route is expected to return native ETH.
    function _executeSwap(
        address _universalRouter,
        uint256 ethValue,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 deadline,
        bool expectsEthOutput
    ) internal {
        if (block.timestamp > deadline) revert ILiquidRouter.DeadlineExpired();
        if (commands.length == 0) revert ILiquidRouter.InvalidRouteData();
        if (commands.length != inputs.length) revert CommandInputLengthMismatch();

        RoutePolicy.validateRoute(commands, inputs, expectsEthOutput);

        bytes memory routeData = abi.encodeWithSignature(
            "execute(bytes,bytes[],uint256)",
            commands,
            inputs,
            deadline
        );

        (bool success, bytes memory result) = _universalRouter.call{
            value: ethValue
        }(routeData);

        if (!success) {
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert ILiquidRouter.SwapFailed();
        }
    }

    /// @notice Calculate basis-point fee.
    function _calculateFee(
        uint256 amount,
        uint256 bps
    ) internal pure returns (uint256) {
        return (amount * bps) / 10_000;
    }

    /// @notice Sends ETH fee to protocolFeeRecipient. If send fails, ETH remains in contract (owner can rescue).
    function _sendEthFee(uint256 amount) internal {
        address to = _protocolFeeRecipient != address(0)
            ? _protocolFeeRecipient
            : owner();
        if (to == address(0) || amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) {
            // ETH stays in contract; owner can rescue via rescueETH
        }
    }

    /// @notice Safe cast to uint128 (clamps to max if overflow)
    function _toUint128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) return type(uint128).max;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }

    /// @notice Safe cast to uint64 (clamps to max if overflow)
    function _toUint64(uint256 x) internal pure returns (uint64) {
        if (x > type(uint64).max) return type(uint64).max;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(x);
    }

    /// @notice Exit a fully filled bid: CCA refunds RARE to bid owner, we swap to ETH and send to recipient
    /// @dev Caller must be bid owner. We pull refunded RARE from user, swap via Universal Router, send ETH.
    /// @param liquidToken The LiquidGraduated token
    /// @param bidId The CCA bid ID
    /// @param recipient ETH recipient
    /// @param minEthOut Minimum ETH out (slippage protection)
    /// @param commands Encoded Universal Router command bytes (RARE -> ETH)
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Swap deadline
    /// @return ethReceived ETH sent to recipient
    function exitBidToETH(
        address liquidToken,
        uint256 bidId,
        address recipient,
        uint256 minEthOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 ethReceived) {
        if (recipient == address(0)) revert ILiquidRouter.AddressZero();
        _requireRegistered(liquidToken);

        // Call CCA exitBid - refunds RARE to bid owner (msg.sender)
        address auction = ILiquidGraduated(liquidToken).auctionAddress();
        uint256 ownerRareBefore = IERC20(BASE_TOKEN).balanceOf(msg.sender);
        (bool ok, ) = auction.call(
            abi.encodeWithSignature("exitBid(uint256)", bidId)
        );
        if (!ok) revert NotGraduated();
        uint256 rareRefund = IERC20(BASE_TOKEN).balanceOf(msg.sender) -
            ownerRareBefore;
        if (rareRefund == 0) return 0;

        // Pull refund from user (they must have approved this contract)
        IERC20(BASE_TOKEN).safeTransferFrom(
            msg.sender,
            address(this),
            rareRefund
        );

        // Track balances as deltas (avoids counting pre-existing tokens/ETH)
        uint256 ethBefore = address(this).balance;
        uint256 rareBefore = IERC20(BASE_TOKEN).balanceOf(address(this));

        // Swap RARE -> ETH via Universal Router (uses Permit2)
        _approvePermit2ForRouter(rareRefund);
        _executeSwap(
            universalRouter,
            0,
            commands,
            inputs,
            deadline,
            true
        );
        _clearPermit2ForRouter();

        // Ensure all RARE we pulled was consumed (prevents partial swap exploits)
        if (
            IERC20(BASE_TOKEN).balanceOf(address(this)) !=
            rareBefore - rareRefund
        ) revert UnexpectedTokenBalance();

        // ETH received = balance delta
        ethReceived = address(this).balance - ethBefore;
        if (ethReceived < minEthOut) revert SlippageExceeded();

        if (ethReceived > 0) {
            (bool sent, ) = recipient.call{value: ethReceived}("");
            if (!sent) revert ILiquidRouter.EthTransferFailed();
        }
        return ethReceived;
    }

    /// @notice Exit a partially filled bid at clearing price boundary
    /// @dev Same flow as exitBidToETH but uses exitPartiallyFilledBid with checkpoint params
    /// @param liquidToken The LiquidGraduated token
    /// @param bidId The CCA bid ID
    /// @param lastFullyFilledCheckpointBlock Block of last fully filled checkpoint
    /// @param outbidBlock Block when bid was outbid
    /// @param recipient ETH recipient
    /// @param minEthOut Minimum ETH out (slippage protection)
    /// @param commands Encoded Universal Router command bytes (RARE -> ETH)
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Swap deadline
    /// @return ethReceived ETH sent to recipient
    function exitPartialBidToETH(
        address liquidToken,
        uint256 bidId,
        uint256 lastFullyFilledCheckpointBlock,
        uint256 outbidBlock,
        address recipient,
        uint256 minEthOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 ethReceived) {
        if (recipient == address(0)) revert ILiquidRouter.AddressZero();
        _requireRegistered(liquidToken);

        address auction = ILiquidGraduated(liquidToken).auctionAddress();
        uint256 ownerRareBefore = IERC20(BASE_TOKEN).balanceOf(msg.sender);
        (bool ok, ) = auction.call(
            abi.encodeWithSignature(
                "exitPartiallyFilledBid(uint256,uint64,uint64)",
                bidId,
                _toUint64(lastFullyFilledCheckpointBlock),
                _toUint64(outbidBlock)
            )
        );
        if (!ok) revert NotGraduated();
        uint256 rareRefund = IERC20(BASE_TOKEN).balanceOf(msg.sender) -
            ownerRareBefore;
        if (rareRefund == 0) return 0;

        IERC20(BASE_TOKEN).safeTransferFrom(
            msg.sender,
            address(this),
            rareRefund
        );

        // Track balances as deltas (avoids counting pre-existing tokens/ETH)
        uint256 ethBefore = address(this).balance;
        uint256 rareBefore = IERC20(BASE_TOKEN).balanceOf(address(this));

        // Swap RARE -> ETH via Universal Router (uses Permit2)
        _approvePermit2ForRouter(rareRefund);
        _executeSwap(
            universalRouter,
            0,
            commands,
            inputs,
            deadline,
            true
        );
        _clearPermit2ForRouter();

        // Ensure all RARE we pulled was consumed (prevents partial swap exploits)
        if (
            IERC20(BASE_TOKEN).balanceOf(address(this)) !=
            rareBefore - rareRefund
        ) revert UnexpectedTokenBalance();

        // ETH received = balance delta
        ethReceived = address(this).balance - ethBefore;
        if (ethReceived < minEthOut) revert SlippageExceeded();

        if (ethReceived > 0) {
            (bool sent, ) = recipient.call{value: ethReceived}("");
            if (!sent) revert ILiquidRouter.EthTransferFailed();
        }
        return ethReceived;
    }

    /// @notice Claim filled auction tokens after auction ends
    /// @dev Forwards to CCA claimTokens - bid owner receives LIQUID tokens
    /// @param liquidToken The LiquidGraduated token
    /// @param bidId The CCA bid ID
    function claimAuctionTokens(
        address liquidToken,
        uint256 bidId
    ) external nonReentrant whenNotPaused {
        _requireRegistered(liquidToken);
        address auction = ILiquidGraduated(liquidToken).auctionAddress();
        (bool ok, ) = auction.call(
            abi.encodeWithSignature("claimTokens(uint256)", bidId)
        );
        if (!ok) revert NotGraduated();
    }

    /// @notice For graduated tokens: anyone can call strategy.migrate() directly after auction ends.
    ///         This contract focuses on UX routing (bid, exitBidToETH) only.
    /// @dev Call ILBPStrategy(strategy).migrate() on the token's strategy to create the pool.

    /// @notice Sets up Permit2 approvals for Universal Router to pull RARE
    /// @dev Two-step approval: ERC20 approve Permit2, then Permit2 approves Universal Router.
    ///      Clamps amount to uint160.max if overflow (Permit2 limitation). Used for exitBidToETH swaps.
    /// @param amount RARE amount to approve
    function _approvePermit2ForRouter(uint256 amount) internal {
        IERC20(BASE_TOKEN).forceApprove(PERMIT2, amount);
        // Permit2 amount is uint160.
        uint160 permitAmount = amount > type(uint160).max
            ? type(uint160).max // forge-lint: disable-next-line(unsafe-typecast) -- amount clamped to uint160.max if needed
            : uint160(amount);
        IPermit2(PERMIT2).approve(
            BASE_TOKEN,
            universalRouter,
            permitAmount,
            uint48(block.timestamp + 1 hours)
        );
    }

    /// @notice Clears Permit2 approvals after swap
    /// @dev Cleans up both ERC20 and Permit2 approvals to prevent lingering permissions.
    ///      Called after exitBidToETH swap completes.
    function _clearPermit2ForRouter() internal {
        IERC20(BASE_TOKEN).forceApprove(PERMIT2, 0);
        IPermit2(PERMIT2).approve(BASE_TOKEN, universalRouter, 0, 0);
    }

    /// @notice Sets beneficiary for a Liquid token (receives creator fee share)
    /// @param token The Liquid token address
    /// @param beneficiary Beneficiary address
    function setBeneficiary(
        address token,
        address beneficiary
    ) external onlyOwner {
        _liquidRegistry.setBeneficiary(token, beneficiary);
    }

    /// @notice Read token beneficiary from registry.
    function tokenBeneficiaries(
        address token
    ) external view returns (address) {
        return _liquidRegistry.beneficiaryOf(token);
    }

    /// @notice Pauses all trading (bid, exitBidToETH, etc.)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses trading
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Rescue stuck ETH (emergency recovery)
    /// @dev Only callable by owner. Intended for accidentally sent ETH.
    /// @param to The recipient address
    /// @param amount The amount to rescue
    function rescueETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ILiquidRouter.AddressZero();
        if (amount == 0) revert ILiquidRouter.InvalidAmount();
        if (address(this).balance < amount)
            revert ILiquidRouter.InsufficientBalance();

        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert ILiquidRouter.EthTransferFailed();
        emit ILiquidAuctioneer.EthRescued(to, amount);
    }

    /// @notice Rescue stuck ERC20 tokens (emergency recovery)
    /// @dev Only callable by owner. Intended for accidentally sent tokens.
    /// @param token The ERC20 token to rescue
    /// @param to The recipient address
    /// @param amount The amount to rescue
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ILiquidRouter.AddressZero();
        if (amount == 0) revert ILiquidRouter.InvalidAmount();

        IERC20(token).safeTransfer(to, amount);
        emit ILiquidAuctioneer.TokensRescued(token, to, amount);
    }

    /// @notice Receives ETH from Universal Router during swaps (WETH unwrap)
    receive() external payable {}
}
