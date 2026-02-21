// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {ILiquidBase} from "liquid-editions/interfaces/ILiquidBase.sol";
import {ILiquidFactory} from "liquid-editions/interfaces/ILiquidFactory.sol";
import {IRender} from "liquid-editions/interfaces/IRender.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Curve, Multicurve} from "doppler/libraries/Multicurve.sol";
import {Position} from "doppler/types/Position.sol";

import {QuoterRevert} from "@uniswap/v4-periphery/libraries/QuoterRevert.sol";

/*                                    
  _       _____  ____   _    _  _____  _____  
 | |     |_   _|/ __ \ | |  | ||_   _||  __ \ 
 | |       | | | |  | || |  | |  | |  | |  | |
 | |       | | | |  | || |  | |  | |  | |  | |
 | |____  _| |_| |__| || |__| | _| |_ | |__| |
 |______||_____|\___\_\ \____/ |_____||_____/ 

*/

/// @notice Thrown when curves array is empty
error ZeroCurves();
/// @notice Thrown when a token has already been initialized
error AlreadyInitialized();

/// @title LiquidMultiCurve
/// @notice A liquid edition token with multi-position concentrated liquidity (anti-sniping launch).
/// @dev Uses Doppler's Multicurve library to distribute liquidity across multiple positions instead of one.
///      Implements ILiquid + ILiquidBase identically to LiquidInstant for frontend compatibility.
contract LiquidMultiCurve is
    ILiquid,
    ILiquidBase,
    ERC20Upgradeable,
    ReentrancyGuardUpgradeable,
    IUnlockCallback
{
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using QuoterRevert for bytes;
    using SafeERC20 for IERC20;

    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000e18;
    uint256 internal constant POOL_LAUNCH_SUPPLY = 900_000e18;
    uint256 internal constant CREATOR_LAUNCH_REWARD = 100_000e18;
    uint24 internal constant LP_FEE = 0;

    address public factory;
    address public baseToken;
    address public tokenCreator;
    string public initialTokenUri;
    address public renderContract;

    PoolKey public poolKey;
    PoolId public poolId;
    address public poolManager;

    int24 public lpTickLower;
    int24 public lpTickUpper;
    uint128 public lpLiquidity; // Always 0 for multicurve (liquidity spread across positions)

    /// @notice Stored positions from initialization (needed for liquidity removal)
    Position[] internal _storedPositions;

    enum UnlockAction {
        INITIALIZE_POOL,
        QUOTE_SWAP_BUY,
        QUOTE_SWAP_SELL,
        REMOVE_LIQUIDITY
    }

    struct UnlockContext {
        UnlockAction action;
        bytes data;
    }

    bool private _unlockExpected;

    /// @notice Disables initialization on the implementation contract
    /// @dev Clones (EIP-1167) have separate storage and can still call initialize()
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a new Liquid token with multicurve liquidity (anti-sniping launch)
    /// @dev Called once by factory after cloning. Creates Uniswap V4 pool with liquidity distributed
    ///      across multiple concentrated positions per the provided curves.
    /// @param _creator The address of the liquid token creator (receives launch reward)
    /// @param _tokenUri The location of initial token metadata
    /// @param _name The liquid token name
    /// @param _symbol The liquid token symbol
    /// @param _minRequiredRareLiquidity Minimum RARE tokens required to bootstrap the pool
    /// @param _curves Curve configuration (tick ranges, positions) for multicurve deployment
    function initialize(
        address _creator,
        string memory _tokenUri,
        string memory _name,
        string memory _symbol,
        uint256 _minRequiredRareLiquidity,
        Curve[] calldata _curves
    ) external initializer {
        if (factory != address(0)) revert AlreadyInitialized();

        // Validate curves array is non-empty
        if (_curves.length == 0) revert ZeroCurves();

        // Store factory and pull config (baseToken, poolManager)
        factory = msg.sender;
        ILiquidFactory factoryContract = ILiquidFactory(factory);
        baseToken = factoryContract.baseToken();
        poolManager = factoryContract.poolManager();
        if (baseToken == address(0) || poolManager == address(0))
            revert AddressZero();

        // Validate token URI
        if (bytes(_tokenUri).length == 0) revert InvalidTokenURI();

        // Factory transfers RARE to this contract before calling initialize - verify we have enough
        uint256 rareBalance = IERC20(baseToken).balanceOf(address(this));
        if (rareBalance < _minRequiredRareLiquidity)
            revert RARELiquidityTooSmall();

        if (_creator == address(0)) revert AddressZero();

        // Initialize ERC20 and reentrancy guard
        __ERC20_init(_name, _symbol);
        __ReentrancyGuard_init();

        tokenCreator = _creator;
        initialTokenUri = _tokenUri;

        // Mint full supply and distribute: creator gets reward, rest goes to pool
        _mint(address(this), MAX_TOTAL_SUPPLY);
        _transfer(address(this), _creator, CREATOR_LAUNCH_REWARD);

        // Deploy pool with multicurve liquidity (multiple concentrated positions)
        _deployPool(rareBalance, _curves);
    }

    /// @notice Burns tokens from caller's balance
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external nonReentrant {
        _burn(msg.sender, amount);
    }

    /// @notice Overrides ERC20 _update to emit enhanced LiquidTransfer event
    /// @param from Sender address
    /// @param to Recipient address
    /// @param value Amount transferred
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        super._update(from, to, value);
        emit LiquidTransfer(
            from,
            to,
            value,
            balanceOf(from),
            balanceOf(to),
            totalSupply()
        );
    }

    /// @notice Returns token metadata URI (ERC-1046 compatible)
    /// @dev Checks render contract first if set, falls back to initialTokenUri
    function tokenURI() external view returns (string memory) {
        if (renderContract != address(0)) {
            try IRender(renderContract).tokenURI() returns (string memory uri) {
                if (bytes(uri).length > 0) return uri;
            } catch {}
            try IRender(renderContract).tokenURI(uint256(0)) returns (
                string memory uri
            ) {
                if (bytes(uri).length > 0) return uri;
            } catch {}
        }
        return initialTokenUri;
    }

    /// @notice Sets the render contract for dynamic metadata (token creator only)
    /// @param _renderContract Address of render contract (or address(0) to clear)
    function setRenderContract(address _renderContract) external {
        if (msg.sender != tokenCreator) revert NotTokenCreator();
        renderContract = _renderContract;
        emit RenderContractSet(_renderContract);
    }

    /// @notice Removes all LP liquidity and sends underlying tokens to recipient
    /// @dev Only callable by factory's protocolFeeRecipient. Enables migration to a new pool.
    /// @param recipient Address to receive the withdrawn tokens (RARE + LIQUID)
    function removeLiquidity(address recipient) external {
        address pfr = ILiquidFactory(factory).protocolFeeRecipient();
        if (msg.sender != pfr) revert OnlyProtocolFeeRecipient();
        if (_storedPositions.length == 0) revert ZeroLiquidity();
        if (recipient == address(0)) revert AddressZero();

        _unlockExpected = true;
        IPoolManager(poolManager).unlock(
            abi.encode(
                UnlockContext({
                    action: UnlockAction.REMOVE_LIQUIDITY,
                    data: abi.encode(recipient)
                })
            )
        );
        _unlockExpected = false;
    }

    /// @notice Returns the number of stored LP positions
    function storedPositionsLength() external view returns (uint256) {
        return _storedPositions.length;
    }

    /// @notice Returns launch type and state (multicurve is always live, no auction)
    /// @return launchType MULTICURVE
    /// @return poolLive Always true (pool created at init)
    /// @return auction Always address(0)
    /// @return strategyAddr Always address(0)
    function getLaunchState()
        external
        pure
        returns (
            ILiquidBase.LaunchType launchType,
            bool poolLive,
            address auction,
            address strategyAddr
        )
    {
        return (
            ILiquidBase.LaunchType.MULTICURVE,
            true,
            address(0),
            address(0)
        );
    }

    /// @notice Returns current pool price in both directions (RARE per token, token per RARE)
    /// @dev Reads sqrtPriceX96 from pool slot0 and converts to human-readable ratios
    function getCurrentPrice()
        external
        view
        returns (uint256 rarePerToken, uint256 tokenPerRare)
    {
        if (PoolId.unwrap(poolId) == bytes32(0)) revert PoolNotInitialized();

        IPoolManager pm = IPoolManager(poolManager);
        (uint160 sqrtPriceX96, , , ) = pm.getSlot0(poolId);

        uint256 priceQ128 = FullMath.mulDiv(
            uint256(sqrtPriceX96),
            uint256(sqrtPriceX96),
            1 << 64
        );
        uint256 denominatorQ128 = 1 << 128;

        if (priceQ128 == 0) return (0, 0);

        bool baseTokenIsCurrency0 = baseToken < address(this);

        if (baseTokenIsCurrency0) {
            rarePerToken = FullMath.mulDiv(denominatorQ128, 1e18, priceQ128);
            tokenPerRare = FullMath.mulDiv(priceQ128, 1e18, denominatorQ128);
        } else {
            rarePerToken = FullMath.mulDiv(priceQ128, 1e18, denominatorQ128);
            tokenPerRare = FullMath.mulDiv(denominatorQ128, 1e18, priceQ128);
        }
    }

    /// @notice Returns full market state (price, tick, liquidity, supply)
    /// @dev Combines getCurrentPrice with pool tick/liquidity and total supply
    function getMarketState()
        external
        view
        returns (
            uint256 rarePerToken,
            uint256 tokenPerRare,
            uint160 sqrtPriceX96,
            int24 currentTick,
            uint128 liquidity,
            uint256 currentSupply
        )
    {
        if (PoolId.unwrap(poolId) == bytes32(0)) revert PoolNotInitialized();

        IPoolManager pm = IPoolManager(poolManager);
        (sqrtPriceX96, currentTick, , ) = pm.getSlot0(poolId);
        liquidity = pm.getLiquidity(poolId);
        currentSupply = totalSupply();

        uint256 priceQ128 = FullMath.mulDiv(
            uint256(sqrtPriceX96),
            uint256(sqrtPriceX96),
            1 << 64
        );
        uint256 denominatorQ128 = 1 << 128;

        if (priceQ128 == 0) {
            return (0, 0, sqrtPriceX96, currentTick, liquidity, currentSupply);
        }

        bool baseTokenIsCurrency0 = baseToken < address(this);

        if (baseTokenIsCurrency0) {
            rarePerToken = FullMath.mulDiv(denominatorQ128, 1e18, priceQ128);
            tokenPerRare = FullMath.mulDiv(priceQ128, 1e18, denominatorQ128);
        } else {
            rarePerToken = FullMath.mulDiv(priceQ128, 1e18, denominatorQ128);
            tokenPerRare = FullMath.mulDiv(denominatorQ128, 1e18, priceQ128);
        }
    }

    /// @notice Simulates RARE -> LIQUID swap (buy) via revert-as-return pattern
    /// @param rareIn Amount of RARE to swap
    /// @return liquidOut Expected LIQUID output
    /// @return sqrtPriceX96After Post-swap sqrt price
    function quoteBuy(
        uint256 rareIn
    ) external returns (uint256 liquidOut, uint160 sqrtPriceX96After) {
        return _simulateQuoteBuy(rareIn);
    }

    /// @notice Simulates LIQUID -> RARE swap (sell) via revert-as-return pattern
    /// @param liquidIn Amount of LIQUID tokens to swap
    /// @return rareOut Expected RARE output
    /// @return sqrtPriceX96After Post-swap sqrt price
    function quoteSell(
        uint256 liquidIn
    ) external returns (uint256 rareOut, uint160 sqrtPriceX96After) {
        return _simulateQuoteSell(liquidIn);
    }

    /// @notice Deploys Uniswap V4 pool with multicurve liquidity (multiple concentrated positions)
    /// @dev Uses Doppler Multicurve library to distribute liquidity across positions for anti-sniping
    /// @param rareBalance Amount of RARE tokens for initial liquidity
    /// @param curves Curve configuration (tick ranges, shares) for position distribution
    function _deployPool(
        uint256 rareBalance,
        Curve[] calldata curves
    ) internal {
        // Pull pool config from factory
        ILiquidFactory factoryContract = ILiquidFactory(factory);
        int24 tickSpacing = factoryContract.poolTickSpacing();
        address hooks = factoryContract.poolHooks();

        // Multicurve: isToken0 = true if the asset we're selling (LIQUID) is token0
        bool isToken0 = address(this) < baseToken;

        // Build currencies sorted by address (Uniswap requirement)
        Currency currency0;
        Currency currency1;
        if (baseToken < address(this)) {
            currency0 = Currency.wrap(baseToken);
            currency1 = Currency.wrap(address(this));
        } else {
            currency0 = Currency.wrap(address(this));
            currency1 = Currency.wrap(baseToken);
        }

        // Create pool key and derive pool ID
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
        poolId = poolKey.toId();

        // Copy curves to memory (Multicurve library needs memory, not calldata)
        Curve[] memory curvesMem = new Curve[](curves.length);
        for (uint256 i; i < curves.length; i++) {
            curvesMem[i] = curves[i];
        }

        // Adjust curves to tick spacing and get bounds
        (
            Curve[] memory adjustedCurves,
            int24 lowerTickBoundary,
            int24 upperTickBoundary
        ) = Multicurve.adjustCurves(curvesMem, 0, tickSpacing, isToken0);

        // Start at boundary where LIQUID is cheap (launch price)
        // When isToken0: LIQUID=token0, cheap at low tick → use lowerTickBoundary
        // When !isToken0: LIQUID=token1, cheap at high tick → use upperTickBoundary
        int24 launchTick = isToken0 ? lowerTickBoundary : upperTickBoundary;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(launchTick);

        // Calculate positions for each curve (liquidity per tick range)
        Position[] memory positions = Multicurve.calculatePositions(
            adjustedCurves,
            tickSpacing,
            POOL_LAUNCH_SUPPLY,
            rareBalance,
            isToken0
        );

        // Store tick bounds; lpLiquidity is 0 for multicurve (spread across positions)
        lpTickLower = lowerTickBoundary;
        lpTickUpper = upperTickBoundary;
        lpLiquidity = 0;

        // Trigger unlock callback to initialize pool and add all positions
        _unlockExpected = true;
        IPoolManager(poolManager).unlock(
            abi.encode(
                UnlockContext({
                    action: UnlockAction.INITIALIZE_POOL,
                    data: abi.encode(sqrtPriceX96, positions)
                })
            )
        );
        _unlockExpected = false;

        emit LiquidMarketGraduated(
            address(this),
            address(poolManager),
            rareBalance,
            POOL_LAUNCH_SUPPLY,
            0
        );
    }

    /// @notice Simulates buy swap via unlock callback (revert-as-return pattern)
    /// @param rareAmount Amount of RARE to simulate swapping
    /// @return amountOut Expected LIQUID output
    /// @return sqrtPriceAfter Post-swap sqrt price
    function _simulateQuoteBuy(
        uint256 rareAmount
    ) internal returns (uint256 amountOut, uint160 sqrtPriceAfter) {
        _unlockExpected = true;
        try
            IPoolManager(poolManager).unlock(
                abi.encode(
                    UnlockContext({
                        action: UnlockAction.QUOTE_SWAP_BUY,
                        data: abi.encode(rareAmount)
                    })
                )
            )
        returns (bytes memory) {
            _unlockExpected = false;
            revert QuoteSimulationDidNotRevert();
        } catch (bytes memory reason) {
            _unlockExpected = false;
            (amountOut, sqrtPriceAfter) = _decodeQuoteResult(reason);
        }
    }

    /// @notice Simulates sell swap via unlock callback (revert-as-return pattern)
    /// @param tokenAmount Amount of LIQUID tokens to simulate swapping
    /// @return amountOut Expected RARE output
    /// @return sqrtPriceAfter Post-swap sqrt price
    function _simulateQuoteSell(
        uint256 tokenAmount
    ) internal returns (uint256 amountOut, uint160 sqrtPriceAfter) {
        _unlockExpected = true;
        try
            IPoolManager(poolManager).unlock(
                abi.encode(
                    UnlockContext({
                        action: UnlockAction.QUOTE_SWAP_SELL,
                        data: abi.encode(tokenAmount)
                    })
                )
            )
        returns (bytes memory) {
            _unlockExpected = false;
            revert QuoteSimulationDidNotRevert();
        } catch (bytes memory reason) {
            _unlockExpected = false;
            (amountOut, sqrtPriceAfter) = _decodeQuoteResult(reason);
        }
    }

    /// @notice Parses QuoteResult from revert reason
    /// @dev Extracts amountOut and sqrtPriceAfter from revert data; re-throws if selector mismatch
    /// @param reason Revert reason bytes
    /// @return amountOut The simulated output amount
    /// @return sqrtPriceAfter Post-swap sqrt price
    function _decodeQuoteResult(
        bytes memory reason
    ) internal pure returns (uint256 amountOut, uint160 sqrtPriceAfter) {
        // Extract error selector (first 4 bytes)
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }

        // If not QuoteResult, re-throw the original revert
        if (selector != QuoteResult.selector) {
            reason.bubbleReason();
        }

        // Parse amountOut (uint256) and sqrtPriceAfter (uint160) from revert payload
        assembly ("memory-safe") {
            amountOut := mload(add(reason, 0x24))
            sqrtPriceAfter := mload(add(reason, 0x44))
        }
    }

    /// @notice V4 unlock callback - dispatches to pool init or quote simulation
    /// @dev Only callable by PoolManager during expected unlock operations
    /// @param data Encoded UnlockContext (action + data)
    /// @return Empty bytes on success
    function unlockCallback(
        bytes calldata data
    ) external nonReentrant returns (bytes memory) {
        // Security: only PoolManager can call
        if (msg.sender != poolManager) revert OnlyPoolManager();
        if (!_unlockExpected) revert UnexpectedUnlock();

        UnlockContext memory ctx = abi.decode(data, (UnlockContext));

        if (ctx.action == UnlockAction.INITIALIZE_POOL) {
            return _unlockInitializePool(ctx.data);
        } else if (ctx.action == UnlockAction.QUOTE_SWAP_BUY) {
            return _unlockQuoteSwapBuy(ctx.data);
        } else if (ctx.action == UnlockAction.QUOTE_SWAP_SELL) {
            return _unlockQuoteSwapSell(ctx.data);
        } else if (ctx.action == UnlockAction.REMOVE_LIQUIDITY) {
            return _unlockRemoveLiquidity(ctx.data);
        }

        revert UnexpectedUnlock();
    }

    /// @notice Initializes pool and adds all multicurve positions
    /// @param data Encoded (sqrtPriceX96, positions)
    function _unlockInitializePool(
        bytes memory data
    ) internal returns (bytes memory) {
        (uint160 sqrtPriceX96, Position[] memory positions) = abi.decode(
            data,
            (uint160, Position[])
        );

        IPoolManager pm = IPoolManager(poolManager);

        // Initialize pool at launch price
        pm.initialize(poolKey, sqrtPriceX96);

        // Add liquidity to each position
        for (uint256 i; i < positions.length; i++) {
            Position memory pos = positions[i];
            if (pos.liquidity == 0) continue;

            // V4 modifyLiquidity uses int128 - ensure we don't overflow
            if (pos.liquidity > uint128(type(int128).max)) {
                revert LiquidityTooLarge(pos.liquidity);
            }

            // Store position for future liquidity removal
            _storedPositions.push(pos);

            // Add liquidity to this tick range
            (BalanceDelta delta, ) = pm.modifyLiquidity(
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: pos.tickLower,
                    tickUpper: pos.tickUpper,
                    liquidityDelta: int128(uint128(pos.liquidity)),
                    salt: pos.salt
                }),
                ""
            );

            int128 delta0 = delta.amount0();
            int128 delta1 = delta.amount1();

            // Settle currency0 debt (negative delta = we owe tokens)
            if (delta0 < 0) {
                uint128 owed0 = _toUint128Neg(delta0);
                address token0 = Currency.unwrap(poolKey.currency0);
                pm.sync(poolKey.currency0);
                if (token0 == address(this)) {
                    _transfer(address(this), address(pm), owed0);
                } else {
                    IERC20(token0).safeTransfer(address(pm), owed0);
                }
                pm.settle();
            }

            // Settle currency1 debt
            if (delta1 < 0) {
                uint128 owed1 = _toUint128Neg(delta1);
                address token1 = Currency.unwrap(poolKey.currency1);
                pm.sync(poolKey.currency1);
                if (token1 == address(this)) {
                    _transfer(address(this), address(pm), owed1);
                } else {
                    IERC20(token1).safeTransfer(address(pm), owed1);
                }
                pm.settle();
            }
        }

        // Return excess RARE to creator (rounding may leave dust)
        uint256 remainingRare = IERC20(baseToken).balanceOf(address(this));
        if (remainingRare > 1) {
            IERC20(baseToken).safeTransfer(tokenCreator, remainingRare);
        }

        return "";
    }

    /// @notice Remove all multicurve LP positions and send tokens to recipient
    /// @param data Encoded recipient address
    function _unlockRemoveLiquidity(
        bytes memory data
    ) internal returns (bytes memory) {
        address recipient = abi.decode(data, (address));

        IPoolManager pm = IPoolManager(poolManager);

        uint256 totalAmount0;
        uint256 totalAmount1;

        // Remove liquidity from each stored position
        for (uint256 i; i < _storedPositions.length; i++) {
            Position memory pos = _storedPositions[i];

            (BalanceDelta delta, ) = pm.modifyLiquidity(
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: pos.tickLower,
                    tickUpper: pos.tickUpper,
                    liquidityDelta: -int128(uint128(pos.liquidity)),
                    salt: pos.salt
                }),
                ""
            );

            int128 delta0 = delta.amount0();
            int128 delta1 = delta.amount1();

            if (delta0 > 0) totalAmount0 += uint128(delta0);
            if (delta1 > 0) totalAmount1 += uint128(delta1);
        }

        // Clear stored positions
        delete _storedPositions;

        // Claim all accumulated tokens to recipient
        if (totalAmount0 > 0) {
            pm.take(poolKey.currency0, recipient, totalAmount0);
        }
        if (totalAmount1 > 0) {
            pm.take(poolKey.currency1, recipient, totalAmount1);
        }

        emit LiquidityRemoved(recipient, totalAmount0, totalAmount1);

        return "";
    }

    /// @notice Quote helper for RARE -> LIQUID swaps (reverts with QuoteResult)
    /// @param data Encoded rareAmount
    function _unlockQuoteSwapBuy(
        bytes memory data
    ) internal returns (bytes memory) {
        uint256 rareAmount = abi.decode(data, (uint256));

        IPoolManager pm = IPoolManager(poolManager);
        // RARE -> LIQUID: zeroForOne when RARE is currency0
        bool baseTokenIsCurrency0 = baseToken < address(this);
        bool zeroForOne = baseTokenIsCurrency0;

        // Simulate swap (amountSpecified negative = exact input)
        BalanceDelta delta = pm.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -SafeCast.toInt256(rareAmount),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Validate swap direction: input negative, output positive
        if (zeroForOne) {
            if (delta0 >= 0) revert InvalidSwapDelta0(delta0);
            if (delta1 <= 0) revert InvalidSwapDelta1(delta1);
        } else {
            if (delta0 <= 0) revert InvalidSwapDelta0(delta0);
            if (delta1 >= 0) revert InvalidSwapDelta1(delta1);
        }

        // Extract LIQUID output (positive delta)
        uint256 tokensReceived = baseTokenIsCurrency0
            ? _toUint128Pos(delta1)
            : _toUint128Pos(delta0);
        (uint160 sqrtPriceAfter, , , ) = pm.getSlot0(poolKey.toId());

        revert QuoteResult(tokensReceived, sqrtPriceAfter);
    }

    /// @notice Quote helper for LIQUID -> RARE swaps (reverts with QuoteResult)
    /// @param data Encoded tokenAmount
    function _unlockQuoteSwapSell(
        bytes memory data
    ) internal returns (bytes memory) {
        uint256 tokenAmount = abi.decode(data, (uint256));

        IPoolManager pm = IPoolManager(poolManager);
        // LIQUID -> RARE: zeroForOne when LIQUID is currency0
        bool baseTokenIsCurrency0 = baseToken < address(this);
        bool zeroForOne = !baseTokenIsCurrency0;

        // Simulate swap (amountSpecified negative = exact input)
        BalanceDelta delta = pm.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -SafeCast.toInt256(tokenAmount),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (zeroForOne) {
            if (delta0 >= 0) revert InvalidSwapDelta0(delta0);
            if (delta1 <= 0) revert InvalidSwapDelta1(delta1);
        } else {
            if (delta0 <= 0) revert InvalidSwapDelta0(delta0);
            if (delta1 >= 0) revert InvalidSwapDelta1(delta1);
        }

        // Extract RARE output (positive delta)
        uint256 rareReceived = baseTokenIsCurrency0
            ? _toUint128Pos(delta0)
            : _toUint128Pos(delta1);
        (uint160 sqrtPriceAfter, , , ) = pm.getSlot0(poolKey.toId());

        // Revert with result - caller catches and decodes
        revert QuoteResult(rareReceived, sqrtPriceAfter);
    }

    /// @notice Safe cast: int128 positive to uint128
    function _toUint128Pos(int128 x) internal pure returns (uint128) {
        if (x < 0) revert NegativeValue(x);
        return uint128(uint256(int256(x)));
    }

    /// @notice Safe cast: int128 negative to uint128 (absolute value)
    function _toUint128Neg(int128 x) internal pure returns (uint128) {
        if (x > 0) revert PositiveValue(x);
        int256 y = -int256(x);
        if (uint256(y) > type(uint128).max)
            revert AmountExceedsUint128(uint256(y));
        return uint128(uint256(y));
    }
}
