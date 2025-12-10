// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILiquidRouter} from "./interfaces/ILiquidRouter.sol";
import {ILiquidFactory} from "./interfaces/ILiquidFactory.sol";
import {IRAREBurner} from "./interfaces/IRAREBurner.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";

/// @title LiquidRouter
/// @author SuperRare Labs
/// @notice A router contract that enables Liquid-style trading (buy/sell with fees) for ANY existing ERC20 token
/// @dev Routes swaps through Uniswap's Universal Router while collecting and distributing fees.
///      Fee configuration is pulled from LiquidFactory to stay in sync with Liquid tokens.
///
/// ## Architecture Overview
/// Unlike Liquid tokens (which are bonding-curve tokens with embedded trading), this router:
/// - Single contract handles ALL tokens (no factory/clones needed)
/// - Client passes token address + swap route at call time
/// - Minimal on-chain state: token-to-beneficiary mapping + optional allowlist
/// - Relies on Uniswap for price discovery and liquidity
///
/// ## Fee Flow
/// 1. TIER 1: Total fee (TOTAL_FEE_BPS) is collected from the trade (ETH side)
/// 2. TIER 2: Beneficiary gets their fixed cut first (BENEFICIARY_FEE_BPS)
/// 3. TIER 3: Remainder is split among protocol/referrer/RARE burn per factory config
/// 4. Any rounding dust goes to protocol to ensure exact accounting
///
/// ## Client Integration
/// Clients must:
/// 1. Use Universal Router's Quoter to determine expected output off-chain
/// 2. Encode the swap route using Universal Router's command format
/// 3. Pass the encoded routeData to buy()/sell()
/// 4. The routeData MUST use EXACT_INPUT for buys (no partial fills / ETH refunds)
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

    /// @notice Total trading fee in basis points (1% = 100 BPS)
    /// @dev This is the "TIER 1" fee - the gross amount collected from each trade.
    ///      For buys, fee is deducted from ETH input BEFORE the swap.
    ///      For sells, fee is deducted from ETH output AFTER the swap.
    uint256 public constant TOTAL_FEE_BPS = 300;

    /// @notice Beneficiary's share of total fees in basis points
    /// @dev This is the "TIER 2" fee - beneficiary gets their cut first from the total fee.
    ///      Can be any address. Can be updated by owner via updateBeneficiary().
    ///      The beneficiary is typically a project treasury or token deployer.
    ///      After beneficiary cut, the remainder goes to TIER 3 (protocol/referrer/burn split).
    uint256 public constant BENEFICIARY_FEE_BPS = 2500;

    /// @notice Gas limit for external fee transfers to prevent griefing
    /// @dev SECURITY: Prevents malicious recipients from consuming excessive gas.
    ///      50k gas is enough for simple ETH receives but prevents complex callbacks.
    ///      If a recipient's receive() uses more gas, the transfer fails silently
    ///      and the fee is redirected to the protocol instead.
    uint256 internal constant GAS_LIMIT_TRANSFER = 50000;

    /// @notice Uniswap Permit2 contract address
    /// @dev Universal Router pulls tokens via Permit2, not directly.
    ///      This is the canonical Permit2 address (same on all EVM chains).
    ///      For sells, we must approve Permit2 so Universal Router can pull tokens.
    address internal constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ============================================
    // STORAGE
    // ============================================

    /// @notice Uniswap Universal Router address
    /// @dev This is the swap execution engine. Can be updated by owner for router upgrades.
    ///      Universal Router supports multiple DEX protocols and complex multi-hop routes.
    ///      Different networks have different router addresses.
    address public universalRouter;

    /// @notice LiquidFactory address for shared configuration
    /// @dev Fee config is read from factory at runtime. Can be updated by owner.
    ///      This keeps router fees in sync with Liquid token fees automatically.
    ///      Reads: protocolFeeRecipient, rareBurner, rareBurnFeeBPS, protocolFeeBPS, referrerFeeBPS
    address public factory;

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

    /// @notice Deploys the LiquidRouter contract
    /// @param _universalRouter Address of Uniswap's Universal Router
    /// @param _factory Address of LiquidFactory for shared configuration
    /// @dev Both addresses are immutable after deployment.
    ///      Owner is set to msg.sender and can be transferred via Ownable.
    ///      Contract starts in unpaused state with allowlist disabled.
    constructor(
        address _universalRouter,
        address _factory
    ) Ownable(msg.sender) {
        // Both addresses are required - no recovery if set wrong (immutable)
        if (_universalRouter == address(0)) revert AddressZero();
        if (_factory == address(0)) revert AddressZero();

        universalRouter = _universalRouter;
        factory = _factory;

        // Note: allowlistEnabled defaults to false (permissionless mode)
        // Note: contract starts unpaused
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
    /// @param routeData Encoded Universal Router commands and inputs for the swap
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
    /// - routeData must be pre-encoded for ETH → token swap
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
        bytes calldata routeData,
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
        uint256 fee = _calculateFee(msg.value, TOTAL_FEE_BPS);
        uint256 ethForSwap = msg.value - fee;

        // Record balances before swap to calculate received amounts
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // IMPORTANT: Exclude msg.value which we just received but hasn't been "processed" yet
        // This gives us the "baseline" ETH balance to compare against after swap
        uint256 ethBalanceBefore = address(this).balance - msg.value;

        // Client provides pre-encoded Universal Router calldata
        // Route: ETH → token (potentially multi-hop via WETH → intermediate → token)
        _executeSwap(ethForSwap, routeData, deadline);

        // SECURITY: Ensure no ETH was returned by the router
        // If router returned ETH, it means EXACT_OUTPUT was used which breaks accounting:
        // - We calculated fee on full msg.value
        // - But only part of it was actually swapped
        // - Returned ETH would be stuck in contract
        // NOTE: Expected balance after swap = ethBalanceBefore + fee
        if (address(this).balance > ethBalanceBefore + fee) {
            revert UnexpectedEthRefund();
        }

        // Calculate the amount of tokens received
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        tokensReceived = balanceAfter - balanceBefore;

        // Revert if output is below user's minimum acceptable amount
        if (tokensReceived < minTokensOut) revert SlippageExceeded();

        // Reject fee-on-transfer tokens on outbound transfer to recipient
        // Measure recipient balance before/after to detect any transfer fees
        uint256 recipientBalanceBefore = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransfer(recipient, tokensReceived);
        uint256 recipientBalanceAfter = IERC20(token).balanceOf(recipient);

        uint256 recipientReceived = recipientBalanceAfter -
            recipientBalanceBefore;
        if (recipientReceived != tokensReceived) {
            revert FeeOnTransferDetected(tokensReceived, recipientReceived);
        }

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
    /// @param routeData Encoded Universal Router commands and inputs for the swap
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
    /// - routeData must be pre-encoded for token → ETH swap (unwrap WETH to ETH)
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
        bytes calldata routeData,
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

        // User must have called token.approve(router, amount) first
        // SafeERC20 handles tokens that don't return bool on transfer
        uint256 tokenBalanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        uint256 tokenBalanceAfter = IERC20(token).balanceOf(address(this));

        // Reject fee-on-transfer/deflationary tokens to keep swap amounts exact
        uint256 tokensReceived = tokenBalanceAfter - tokenBalanceBefore;
        if (tokensReceived != tokenAmount) {
            revert FeeOnTransferDetected(tokenAmount, tokensReceived);
        }

        // Grant Permit2 permission to pull tokens during swap
        // Universal Router pulls tokens via Permit2, which requires two approvals:
        // 1. ERC20 approve: Allow Permit2 to pull tokens from this contract
        // 2. Permit2 approve: Allow Universal Router to use Permit2 to pull tokens
        IERC20(token).forceApprove(PERMIT2, tokensReceived);

        // Set Permit2 allowance for Universal Router with a short expiration
        // Using uint48 max for amount since we control the exact tokenAmount via ERC20 approve
        // Expiration is deadline + 1 hour to be safe
        IPermit2(PERMIT2).approve(
            token,
            universalRouter,
            uint160(tokensReceived),
            uint48(deadline + 1 hours)
        );

        uint256 ethBalanceBefore = address(this).balance;

        // Client provides pre-encoded Universal Router calldata
        // Route: token → ETH (via token → WETH → unwrap, potentially multi-hop)
        // Pass 0 ETH value since we're selling tokens, not buying
        _executeSwap(0, routeData, deadline);

        // SECURITY: Remove leftover approvals to prevent further token pulls
        // Clear both ERC20 approval to Permit2 and Permit2 allowance to Universal Router
        IERC20(token).forceApprove(PERMIT2, 0);
        IPermit2(PERMIT2).approve(token, universalRouter, 0, 0);

        // Measure how much ETH the swap produced
        uint256 ethBalanceAfter = address(this).balance;
        uint256 grossEthReceived = ethBalanceAfter - ethBalanceBefore;

        // Fee is taken AFTER the swap from the ETH output
        // This means fee is based on actual swap proceeds
        uint256 fee = _calculateFee(grossEthReceived, TOTAL_FEE_BPS);
        ethReceived = grossEthReceived - fee;

        // Slippage check: minEthOut is the expected GROSS output from the swap.
        // We internally calculate what the minimum NET should be after fees.
        // This simplifies client integration - they just pass quoted gross with slippage.
        uint256 minNetEthExpected = minEthOut -
            _calculateFee(minEthOut, TOTAL_FEE_BPS);
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

    // ============================================
    // QUOTE FUNCTIONS
    // ============================================
    //
    // Fee calculation is simple: fee = amount × TOTAL_FEE_BPS / 10000
    // Clients can do this math themselves. These helpers show how fees are DISTRIBUTED.
    //
    // ## Client Fee Math (do this yourself)
    // For BUY:  ethFee = ethAmount × 300 / 10000, ethForSwap = ethAmount - ethFee
    // For SELL: ethFee = grossEth × 300 / 10000, netEth = grossEth - ethFee
    //
    // ## Typical Client Flow
    // 1. Calculate fee: ethForSwap = ethAmount × 9700 / 10000 (or grossEth for sell)
    // 2. Quote swap via Universal Router Quoter off-chain
    // 3. Apply slippage tolerance to quoted amount
    // 4. Execute buy()/sell()

    /// @notice Quote the fee breakdown for a given total fee
    /// @dev Fee percentages are read from LiquidFactory (may change over time)
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
    /// 3. remaining = totalFee - beneficiaryFee (split per factory config)
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
        // Pull current fee config from factory (may have been updated)
        ILiquidFactory f = ILiquidFactory(factory);
        uint256 rareBurnFeeBPS = f.rareBurnFeeBPS();
        uint256 _protocolFeeBPS = f.protocolFeeBPS();
        uint256 _referrerFeeBPS = f.referrerFeeBPS();

        // TIER 2: Beneficiary gets their fixed share first
        beneficiaryFee = _calculateFee(totalFee, BENEFICIARY_FEE_BPS);
        uint256 remainingFee = totalFee - beneficiaryFee;

        // TIER 3: Split remainder among burn/protocol/referrer
        // Each percentage is applied to remainingFee (not totalFee)
        burnFee = _calculateFee(remainingFee, rareBurnFeeBPS);
        referrerFee = _calculateFee(remainingFee, _referrerFeeBPS);
        protocolFee = _calculateFee(remainingFee, _protocolFeeBPS);

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

    /// @notice Update the Universal Router address
    /// @param _universalRouter The new Universal Router address
    /// @dev Use this when Uniswap deploys a new router version.
    ///      CAUTION: Verify the new router is legitimate before updating.
    function setUniversalRouter(address _universalRouter) external onlyOwner {
        if (_universalRouter == address(0)) revert AddressZero();
        address oldRouter = universalRouter;
        universalRouter = _universalRouter;
        emit UniversalRouterUpdated(oldRouter, _universalRouter);
    }

    /// @notice Update the LiquidFactory address
    /// @param _factory The new LiquidFactory address
    /// @dev Use this when deploying a new factory version.
    ///      CAUTION: Verify the new factory is legitimate before updating.
    function setFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert AddressZero();
        address oldFactory = factory;
        factory = _factory;
        emit FactoryUpdated(oldFactory, _factory);
    }

    /// @notice Pause the contract (emergency stop)
    /// @dev Only callable by owner. Prevents buy() and sell() operations.
    ///      Admin functions remain callable while paused.
    ///      Use for: security incidents, critical bugs, or planned maintenance.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    /// @dev Only callable by owner. Re-enables buy() and sell() operations.
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

    /// @notice Executes a swap via Universal Router
    /// @dev Validates deadline and routeData before executing
    /// @param ethValue ETH value to send with the call (0 for sell)
    /// @param routeData Encoded Universal Router commands and inputs
    /// @param deadline Transaction deadline timestamp
    ///
    /// ## routeData Format
    /// The routeData is the FULL calldata for Universal Router's execute() function:
    /// `execute(bytes commands, bytes[] inputs, uint256 deadline)`
    ///
    /// Commands are single bytes that specify operations (e.g., V3_SWAP_EXACT_IN, UNWRAP_WETH).
    /// Inputs are ABI-encoded parameters for each command.
    ///
    /// ## Example for Buy (ETH → Token):
    /// Commands: WRAP_ETH | V3_SWAP_EXACT_IN
    /// - WRAP_ETH: wraps ETH to WETH
    /// - V3_SWAP_EXACT_IN: swaps WETH for token via Uniswap V3
    ///
    /// ## Example for Sell (Token → ETH):
    /// Commands: V3_SWAP_EXACT_IN | UNWRAP_WETH
    /// - V3_SWAP_EXACT_IN: swaps token for WETH via Uniswap V3
    /// - UNWRAP_WETH: unwraps WETH to ETH (sent to this contract)
    ///
    /// ## Error Handling
    /// If the router reverts, we bubble up the original error message.
    /// This helps clients debug swap failures (e.g., "Too little received").
    function _executeSwap(
        uint256 ethValue,
        bytes calldata routeData,
        uint256 deadline
    ) internal {
        // Check deadline first to fail fast
        if (block.timestamp > deadline) revert DeadlineExpired();

        // Sanity check - empty routeData means client error
        if (routeData.length == 0) revert InvalidRouteData();

        // Execute the swap - routeData is passed directly as calldata
        // For buys: ethValue > 0 (ETH for swap)
        // For sells: ethValue = 0 (no ETH needed, swapping tokens)
        (bool success, bytes memory result) = universalRouter.call{
            value: ethValue
        }(routeData);

        if (!success) {
            // Bubble up the revert reason from Universal Router
            // This preserves error messages like "Too little received" or "Invalid path"
            if (result.length > 0) {
                // Assembly is needed to forward the revert reason
                // result is ABI-encoded: first 32 bytes = length, then data
                assembly {
                    // revert(pointer to data, length of data)
                    revert(add(result, 32), mload(result))
                }
            }
            // Fallback if no revert reason provided
            revert SwapFailed();
        }
    }

    /// @notice Calculates fee amount based on basis points
    /// @param amount The amount to calculate fee from
    /// @param bps The fee in basis points (1 BPS = 0.01%, 100 BPS = 1%)
    /// @return The calculated fee amount (rounds down due to integer division)
    ///
    /// ## Math
    /// fee = amount * bps / 10000
    /// Example: 1 ETH at 300 BPS = 1e18 * 300 / 10000 = 0.03 ETH
    ///
    /// ## Rounding
    /// Integer division truncates (rounds down), so fee is slightly less.
    /// Dust is handled separately and added to protocol fee.
    function _calculateFee(
        uint256 amount,
        uint256 bps
    ) internal pure returns (uint256) {
        return (amount * bps) / 10_000;
    }

    /// @notice Distributes collected fees to beneficiary, protocol, referrer, and RARE burn
    /// @param _fee The total fee amount to distribute
    /// @param _orderReferrer The address of the order referrer
    /// @param _beneficiary The address of the token beneficiary
    /// @return protocolFee Actual protocol fee transferred
    /// @return referrerFee Actual referrer fee transferred
    /// @return beneficiaryFee Actual beneficiary fee transferred
    /// @return rareBurnFee Actual RARE burn fee deposited
    ///
    /// ## Fee Distribution Architecture (Tiered)
    ///
    /// TIER 1: Total fee collected (TOTAL_FEE_BPS of trade) - already calculated before this function
    ///
    /// TIER 2: Beneficiary's fixed share (BENEFICIARY_FEE_BPS)
    /// - Beneficiary gets their cut first from total fee
    /// - See BENEFICIARY_FEE_BPS constant for current value
    ///
    /// TIER 3: Remainder split per factory config
    /// - Protocol: base protocol fee (configurable)
    /// - Referrer: incentive for order sourcing (configurable)
    /// - RARE Burn: deflationary mechanism (configurable)
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
        // =====================
        // STEP 1: Load Factory Config
        // =====================
        // Fee config is read at runtime so changes to factory propagate automatically
        ILiquidFactory f = ILiquidFactory(factory);
        address protocolFeeRecipient = f.protocolFeeRecipient();
        address rareBurner = f.rareBurner();
        uint256 rareBurnFeeBPS = f.rareBurnFeeBPS();
        uint256 _protocolFeeBPS = f.protocolFeeBPS();
        uint256 _referrerFeeBPS = f.referrerFeeBPS();

        // =====================
        // STEP 2: Check if referrer should receive separate transfer
        // =====================
        // If no referrer provided OR referrer is already protocol, skip separate transfer
        // This avoids two ETH transfers to the same address (gas optimization)
        bool skipReferrerTransfer = _orderReferrer == address(0) ||
            _orderReferrer == protocolFeeRecipient;

        // =====================
        // STEP 3: TIER 2 - Beneficiary Share
        // =====================
        // Beneficiary gets their fixed percentage first
        beneficiaryFee = _calculateFee(_fee, BENEFICIARY_FEE_BPS);
        uint256 remainingFee = _fee - beneficiaryFee;

        // =====================
        // STEP 4: TIER 3 - Split Remainder
        // =====================
        // Apply each percentage to the remaining fee (after beneficiary cut)
        rareBurnFee = _calculateFee(remainingFee, rareBurnFeeBPS);
        referrerFee = _calculateFee(remainingFee, _referrerFeeBPS);
        protocolFee = _calculateFee(remainingFee, _protocolFeeBPS);

        // =====================
        // STEP 5: Handle Dust
        // =====================
        // Due to integer division, sum of parts may be less than remainingFee
        // Add dust to protocol to ensure exact accounting (no ETH stuck in contract)
        uint256 totalRemainder = rareBurnFee + referrerFee + protocolFee;
        uint256 dust = remainingFee - totalRemainder;
        protocolFee += dust;

        // =====================
        // STEP 6: RARE Burn Deposit
        // =====================
        // Attempt to deposit to RARE burner contract
        // Non-reverting: if deposit fails, amount goes to protocol
        if (rareBurnFee > 0 && rareBurner != address(0)) {
            // Call the burner's depositForBurn() function
            (bool ok, ) = rareBurner.call{value: rareBurnFee}(
                abi.encodeWithSelector(IRAREBurner.depositForBurn.selector)
            );

            // Always emit for transparency (success or failure)
            emit BurnerDeposit(address(this), rareBurner, rareBurnFee, ok);

            if (!ok) {
                // FALLBACK: Burner failed, redirect to protocol
                // This ensures fees aren't lost if burner is paused/broken
                protocolFee += rareBurnFee;
                rareBurnFee = 0;
            }
        } else {
            // No burner configured, burn share goes to protocol
            protocolFee += rareBurnFee;
            rareBurnFee = 0;
        }

        // =====================
        // STEP 7: Track Running Totals
        // =====================
        // protocolTotal accumulates all fees that end up going to protocol
        // (base protocol fee + any failed transfers + dust)
        uint256 protocolTotal = protocolFee;

        // Track what was actually paid to each recipient
        uint256 beneficiaryPaid = beneficiaryFee;
        uint256 referrerPaid = referrerFee;

        // =====================
        // STEP 8: Beneficiary Transfer (Non-Reverting)
        // =====================
        if (_beneficiary != address(0) && beneficiaryFee > 0) {
            // Gas-limited call to prevent griefing
            (bool beneficiaryOk, ) = _beneficiary.call{
                value: beneficiaryFee,
                gas: GAS_LIMIT_TRANSFER
            }("");

            if (!beneficiaryOk) {
                // ABSORBED: Failed transfer goes to protocol
                protocolTotal += beneficiaryFee;
                beneficiaryPaid = 0;
                emit FeeTransferFailed(
                    _beneficiary,
                    beneficiaryFee,
                    "beneficiary"
                );
            }
        } else {
            // No beneficiary set, their share goes to protocol
            protocolTotal += beneficiaryFee;
            beneficiaryPaid = 0;
        }

        // =====================
        // STEP 9: Referrer Transfer (Non-Reverting)
        // =====================
        // Skip separate transfer if referrer is zero or equals protocol (gas optimization)
        if (skipReferrerTransfer) {
            // Referrer fee goes to protocol - no separate transfer needed
            protocolTotal += referrerFee;
            referrerPaid = 0;
        } else {
            // Gas-limited call to prevent griefing
            (bool referrerOk, ) = _orderReferrer.call{
                value: referrerFee,
                gas: GAS_LIMIT_TRANSFER
            }("");

            if (!referrerOk) {
                // ABSORBED: Failed transfer goes to protocol
                protocolTotal += referrerFee;
                referrerPaid = 0;
                emit FeeTransferFailed(_orderReferrer, referrerFee, "referrer");
            }
        }

        // =====================
        // STEP 10: Protocol Transfer (MUST SUCCEED)
        // =====================
        // This is the final catch-all transfer
        // If this fails, the trade MUST revert to prevent stuck funds
        (bool protocolOk, ) = protocolFeeRecipient.call{value: protocolTotal}(
            ""
        );
        if (!protocolOk) revert EthTransferFailed();

        // =====================
        // STEP 11: Emit Summary Event
        // =====================
        // Single event captures the final distribution for indexers
        emit RouterFees(
            _beneficiary,
            _orderReferrer,
            protocolFeeRecipient,
            rareBurnFee, // Actual amount burned (0 if failed)
            beneficiaryPaid, // Actual amount to beneficiary (0 if failed/none)
            referrerPaid, // Actual amount to referrer (0 if failed)
            protocolTotal // Total to protocol (includes absorbed failures)
        );

        // Return actual amounts distributed (for event emission in caller)
        return (protocolTotal, referrerPaid, beneficiaryPaid, rareBurnFee);
    }

    // ============================================
    // RECEIVE FUNCTION
    // ============================================

    /// @notice Receive ETH from Universal Router during sells
    /// @dev This is called when Universal Router unwraps WETH to ETH during sell().
    ///      The UNWRAP_WETH command sends native ETH to the recipient (this contract).
    ///
    /// ## Security Note
    /// Anyone can send ETH to this contract. That's fine because:
    /// 1. ETH received during trades is immediately distributed
    /// 2. Any "stuck" ETH can be recovered via rescueETH() by owner
    /// 3. Extra ETH doesn't affect trade accounting (we measure delta)
    receive() external payable {}
}
