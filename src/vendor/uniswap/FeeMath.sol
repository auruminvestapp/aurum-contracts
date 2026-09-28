// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FullMath} from "./FullMath.sol";

/// @title FeeMath — uncollected-fee accounting, shared by the V3 and V4 strategies.
/// @notice A concentrated-liquidity pool records fees as an ever-growing
///         per-unit-of-liquidity accumulator. A position stores the value that
///         accumulator had when it was last touched; everything earned since is
///         the difference. The pool never stores "fees owed to this position"
///         until a poke realizes them, so reading them without mutating state
///         means recomputing the in-range accumulator here.
///
///         All arithmetic is deliberately UNCHECKED: these accumulators are
///         meant to overflow and wrap, and the differences stay correct as long
///         as they do. This mirrors Uniswap's own implementation — using
///         checked math here would revert on healthy, long-lived pools.
library FeeMath {
    /// @notice The fee accumulator measured across [tickLower, tickUpper] only.
    /// @param feeGrowthGlobalX128 the pool-wide accumulator
    /// @param lowerOutsideX128 the lower tick's far-side accumulator
    /// @param upperOutsideX128 the upper tick's far-side accumulator
    /// @param tickCurrent the pool's current tick
    function feeGrowthInside(
        uint256 feeGrowthGlobalX128,
        uint256 lowerOutsideX128,
        uint256 upperOutsideX128,
        int24 tickCurrent,
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (uint256) {
        unchecked {
            // "Outside" is relative to where the price stands: below the range
            // the lower tick's accumulator already measures the far side, above
            // it the complement does.
            uint256 below = tickCurrent >= tickLower ? lowerOutsideX128 : feeGrowthGlobalX128 - lowerOutsideX128;
            uint256 above = tickCurrent < tickUpper ? upperOutsideX128 : feeGrowthGlobalX128 - upperOutsideX128;
            return feeGrowthGlobalX128 - below - above;
        }
    }

    /// @notice Fees a position has earned since its stored snapshot.
    /// @dev Q128 accumulator × liquidity, rounded down — the same truncation
    ///      the pool applies when it realizes them, so this never over-reports.
    function feesEarned(uint256 insideNowX128, uint256 insideLastX128, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        if (liquidity == 0) return 0;
        unchecked {
            return FullMath.mulDiv(insideNowX128 - insideLastX128, liquidity, 1 << 128);
        }
    }
}
