// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LiquidFeeLib} from "liquid-editions/LiquidFeeLib.sol";
import {ILiquidGraduated} from "liquid-editions/interfaces/ILiquidGraduated.sol";
import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {ILiquidAuctioneer} from "liquid-editions/interfaces/ILiquidAuctioneer.sol";
import {IPermit2} from "liquid-editions/interfaces/IPermit2.sol";

/// @title LiquidAuctioneer
/// @notice Router for CCA auction interactions: bid, exit/claim, trigger graduation
/// @dev Uses LiquidFeeLib for fee and swap logic. Bid ownership is non-custodial (bidOwner = user).
contract LiquidAuctioneer is
    ILiquidAuctioneer,
    ReentrancyGuard,
    Ownable,
    Pausable
{
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_FEE_BPS = LiquidFeeLib.TOTAL_FEE_BPS;
    address private constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address public UNIVERSAL_ROUTER;
    address public PROTOCOL_FEE_RECIPIENT;
    address public immutable RARE_BURNER;
    /// @dev RARE token address (base token for pools)
    address public immutable BASE_TOKEN;
    /// @dev canonical wrapped native token for this chain
    address public immutable WETH;
    uint256 public immutable RARE_BURN_FEE_BPS;
    uint256 public immutable PROTOCOL_FEE_BPS;
    uint256 public immutable REFERRER_FEE_BPS;

    struct TokenRoute {
        RouteKind kind;
        uint24 v4Fee;
        int24 v4TickSpacing;
        address v4Hooks;
        bytes v3Path;
        address[] v2Path;
    }

    mapping(address => address) public tokenBeneficiaries;
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

    /// @notice Creates LiquidAuctioneer with fee configuration
    /// @param _owner Owner address
    /// @param _universalRouter Uniswap Universal Router for swaps
    /// @param _protocolFeeRecipient Protocol fee recipient
    /// @param _rareBurner RARE burner contract
    /// @param _baseToken RARE token address
    /// @param _weth canonical wrapped native token for this chain
    /// @param _rareBurnFeeBPS RARE burn fee in BPS (must sum with others to 10000)
    /// @param _protocolFeeBPS Protocol fee in BPS
    /// @param _referrerFeeBPS Referrer fee in BPS
    constructor(
        address _owner,
        address _universalRouter,
        address _protocolFeeRecipient,
        address _rareBurner,
        address _baseToken,
        address _weth,
        uint256 _rareBurnFeeBPS,
        uint256 _protocolFeeBPS,
        uint256 _referrerFeeBPS
    ) Ownable(_owner) {
        if (
            _owner == address(0) ||
            _universalRouter == address(0) ||
            _protocolFeeRecipient == address(0) ||
            _rareBurner == address(0) ||
            _baseToken == address(0) ||
            _weth == address(0)
        ) revert ILiquidRouter.AddressZero();
        if (_rareBurnFeeBPS + _protocolFeeBPS + _referrerFeeBPS != 10000)
            revert ILiquidRouter.InvalidFeeDistribution();

        UNIVERSAL_ROUTER = _universalRouter;
        PROTOCOL_FEE_RECIPIENT = _protocolFeeRecipient;
        RARE_BURNER = _rareBurner;
        BASE_TOKEN = _baseToken;
        WETH = _weth;
        RARE_BURN_FEE_BPS = _rareBurnFeeBPS;
        PROTOCOL_FEE_BPS = _protocolFeeBPS;
        REFERRER_FEE_BPS = _referrerFeeBPS;

        // Safe default native ETH -> RARE route; owner can override via route setters.
        TokenRoute storage nativeRoute = tokenToRareRoutes[address(0)];
        nativeRoute.kind = RouteKind.V4_SINGLE;
        nativeRoute.v4Fee = 3000;
        nativeRoute.v4TickSpacing = 60;
        nativeRoute.v4Hooks = address(0);
    }

    // Errors defined in ILiquidAuctioneer interface

    /// @notice Bid on a CCA auction using a configured preset token->RARE route
    /// @dev For native ETH (tokenIn = address(0)), deducts 4% fee and distributes ETH fees.
    ///      For ERC20 token bids, fee distribution is skipped and amountIn is swapped as provided.
    /// @param liquidToken The LiquidGraduated token (auction not yet graduated)
    /// @param tokenIn Input token (address(0) for native ETH)
    /// @param amountIn Input amount for ERC20 bids (ignored for native ETH bids)
    /// @param maxPrice Maximum price willing to pay (0 = accept any)
    /// @param bidOwner Address that will own the bid and receive filled tokens
    /// @param orderReferrer Referrer address (receives referrer fee)
    /// @param prevTickPrice Previous tick price for CCA (use floorPrice when maxPrice=0)
    /// @param minRareOut Minimum RARE amount to bid (slippage protection)
    /// @param deadline Swap deadline
    /// @return bidId The CCA bid ID
    function bid(
        address tokenIn,
        uint256 amountIn,
        address liquidToken,
        uint256 maxPrice,
        address bidOwner,
        address orderReferrer,
        uint256 prevTickPrice,
        uint256 minRareOut,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused returns (uint256 bidId) {
        if (liquidToken == address(0) || bidOwner == address(0))
            revert ILiquidRouter.AddressZero();
        if (minRareOut == 0) revert ILiquidRouter.InvalidAmount();

        uint256 fee = 0;
        uint256 swapAmountIn;
        uint256 tokenBalanceBefore;
        uint256 ethBalanceBefore = address(this).balance;

        if (tokenIn == address(0)) {
            if (msg.value == 0) revert ILiquidRouter.InvalidAmount();
            // Deduct 4% fee from ETH input.
            fee = LiquidFeeLib.calculateFee(msg.value, TOTAL_FEE_BPS);
            swapAmountIn = msg.value - fee;
            // Exclude msg.value to get pre-call baseline.
            ethBalanceBefore = address(this).balance - msg.value;
        } else if (tokenIn == BASE_TOKEN) {
            // Optimized path: BASE token bids can use user-provided RARE directly.
            if (msg.value != 0) revert ILiquidRouter.InvalidAmount();
            if (amountIn == 0) revert ILiquidRouter.InvalidAmount();
            uint256 tokenBalanceBeforeRare = IERC20(tokenIn).balanceOf(address(this));
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            uint256 tokenBalanceAfterRare = IERC20(tokenIn).balanceOf(address(this));
            if (tokenBalanceAfterRare < tokenBalanceBeforeRare) {
                revert ILiquidAuctioneer.UnexpectedTokenBalance();
            }
            uint256 rareAmountInput = tokenBalanceAfterRare - tokenBalanceBeforeRare;
            // Route and swap are bypassed for BASE token bids.
            if (rareAmountInput < minRareOut) revert SlippageExceeded();

            // Get auction address and set up Permit2 for CCA to pull RARE
            address auctionRareIn = ILiquidGraduated(liquidToken).auctionAddress();
            IERC20(BASE_TOKEN).forceApprove(PERMIT2, rareAmountInput);
            IPermit2(PERMIT2).approve(
                BASE_TOKEN,
                auctionRareIn,
                uint160(rareAmountInput),
                uint48(block.timestamp + 1 hours)
            );
            bidId = _submitBid(
                auctionRareIn,
                maxPrice,
                rareAmountInput,
                bidOwner,
                prevTickPrice
            );

            // Clear Permit2 approvals
            IERC20(BASE_TOKEN).forceApprove(PERMIT2, 0);
            IPermit2(PERMIT2).approve(BASE_TOKEN, auctionRareIn, 0, 0);

            // Distribute fees for native ETH bids only (fee value is in ETH).
            if (fee > 0) {
                address beneficiary = tokenBeneficiaries[liquidToken];
                LiquidFeeLib.disperseFees(
                    fee,
                    orderReferrer,
                    beneficiary,
                    beneficiary,
                    PROTOCOL_FEE_RECIPIENT,
                    RARE_BURNER,
                    RARE_BURN_FEE_BPS,
                    PROTOCOL_FEE_BPS,
                    REFERRER_FEE_BPS
                );
            }
            return bidId;
        } else {
            if (msg.value != 0) revert ILiquidRouter.InvalidAmount();
            if (amountIn == 0) revert ILiquidRouter.InvalidAmount();
            swapAmountIn = amountIn;
        }
        (bytes memory commands, bytes[] memory inputs) = _buildTokenToRareRoute(
            tokenIn,
            swapAmountIn,
            minRareOut
        );
        bool contractFunds = _isContractFundsSwap(tokenIn);

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

        // Swap tokenIn -> RARE via Universal Router (use balance delta to avoid counting pre-existing RARE)
        uint256 rareBalanceBefore = IERC20(BASE_TOKEN).balanceOf(address(this));
        if (contractFunds) {
            IERC20(tokenIn).forceApprove(PERMIT2, swapAmountIn);
            IPermit2(PERMIT2).approve(
                tokenIn,
                UNIVERSAL_ROUTER,
                uint160(
                    swapAmountIn > type(uint160).max
                        ? type(uint160).max
                        : swapAmountIn
                ),
                uint48(block.timestamp + 1 hours)
            );
        }
        LiquidFeeLib.executeSwap(
            UNIVERSAL_ROUTER,
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
            IPermit2(PERMIT2).approve(tokenIn, UNIVERSAL_ROUTER, 0, 0);
        }

        // SECURITY: Ensure no ETH was returned by the router when fee accounting depends on ETH input.
        if (
            tokenIn == address(0) &&
            address(this).balance > ethBalanceBefore + fee
        ) {
            revert ILiquidAuctioneer.UnexpectedEthRefund();
        }

        uint256 rareAmount = IERC20(BASE_TOKEN).balanceOf(address(this)) -
            rareBalanceBefore;
        if (rareAmount < minRareOut) revert SlippageExceeded();

        // Get auction address and set up Permit2 for CCA to pull RARE
        address auction = ILiquidGraduated(liquidToken).auctionAddress();
        IERC20(BASE_TOKEN).forceApprove(PERMIT2, rareAmount);
        IPermit2(PERMIT2).approve(
            BASE_TOKEN,
            auction,
            // Permit2 amount is uint160; rareAmount from balance is bounded by token supply
            // forge-lint: disable-next-line(unsafe-typecast)
            uint160(rareAmount),
            uint48(block.timestamp + 1 hours)
        );
        // Submit bid to CCA (bidOwner receives filled tokens)
        bidId = _submitBid(
            auction,
            maxPrice,
            rareAmount,
            bidOwner,
            prevTickPrice
        );

        // Clear Permit2 approvals
        IERC20(BASE_TOKEN).forceApprove(PERMIT2, 0);
        IPermit2(PERMIT2).approve(BASE_TOKEN, auction, 0, 0);

        // Distribute fees for native ETH bids only (fee value is in ETH).
        if (fee > 0) {
            address beneficiary = tokenBeneficiaries[liquidToken];
            LiquidFeeLib.disperseFees(
                fee,
                orderReferrer,
                beneficiary,
                beneficiary,
                PROTOCOL_FEE_RECIPIENT,
                RARE_BURNER,
                RARE_BURN_FEE_BPS,
                PROTOCOL_FEE_BPS,
                REFERRER_FEE_BPS
            );
        }
        return bidId;
    }

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

    function removeTokenRoute(address tokenIn) external onlyOwner {
        delete tokenToRareRoutes[tokenIn];
        emit TokenRouteUpdated(tokenIn, RouteKind.NONE);
    }

    function setUniversalRouter(address _universalRouter) external onlyOwner {
        if (_universalRouter == address(0)) revert ILiquidRouter.AddressZero();
        address oldRouter = UNIVERSAL_ROUTER;
        UNIVERSAL_ROUTER = _universalRouter;
        emit UniversalRouterUpdated(oldRouter, _universalRouter);
    }

    function setProtocolFeeRecipient(
        address _protocolFeeRecipient
    ) external onlyOwner {
        if (_protocolFeeRecipient == address(0))
            revert ILiquidRouter.AddressZero();
        address oldRecipient = PROTOCOL_FEE_RECIPIENT;
        PROTOCOL_FEE_RECIPIENT = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdated(
            oldRecipient,
            _protocolFeeRecipient
        );
    }

    function getTokenToRareV2Path(
        address tokenIn
    ) external view returns (address[] memory) {
        return tokenToRareRoutes[tokenIn].v2Path;
    }

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

    function _isContractFundsSwap(
        address tokenIn
    ) internal view returns (bool) {
        if (tokenIn == address(0)) return false;

        TokenRoute storage route = tokenToRareRoutes[tokenIn];
        return route.kind == RouteKind.V4_SINGLE;
    }

    /// @notice Returns (maxValidPrice, floorPrice) for "accept any price" bids
    ///      maxValidPrice = MAX_BID_PRICE rounded down to tick boundary.
    ///      floorPrice is used as prevTickPrice since it's always an initialized tick.
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
        LiquidFeeLib.executeSwap(
            UNIVERSAL_ROUTER,
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
            if (!sent) revert LiquidFeeLib.EthTransferFailed();
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
        LiquidFeeLib.executeSwap(
            UNIVERSAL_ROUTER,
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
            if (!sent) revert LiquidFeeLib.EthTransferFailed();
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
    /// @param amount RARE amount to approve
    function _approvePermit2ForRouter(uint256 amount) internal {
        IERC20(BASE_TOKEN).forceApprove(PERMIT2, amount);
        // Permit2 amount is uint160.
        uint160 permitAmount = amount > type(uint160).max
            ? type(uint160).max // forge-lint: disable-next-line(unsafe-typecast) -- amount clamped to uint160.max if needed
            : uint160(amount);
        IPermit2(PERMIT2).approve(
            BASE_TOKEN,
            UNIVERSAL_ROUTER,
            permitAmount,
            uint48(block.timestamp + 1 hours)
        );
    }

    /// @notice Clears Permit2 approvals after swap
    function _clearPermit2ForRouter() internal {
        IERC20(BASE_TOKEN).forceApprove(PERMIT2, 0);
        IPermit2(PERMIT2).approve(BASE_TOKEN, UNIVERSAL_ROUTER, 0, 0);
    }

    /// @notice Sets beneficiary for a Liquid token (receives creator fee share)
    /// @param token The Liquid token address
    /// @param beneficiary Beneficiary address
    function setBeneficiary(
        address token,
        address beneficiary
    ) external onlyOwner {
        tokenBeneficiaries[token] = beneficiary;
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
        if (!ok) revert LiquidFeeLib.EthTransferFailed();
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
