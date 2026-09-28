// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "../vendor/uniswap/TickMath.sol";
import {FullMath} from "../vendor/uniswap/FullMath.sol";
import {LiquidityAmounts} from "../vendor/uniswap/LiquidityAmounts.sol";

interface IFeeConfigRead {
    function getFees(address vault) external view returns (uint256 totalBps, uint256 callerBps, address treasury);
}

interface IObservablePool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @title StrategyLib — position math and fee payment shared by the V3, V4 and
///        Slipstream strategies.
/// @notice An external library, so each strategy carries one copy of this code
///         between them instead of three. `payFees` runs by DELEGATECALL in the
///         strategy's context: `address(this)` is the strategy that pays.
library StrategyLib {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    /// @notice The treasury could not receive its fee slice (frozen, paused or
    ///         denylisted). The slice stays in the strategy as idle yield for
    ///         holders rather than blocking harvests, deposits or exits.
    event TreasuryFeeRetained(address indexed token, uint256 amount);

    error BadTicks();
    error BadRails();

    // ------------------------------------------------------------------ fees

    /// @notice Pay the performance fee on harvested `fees0`/`fees1`: the caller
    ///         slice to `callFeeRecipient` (when set), the rest to the treasury.
    ///         With `allToTreasury` (a fee realized without a harvest caller,
    ///         as V4 does on divest) the treasury takes the whole fee.
    /// @dev The treasury leg never reverts: a treasury the token refuses to pay
    ///      must not block the calls that realize fees — withdrawals among
    ///      them. Zero amounts are skipped.
    function payFees(
        address feeConfig,
        address vault,
        address token0,
        address token1,
        uint256 fees0,
        uint256 fees1,
        address callFeeRecipient,
        bool allToTreasury
    ) external {
        if (fees0 == 0 && fees1 == 0) return;
        (uint256 totalBps, uint256 callerBps, address treasury) = IFeeConfigRead(feeConfig).getFees(vault);
        if (allToTreasury) {
            callerBps = 0;
        } else {
            totalBps -= callerBps; // the treasury's slice
            if (callFeeRecipient == address(0)) callerBps = 0; // unclaimed caller slice stays with holders
        }
        _push(token0, callFeeRecipient, (fees0 * callerBps) / BPS);
        _push(token1, callFeeRecipient, (fees1 * callerBps) / BPS);
        _pushTreasury(token0, treasury, (fees0 * totalBps) / BPS);
        _pushTreasury(token1, treasury, (fees1 * totalBps) / BPS);
    }

    function _push(address token, address to, uint256 amount) private {
        if (amount > 0) IERC20(token).safeTransfer(to, amount);
    }

    function _pushTreasury(address token, address treasury, uint256 amount) private {
        if (amount == 0) return;
        if (!IERC20(token).trySafeTransfer(treasury, amount)) emit TreasuryFeeRetained(token, amount);
    }

    // ------------------------------------------------------------ positions

    /// @notice The exact amounts a proportional deposit of at most
    ///         `amount0Max`/`amount1Max` needs at `sqrtPriceX96`, and the
    ///         liquidity it mints.
    /// @dev One wei of headroom is reserved per side and added back, so the
    ///      pool's round-up on mint is covered and the result never exceeds
    ///      the caller's stated maxima.
    function quoteDeposit(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint256 amount0Max, uint256 amount1Max)
        external
        pure
        returns (uint256 used0, uint256 used1, uint128 liquidity)
    {
        uint256 q0 = amount0Max > 0 ? amount0Max - 1 : 0;
        uint256 q1 = amount1Max > 0 ? amount1Max - 1 : 0;
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, q0, q1);
        (used0, used1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, liquidity);
        if (used0 > 0) used0 += 1;
        if (used1 > 0) used1 += 1;
    }

    /// @notice The liquidity `amount0`/`amount1` buy at `sqrtPriceX96`.
    function liquidityFor(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        external
        pure
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), amount0, amount1
        );
    }

    /// @notice The one swap that brings `bal0`/`bal1` to the range's
    ///         composition, bounded by a price limit `maxTickDeviation` ticks
    ///         from the reference tick `refTick` (TWAP or checkpoint).
    /// @return amountIn Exact input; zero when no swap is due or the limit is
    ///         not strictly beyond spot (the pool would reject it — the calm
    ///         band's edge), in which case the caller adds liquidity as is.
    function compoundSwap(
        uint256 bal0,
        uint256 bal1,
        uint160 sqrtPriceX96,
        int24 tick,
        int24 tickLower,
        int24 tickUpper,
        int24 refTick,
        int24 maxTickDeviation
    ) external pure returns (uint256 amountIn, bool zeroForOne, uint160 limit) {
        (amountIn, zeroForOne) = _swapToRatio(
            bal0,
            bal1,
            sqrtPriceX96,
            tick,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper)
        );
        if (amountIn == 0) return (0, false, 0);
        // Edge of the calm band around the reference: execution can never be
        // worse than the manipulation bound, only partially fill.
        limit = TickMath.getSqrtRatioAtTick(
            clampTick(zeroForOne ? refTick - maxTickDeviation : refTick + maxTickDeviation)
        );
        if (zeroForOne ? limit >= sqrtPriceX96 : limit <= sqrtPriceX96) return (0, false, 0);
    }

    /// @dev How much of which token to sell so balances match the range ratio.
    function _swapToRatio(uint256 bal0, uint256 bal1, uint160 sqrtPriceX96, int24 tick, uint160 sqrtA, uint160 sqrtB)
        private
        pure
        returns (uint256 amountIn, bool zeroForOne)
    {
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) return (0, false);

        // Below range: position wants only token0 — sell all token1. Above: inverse.
        if (sqrtPriceX96 <= sqrtA) return (bal1, false);
        if (sqrtPriceX96 >= sqrtB) return (bal0, true);

        // In range: target the composition of one unit of liquidity.
        (uint256 unit0, uint256 unit1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, uint128(1e18));
        uint256 unitTotal1 = _amount0ToAmount1(unit0, sqrtPriceX96) + unit1;
        if (unitTotal1 == 0) return (0, false);

        uint256 total1 = bal1 + _amount0ToAmount1(bal0, sqrtPriceX96);
        uint256 target1 = FullMath.mulDiv(total1, unit1, unitTotal1);

        if (bal1 > target1) return (bal1 - target1, false); // sell excess token1
        uint256 sell0 = _amount1ToAmount0(target1 - bal1, sqrtPriceX96);
        if (sell0 > bal0) sell0 = bal0;
        return (sell0, true);
    }

    function _amount0ToAmount1(uint256 amount0, uint160 sqrtPriceX96) private pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
    }

    function _amount1ToAmount0(uint256 amount1, uint160 sqrtPriceX96) private pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount1, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
    }

    // ---------------------------------------------------------------- rails

    /// @notice Reject a range off the tick grid, outside the tick domain, or
    ///         outside the width rails.
    function validateTicks(int24 lower, int24 upper, int24 spacing, int24 minWidth, int24 maxWidth) external pure {
        if (
            lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK || lower % spacing != 0
                || upper % spacing != 0
        ) revert BadTicks();
        int24 width = upper - lower;
        if (width < minWidth || width > maxWidth) revert BadTicks();
    }

    /// @notice Owner fat-finger guard shared by every strategy's rails: a
    ///         non-positive calm band bricks isCalm(), and minWidth must be
    ///         positive and no greater than maxWidth or validateTicks can never
    ///         be satisfied.
    function validateBands(int24 maxTickDeviation, int24 minTickWidth, int24 maxTickWidth) external pure {
        if (maxTickDeviation <= 0) revert BadRails();
        if (minTickWidth <= 0 || minTickWidth > maxTickWidth) revert BadRails();
    }

    // --------------------------------------------------------------- oracle

    /// @notice Arithmetic-mean tick over `interval` seconds of a V3-style pool
    ///         (Uniswap V3 or Slipstream), rounded toward negative infinity
    ///         like Uniswap's OracleLibrary.
    function twapTick(address pool, uint32 interval) external view returns (int24 tick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = interval;
        (int56[] memory tickCumulatives,) = IObservablePool(pool).observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        tick = int24(delta / int56(uint56(interval)));
        if (delta < 0 && (delta % int56(uint56(interval)) != 0)) tick--;
    }

    function clampTick(int24 tick) internal pure returns (int24) {
        if (tick < TickMath.MIN_TICK) return TickMath.MIN_TICK;
        if (tick > TickMath.MAX_TICK) return TickMath.MAX_TICK;
        return tick;
    }
}
