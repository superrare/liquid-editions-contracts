// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {IFeeDistributor} from "liquid-editions/interfaces/IFeeDistributor.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";

import {IPermit2} from "liquid-editions/interfaces/IPermit2.sol";
import {LiquidFeeLib} from "liquid-editions/LiquidFeeLib.sol";

/// @title LiquidRouter
/// @author SuperRare Labs
/// @notice A router contract that enables Liquid-style trading (buy/sell with fees) for any existing ERC20 token
/// @dev Routes swaps through Uniswap's Universal Router while collecting and distributing fees.
///      Fee split configuration is delegated to FeeDistributor and can be updated there.
///
/// ## Architecture Overview
/// LiquidRouter enables fee collection and distribution for any ERC20 token:
/// - Routes swaps through Uniswap's Universal Router (supports V2/V3/V4 and multi-hop routes)
/// - Collects trading fees (configurable via FeeDistributor.totalFeeBPS) and distributes them:
///   * 50/50 between beneficiary and protocol (with one beneficiary or two identical beneficiaries)
///   * 33/33/34 between beneficiaryA, beneficiaryB, and protocol (with two distinct beneficiaries in swap())
///   * 100% to protocol (if no beneficiary)
/// - Minimal on-chain state: token registration and beneficiary mapping via LiquidRegistry
/// - Fee split configuration is delegated to FeeDistributor
/// - Uses Permit2 for secure token approvals during sell operations
/// - Supports buy (ETH → token), sell (token → ETH), and swap (any → any via ETH midpoint)
///
/// ## Fee Flow
/// 1. Total fee (FeeDistributor.totalFeeBPS) is collected from the trade (ETH side)
/// 2. Fee split depends on beneficiary configuration:
///    - One beneficiary (or two identical): 50% beneficiary, 50% protocol
///    - Two distinct beneficiaries (swap only): 33% beneficiaryA, 33% beneficiaryB, 34% protocol
///    - No beneficiary: 100% protocol
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
/// - Failed fee transfers to beneficiary are absorbed (not reverted)
/// - Protocol fee transfer failure DOES revert (ensures fees aren't lost)
/// - Gas-limited external calls prevent griefing attacks
contract LiquidRouter is ILiquidRouter, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ============================================
    // CONFIG (mutable modules)
    // ============================================

    /// @notice Contract that owns fee policy + split execution.
    IFeeDistributor private _feeDistributor;

    /// @notice Contract that owns token->beneficiary mapping and token registration.
    ILiquidRegistry private _liquidRegistry;

    /// @notice Uniswap Permit2 contract address
    /// @dev Universal Router pulls tokens via Permit2, not directly.
    ///      This is the canonical Permit2 address (same on all EVM chains).
    ///      For sells, we must approve Permit2 so Universal Router can pull tokens.
    address internal constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ============================================
    // CONFIG (owner-editable + mutable policy)
    // ============================================

    /// @notice Uniswap Universal Router address
    /// @dev This is the swap execution engine. Can be updated by owner.
    ///      Universal Router supports multiple DEX protocols and complex multi-hop routes.
    ///      Different networks have different router addresses.
    address public universalRouter;

    // ============================================
    // STORAGE (mutable)
    // ============================================

    // ============================================
    // CONSTRUCTOR
    // ============================================

    function _initContract(
        address _universalRouter,
        IFeeDistributor feeDistributorModule,
        ILiquidRegistry liquidRegistryModule
    ) internal {
        if (_universalRouter == address(0)) {
            revert AddressZero();
        }
        if (address(feeDistributorModule) == address(0)) {
            revert AddressZero();
        }
        if (address(liquidRegistryModule) == address(0)) {
            revert AddressZero();
        }

        universalRouter = _universalRouter;
        _feeDistributor = feeDistributorModule;
        _liquidRegistry = liquidRegistryModule;
    }

    /// @notice Unified constructor for module-backed deployments.
    /// @param _owner Owner address (can transfer ownership via Ownable)
    /// @param _universalRouter Address of Uniswap's Universal Router
    /// @param _feeDistributorAddress FeeDistributor module address
    /// @param _liquidRegistryAddress LiquidRegistry module address
    constructor(
        address _owner,
        address _universalRouter,
        address _feeDistributorAddress,
        address _liquidRegistryAddress
    ) Ownable(_owner) {
        if (_owner == address(0)) {
            revert AddressZero();
        }
        if (_universalRouter == address(0)) {
            revert AddressZero();
        }
        if (_feeDistributorAddress == address(0)) {
            revert AddressZero();
        }
        if (_liquidRegistryAddress == address(0)) {
            revert AddressZero();
        }

        _initContract(
            _universalRouter,
            IFeeDistributor(_feeDistributorAddress),
            ILiquidRegistry(_liquidRegistryAddress)
        );
    }

    /// @notice Read the active fee distributor contract address.
    function feeDistributor() external view returns (address) {
        return address(_feeDistributor);
    }

    /// @notice Read the active liquid registry contract address.
    function liquidRegistry() external view returns (address) {
        return address(_liquidRegistry);
    }

    /// @notice Read token beneficiary from registry.
    function tokenBeneficiaries(
        address token
    ) external view returns (address) {
        return _liquidRegistry.beneficiaryOf(token);
    }

    /// @notice Set a new fee distributor module.
    function setFeeDistributor(address feeDistributorAddress) external onlyOwner {
        if (feeDistributorAddress == address(0)) revert AddressZero();
        if (feeDistributorAddress.code.length == 0) {
            revert InvalidModule();
        }
        address old = address(_feeDistributor);
        _feeDistributor = IFeeDistributor(feeDistributorAddress);
        emit FeeDistributorUpdated(old, feeDistributorAddress);
    }

    /// @notice Set a new liquid registry module.
    function setLiquidRegistry(address liquidRegistryAddress) external onlyOwner {
        if (liquidRegistryAddress == address(0)) revert AddressZero();
        if (liquidRegistryAddress.code.length == 0) {
            revert InvalidModule();
        }
        address old = address(_liquidRegistry);
        _liquidRegistry = ILiquidRegistry(liquidRegistryAddress);
        emit LiquidRegistryUpdated(old, liquidRegistryAddress);
    }

    // ============================================
    // TRADING FUNCTIONS
    // ============================================

    /// @notice Buy tokens with ETH
    /// @dev Fee is deducted from ETH input before swap
    /// @param token The ERC20 token to buy
    /// @param recipient The address to receive the tokens
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
    /// 5. Fee is distributed to beneficiary/protocol
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

        // Only registered tokens can be traded
        if (!_liquidRegistry.isRegistered(token)) {
            revert TokenNotAllowed(token);
        }

        // Fee is taken BEFORE the swap from the ETH input
        // This means user pays fee on their full ETH amount
        uint256 fee = LiquidFeeLib.calculateFee(
            msg.value,
            _feeDistributor.totalFeeBPS()
        );
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
        address beneficiary = _liquidRegistry.beneficiaryOf(token);
        (
            uint256 protocolFee,
            uint256 beneficiaryFeeA,
            uint256 beneficiaryFeeB
        ) = _feeDistributor.distributeFees{value: fee}(
                fee,
                beneficiary,
                beneficiary
            );
        uint256 beneficiaryFee = beneficiaryFeeA + beneficiaryFeeB;

        // Comprehensive event for off-chain indexing and analytics
        emit RouterBuy(
            token,
            msg.sender, // buyer
            recipient, // may differ from buyer (gift purchases, etc.)
            msg.value, // total ETH sent
            fee, // total fee collected
            ethForSwap, // ETH actually swapped
            tokensReceived,
            protocolFee,
            beneficiaryFee
        );

        return tokensReceived;
    }

    /// @notice Sell tokens for ETH
    /// @dev Fee is deducted from ETH output after swap
    /// @param token The ERC20 token to sell
    /// @param tokenAmount The amount of tokens to sell
    /// @param recipient The address to receive the ETH
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
    /// 8. Fee is distributed to beneficiary/protocol
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

        // Only registered tokens can be traded
        if (!_liquidRegistry.isRegistered(token)) {
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
            _feeDistributor.totalFeeBPS()
        );
        ethReceived = grossEthReceived - fee;

        // Slippage check: minEthOut is the expected GROSS output from the swap.
        // We internally calculate what the minimum NET should be after fees.
        // This simplifies client integration - they just pass quoted gross with slippage.
        uint256 minNetEthExpected = minEthOut -
            LiquidFeeLib.calculateFee(
                minEthOut,
                _feeDistributor.totalFeeBPS()
            );
        if (ethReceived < minNetEthExpected) revert SlippageExceeded();

        // Using low-level call to support smart contract recipients
        // Reverts entire transaction if transfer fails
        (bool success, ) = recipient.call{value: ethReceived}("");
        if (!success) revert EthTransferFailed();

        address beneficiary = _liquidRegistry.beneficiaryOf(token);
        (
            uint256 protocolFee,
            uint256 beneficiaryFeeA,
            uint256 beneficiaryFeeB
        ) = _feeDistributor.distributeFees{value: fee}(
                fee,
                beneficiary,
                beneficiary
            );
        uint256 beneficiaryFee = beneficiaryFeeA + beneficiaryFeeB;

        emit RouterSell(
            token,
            msg.sender, // seller
            recipient, // may differ from seller
            tokenAmount, // tokens sold
            grossEthReceived, // ETH from swap (before fee)
            fee, // total fee collected
            ethReceived, // ETH to user (after fee)
            protocolFee,
            beneficiaryFee
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

            // Only registered tokens can be traded
            if (!_liquidRegistry.isRegistered(tokenIn)) {
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
        uint256 fee = LiquidFeeLib.calculateFee(
            grossEth,
            _feeDistributor.totalFeeBPS()
        );
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

            // Only registered tokens can be traded
            if (!_liquidRegistry.isRegistered(tokenOut)) {
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
            ? _liquidRegistry.beneficiaryOf(tokenIn)
            : address(0);
        address beneficiaryOut = (tokenOut != address(0))
            ? _liquidRegistry.beneficiaryOf(tokenOut)
            : address(0);

        (
            uint256 protocolFee,
            uint256 beneficiaryFeeA,
            uint256 beneficiaryFeeB
        ) = _feeDistributor.distributeFees{value: fee}(
            fee,
            beneficiaryIn,
            beneficiaryOut
        );

        emit RouterSwap(
            tokenIn,
            tokenOut,
            msg.sender,
            recipient,
            leg1Commands.length == 0 ? msg.value : amountIn,
            grossEth,
            fee,
            amountOut,
            protocolFee,
            beneficiaryFeeA,
            beneficiaryFeeB
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

    /// @notice Quote the fee breakdown for a given total fee (single-beneficiary case only)
    /// @dev This function only handles the single-beneficiary scenario (50/50 split).
    ///      It delegates to FeeDistributor.quoteFeeBreakdown() which only supports 50/50 splits.
    ///      For swap operations with two distinct beneficiaries (33/33/34 split),
    ///      the actual fee distribution is handled internally by swap() using distributeFees().
    ///      This quote function is primarily useful for buy() and sell() operations.
    /// @param totalFee The total fee amount
    /// @return beneficiaryFee Fee to beneficiary (50% of totalFee)
    /// @return protocolFee Fee to protocol (50% of totalFee)
    function quoteFeeBreakdown(
        uint256 totalFee
    )
        external
        view
        returns (
            uint256 beneficiaryFee,
            uint256 protocolFee
        )
    {
        return _feeDistributor.quoteFeeBreakdown(totalFee);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================
    //
    // All admin functions are onlyOwner. Owner can be transferred via Ownable.
    // Consider using a multisig or timelock for production deployments.
    //
    // ## Registration
    // - Only tokens registered in LiquidRegistry can be traded
    // - Factory registers tokens directly with the registry at creation time
    // - registerToken() is for manual admin registration of tokens
    // - removeToken() deregisters from registry, blocking all trading

    /// @notice Register a token with its beneficiary (admin only)
    /// @param token The token address
    /// @param beneficiary The beneficiary address (receives "creator" fees)
    /// @dev Registers the token in LiquidRegistry. Only registered tokens can be traded.
    function registerToken(address token, address beneficiary) external onlyOwner {
        if (token == address(0)) revert AddressZero();
        if (beneficiary == address(0)) revert AddressZero();

        _liquidRegistry.setBeneficiary(token, beneficiary);

        emit TokenRegistered(token, beneficiary);
    }

    /// @notice Update Universal Router address
    /// @param _universalRouter New Universal Router address
    /// @dev Can only be called by owner. Used to migrate to a different router
    ///      if the upstream address changes.
    function setUniversalRouter(address _universalRouter) external onlyOwner {
        if (_universalRouter == address(0)) revert AddressZero();
        address oldUniversalRouter = universalRouter;
        universalRouter = _universalRouter;
        emit UniversalRouterUpdated(oldUniversalRouter, _universalRouter);
    }

    /// @notice Remove a token from the registry
    /// @dev Clears the beneficiary mapping, which deregisters the token and
    ///      blocks all trading for it through the router and auctioneer.
    /// @param token The token address
    function removeToken(address token) external onlyOwner {
        if (token == address(0)) revert AddressZero();

        _liquidRegistry.removeBeneficiary(token);

        emit TokenRemoved(token);
    }

    /// @notice Update a token's beneficiary
    /// @param token The token address
    /// @param newBeneficiary The new beneficiary address
    /// @dev Use this to change who receives beneficiary fees for a token.
    function updateBeneficiary(
        address token,
        address newBeneficiary
    ) external onlyOwner {
        if (token == address(0)) revert AddressZero();
        if (newBeneficiary == address(0)) revert AddressZero();

        address oldBeneficiary = _liquidRegistry.beneficiaryOf(token);
        _liquidRegistry.setBeneficiary(token, newBeneficiary);

        emit BeneficiaryUpdated(token, oldBeneficiary, newBeneficiary);
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

    /// @notice Distributes collected fees to beneficiary and protocol (single-beneficiary wrapper)
    /// @dev Internal helper used by buy() and sell() operations. Wraps FeeDistributor.distributeFees()
    ///      for the single-beneficiary case (50/50 split). Passes the same beneficiary address
    ///      as both beneficiaryA and beneficiaryB to FeeDistributor, which results in a 50/50 split.
    ///      Failed beneficiary transfers are absorbed by protocol (handled by FeeDistributor).
    /// @param _fee The total fee amount to distribute (must equal msg.value when called)
    /// @param _beneficiary The address of the token beneficiary (receives 50% of fee)
    /// @return protocolFee Actual protocol fee transferred (includes any failed beneficiary transfers)
    /// @return beneficiaryFee Actual beneficiary fee transferred (sum of beneficiaryFeeA and beneficiaryFeeB)
    function _disperseFees(
        uint256 _fee,
        address _beneficiary
    )
        internal
        returns (
            uint256 protocolFee,
            uint256 beneficiaryFee
        )
    {
        uint256 beneficiaryFeeA;
        uint256 beneficiaryFeeB;
        (
            protocolFee,
            beneficiaryFeeA,
            beneficiaryFeeB
        ) = _feeDistributor.distributeFees{value: _fee}(
            _fee,
            _beneficiary,
            _beneficiary
        );

        beneficiaryFee = beneficiaryFeeA + beneficiaryFeeB;
    }

    /// @notice Distributes fees with split beneficiaries for swap() operations
    /// @dev Internal helper used by swap() operation. Wraps FeeDistributor.distributeFees()
    ///      for the two-beneficiary case. Fee split depends on beneficiary configuration:
    ///      - Two distinct beneficiaries: 33% beneficiaryA, 33% beneficiaryB, 34% protocol
    ///      - One beneficiary (or two identical): 50% beneficiary, 50% protocol
    ///      - No beneficiary: 100% protocol
    ///      Failed beneficiary transfers are absorbed by protocol (handled by FeeDistributor).
    /// @param _fee The total fee amount to distribute (must equal msg.value when called)
    /// @param _beneficiaryA The first beneficiary address (tokenIn's beneficiary, address(0) if none)
    /// @param _beneficiaryB The second beneficiary address (tokenOut's beneficiary, address(0) if none)
    /// @return protocolFee Actual protocol fee transferred (includes any failed beneficiary transfers)
    /// @return beneficiaryFeeA Actual beneficiary fee transferred to beneficiaryA (0 if transfer failed)
    /// @return beneficiaryFeeB Actual beneficiary fee transferred to beneficiaryB (0 if transfer failed)
    function _disperseFeesSwap(
        uint256 _fee,
        address _beneficiaryA,
        address _beneficiaryB
    )
        internal
        returns (
            uint256 protocolFee,
            uint256 beneficiaryFeeA,
            uint256 beneficiaryFeeB
        )
    {
        return
            _feeDistributor.distributeFees{value: _fee}(
                _fee,
                _beneficiaryA,
                _beneficiaryB
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
