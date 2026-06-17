// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILiquidRouter} from "liquid-editions/interfaces/ILiquidRouter.sol";
import {ILiquidRegistry} from "liquid-editions/interfaces/ILiquidRegistry.sol";
import {IPermit2} from "liquid-editions/interfaces/IPermit2.sol";
import {RoutePolicy} from "liquid-editions/RoutePolicy.sol";

/// @title LiquidRouter
/// @author SuperRare Labs
/// @notice A router contract that enables Liquid-style trading for any registered ERC20 token.
/// @dev Routes swaps through Uniswap's Universal Router. Fees are no longer collected here;
///      they are skimmed at the V4 pool level by the LiquidGuard hook on every swap.
///
/// ## Architecture Overview
/// LiquidRouter is a pure routing layer:
/// - Routes swaps through Uniswap's Universal Router (supports V2/V3/V4 and multi-hop routes)
/// - Token registration and beneficiary mapping via LiquidRegistry
/// - Fee collection is handled entirely by the LiquidGuard V4 hook
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
contract LiquidRouter is ILiquidRouter, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ============================================
    // ERRORS (inline swap-path errors; shared behavior with old fee library names)
    // ============================================

    // ============================================
    // CONFIG
    // ============================================

    /// @notice Contract that owns token->beneficiary mapping and token registration.
    ILiquidRegistry private _liquidRegistry;

    /// @notice Uniswap Permit2 contract address
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ============================================
    // CONFIG (owner-editable)
    // ============================================

    /// @notice Uniswap Universal Router address
    address public universalRouter;

    /// @notice Whitelisted currency tokens (e.g. RARE, USDC) that can appear as swap endpoints
    mapping(address => bool) private _currencyWhitelist;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @param _owner Owner address
    /// @param _universalRouter Address of Uniswap's Universal Router
    /// @param _liquidRegistryAddress LiquidRegistry module address
    constructor(
        address _owner,
        address _universalRouter,
        address _liquidRegistryAddress
    ) Ownable(_owner) {
        if (_owner == address(0)) revert AddressZero();
        if (_universalRouter == address(0)) revert AddressZero();
        if (_universalRouter.code.length == 0) revert InvalidModule();
        if (_liquidRegistryAddress == address(0)) revert AddressZero();

        universalRouter = _universalRouter;
        _liquidRegistry = ILiquidRegistry(_liquidRegistryAddress);
    }

    /// @notice Read the active liquid registry contract address.
    function liquidRegistry() external view returns (address) {
        return address(_liquidRegistry);
    }

    /// @notice Check if a currency is whitelisted.
    function isCurrencyWhitelisted(address currency) external view returns (bool) {
        return _currencyWhitelist[currency];
    }

    /// @notice Set a new liquid registry module.
    function setLiquidRegistry(address liquidRegistryAddress) external onlyOwner {
        if (liquidRegistryAddress == address(0)) revert AddressZero();
        if (liquidRegistryAddress.code.length == 0) revert InvalidModule();
        address old = address(_liquidRegistry);
        _liquidRegistry = ILiquidRegistry(liquidRegistryAddress);
        emit LiquidRegistryUpdated(old, liquidRegistryAddress);
    }

    // ============================================
    // TRADING FUNCTIONS
    // ============================================

    /// @notice Buy tokens with ETH
    /// @dev Entire msg.value is routed to the swap. Fees are collected by LiquidGuard hook in RARE.
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
    /// 2. ETH is routed to Universal Router for the swap
    /// 3. Tokens are transferred to recipient
    /// 4. LiquidGuard hook automatically skims RARE fee during the V4 swap
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
        if (token == address(0)) revert AddressZero();
        if (recipient == address(0)) revert AddressZero();
        if (msg.value == 0) revert InvalidAmount();
        if (minTokensOut == 0) revert InvalidAmount();

        if (!_isAllowedToken(token)) {
            revert TokenNotAllowed(token);
        }

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        uint256 ethBalanceBefore = address(this).balance - msg.value;
        uint256 universalRouterEthBefore = universalRouter.balance;

        _executeSwap(universalRouter, msg.value, commands, inputs, deadline, false);

        // Ensure no ETH was refunded (enforces EXACT_INPUT routes)
        if (address(this).balance > ethBalanceBefore) {
            revert UnexpectedEthRefund();
        }
        _verifyUniversalRouterDidNotRetainEth(universalRouterEthBefore);

        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        tokensReceived = balanceAfter - balanceBefore;

        if (tokensReceived < minTokensOut) revert SlippageExceeded();

        _sendTokens(token, recipient, tokensReceived);

        emit RouterBuy(
            token,
            msg.sender,
            recipient,
            msg.value,
            0,         // ethFee: no longer applicable (fee skimmed in RARE by hook)
            msg.value, // ethSwapped: full amount goes to swap
            tokensReceived,
            0,         // protocolFee: not applicable here
            0          // beneficiaryFee: not applicable here
        );

        return tokensReceived;
    }

    /// @notice Sell tokens for ETH
    /// @dev All ETH output goes to recipient. Fees are collected by LiquidGuard hook in RARE.
    /// @param token The ERC20 token to sell
    /// @param tokenAmount The amount of tokens to sell
    /// @param recipient The address to receive the ETH
    /// @param minEthOut Minimum ETH expected from swap (slippage protection)
    /// @param commands Encoded Universal Router command bytes
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @return ethReceived The amount of ETH received
    function sell(
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 ethReceived) {
        if (token == address(0)) revert AddressZero();
        if (recipient == address(0)) revert AddressZero();
        if (tokenAmount == 0) revert InvalidAmount();
        if (minEthOut == 0) revert InvalidAmount();

        if (!_isAllowedToken(token)) {
            revert TokenNotAllowed(token);
        }

        uint256 tokenBalanceBefore = _pullTokens(token, tokenAmount);
        _approvePermit2(token, tokenAmount);

        uint256 ethBalanceBefore = address(this).balance;
        uint256 universalRouterEthBefore = universalRouter.balance;

        _executeSwap(universalRouter, 0, commands, inputs, deadline, true);

        _clearPermit2(token);
        _verifyTokensConsumed(token, tokenBalanceBefore, tokenAmount);
        _verifyUniversalRouterDidNotRetainEth(universalRouterEthBefore);

        uint256 ethBalanceAfter = address(this).balance;
        ethReceived = ethBalanceAfter - ethBalanceBefore;

        if (ethReceived < minEthOut) revert SlippageExceeded();

        (bool success, ) = recipient.call{value: ethReceived}("");
        if (!success) revert EthTransferFailed();

        emit RouterSell(
            token,
            msg.sender,
            recipient,
            tokenAmount,
            ethReceived,
            0,           // ethFee: not applicable
            ethReceived, // netEthReceived: full amount (no fee deducted here)
            0,           // protocolFee: not applicable
            0            // beneficiaryFee: not applicable
        );

        return ethReceived;
    }

    /// @notice Swap between any two assets using a single Universal Router route
    /// @dev Supports: ERC20->ERC20, ERC20->ETH, ETH->ERC20.
    ///      LiquidGuard hook skims RARE fees at pool level during route execution.
    ///      For direct ETH<>token trades, buy() or sell() can be lower gas.
    ///
    /// @param tokenIn Input token (address(0) for ETH)
    /// @param amountIn Input amount (ignored if ETH — uses msg.value)
    /// @param tokenOut Output token (address(0) for ETH)
    /// @param recipient Address to receive output
    /// @param minAmountOut Minimum final output
    /// @param commands Encoded Universal Router command bytes
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @return amountOut The amount of output received
    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        address recipient,
        uint256 minAmountOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (recipient == address(0)) revert AddressZero();
        if (minAmountOut == 0) revert InvalidAmount();

        bool isEthInput = tokenIn == address(0);
        bool isEthOutput = tokenOut == address(0);
        uint256 ethValue = isEthInput ? msg.value : 0;
        uint256 inputAmount = isEthInput ? msg.value : amountIn;
        uint256 universalRouterEthBefore = universalRouter.balance;

        uint256 tokenInBalanceBefore;
        if (isEthInput) {
            if (msg.value == 0) revert InvalidAmount();
        } else {
            if (amountIn == 0) revert InvalidAmount();
            if (msg.value != 0) revert UnexpectedMsgValue();
            if (!_isAllowedToken(tokenIn)) {
                revert TokenNotAllowed(tokenIn);
            }
            tokenInBalanceBefore = _pullTokens(tokenIn, amountIn);
            _approvePermit2(tokenIn, amountIn);
        }

        if (!isEthOutput && !_isAllowedToken(tokenOut)) {
            revert TokenNotAllowed(tokenOut);
        }

        if (isEthOutput) {
            uint256 ethBalanceBefore = address(this).balance - ethValue;
            _executeSwap(universalRouter, ethValue, commands, inputs, deadline, true);

            if (!isEthInput) {
                _clearPermit2(tokenIn);
                _verifyTokensConsumed(tokenIn, tokenInBalanceBefore, amountIn);
            }
            _verifyUniversalRouterDidNotRetainEth(universalRouterEthBefore);

            amountOut = address(this).balance - ethBalanceBefore;
            if (amountOut < minAmountOut) revert SlippageExceeded();

            (bool success, ) = recipient.call{value: amountOut}("");
            if (!success) revert EthTransferFailed();
        } else {
            uint256 tokenBefore = IERC20(tokenOut).balanceOf(address(this));
            uint256 expectedEthAfter = address(this).balance - ethValue;

            _executeSwap(universalRouter, ethValue, commands, inputs, deadline, false);

            if (!isEthInput) {
                _clearPermit2(tokenIn);
                _verifyTokensConsumed(tokenIn, tokenInBalanceBefore, amountIn);
            }

            if (address(this).balance > expectedEthAfter) {
                revert UnexpectedEthRefund();
            }
            _verifyUniversalRouterDidNotRetainEth(universalRouterEthBefore);

            uint256 tokenAfter = IERC20(tokenOut).balanceOf(address(this));
            amountOut = tokenAfter - tokenBefore;
            if (amountOut < minAmountOut) revert SlippageExceeded();

            _sendTokens(tokenOut, recipient, amountOut);
        }

        emit RouterSwap(
            tokenIn,
            tokenOut,
            msg.sender,
            recipient,
            inputAmount,
            ethValue,
            0,         // fee: not applicable
            amountOut,
            0,         // protocolFee: not applicable
            0,         // beneficiaryFeeA: not applicable
            0          // beneficiaryFeeB: not applicable
        );

        return amountOut;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @notice Add a currency to the whitelist (e.g. RARE, USDC)
    function addCurrency(address currency) external onlyOwner {
        if (currency == address(0)) revert AddressZero();
        _currencyWhitelist[currency] = true;
        emit CurrencyAdded(currency);
    }

    /// @notice Remove a currency from the whitelist
    function removeCurrency(address currency) external onlyOwner {
        if (currency == address(0)) revert AddressZero();
        _currencyWhitelist[currency] = false;
        emit CurrencyRemoved(currency);
    }

    /// @notice Update Universal Router address
    function setUniversalRouter(address _universalRouter) external onlyOwner {
        if (_universalRouter == address(0)) revert AddressZero();
        if (_universalRouter.code.length == 0) revert InvalidModule();
        address oldUniversalRouter = universalRouter;
        universalRouter = _universalRouter;
        emit UniversalRouterUpdated(oldUniversalRouter, _universalRouter);
    }

    /// @notice Pause the contract (emergency stop)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Rescue stuck ERC20 tokens (emergency recovery)
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert AddressZero();
        if (amount == 0) revert InvalidAmount();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    /// @notice Rescue stuck ETH (emergency recovery)
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

    /// @notice Check if a token is allowed (registered liquid edition or whitelisted currency)
    function _isAllowedToken(address token) internal view returns (bool) {
        return _liquidRegistry.isRegistered(token) || _currencyWhitelist[token];
    }

    /// @notice Execute a swap via Universal Router
    /// @param _universalRouter Address of Uniswap Universal Router
    /// @param ethValue ETH to send with the call
    /// @param commands Encoded Universal Router command bytes
    /// @param inputs Encoded Universal Router command inputs (one per command)
    /// @param deadline Transaction deadline timestamp
    /// @param expectsEthOutput True if this route must return native ETH to caller
    function _executeSwap(
        address _universalRouter,
        uint256 ethValue,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 deadline,
        bool expectsEthOutput
    ) internal {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (commands.length == 0) revert InvalidRouteData();
        if (commands.length != inputs.length) revert CommandInputLengthMismatch();

        RoutePolicy.validateRoute(commands, inputs, expectsEthOutput);

        bytes memory routeData = abi.encodeWithSignature(
            "execute(bytes,bytes[],uint256)",
            commands,
            inputs,
            deadline
        );

        (bool success, bytes memory result) = _universalRouter.call{value: ethValue}(routeData);

        if (!success) {
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert SwapFailed();
        }
    }

    /// @notice Pull ERC20 tokens from user with fee-on-transfer check
    function _pullTokens(address token, uint256 amount) internal returns (uint256 balanceBefore) {
        balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        uint256 tokensReceived = balanceAfter - balanceBefore;
        if (tokensReceived != amount) {
            revert FeeOnTransferDetected(amount, tokensReceived);
        }
    }

    /// @notice Set up Permit2 approvals for Universal Router
    function _approvePermit2(address token, uint256 amount) internal {
        // Permit2 amount is uint160.
        uint160 permitAmount = amount > type(uint160).max
            ? type(uint160).max
            : uint160(amount);

        IERC20(token).forceApprove(PERMIT2, amount);
        IPermit2(PERMIT2).approve(
            token,
            universalRouter,
            // forge-lint: disable-next-line(unsafe-typecast) -- amount clamped to uint160.max if needed
            permitAmount,
            uint48(block.timestamp + 1 hours)
        );
    }

    /// @notice Clear Permit2 approvals after swap
    function _clearPermit2(address token) internal {
        IERC20(token).forceApprove(PERMIT2, 0);
        IPermit2(PERMIT2).approve(token, universalRouter, 0, 0);
    }

    /// @notice Verify all pulled tokens were consumed by the swap
    function _verifyTokensConsumed(address token, uint256 balanceBefore, uint256 amountPulled) internal view {
        uint256 finalTokenBalance = IERC20(token).balanceOf(address(this));
        if (finalTokenBalance != balanceBefore) {
            uint256 leftover = finalTokenBalance > balanceBefore
                ? finalTokenBalance - balanceBefore
                : balanceBefore - finalTokenBalance;
            revert UnexpectedTokenRefund(amountPulled, leftover);
        }
    }

    /// @notice Verify ETH-funded routes do not increase the shared Universal Router's native ETH balance
    function _verifyUniversalRouterDidNotRetainEth(uint256 balanceBefore) internal view {
        if (universalRouter.balance > balanceBefore) {
            revert UnexpectedUniversalRouterEthBalance();
        }
    }

    /// @notice Transfer ERC20 tokens to recipient with fee-on-transfer check
    function _sendTokens(address token, address recipient, uint256 amount) internal {
        uint256 recipientBalanceBefore = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransfer(recipient, amount);
        uint256 recipientBalanceAfter = IERC20(token).balanceOf(recipient);

        uint256 recipientReceived = recipientBalanceAfter - recipientBalanceBefore;
        if (recipientReceived != amount) {
            revert FeeOnTransferDetected(amount, recipientReceived);
        }
    }

    // ============================================
    // RECEIVE FUNCTION
    // ============================================

    /// @notice Accept native ETH sent to this contract.
    /// @dev Needed for:
    ///      - refund/settlement paths from external router execution,
    ///      - and downstream protocol accounting hooks.
    ///      ETH does not participate in a direct protocol accounting path here; all V4 conversion proceeds
    ///      through FeeDistributor/notifyFee.
    receive() external payable {}
}
