// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {IPermit2} from "liquid-editions/interfaces/IPermit2.sol";
import {LiquidFeeLib} from "liquid-editions/LiquidFeeLib.sol";

/// @title LiquidRouter
/// @author SuperRare Labs
/// @notice A router contract that enables Liquid-style trading (buy/sell with fees) for any existing ERC20 token
/// @dev Routes swaps through Uniswap's Universal Router while collecting and distributing fees.
///      Fee configuration is immutable and set at deployment.
///
/// ## Architecture Overview
/// LiquidRouter enables fee collection and distribution for any ERC20 token:
/// - Routes swaps through Uniswap's Universal Router (supports V2/V3/V4 and multi-hop routes)
/// - Collects trading fees (4% TOTAL_FEE_BPS) and distributes them to beneficiary/protocol/referrer/RARE burn
/// - Minimal on-chain state: token-to-beneficiary mapping, optional allowlist
/// - Fee configuration is immutable (set in constructor)
/// - Uses Permit2 for secure token approvals during sell operations
/// - Supports buy (ETH → token), sell (token → ETH), and swap (any → any via ETH midpoint)
///
/// ## Fee Flow
/// 1. TIER 1: Total fee (TOTAL_FEE_BPS) is collected from the trade (ETH side)
/// 2. TIER 2: Beneficiary gets their fixed cut first (BENEFICIARY_FEE_BPS)
/// 3. TIER 3: Remainder is split among protocol/referrer/RARE burn per router config
/// 4. Any rounding dust goes to protocol to ensure exact accounting
///
/// ## Client Integration
/// Clients must:
/// 1. Use Universal Router's Quoter to determine expected output off-chain
/// 2. Encode the swap route using Universal Router's command format
/// 3. Pass `commands` and `inputs` to buy()/sell()/swap()
/// 4. Routes MUST use EXACT_INPUT semantics (no partial fills / refunds)
///
/// ## Security Model
/// - nonReentrant on all trading functions
/// - Pausable for emergency stops
/// - Failed fee transfers to beneficiary/referrer are absorbed (not reverted)
/// - Protocol fee transfer failure DOES revert (ensures fees aren't lost)
/// - Gas-limited external calls prevent griefing attacks
contract LiquidRouter is ILiquidRouter, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Total trading fee in basis points (4% = 400 BPS)
    /// @dev This is the "TIER 1" fee - the gross amount collected from each trade.
    ///      Increased from 3% to 4% to compensate for 0% LP fee (removed secondary rewards).
    ///      For buys, fee is deducted from ETH input BEFORE the swap.
    ///      For sells, fee is deducted from ETH output AFTER the swap.
    uint256 public constant TOTAL_FEE_BPS = 400;

    /// @notice Uniswap Permit2 contract address
    /// @dev Universal Router pulls tokens via Permit2, not directly.
    ///      This is the canonical Permit2 address (same on all EVM chains).
    ///      For sells, we must approve Permit2 so Universal Router can pull tokens.
    address internal constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ============================================
    // IMMUTABLES (set in constructor)
    // ============================================

    /// @notice Uniswap Universal Router address
    /// @dev This is the swap execution engine. Immutable after deployment.
    ///      Universal Router supports multiple DEX protocols and complex multi-hop routes.
    ///      Different networks have different router addresses.
    // forge-lint: disable-next-line(screaming-snake-case-immutable) -- camelCase used for public API consistency
    address public immutable universalRouter;

    /// @notice TIER 3 fee splits (must sum to 10000 BPS)
    /// @dev These fees are applied to the remainder after beneficiary takes their cut
    ///      Immutable after deployment - set in constructor.
    // forge-lint: disable-next-line(screaming-snake-case-immutable) -- camelCase used for public API consistency
    uint256 public immutable rareBurnFeeBPS;
    // forge-lint: disable-next-line(screaming-snake-case-immutable) -- camelCase used for public API consistency
    uint256 public immutable protocolFeeBPS;
    // forge-lint: disable-next-line(screaming-snake-case-immutable) -- camelCase used for public API consistency
    uint256 public immutable referrerFeeBPS;

    /// @notice Protocol fee recipient address
    /// @dev Receives protocol fees from trades. Immutable after deployment.
    // forge-lint: disable-next-line(screaming-snake-case-immutable) -- camelCase used for public API consistency
    address public immutable protocolFeeRecipient;

    /// @notice RARE burner contract address
    /// @dev Receives burn fees from trades. Immutable after deployment.
    // forge-lint: disable-next-line(screaming-snake-case-immutable) -- camelCase used for public API consistency
    address public immutable rareBurner;

    // ============================================
    // STORAGE (mutable)
    // ============================================

    /// @notice Mapping of token address to beneficiary (receives "creator" fees)
    /// @dev Beneficiary is optional - if not set, beneficiary fee goes to protocol.
    ///      Typically set to project treasury or token deployer address.
    ///      Can be updated by owner via updateBeneficiary().
    mapping(address => address) public tokenBeneficiaries;

    /// @notice Mapping of allowed tokens (if allowlist is enabled)
    /// @dev Only checked when allowlistEnabled is true.
    ///      When allowlist is disabled, ANY token can be traded through the router.
    ///      registerToken() automatically adds to allowlist.
    mapping(address => bool) public allowedTokens;

    /// @notice Whether the allowlist is enabled
    /// @dev When false: any token can be traded (permissionless mode)
    ///      When true: only tokens in allowedTokens mapping can be traded
    ///      GOTCHA: A token can be in allowedTokens but have no beneficiary set.
    bool public allowlistEnabled;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Constructs a new LiquidRouter contract
    /// @param _owner Owner address (can transfer ownership via Ownable)
    /// @param _universalRouter Address of Uniswap's Universal Router
    /// @param _protocolFeeRecipient Address that receives protocol fees
    /// @param _rareBurner Address of RARE burner contract
    /// @param _rareBurnFeeBPS RARE burn fee in basis points (must sum with other TIER 3 fees to 10000)
    /// @param _protocolFeeBPS Protocol fee in basis points (must sum with other TIER 3 fees to 10000)
    /// @param _referrerFeeBPS Referrer fee in basis points (must sum with other TIER 3 fees to 10000)
    /// @dev Contract starts in unpaused state with allowlist disabled.
    constructor(
        address _owner,
        address _universalRouter,
        address _protocolFeeRecipient,
        address _rareBurner,
        uint256 _rareBurnFeeBPS,
        uint256 _protocolFeeBPS,
        uint256 _referrerFeeBPS
    ) Ownable(_owner) {
        // Validate addresses
        if (_owner == address(0)) revert AddressZero();
        if (_universalRouter == address(0)) revert AddressZero();
        if (_protocolFeeRecipient == address(0)) revert AddressZero();
        if (_rareBurner == address(0)) revert AddressZero();

        // Validate TIER 3 fees sum to exactly 100%
        uint256 tier3Total = _rareBurnFeeBPS +
            _protocolFeeBPS +
            _referrerFeeBPS;
        if (tier3Total != 10000) {
            revert InvalidFeeDistribution();
        }

        // Set immutables
        universalRouter = _universalRouter;
        protocolFeeRecipient = _protocolFeeRecipient;
        rareBurner = _rareBurner;
        rareBurnFeeBPS = _rareBurnFeeBPS;
        protocolFeeBPS = _protocolFeeBPS;
        referrerFeeBPS = _referrerFeeBPS;

        // Note: allowlistEnabled defaults to false (permissionless mode)
        // Note: contract starts unpaused
    }

    /// @notice Beneficiary's share of total fees in basis points (TIER 2)
    /// @dev Matches LiquidFeeLib.BENEFICIARY_FEE_BPS for fee distribution
    function BENEFICIARY_FEE_BPS() external pure returns (uint256) {
        return LiquidFeeLib.BENEFICIARY_FEE_BPS;
    }

    // ============================================
    // TRADING FUNCTIONS
    // ============================================

    /// @notice Buy tokens with ETH
    /// @dev Fee is deducted from ETH input before swap
    /// @param token The ERC20 token to buy
    /// @param recipient The address to receive the tokens
    /// @param orderReferrer The address of the order referrer (receives referrer fee)
    /// @param minTokensOut Minimum tokens to receive (slippage protection)
    /// @param commands Encoded Universal Router command bytes
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @return tokensReceived The amount of tokens received
    ///
    /// ## Buy Flow
    /// 1. User sends ETH with the transaction
    /// 2. Fee (TOTAL_FEE_BPS) is calculated and held aside
    /// 3. Remaining ETH is swapped for tokens via Universal Router
    /// 4. Tokens are transferred to recipient
    /// 5. Fee is distributed to beneficiary/protocol/referrer/burn
    ///
    /// ## Client Requirements
    /// - commands/inputs must encode an ETH → token swap
    /// - MUST use EXACT_INPUT route type (entire ethForSwap amount is consumed)
    /// - Quote the expected output off-chain using Universal Router's Quoter
    /// - Set minTokensOut based on quoted output minus acceptable slippage
    ///
    /// ## GOTCHA: ETH Refund Check
    /// This function REVERTS if the router returns any ETH. This forces clients
    /// to use EXACT_INPUT routes where all ETH is consumed. EXACT_OUTPUT routes
    /// would return unused ETH which breaks our fee accounting.
    function buy(
        address token,
        address recipient,
        address orderReferrer,
        uint256 minTokensOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 tokensReceived)
    {
        // input validation
        if (token == address(0)) revert AddressZero();
        if (recipient == address(0)) revert AddressZero();
        if (minTokensOut == 0) revert InvalidAmount();
        // Note: msg.value of 0 is technically allowed but will fail at swap

        // Check allowlist if enabled (permissionless when disabled)
        if (allowlistEnabled && !allowedTokens[token]) {
            revert TokenNotAllowed(token);
        }

        // Fee is taken BEFORE the swap from the ETH input
        // This means user pays fee on their full ETH amount
        uint256 fee = LiquidFeeLib.calculateFee(msg.value, TOTAL_FEE_BPS);
        uint256 ethForSwap = msg.value - fee;

        // Record balances before swap to calculate received amounts
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // IMPORTANT: Exclude msg.value which we just received but hasn't been "processed" yet
        // This gives us the "baseline" ETH balance to compare against after swap
        uint256 ethBalanceBefore = address(this).balance - msg.value;

        // Route: ETH → token (potentially multi-hop via WETH → intermediate → token)
        LiquidFeeLib.executeSwap(
            universalRouter,
            ethForSwap,
            commands,
            inputs,
            deadline,
            false
        );

        // SECURITY: Ensure no ETH was returned by the router
        // If router returned ETH, it means EXACT_OUTPUT was used which breaks accounting:
        // - We calculated fee on full msg.value
        // - But only part of it was actually swapped
        // - Returned ETH would be stuck in contract
        // NOTE: Expected balance after swap = ethBalanceBefore + fee
        // EDGE CASE: A malicious actor could force-send ETH (via selfdestruct) to trigger this revert.
        //            This is a griefing attack that costs gas, so risk is limited.
        if (address(this).balance > ethBalanceBefore + fee) {
            revert UnexpectedEthRefund();
        }

        // Calculate the amount of tokens received
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        tokensReceived = balanceAfter - balanceBefore;

        // Revert if output is below user's minimum acceptable amount
        if (tokensReceived < minTokensOut) revert SlippageExceeded();

        // Send tokens to recipient (with fee-on-transfer check)
        _sendTokens(token, recipient, tokensReceived);

        // Fee distribution happens AFTER successful swap and token transfer
        address beneficiary = tokenBeneficiaries[token];
        (
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 beneficiaryFee,
            uint256 burnFee
        ) = _disperseFees(fee, orderReferrer, beneficiary);

        // Comprehensive event for off-chain indexing and analytics
        emit RouterBuy(
            token,
            msg.sender, // buyer
            recipient, // may differ from buyer (gift purchases, etc.)
            orderReferrer,
            msg.value, // total ETH sent
            fee, // total fee collected
            ethForSwap, // ETH actually swapped
            tokensReceived,
            protocolFee,
            referrerFee,
            beneficiaryFee,
            burnFee
        );

        return tokensReceived;
    }

    /// @notice Sell tokens for ETH
    /// @dev Fee is deducted from ETH output after swap
    /// @param token The ERC20 token to sell
    /// @param tokenAmount The amount of tokens to sell
    /// @param recipient The address to receive the ETH
    /// @param orderReferrer The address of the order referrer (receives referrer fee)
    /// @param minEthOut Minimum GROSS ETH expected from swap (before fees) - slippage protection
    /// @param commands Encoded Universal Router command bytes
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @return ethReceived The amount of ETH received (after fees)
    ///
    /// ## Sell Flow
    /// 1. User approves this contract to spend their tokens (separate tx)
    /// 2. Tokens are transferred from user to this contract
    /// 3. This contract sets up Permit2 approvals:
    ///    a. ERC20 approve Permit2 to pull tokens
    ///    b. Permit2.approve() to allow Universal Router to use Permit2
    /// 4. Tokens are swapped for ETH via Universal Router (which uses Permit2)
    /// 5. All approvals are cleared (security)
    /// 6. Fee (TOTAL_FEE_BPS) is calculated from ETH output and held aside
    /// 7. Net ETH is transferred to recipient
    /// 8. Fee is distributed to beneficiary/protocol/referrer/burn
    ///
    /// ## Client Requirements
    /// - User must have approved this contract for tokenAmount first
    /// - commands/inputs must encode a token → ETH swap
    /// - Quote the expected ETH output off-chain using Universal Router's Quoter
    /// - Set minEthOut to quoted gross output with your slippage tolerance applied
    /// - The contract internally adjusts for the TOTAL_FEE_BPS fee
    ///
    /// ## Slippage Protection
    /// minEthOut represents expected GROSS output (what the router returns).
    /// The contract internally calculates: minNetEth = minEthOut - fee(minEthOut)
    /// and checks that the user receives at least that amount.
    /// This simplifies client integration - just pass quoted output with slippage.
    function sell(
        address token,
        uint256 tokenAmount,
        address recipient,
        address orderReferrer,
        uint256 minEthOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 ethReceived) {
        // input validation
        if (token == address(0)) revert AddressZero();
        if (recipient == address(0)) revert AddressZero();
        if (tokenAmount == 0) revert InvalidAmount();
        if (minEthOut == 0) revert InvalidAmount();

        // Check allowlist if enabled (permissionless when disabled)
        if (allowlistEnabled && !allowedTokens[token]) {
            revert TokenNotAllowed(token);
        }

        // Pull tokens from user (with fee-on-transfer check)
        uint256 tokenBalanceBefore = _pullTokens(token, tokenAmount);

        // Set up Permit2 approvals
        _approvePermit2(token, tokenAmount);

        uint256 ethBalanceBefore = address(this).balance;

        // Route: token → ETH (via token → WETH → unwrap, potentially multi-hop)
        // Pass 0 ETH value since we're selling tokens, not buying
        LiquidFeeLib.executeSwap(
            universalRouter,
            0,
            commands,
            inputs,
            deadline,
            true
        );

        // Clear Permit2 approvals
        _clearPermit2(token);

        // Verify all tokens were consumed
        _verifyTokensConsumed(token, tokenBalanceBefore, tokenAmount);

        // Measure how much ETH the swap produced
        uint256 ethBalanceAfter = address(this).balance;
        uint256 grossEthReceived = ethBalanceAfter - ethBalanceBefore;

        // Fee is taken AFTER the swap from the ETH output
        // This means fee is based on actual swap proceeds
        uint256 fee = LiquidFeeLib.calculateFee(
            grossEthReceived,
            TOTAL_FEE_BPS
        );
        ethReceived = grossEthReceived - fee;

        // Slippage check: minEthOut is the expected GROSS output from the swap.
        // We internally calculate what the minimum NET should be after fees.
        // This simplifies client integration - they just pass quoted gross with slippage.
        uint256 minNetEthExpected = minEthOut -
            LiquidFeeLib.calculateFee(minEthOut, TOTAL_FEE_BPS);
        if (ethReceived < minNetEthExpected) revert SlippageExceeded();

        // Using low-level call to support smart contract recipients
        // Reverts entire transaction if transfer fails
        (bool success, ) = recipient.call{value: ethReceived}("");
        if (!success) revert EthTransferFailed();

        address beneficiary = tokenBeneficiaries[token];
        (
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 beneficiaryFee,
            uint256 burnFee
        ) = _disperseFees(fee, orderReferrer, beneficiary);

        emit RouterSell(
            token,
            msg.sender, // seller
            recipient, // may differ from seller
            orderReferrer,
            tokenAmount, // tokens sold
            grossEthReceived, // ETH from swap (before fee)
            fee, // total fee collected
            ethReceived, // ETH to user (after fee)
            protocolFee,
            referrerFee,
            beneficiaryFee,
            burnFee
        );

        return ethReceived;
    }

    /// @notice Swap between any two assets, always collecting fees in ETH
    /// @dev Executes two route legs with ETH fee harvest at the midpoint.
    ///      Supports: ERC20->ERC20, ERC20->ETH, ETH->ERC20.
    ///      For ETH-only trades, use buy() or sell() for lower gas.
    ///
    /// ## Swap Flow
    /// 1. LEG 1 (tokenIn -> ETH): Pull tokens, Permit2 setup, execute leg1
    /// 2. FEE HARVEST: Calculate fee from ETH midpoint amount
    /// 3. LEG 2 (ETH -> tokenOut): Execute leg2 with post-fee ETH
    /// 4. DISTRIBUTE: Split beneficiary fee between both tokens' beneficiaries
    ///
    /// ## Slippage Protection
    /// Only the final output is checked against minAmountOut.
    /// If leg1 gets a bad price, the final output will be low and fail the check.
    /// No midpoint slippage check — it would waste gas with no added safety.
    ///
    /// ## Client Integration
    /// 1. Quote leg1 off-chain to estimate ETH midpoint
    /// 2. Subtract 4% fee: ethForLeg2 = ethMidpoint * 9600 / 10000
    /// 3. Quote leg2 off-chain with ethForLeg2
    /// 4. Set minAmountOut from leg2 quote with slippage tolerance
    /// 5. Encode leg1 and leg2 as Universal Router commands/inputs
    /// 6. Both legs MUST use EXACT_INPUT routes
    ///
    /// @param tokenIn Input token (address(0) for ETH)
    /// @param amountIn Input amount (ignored if ETH — uses msg.value)
    /// @param tokenOut Output token (address(0) for ETH)
    /// @param recipient Address to receive output
    /// @param orderReferrer Address of the order referrer (receives referrer fee)
    /// @param minAmountOut Minimum final output after fees
    /// @param leg1Commands Route commands for tokenIn -> ETH (empty if input is ETH)
    /// @param leg1Inputs Route inputs for tokenIn -> ETH
    /// @param leg2Commands Route commands for ETH -> tokenOut (empty if output is ETH)
    /// @param leg2Inputs Route inputs for ETH -> tokenOut
    /// @param deadline Transaction deadline timestamp
    /// @return amountOut The amount of output received
    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        address recipient,
        address orderReferrer,
        uint256 minAmountOut,
        bytes calldata leg1Commands,
        bytes[] calldata leg1Inputs,
        bytes calldata leg2Commands,
        bytes[] calldata leg2Inputs,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused returns (uint256 amountOut) {
        // --- VALIDATION ---
        if (recipient == address(0)) revert AddressZero();
        if (minAmountOut == 0) revert InvalidAmount();
        if (leg1Commands.length == 0 && leg2Commands.length == 0) {
            revert BothLegsEmpty();
        }
        if (leg1Commands.length == 0 && leg1Inputs.length != 0) {
            revert InvalidRouteData();
        }
        if (leg2Commands.length == 0 && leg2Inputs.length != 0) {
            revert InvalidRouteData();
        }

        // --- LEG 1: tokenIn -> ETH ---
        uint256 grossEth;

        if (leg1Commands.length == 0) {
            // Input is ETH
            if (tokenIn != address(0)) revert InvalidRouteData();
            grossEth = msg.value;
        } else {
            // Input is ERC20
            if (tokenIn == address(0)) revert InvalidRouteData();
            if (amountIn == 0) revert InvalidAmount();
            if (msg.value != 0) revert UnexpectedMsgValue();

            // Allowlist check for input token
            if (allowlistEnabled && !allowedTokens[tokenIn]) {
                revert TokenNotAllowed(tokenIn);
            }

            // Pull tokens, approve, swap, cleanup
            uint256 tokenBalanceBefore = _pullTokens(tokenIn, amountIn);
            _approvePermit2(tokenIn, amountIn);

            uint256 ethBefore = address(this).balance;
            LiquidFeeLib.executeSwap(
                universalRouter,
                0,
                leg1Commands,
                leg1Inputs,
                deadline,
                true
            );

            _clearPermit2(tokenIn);
            _verifyTokensConsumed(tokenIn, tokenBalanceBefore, amountIn);

            grossEth = address(this).balance - ethBefore;
        }

        // --- FEE HARVEST (always ETH) ---
        uint256 fee = LiquidFeeLib.calculateFee(grossEth, TOTAL_FEE_BPS);
        uint256 ethForLeg2 = grossEth - fee;

        // --- LEG 2: ETH -> tokenOut ---
        if (leg2Commands.length == 0) {
            // Output is ETH
            if (tokenOut != address(0)) revert InvalidRouteData();
            amountOut = ethForLeg2;

            if (amountOut < minAmountOut) revert SlippageExceeded();

            (bool success, ) = recipient.call{value: amountOut}("");
            if (!success) revert EthTransferFailed();
        } else {
            // Output is ERC20
            if (tokenOut == address(0)) revert InvalidRouteData();

            // Allowlist check for output token
            if (allowlistEnabled && !allowedTokens[tokenOut]) {
                revert TokenNotAllowed(tokenOut);
            }

            uint256 tokenBefore = IERC20(tokenOut).balanceOf(address(this));

            // Capture expected balance: current balance minus the ETH we're about to spend
            uint256 expectedEthAfterLeg2 = address(this).balance - ethForLeg2;

            LiquidFeeLib.executeSwap(
                universalRouter,
                ethForLeg2,
                leg2Commands,
                leg2Inputs,
                deadline,
                false
            );

            // SECURITY: Ensure no ETH was refunded by Universal Router
            // Expected balance = pre-existing ETH + fee (ethForLeg2 was consumed)
            // If balance exceeds expected, router returned ETH which breaks accounting
            if (address(this).balance > expectedEthAfterLeg2) {
                revert UnexpectedEthRefund();
            }

            uint256 tokenAfter = IERC20(tokenOut).balanceOf(address(this));
            amountOut = tokenAfter - tokenBefore;

            if (amountOut < minAmountOut) revert SlippageExceeded();

            _sendTokens(tokenOut, recipient, amountOut);
        }

        // --- FEE DISTRIBUTION ---
        address beneficiaryIn = (tokenIn != address(0))
            ? tokenBeneficiaries[tokenIn]
            : address(0);
        address beneficiaryOut = (tokenOut != address(0))
            ? tokenBeneficiaries[tokenOut]
            : address(0);

        (
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 beneficiaryFeeA,
            uint256 beneficiaryFeeB,
            uint256 burnFee
        ) = _disperseFeesSwap(
                fee,
                orderReferrer,
                beneficiaryIn,
                beneficiaryOut
            );

        emit RouterSwap(
            tokenIn,
            tokenOut,
            msg.sender,
            recipient,
            orderReferrer,
            leg1Commands.length == 0 ? msg.value : amountIn,
            grossEth,
            fee,
            amountOut,
            protocolFee,
            referrerFee,
            beneficiaryFeeA,
            beneficiaryFeeB,
            burnFee
        );

        return amountOut;
    }

    // ============================================
    // QUOTE FUNCTIONS
    // ============================================
    //
    // Fee calculation is simple: fee = amount × TOTAL_FEE_BPS / 10000
    // Clients can do this math themselves. These helpers show how fees are DISTRIBUTED.
    //
    // ## Client Fee Math (do this yourself)
    // For BUY:  ethFee = ethAmount × 400 / 10000, ethForSwap = ethAmount - ethFee
    // For SELL: ethFee = grossEth × 400 / 10000, netEth = grossEth - ethFee
    //
    // ## Typical Client Flow
    // 1. Calculate fee: ethForSwap = ethAmount × 9600 / 10000 (or grossEth for sell)
    // 2. Quote swap via Universal Router Quoter off-chain
    // 3. Apply slippage tolerance to quoted amount
    // 4. Execute buy()/sell()/swap()

    /// @notice Quote the fee breakdown for a given total fee
    /// @dev Fee percentages are read from router immutables
    /// @param totalFee The total fee amount
    /// @return beneficiaryFee Fee to beneficiary
    /// @return protocolFee Fee to protocol
    /// @return referrerFee Fee to referrer
    /// @return burnFee Fee for RARE burn
    ///
    /// ## Fee Distribution Order
    /// 1. Beneficiary gets their fixed % first (TIER 2)
    /// 2. Remaining amount is split among protocol/referrer/burn (TIER 3)
    /// 3. Any rounding dust goes to protocol
    ///
    /// ## Fee Calculation Order
    /// 1. totalFee = tradeAmount × TOTAL_FEE_BPS / 10000
    /// 2. beneficiaryFee = totalFee × BENEFICIARY_FEE_BPS / 10000
    /// 3. remaining = totalFee - beneficiaryFee (split per router config)
    function quoteFeeBreakdown(
        uint256 totalFee
    )
        external
        view
        returns (
            uint256 beneficiaryFee,
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 burnFee
        )
    {
        // TIER 2: Beneficiary gets their fixed share first
        beneficiaryFee = LiquidFeeLib.calculateFee(
            totalFee,
            LiquidFeeLib.BENEFICIARY_FEE_BPS
        );
        uint256 remainingFee = totalFee - beneficiaryFee;

        // TIER 3: Split remainder among burn/protocol/referrer
        // Each percentage is applied to remainingFee (not totalFee)
        burnFee = LiquidFeeLib.calculateFee(remainingFee, rareBurnFeeBPS);
        referrerFee = LiquidFeeLib.calculateFee(remainingFee, referrerFeeBPS);
        protocolFee = LiquidFeeLib.calculateFee(remainingFee, protocolFeeBPS);

        // Handle rounding dust - send to protocol to ensure exact accounting
        // This can happen because BPS calculations truncate
        uint256 totalRemainder = burnFee + referrerFee + protocolFee;
        uint256 dust = remainingFee - totalRemainder;
        protocolFee += dust;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================
    //
    // All admin functions are onlyOwner. Owner can be transferred via Ownable.
    // Consider using a multisig or timelock for production deployments.
    //
    // ## Allowlist Behavior
    // - allowlistEnabled = false: ANY token can be traded (permissionless)
    // - allowlistEnabled = true: Only tokens in allowedTokens can be traded
    // - registerToken() adds to allowlist AND sets beneficiary
    // - removeToken() removes from allowlist AND clears beneficiary
    // - A token can be traded without a beneficiary (fees go to protocol)

    /// @notice Register a token with its beneficiary
    /// @param token The token address
    /// @param beneficiary The beneficiary address (receives "creator" fees)
    /// @dev Automatically adds token to allowlist. Call this for each token
    ///      you want to support with a specific beneficiary.
    function registerToken(
        address token,
        address beneficiary
    ) external onlyOwner {
        if (token == address(0)) revert AddressZero();
        if (beneficiary == address(0)) revert AddressZero();

        // Set beneficiary for fee distribution
        tokenBeneficiaries[token] = beneficiary;

        // Add to allowlist (effective when allowlistEnabled = true)
        allowedTokens[token] = true;

        emit TokenRegistered(token, beneficiary);
    }

    /// @notice Remove a token from the allowlist
    /// @dev Also clears the beneficiary mapping. When allowlist is enabled,
    ///      this effectively blocks trading for this token.
    /// @param token The token address
    function removeToken(address token) external onlyOwner {
        if (token == address(0)) revert AddressZero();

        // Remove from allowlist
        allowedTokens[token] = false;

        // Clear beneficiary (no dangling state)
        delete tokenBeneficiaries[token];

        emit TokenRemoved(token);
    }

    /// @notice Update a token's beneficiary
    /// @param token The token address
    /// @param newBeneficiary The new beneficiary address
    /// @dev Use this to change who receives beneficiary fees for a token.
    ///      Does NOT affect allowlist status.
    function updateBeneficiary(
        address token,
        address newBeneficiary
    ) external onlyOwner {
        if (token == address(0)) revert AddressZero();
        if (newBeneficiary == address(0)) revert AddressZero();

        address oldBeneficiary = tokenBeneficiaries[token];
        tokenBeneficiaries[token] = newBeneficiary;

        emit BeneficiaryUpdated(token, oldBeneficiary, newBeneficiary);
    }

    /// @notice Enable or disable the allowlist
    /// @param enabled Whether to enable the allowlist
    /// @dev When disabled (false): router is permissionless, any token works
    ///      When enabled (true): only registered tokens can be traded
    ///      Useful for gradually rolling out or restricting to vetted tokens
    function setAllowlistEnabled(bool enabled) external onlyOwner {
        allowlistEnabled = enabled;
        emit AllowlistEnabledUpdated(enabled);
    }

    /// @notice Pause the contract (emergency stop)
    /// @dev Only callable by owner. Prevents buy(), sell(), and swap() operations.
    ///      Admin functions remain callable while paused.
    ///      Use for: security incidents, critical bugs, or planned maintenance.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    /// @dev Only callable by owner. Re-enables buy(), sell(), and swap() operations.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Rescue stuck ERC20 tokens (emergency recovery)
    /// @dev Only callable by owner. Intended for accidentally sent tokens.
    /// @param token The ERC20 token to rescue
    /// @param to The recipient address
    /// @param amount The amount to rescue
    ///
    /// ## When to Use
    /// - User accidentally sends tokens directly to contract address
    /// - Swap leaves dust tokens behind
    /// - Any other case where tokens are stuck
    ///
    /// ## CAUTION
    /// This can withdraw ANY token including ones actively being traded.
    /// Use carefully and transparently.
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert AddressZero();
        if (amount == 0) revert InvalidAmount();

        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    /// @notice Rescue stuck ETH (emergency recovery)
    /// @dev Only callable by owner. Intended for accidentally sent ETH.
    /// @param to The recipient address
    /// @param amount The amount to rescue
    ///
    /// ## When to Use
    /// - User accidentally sends ETH directly to contract address
    /// - Fee distribution left dust ETH
    /// - Any other case where ETH is stuck
    ///
    /// ## CAUTION
    /// Should rarely have ETH stuck since all fee ETH is distributed.
    /// If ETH is present, investigate why before rescuing.
    function rescueETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert AddressZero();
        if (amount == 0) revert InvalidAmount();
        if (address(this).balance < amount) revert InsufficientBalance();

        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit EthRescued(to, amount);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /// @notice Pull ERC20 tokens from user with fee-on-transfer check
    /// @dev Reused by sell() and swap()
    /// @param token The token to pull
    /// @param amount The amount to pull
    /// @return balanceBefore The token balance before pulling
    function _pullTokens(
        address token,
        uint256 amount
    ) internal returns (uint256 balanceBefore) {
        balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        // Reject fee-on-transfer/deflationary tokens (balance delta must equal amount)
        uint256 tokensReceived = balanceAfter - balanceBefore;
        if (tokensReceived != amount) {
            revert FeeOnTransferDetected(amount, tokensReceived);
        }
    }

    /// @notice Set up Permit2 approvals for Universal Router
    /// @dev Reused by sell() and swap()
    /// @param token The token to approve
    /// @param amount The amount to approve
    function _approvePermit2(address token, uint256 amount) internal {
        // ERC20 approve Permit2, then Permit2 approves Universal Router (two-step for sells)
        IERC20(token).forceApprove(PERMIT2, amount);
        IPermit2(PERMIT2).approve(
            token,
            universalRouter,
            // forge-lint: disable-next-line(unsafe-typecast) -- amount fits uint160 (token amounts)
            uint160(amount),
            uint48(block.timestamp + 1 hours)
        );
    }

    /// @notice Clear Permit2 approvals after swap
    /// @dev Reused by sell() and swap()
    /// @param token The token to clear approvals for
    function _clearPermit2(address token) internal {
        IERC20(token).forceApprove(PERMIT2, 0);
        IPermit2(PERMIT2).approve(token, universalRouter, 0, 0);
    }

    /// @notice Verify all pulled tokens were consumed by the swap
    /// @dev Reused by sell() and swap()
    /// @param token The token to check
    /// @param balanceBefore The balance before pulling tokens
    /// @param amountPulled The amount that was pulled
    function _verifyTokensConsumed(
        address token,
        uint256 balanceBefore,
        uint256 amountPulled
    ) internal view {
        // After swap, balance should be balanceBefore (all pulled tokens consumed)
        // Mismatch indicates EXACT_OUTPUT or partial fill - would break accounting
        uint256 finalTokenBalance = IERC20(token).balanceOf(address(this));
        if (finalTokenBalance != balanceBefore) {
            uint256 leftover = finalTokenBalance > balanceBefore
                ? finalTokenBalance - balanceBefore
                : balanceBefore - finalTokenBalance;
            revert UnexpectedTokenRefund(amountPulled, leftover);
        }
    }

    /// @notice Transfer ERC20 tokens to recipient with fee-on-transfer check
    /// @dev Reused by buy() and swap()
    /// @param token The token to transfer
    /// @param recipient The recipient address
    /// @param amount The amount to transfer
    function _sendTokens(
        address token,
        address recipient,
        uint256 amount
    ) internal {
        uint256 recipientBalanceBefore = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransfer(recipient, amount);
        uint256 recipientBalanceAfter = IERC20(token).balanceOf(recipient);

        uint256 recipientReceived = recipientBalanceAfter -
            recipientBalanceBefore;
        if (recipientReceived != amount) {
            revert FeeOnTransferDetected(amount, recipientReceived);
        }
    }

    /// @notice Distributes collected fees to beneficiary, protocol, referrer, and RARE burn
    /// @dev Wrapper around LiquidFeeLib.disperseFees for single beneficiary (used by buy/sell)
    /// @param _fee The total fee amount to distribute
    /// @param _orderReferrer The address of the order referrer
    /// @param _beneficiary The address of the token beneficiary
    /// @return protocolFee Actual protocol fee transferred
    /// @return referrerFee Actual referrer fee transferred
    /// @return beneficiaryFee Actual beneficiary fee transferred (sum of A and B)
    /// @return rareBurnFee Actual RARE burn fee deposited
    function _disperseFees(
        uint256 _fee,
        address _orderReferrer,
        address _beneficiary
    )
        internal
        returns (
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 beneficiaryFee,
            uint256 rareBurnFee
        )
    {
        (
            uint256 p,
            uint256 r,
            uint256 bA,
            uint256 bB,
            uint256 burn
        ) = LiquidFeeLib.disperseFees(
                _fee,
                _orderReferrer,
                _beneficiary,
                _beneficiary,
                protocolFeeRecipient,
                rareBurner,
                rareBurnFeeBPS,
                protocolFeeBPS,
                referrerFeeBPS
            );
        return (p, r, bA + bB, burn);
    }

    /// @notice Distributes fees with split beneficiary for swap()
    /// @dev Core implementation that handles two beneficiaries (used by swap)
    /// @param _fee The total fee amount to distribute
    /// @param _orderReferrer The address of the order referrer
    /// @param _beneficiaryA The first beneficiary address (tokenIn's beneficiary)
    /// @param _beneficiaryB The second beneficiary address (tokenOut's beneficiary)
    /// @return protocolFee Actual protocol fee transferred
    /// @return referrerFee Actual referrer fee transferred
    /// @return beneficiaryFeeA Actual beneficiary fee transferred to beneficiaryA
    /// @return beneficiaryFeeB Actual beneficiary fee transferred to beneficiaryB
    /// @return rareBurnFee Actual RARE burn fee deposited
    ///
    /// ## Fee Distribution Architecture (Tiered)
    ///
    /// TIER 1: Total fee collected (TOTAL_FEE_BPS of trade) - already calculated before this function
    ///
    /// TIER 2: Beneficiary's fixed share (BENEFICIARY_FEE_BPS)
    /// - Beneficiary gets their cut first from total fee
    /// - For swap(): split 50/50 between beneficiaryA and beneficiaryB
    /// - If both are the same address, send full amount to that address
    /// - If only one is set, that one gets the full beneficiary share
    ///
    /// TIER 3: Remainder split per router config
    /// - Protocol: base protocol fee (immutable)
    /// - Referrer: incentive for order sourcing (immutable)
    /// - RARE Burn: deflationary mechanism (immutable)
    /// - Dust: any rounding remainder goes to protocol
    ///
    /// ## Non-Reverting Pattern (IMPORTANT)
    /// This function uses a "soft failure" pattern for non-critical transfers:
    /// - Beneficiary transfer fails → funds go to protocol (not lost)
    /// - Referrer transfer fails → funds go to protocol (not lost)
    /// - Burner deposit fails → funds go to protocol (not lost)
    /// - Protocol transfer fails → REVERTS THE TRADE (critical)
    ///
    /// Why? Malicious/broken recipients shouldn't block trades.
    /// Protocol is the "catch-all" - if we can't pay someone, protocol gets it.
    /// Protocol transfer is the only one that reverts because if IT fails, funds would be stuck.
    ///
    /// ## Gas Limiting (Security)
    /// External calls to beneficiary/referrer are gas-limited to 50k.
    /// This prevents griefing attacks where a malicious recipient consumes
    /// excessive gas to make trades expensive or fail.
    function _disperseFeesSwap(
        uint256 _fee,
        address _orderReferrer,
        address _beneficiaryA,
        address _beneficiaryB
    )
        internal
        returns (
            uint256 protocolFee,
            uint256 referrerFee,
            uint256 beneficiaryFeeA,
            uint256 beneficiaryFeeB,
            uint256 rareBurnFee
        )
    {
        return
            LiquidFeeLib.disperseFees(
                _fee,
                _orderReferrer,
                _beneficiaryA,
                _beneficiaryB,
                protocolFeeRecipient,
                rareBurner,
                rareBurnFeeBPS,
                protocolFeeBPS,
                referrerFeeBPS
            );
    }

    // ============================================
    // RECEIVE FUNCTION
    // ============================================

    /// @notice Receive ETH from Universal Router during sells and swaps
    /// @dev This is called when Universal Router unwraps WETH to ETH during sell() or swap().
    ///      The UNWRAP_WETH command sends native ETH to the recipient (this contract).
    ///
    /// ## Security Note
    /// Anyone can send ETH to this contract. That's fine because:
    /// 1. ETH received during trades is immediately distributed
    /// 2. Any "stuck" ETH can be recovered via rescueETH() by owner
    /// 3. Extra ETH doesn't affect trade accounting (we measure delta)
    receive() external payable {}
}
