// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/// Minimal interface for PositionManager
interface IPositionManager {
    function multicall(bytes[] calldata calls) external payable;

    function modifyLiquidities(
        bytes calldata unlockData,
        uint256 deadline
    ) external payable;
}

/// Minimal interface for PoolInitializer
interface IPoolInitializer {
    function initializePool(
        PoolKey memory key,
        uint160 sqrtPriceX96
    ) external returns (int24);
}

/// Minimal interface for Permit2
interface IPermit2 {
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
}

/// @title DeployV4Pool
/// @notice Script to deploy and initialize a Uniswap V4 pool on Base Sepolia
/// @dev Supports native ETH pairing with any ERC20 token
///      Optionally adds initial liquidity in the same transaction
///
/// IMPORTANT CHANGES (see inline comments for details):
///   - Proper Permit2 setup: ERC20.approve(Permit2) + Permit2.approve(PositionManager)
///   - SETTLE_PAIR params fixed to only include (currency0, currency1)
///   - SWEEP action added for ETH refunds
///   - modifyLiquidities signature corrected to use unlockData
///   - Tick spacing validation and rounding applied to tickLower/tickUpper
///   - Fallback path via SEPARATE_INIT env var if PositionManager doesn't expose initializePool
///
/// PRICE SETUP:
///   The pool price is set via SQRT_PRICE_X96 environment variable.
///   For a desired price ratio (token1/token0), calculate:
///     sqrtPriceX96 = sqrt(price) * 2^96
///   Example: For 1 ETH = 1000 tokens, price = 1000, sqrtPriceX96 ≈ sqrt(1000) * 2^96
///   Default is 1:1 (79228162514264337593543950336)
///
///   WARNING: If your ERC-20 is not 18 decimals, you must scale the price by 10^(dec1-dec0)
///   before taking the sqrt, or provide the exact SQRT_PRICE_X96 value directly.
///
/// NOTE: This script automatically uses the RARE token address from NetworkConfig.sol
///       based on the detected chain ID. No TOKEN_ADDRESS env var needed!
///
/// Example usage for RARE/ETH pool on Base Sepolia (pool only):
///   forge script script/DeployV4Pool.s.sol:DeployV4Pool --rpc-url base_sepolia --broadcast
///
/// Example usage with initial liquidity (1:1 price):
///   ADD_LIQUIDITY=true
///   ETH_AMOUNT=1000000000000000000  # 1 ETH
///   TOKEN_AMOUNT=1000000000000000000  # 1 token (must match price ratio)
///   forge script script/DeployV4Pool.s.sol:DeployV4Pool --rpc-url base_sepolia --broadcast --value 1ether
///
/// Example usage with custom price (1 ETH = 100 tokens):
///   SQRT_PRICE_X96=<calculated_value>  # sqrt(100) * 2^96 ≈ 125000000000000000000000000000
///   ADD_LIQUIDITY=true
///   ETH_AMOUNT=1000000000000000000  # 1 ETH
///   TOKEN_AMOUNT=100000000000000000000  # 100 tokens (matches price ratio)
///   forge script script/DeployV4Pool.s.sol:DeployV4Pool --rpc-url base_sepolia --broadcast --value 1ether
///
/// Example usage with separate initialization (if PositionManager doesn't have initializePool):
///   ADD_LIQUIDITY=true
///   SEPARATE_INIT=true  # Initialize via PoolManager, then add liquidity
///   ETH_AMOUNT=1000000000000000000
///   TOKEN_AMOUNT=1000000000000000000
///   forge script script/DeployV4Pool.s.sol:DeployV4Pool --rpc-url base_sepolia --broadcast --value 1ether
contract DeployV4Pool is Script {
    // Permit2 address (same across all networks)
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Default 1:1 price (sqrt(1) * 2^96)
    uint160 constant DEFAULT_SQRT_PRICE_X96 = 79228162514264337593543950336;

    // V4 PositionManager action codes (from v4-periphery Actions library)
    uint8 constant MINT_POSITION = 0;
    uint8 constant SETTLE_PAIR = 5;
    uint8 constant SWEEP = 7;

    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Get chain ID from environment or use block.chainid
        uint256 chainId;
        try vm.envUint("CHAIN_ID") returns (uint256 _chainId) {
            chainId = _chainId;
        } catch {
            chainId = block.chainid;
        }

        // Get network configuration
        NetworkConfig.Config memory config = NetworkConfig.getConfig(chainId);

        // Use RARE token from network config (no need for TOKEN_ADDRESS env var)
        address tokenAddress = config.rareToken;

        // Pool configuration with correct types from the start
        // Use defaults unless environment variables override them
        uint160 sqrtPriceX96 = DEFAULT_SQRT_PRICE_X96;
        uint24 fee = 3000; // 0.30%
        int24 tickSpacing = 60; // For 0.30% fee tier

        // Override from environment if provided
        // Note: Foundry only supports uint256/int256 from env, so we validate bounds
        try vm.envUint("SQRT_PRICE_X96") returns (uint256 _price) {
            require(
                _price <= type(uint160).max,
                "SQRT_PRICE_X96 exceeds uint160 max"
            );
            sqrtPriceX96 = uint160(_price);
        } catch {}

        try vm.envUint("POOL_FEE") returns (uint256 _fee) {
            require(_fee <= type(uint24).max, "POOL_FEE exceeds uint24 max");
            fee = uint24(_fee);
        } catch {}

        try vm.envInt("TICK_SPACING") returns (int256 _tickSpacing) {
            require(
                _tickSpacing >= type(int24).min &&
                    _tickSpacing <= type(int24).max,
                "TICK_SPACING out of int24 bounds"
            );
            tickSpacing = int24(_tickSpacing);
        } catch {}

        // Optional: add liquidity (defaults to false)
        bool addLiquidity = false;
        try vm.envBool("ADD_LIQUIDITY") returns (bool _addLiquidity) {
            addLiquidity = _addLiquidity;
        } catch {}

        // Optional: use separate transactions for init and liquidity (defaults to false)
        // Set to true if your PositionManager doesn't expose initializePool
        bool separateInit = false;
        try vm.envBool("SEPARATE_INIT") returns (bool _separateInit) {
            separateInit = _separateInit;
        } catch {}

        // Liquidity configuration
        uint256 ethAmount = 0;
        uint256 tokenAmount = 0;
        int24 tickLower = -120000; // Wide range default
        int24 tickUpper = 120000;

        if (addLiquidity) {
            ethAmount = vm.envUint("ETH_AMOUNT");
            tokenAmount = vm.envUint("TOKEN_AMOUNT");

            // Optional: custom tick range with bounds validation
            try vm.envInt("TICK_LOWER") returns (int256 _tickLower) {
                require(
                    _tickLower >= type(int24).min &&
                        _tickLower <= type(int24).max,
                    "TICK_LOWER out of int24 bounds"
                );
                tickLower = int24(_tickLower);
            } catch {}
            try vm.envInt("TICK_UPPER") returns (int256 _tickUpper) {
                require(
                    _tickUpper >= type(int24).min &&
                        _tickUpper <= type(int24).max,
                    "TICK_UPPER out of int24 bounds"
                );
                tickUpper = int24(_tickUpper);
            } catch {}

            // Enforce tick spacing (round toward zero)
            tickLower = int24((tickLower / tickSpacing) * tickSpacing);
            tickUpper = int24((tickUpper / tickSpacing) * tickSpacing);
            require(tickLower < tickUpper, "DeployV4Pool: invalid tick range");
        }

        console.log("=== Uniswap V4 Pool Deployment ===");
        console.log("Chain ID:");
        console.logUint(chainId);
        console.log("Deployer address:");
        console.logAddress(vm.addr(deployerPrivateKey));
        console.log("Token address:");
        console.logAddress(tokenAddress);
        console.log("Using native ETH (address(0))");
        console.log("Fee (pips, e.g. 3000 = 0.30%):");
        console.logUint(fee);
        console.log("Tick spacing:");
        console.logInt(tickSpacing);
        console.log("Sqrt price X96:");
        console.logUint(sqrtPriceX96);

        // Log currency ordering
        console.log("");
        console.log("Currency Ordering:");
        bool isEthCurrency0Display = uint160(address(0)) <
            uint160(tokenAddress);
        if (isEthCurrency0Display) {
            console.log("  currency0: ETH (native)");
            console.log("  currency1:");
            console.logAddress(tokenAddress);
        } else {
            console.log("  currency0:");
            console.logAddress(tokenAddress);
            console.log("  currency1: ETH (native)");
        }

        if (addLiquidity) {
            console.log("");
            console.log("Liquidity Configuration:");
            console.log("  ETH amount:");
            console.logUint(ethAmount);
            console.log("  Token amount:");
            console.logUint(tokenAmount);
            console.log("  Tick range (after spacing adjustment):");
            console.logInt(tickLower);
            console.log("  to");
            console.logInt(tickUpper);
            if (separateInit) {
                console.log(
                    "  Mode: Separate initialization (SEPARATE_INIT=true)"
                );
            } else {
                console.log("  Mode: Single multicall transaction");
            }
        }
        console.log("");

        // Build PoolKey
        // Native ETH is represented as address(0)
        Currency ethCurrency = CurrencyLibrary.ADDRESS_ZERO;

        // Currency sorting: currency0 must be < currency1
        // Native ETH (address(0)) always sorts first, so it will be currency0
        Currency currency0;
        Currency currency1;

        if (uint160(address(0)) < uint160(tokenAddress)) {
            currency0 = ethCurrency;
            currency1 = Currency.wrap(tokenAddress);
        } else {
            currency0 = Currency.wrap(tokenAddress);
            currency1 = ethCurrency;
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0)) // No hooks
        });

        // Compute PoolId for verification
        bytes32 poolId = PoolId.unwrap(PoolIdLibrary.toId(key));
        console.log("Computed PoolId:");
        console.logBytes32(poolId);
        console.log("");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        if (addLiquidity) {
            // Configure Permit2 so PositionManager can pull ERC20 during MINT_POSITION
            IERC20 token = IERC20(tokenAddress);

            // Step 1: ERC20 approve -> Permit2 (so Permit2 can pull tokens from our wallet)
            uint256 currentAllowance = token.allowance(
                vm.addr(deployerPrivateKey),
                PERMIT2
            );
            if (currentAllowance < tokenAmount) {
                console.log(
                    "ERC20 approve -> Permit2 (so Permit2 can pull tokens)..."
                );
                token.approve(PERMIT2, type(uint256).max);
            }

            // Step 2: Permit2.approve -> PositionManager (so PositionManager can use Permit2 to pull our tokens)
            console.log("Permit2.approve -> PositionManager...");
            IPermit2(PERMIT2).approve(
                tokenAddress,
                config.uniswapV4PositionManager,
                type(uint160).max,
                type(uint48).max // no expiry
            );

            bytes[] memory calls;
            // MINT_POSITION + SETTLE_PAIR + SWEEP (for ETH leftover refund)
            bytes memory actions = abi.encodePacked(
                MINT_POSITION,
                SETTLE_PAIR,
                SWEEP
            );

            if (separateInit) {
                // Fallback: Initialize pool separately, then add liquidity
                console.log("Initializing pool via PoolManager...");
                IPoolManager poolManager = IPoolManager(
                    config.uniswapV4PoolManager
                );
                poolManager.initialize(key, sqrtPriceX96);
                console.log("Pool initialized!");

                console.log("Adding liquidity via PositionManager...");

                // Prepare single call: modifyLiquidities only
                calls = new bytes[](1);
            } else {
                // Default: create pool and add liquidity in one multicall transaction
                console.log(
                    "Creating pool and adding liquidity in one transaction..."
                );

                // Prepare multicall: initializePool + modifyLiquidities
                // Note: This assumes your PositionManager inherits PoolInitializer.
                // If not, set SEPARATE_INIT=true in your environment.
                calls = new bytes[](2);

                // Call 0: Initialize pool (only works if PositionManager inherits PoolInitializer)
                calls[0] = abi.encodeWithSelector(
                    IPoolInitializer.initializePool.selector,
                    key,
                    sqrtPriceX96
                );
            }

            // Determine which currency is currency0 and currency1
            // currency0 is always the smaller address
            bool isEthCurrency0 = uint160(address(0)) < uint160(tokenAddress);

            // Map amounts to currency0 and currency1
            uint256 amount0;
            uint256 amount1;

            if (isEthCurrency0) {
                amount0 = ethAmount;
                amount1 = tokenAmount;
            } else {
                amount0 = tokenAmount;
                amount1 = ethAmount;
            }

            // Calculate proper liquidity based on current price and tick range
            // IMPORTANT: The sqrtPriceX96 used to initialize the pool MUST match the desired
            // swap price. This ensures that when liquidity is added, the pool reflects the
            // correct exchange rate between the two currencies.
            //
            // For testnets: Small price discrepancies may be acceptable for testing purposes,
            // but users should still aim for accuracy.
            // For mainnet: Getting the exact price is critical as it affects all subsequent swaps.
            //
            // The liquidity calculation accounts for:
            // - Current pool price (sqrtPriceX96)
            // - Price range (tickLower, tickUpper)
            // - Amounts provided (amount0, amount1)
            // - Whether price is in/above/below the range
            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

            // Calculate liquidity using proper formula
            uint128 liquidity = _calculateLiquidity(
                sqrtPriceX96,
                sqrtPriceLowerX96,
                sqrtPriceUpperX96,
                amount0,
                amount1
            );

            console.log("Calculated liquidity:");
            console.logUint(uint256(liquidity));
            console.log("Amount0 (currency0):");
            console.logUint(amount0);
            console.log("Amount1 (currency1):");
            console.logUint(amount1);

            // Three params: MINT_POSITION, SETTLE_PAIR, SWEEP
            bytes[] memory mintParams = new bytes[](3);
            mintParams[0] = abi.encode(
                key,
                tickLower,
                tickUpper,
                liquidity,
                amount0, // amount0Max
                amount1, // amount1Max
                vm.addr(deployerPrivateKey), // recipient
                "" // hookData
            );
            // SETTLE_PAIR: just the two currencies (no explicit amounts)
            mintParams[1] = abi.encode(key.currency0, key.currency1);
            // SWEEP: sweep any excess ETH back to the deployer
            mintParams[2] = abi.encode(
                CurrencyLibrary.ADDRESS_ZERO,
                vm.addr(deployerPrivateKey)
            );

            uint256 deadline = block.timestamp + 3600;

            // modifyLiquidities(bytes unlockData, uint256 deadline)
            // unlockData = abi.encode(actions, params)
            bytes4 modifySelector = IPositionManager.modifyLiquidities.selector;

            // Set the modifyLiquidities call at the correct index
            uint256 modifyIndex = separateInit ? 0 : 1;
            calls[modifyIndex] = abi.encodeWithSelector(
                modifySelector,
                abi.encode(actions, mintParams),
                deadline
            );

            // Execute multicall with ETH value
            IPositionManager positionManager = IPositionManager(
                config.uniswapV4PositionManager
            );
            positionManager.multicall{value: ethAmount}(calls);

            console.log("Pool created and liquidity added!");
        } else {
            // Initialize pool only
            console.log("Initializing pool...");
            IPoolManager poolManager = IPoolManager(
                config.uniswapV4PoolManager
            );
            poolManager.initialize(key, sqrtPriceX96);
            console.log("Pool initialized!");
        }

        vm.stopBroadcast();

        // Log deployment summary
        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("Chain ID:");
        console.logUint(chainId);
        console.log("PoolManager:");
        console.logAddress(config.uniswapV4PoolManager);
        console.log("PositionManager:");
        console.logAddress(config.uniswapV4PositionManager);
        console.log("Quoter:");
        console.logAddress(config.uniswapV4Quoter);
        console.log("Permit2:");
        console.logAddress(PERMIT2);
        console.log("");
        console.log("Pool Configuration:");
        console.log("-------------------");
        console.log("Currency0:");
        console.logAddress(Currency.unwrap(key.currency0));
        console.log("Currency1:");
        console.logAddress(Currency.unwrap(key.currency1));
        console.log("Fee (pips):");
        console.logUint(key.fee);
        console.log("Tick Spacing:");
        console.logInt(key.tickSpacing);
        console.log("PoolId:");
        console.logBytes32(poolId);
        console.log("Starting Price (sqrtPriceX96):");
        console.logUint(sqrtPriceX96);
        console.log("");
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Verify pool initialization on Basescan");
        console.log("2. Add liquidity using PositionManager");
        console.log("3. Use the pool for swaps");
        console.log("");
        console.log(
            "To add liquidity, you can use PositionManager.multicall()"
        );
        console.log(
            "See: https://docs.uniswap.org/contracts/v4/quickstart/create-pool"
        );
    }

    /// @notice Helper function to compute sqrtPriceX96 for a given price ratio
    /// @param price The price ratio (token1 / token0)
    /// @return sqrtPriceX96 The sqrt price in X96 format
    function computeSqrtPriceX96(
        uint256 price
    ) internal pure returns (uint160) {
        // sqrt(price) * 2^96
        // Simplified: for exact ratios, use sqrt(price) * 2^96
        // For production, use proper fixed-point math libraries
        uint256 sqrtPrice = sqrt(price * (2 ** 192));
        require(
            sqrtPrice <= type(uint160).max,
            "computeSqrtPriceX96: result exceeds uint160 max"
        );
        return uint160(sqrtPrice);
    }

    /// @notice Simple integer square root (Babylonian method)
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /// @notice Calculate liquidity for amount0 (when price is below range)
    /// @dev L = amount0 * sqrt(upper) * sqrt(lower) / (sqrt(upper) - sqrt(lower))
    function _getLiquidityForAmount0(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0
    ) internal pure returns (uint128) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        uint256 intermediate = FullMath.mulDiv(
            sqrtPriceAX96,
            sqrtPriceBX96,
            FixedPoint96.Q96
        );
        uint256 liquidity = FullMath.mulDiv(
            amount0,
            intermediate,
            sqrtPriceBX96 - sqrtPriceAX96
        );
        require(
            liquidity <= type(uint128).max,
            "_getLiquidityForAmount0: liquidity exceeds uint128 max"
        );
        return uint128(liquidity);
    }

    /// @notice Calculate liquidity for amount1 (when price is above range)
    /// @dev L = amount1 / (sqrt(upper) - sqrt(lower))
    function _getLiquidityForAmount1(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount1
    ) internal pure returns (uint128) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        uint256 liquidity = FullMath.mulDiv(
            amount1,
            FixedPoint96.Q96,
            sqrtPriceBX96 - sqrtPriceAX96
        );
        require(
            liquidity <= type(uint128).max,
            "_getLiquidityForAmount1: liquidity exceeds uint128 max"
        );
        return uint128(liquidity);
    }

    /// @notice Calculate liquidity from amounts and price range
    /// @param sqrtPriceX96 Current pool price
    /// @param sqrtPriceAX96 Lower tick price
    /// @param sqrtPriceBX96 Upper tick price
    /// @param amount0 Amount of currency0
    /// @param amount1 Amount of currency1
    function _calculateLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        // Ensure sqrtPriceAX96 < sqrtPriceBX96
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            // Price is below range: only amount0 contributes
            return
                _getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            // Price is in range: both amount0 and amount1 contribute
            uint128 liquidity0 = _getLiquidityForAmount0(
                sqrtPriceX96,
                sqrtPriceBX96,
                amount0
            );
            uint128 liquidity1 = _getLiquidityForAmount1(
                sqrtPriceAX96,
                sqrtPriceX96,
                amount1
            );
            // Take the minimum to ensure both amounts can be fully utilized
            return liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            // Price is above range: only amount1 contributes
            return
                _getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }
}
