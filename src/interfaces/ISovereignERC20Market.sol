// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC1046} from "liquid-editions/interfaces/ISovereignERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title ISovereignERC20Market
/// @notice Minimal market surface for Sovereign ERC20 tokens launched into Uniswap V4.
interface ISovereignERC20Market is IERC1046 {
    error SovereignMarketZeroSupply();
    error SovereignMarketZeroCurves();
    error SovereignMarketAlreadyInitialized();
    error SovereignMarketOnlyPoolManager();
    error SovereignMarketUnexpectedUnlock();
    error SovereignMarketTooManyPositions();
    error SovereignMarketNoLiquidity();
    error SovereignMarketLiquidityTooLarge(uint256 liquidity);
    error SovereignMarketPositiveValue(int128 value);
    error SovereignMarketAmountExceedsUint128(uint256 value);

    event SovereignMarketInitialized(address indexed token, address indexed poolManager, uint256 tokenLiquidity);

    function factory() external view returns (address);
    function baseToken() external view returns (address);
    function poolManager() external view returns (address);
    function marketSupply() external view returns (uint256);
    function poolKey()
        external
        view
        returns (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks);
    function poolId() external view returns (PoolId);
}
