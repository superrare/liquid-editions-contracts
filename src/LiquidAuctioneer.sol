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
/// @notice Router for CCA auction interactions: bid with ETH, exit/claim, trigger graduation
/// @dev Uses LiquidFeeLib for fee and swap logic. Bid ownership is non-custodial (bidOwner = user).
contract LiquidAuctioneer is
    ILiquidAuctioneer,
    ReentrancyGuard,
    Ownable,
    Pausable
{
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_FEE_BPS = 400;
    address private constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address public immutable UNIVERSAL_ROUTER;
    address public immutable PROTOCOL_FEE_RECIPIENT;
    address public immutable RARE_BURNER;
    /// @dev RARE token address (base token for pools)
    address public immutable BASE_TOKEN;
    uint256 public immutable RARE_BURN_FEE_BPS;
    uint256 public immutable PROTOCOL_FEE_BPS;
    uint256 public immutable REFERRER_FEE_BPS;

    mapping(address => address) public tokenBeneficiaries;

    /// @notice Creates LiquidAuctioneer with fee configuration
    /// @param _owner Owner address
    /// @param _universalRouter Uniswap Universal Router for swaps
    /// @param _protocolFeeRecipient Protocol fee recipient
    /// @param _rareBurner RARE burner contract
    /// @param _baseToken RARE token address
    /// @param _rareBurnFeeBPS RARE burn fee in BPS (must sum with others to 10000)
    /// @param _protocolFeeBPS Protocol fee in BPS
    /// @param _referrerFeeBPS Referrer fee in BPS
    constructor(
        address _owner,
        address _universalRouter,
        address _protocolFeeRecipient,
        address _rareBurner,
        address _baseToken,
        uint256 _rareBurnFeeBPS,
        uint256 _protocolFeeBPS,
        uint256 _referrerFeeBPS
    ) Ownable(_owner) {
        if (
            _owner == address(0) ||
            _universalRouter == address(0) ||
            _protocolFeeRecipient == address(0) ||
            _rareBurner == address(0) ||
            _baseToken == address(0)
        ) revert ILiquidRouter.AddressZero();
        if (_rareBurnFeeBPS + _protocolFeeBPS + _referrerFeeBPS != 10000)
            revert ILiquidRouter.InvalidFeeDistribution();

        UNIVERSAL_ROUTER = _universalRouter;
        PROTOCOL_FEE_RECIPIENT = _protocolFeeRecipient;
        RARE_BURNER = _rareBurner;
        BASE_TOKEN = _baseToken;
        RARE_BURN_FEE_BPS = _rareBurnFeeBPS;
        PROTOCOL_FEE_BPS = _protocolFeeBPS;
        REFERRER_FEE_BPS = _referrerFeeBPS;
    }

    // Errors defined in ILiquidAuctioneer interface

    /// @notice Bid on a CCA auction using ETH
    /// @dev Deducts 4% fee, swaps remainder to RARE via Universal Router, submits bid to CCA.
    ///      bidOwner receives the filled tokens; orderReferrer receives referrer fee.
    /// @param liquidToken The LiquidGraduated token (auction not yet graduated)
    /// @param maxPrice Maximum price willing to pay (0 = accept any)
    /// @param bidOwner Address that will own the bid and receive filled tokens
    /// @param orderReferrer Referrer address (receives referrer fee)
    /// @param prevTickPrice Previous tick price for CCA (use floorPrice when maxPrice=0)
    /// @param commands Encoded Universal Router command bytes (ETH -> RARE)
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Swap deadline
    /// @return bidId The CCA bid ID
    function bidWithETH(
        address liquidToken,
        uint256 maxPrice,
        address bidOwner,
        address orderReferrer,
        uint256 prevTickPrice,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused returns (uint256 bidId) {
        if (liquidToken == address(0) || bidOwner == address(0))
            revert ILiquidRouter.AddressZero();

        // Deduct 4% fee from ETH input
        uint256 fee = LiquidFeeLib.calculateFee(msg.value, TOTAL_FEE_BPS);
        uint256 ethForSwap = msg.value - fee;

        // Record ETH balance before swap (exclude msg.value to get baseline)
        uint256 ethBalanceBefore = address(this).balance - msg.value;

        // Swap ETH -> RARE via Universal Router (use balance delta to avoid counting pre-existing RARE)
        uint256 rareBalanceBefore = IERC20(BASE_TOKEN).balanceOf(address(this));
        LiquidFeeLib.executeSwap(
            UNIVERSAL_ROUTER,
            ethForSwap,
            commands,
            inputs,
            deadline,
            false
        );

        // SECURITY: Ensure no ETH was returned by the router (breaks fee accounting)
        if (address(this).balance > ethBalanceBefore + fee) {
            revert ILiquidAuctioneer.UnexpectedEthRefund();
        }

        uint256 rareAmount = IERC20(BASE_TOKEN).balanceOf(address(this)) -
            rareBalanceBefore;
        if (rareAmount == 0) revert NotGraduated();

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

        // Distribute fees (beneficiary, protocol, referrer, burn)
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
        return bidId;
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
    ///         This contract focuses on UX routing (bidWithETH, exitBidToETH) only.
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

    /// @notice Pauses all trading (bidWithETH, exitBidToETH, etc.)
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
        if (address(this).balance < amount) revert ILiquidRouter.InsufficientBalance();

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
