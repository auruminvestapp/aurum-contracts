// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAurumStrategy} from "./interfaces/IAurumStrategy.sol";
import {IUniswapV3Pool, IUniswapV3MintCallback, IUniswapV3SwapCallback} from "./interfaces/IUniswapV3Pool.sol";
import {FullMath} from "./vendor/uniswap/FullMath.sol";
import {FeeMath} from "./vendor/uniswap/FeeMath.sol";
import {StrategyLib} from "./libraries/StrategyLib.sol";

interface IVaultView {
    function isActive() external view returns (bool);
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function totalSupply() external view returns (uint256);
}

interface IFeeConfigView {
    function getFees(address vault) external view returns (uint256 totalBps, uint256 callerBps, address treasury);
}

/// @title AurumStrategyUniV3 — position mechanics for a Uniswap V3 pool.
/// @notice Talks to the pool directly (mint/burn/collect/swap — no position
///         manager, no router, zero standing approvals). The agent holds only
///         the keeper role and can act exclusively inside hard rails: cooldown,
///         tick-width bounds and a TWAP calm-period check. The emergency exit
///         performs zero swaps and zero oracle reads.
contract AurumStrategyUniV3 is IAurumStrategy, Initializable, ReentrancyGuard, IUniswapV3MintCallback, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;

    struct Rails {
        uint32 twapInterval;
        int24 maxTickDeviation;
        uint256 rebalanceCooldown;
        int24 minTickWidth;
        int24 maxTickWidth;
        uint256 fallbackRebalanceDelay;
    }

    uint256 internal constant BPS = 10_000;
    uint32 internal constant MIN_TWAP_INTERVAL = 30; // seconds — a shorter window is trivially skewed

    IUniswapV3Pool public pool;
    address public vault;
    address public override token0;
    address public override token1;
    int24 public tickSpacing;
    int24 public tickLower;
    int24 public tickUpper;

    // Rails — changeable only by the vault owner.
    uint32 public twapInterval; // seconds
    int24 public maxTickDeviation; // calm-period bound, in ticks
    uint256 public rebalanceCooldown; // seconds between rebalances
    int24 public minTickWidth;
    int24 public maxTickWidth;
    uint256 public fallbackRebalanceDelay; // out-of-range duration after which rebalance goes permissionless

    address public feeConfig;
    uint256 public lastRebalance;
    uint256 public lastInRange;
    // When the position most recently LEFT its range (0 while in range). The
    // permissionless fallback measures real out-of-range duration from this,
    // not from lastInRange (which only advanced on harvest/rebalance and could
    // be stale enough to open the fallback the instant the position exited).
    uint64 public outOfRangeSince;

    event Harvest(address indexed caller, uint256 fees0, uint256 fees1, uint256 ppsAfter);
    event Rebalance(int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper, bool viaFallback);
    event EmergencyExit(uint256 balance0, uint256 balance1);
    event Reinvested(uint128 liquidity);
    /// @dev Emitted by StrategyLib.payFees (DELEGATECALL, so from this
    ///      address) when the treasury can't receive its slice; declared here
    ///      so it is in this contract's ABI.
    event TreasuryFeeRetained(address indexed token, uint256 amount);
    event RailsSet(uint32 twapInterval, int24 maxTickDeviation, uint256 cooldown, int24 minWidth, int24 maxWidth, uint256 fallbackDelay);

    error NotVault();
    error NotVaultOwner();
    error NotKeeperNorFallback();
    error NotPool();
    error VaultNotActive();
    error NotCalm();
    error CooldownActive();
    error BadTicks();
    error RangeMustBracketPrice();
    error ZeroAddress();
    error BadTwapInterval();
    error BadRails();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    modifier onlyVaultOwner() {
        if (msg.sender != IVaultView(vault).owner()) revert NotVaultOwner();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address pool_, address vault_, int24 tickLower_, int24 tickUpper_, address feeConfig_, Rails calldata rails)
        external
        initializer
    {
        if (pool_ == address(0) || vault_ == address(0) || feeConfig_ == address(0)) revert ZeroAddress();
        _validateRails(rails.twapInterval, rails.maxTickDeviation, rails.minTickWidth, rails.maxTickWidth);

        pool = IUniswapV3Pool(pool_);
        vault = vault_;
        token0 = pool.token0();
        token1 = pool.token1();
        tickSpacing = pool.tickSpacing();
        feeConfig = feeConfig_;

        twapInterval = rails.twapInterval;
        maxTickDeviation = rails.maxTickDeviation;
        rebalanceCooldown = rails.rebalanceCooldown;
        minTickWidth = rails.minTickWidth;
        maxTickWidth = rails.maxTickWidth;
        fallbackRebalanceDelay = rails.fallbackRebalanceDelay;

        _validateTicks(tickLower_, tickUpper_);
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        lastInRange = block.timestamp;
    }

    // ---------------------------------------------------------------- views

    function totalLiquidity() public view override returns (uint128 liquidity_) {
        (liquidity_,,,,) = pool.positions(_positionKey());
    }

    function inRange() public view override returns (bool) {
        (, int24 tick,,,,,) = pool.slot0();
        return tick >= tickLower && tick < tickUpper;
    }

    /// @notice Spot tick within `maxTickDeviation` of the TWAP tick.
    function isCalm() public view override returns (bool) {
        (, int24 tick,,,,,) = pool.slot0();
        int24 twap = twapTick();
        int24 diff = tick > twap ? tick - twap : twap - tick;
        return diff <= maxTickDeviation;
    }

    function twapTick() public view returns (int24) {
        return StrategyLib.twapTick(address(pool), twapInterval);
    }

    function quoteDeposit(uint256 amount0Max, uint256 amount1Max)
        external
        view
        override
        returns (uint256 used0, uint256 used1, uint128 liquidity)
    {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        return StrategyLib.quoteDeposit(sqrtPriceX96, tickLower, tickUpper, amount0Max, amount1Max);
    }

    // ------------------------------------------------------------ vault flow

    function invest(uint256 amount0, uint256 amount1) external override onlyVault nonReentrant returns (uint128 liquidityAdded) {
        liquidityAdded = _mintMaxLiquidity(amount0, amount1);
    }

    function divest(uint256 shares, uint256 totalShares, address receiver)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        // Pro-rata slice of the position principal, collected straight to the
        // receiver. Pending fees are untouched — they belong to all holders
        // and get compounded at the next harvest.
        uint128 liquidity_ = totalLiquidity();
        uint128 burnLiquidity = uint128(FullMath.mulDiv(liquidity_, shares, totalShares));
        if (burnLiquidity > 0) {
            (uint256 burned0, uint256 burned1) = pool.burn(tickLower, tickUpper, burnLiquidity);
            (uint128 c0, uint128 c1) = pool.collect(receiver, tickLower, tickUpper, _u128(burned0), _u128(burned1));
            out0 += c0;
            out1 += c1;
        }

        // Pro-rata slice of idle balances (compound dust, post-panic holdings).
        uint256 idle0 = FullMath.mulDiv(IERC20(token0).balanceOf(address(this)), shares, totalShares);
        uint256 idle1 = FullMath.mulDiv(IERC20(token1).balanceOf(address(this)), shares, totalShares);
        if (idle0 > 0) IERC20(token0).safeTransfer(receiver, idle0);
        if (idle1 > 0) IERC20(token1).safeTransfer(receiver, idle1);
        out0 += idle0;
        out1 += idle1;
    }

    /// @inheritdoc IAurumStrategy
    function pendingFees()
        external
        view
        override
        returns (uint256 fees0, uint256 fees1, uint256 callerFee0, uint256 callerFee1)
    {
        (uint128 liq, uint256 inside0Last, uint256 inside1Last, uint128 owed0, uint128 owed1) =
            pool.positions(_positionKey());

        // tokensOwed is what a previous poke already realized and left sitting
        // in the pool; the growth delta is everything earned since. A harvest
        // collects both, so both belong in the answer.
        fees0 = owed0;
        fees1 = owed1;

        if (liq > 0) {
            (, int24 tickNow,,,,,) = pool.slot0();
            (,, uint256 lo0, uint256 lo1,,,,) = pool.ticks(tickLower);
            (,, uint256 up0, uint256 up1,,,,) = pool.ticks(tickUpper);
            fees0 += FeeMath.feesEarned(
                FeeMath.feeGrowthInside(pool.feeGrowthGlobal0X128(), lo0, up0, tickNow, tickLower, tickUpper),
                inside0Last,
                liq
            );
            fees1 += FeeMath.feesEarned(
                FeeMath.feeGrowthInside(pool.feeGrowthGlobal1X128(), lo1, up1, tickNow, tickLower, tickUpper),
                inside1Last,
                liq
            );
        }

        // The same split _harvest applies, so a keeper reads its own take
        // rather than re-deriving the fee policy from FeeConfig.
        (, uint256 callerBps,) = IFeeConfigView(feeConfig).getFees(vault);
        callerFee0 = (fees0 * callerBps) / BPS;
        callerFee1 = (fees1 * callerBps) / BPS;
    }

    // -------------------------------------------------------------- keeper

    /// @notice Permissionless compounding: collect fees, split the performance
    ///         fee (caller / treasury), swap the rest toward the position
    ///         ratio and reinvest.
    function harvest(address callFeeRecipient) external override nonReentrant {
        if (!IVaultView(vault).isActive()) revert VaultNotActive();
        (uint256 fees0, uint256 fees1) = _harvest(callFeeRecipient);
        // Compounding runs a swap; only do it while calm — otherwise a
        // manipulated spot could force the compound trade to the edge of the
        // TWAP band. Fees are already collected either way; when not calm they
        // simply wait for a calmer harvest to compound. Never reverts, so
        // permissionless fee collection is not griefable. (deposit/rebalance
        // already gate their swaps this way — this closes the harvest gap.)
        if (isCalm()) _compound();
        _syncRangeStatus();
        emit Harvest(callFeeRecipient, fees0, fees1, _pps());
    }

    /// @notice Move the range. Keeper-only inside the rails; permissionless
    ///         once the position has sat out of range past the fallback delay.
    function rebalance(int24 newTickLower, int24 newTickUpper) external override nonReentrant {
        if (!IVaultView(vault).isActive()) revert VaultNotActive();
        // Refresh the out-of-range clock before the fallback gate so it reflects
        // this block: a position that only just exited has outOfRangeSince == now
        // and cannot yet be force-rebalanced.
        _syncRangeStatus();

        bool viaFallback = false;
        if (msg.sender != IVaultView(vault).keeper()) {
            // Anyone may re-center a long-abandoned position — the protocol must
            // degrade gracefully if the agent disappears — but only after the
            // position has ACTUALLY sat out of range for the full delay.
            // outOfRangeSince is maintained by the permissionless harvest (and
            // rebalance), so anyone can start the clock on an abandoned position.
            if (
                inRange() || _refInRange() || outOfRangeSince == 0
                    || block.timestamp < outOfRangeSince + fallbackRebalanceDelay
            ) revert NotKeeperNorFallback();
            viaFallback = true;
        }

        if (block.timestamp < lastRebalance + rebalanceCooldown) revert CooldownActive();
        if (!isCalm()) revert NotCalm();
        _validateTicks(newTickLower, newTickUpper);
        // The new range must bracket the current price. This keeps the mandatory
        // compound swap a small composition adjustment — never a full one-sided
        // flip of the whole principal — which is the only value a compromised
        // keeper (or the permissionless fallback caller) could otherwise extract
        // by self-sandwiching. It also guarantees the position lands in range, so
        // lastInRange refreshes and the fallback window cannot self-perpetuate.
        (, int24 spotTick,,,,,) = pool.slot0();
        if (spotTick < newTickLower || spotTick >= newTickUpper) revert RangeMustBracketPrice();

        (uint256 hf0, uint256 hf1) = _harvest(msg.sender);

        // Exit the whole position, move the range, re-enter.
        uint128 liquidity_ = totalLiquidity();
        if (liquidity_ > 0) {
            (uint256 burned0, uint256 burned1) = pool.burn(tickLower, tickUpper, liquidity_);
            pool.collect(address(this), tickLower, tickUpper, _u128(burned0), _u128(burned1));
        }

        int24 oldLower = tickLower;
        int24 oldUpper = tickUpper;
        tickLower = newTickLower;
        tickUpper = newTickUpper;

        _compound();

        lastRebalance = block.timestamp;
        _syncRangeStatus();
        emit Harvest(msg.sender, hf0, hf1, _pps());
        emit Rebalance(oldLower, oldUpper, newTickLower, newTickUpper, viaFallback);
    }

    // ------------------------------------------------------------ emergency

    /// @dev Zero swaps, zero oracle reads — must work mid-manipulation.
    function emergencyExit() external override onlyVault nonReentrant {
        _exitPosition();
        emit EmergencyExit(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    function reinvestIdle() external override onlyVault nonReentrant {
        // Re-entering the whole idle principal runs a compound swap; only do so
        // in calm conditions so a large re-entry can't execute mid-manipulation.
        if (!isCalm()) revert NotCalm();
        _compound();
        emit Reinvested(totalLiquidity());
    }

    // ----------------------------------------------------------------- admin

    function setRails(
        uint32 twapInterval_,
        int24 maxTickDeviation_,
        uint256 rebalanceCooldown_,
        int24 minTickWidth_,
        int24 maxTickWidth_,
        uint256 fallbackRebalanceDelay_
    ) external onlyVaultOwner {
        _validateRails(twapInterval_, maxTickDeviation_, minTickWidth_, maxTickWidth_);
        twapInterval = twapInterval_;
        maxTickDeviation = maxTickDeviation_;
        rebalanceCooldown = rebalanceCooldown_;
        minTickWidth = minTickWidth_;
        maxTickWidth = maxTickWidth_;
        fallbackRebalanceDelay = fallbackRebalanceDelay_;
        emit RailsSet(twapInterval_, maxTickDeviation_, rebalanceCooldown_, minTickWidth_, maxTickWidth_, fallbackRebalanceDelay_);
    }

    // ------------------------------------------------------------- callbacks

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external override {
        if (msg.sender != address(pool)) revert NotPool();
        if (amount0Owed > 0) IERC20(token0).safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) IERC20(token1).safeTransfer(msg.sender, amount1Owed);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        if (msg.sender != address(pool)) revert NotPool();
        if (amount0Delta > 0) IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    // ------------------------------------------------------------- internals

    /// @dev Collect all pending fees and split the performance fee. Charged on
    ///      harvested yield only — never on principal.
    function _harvest(address callFeeRecipient) internal returns (uint256 fees0, uint256 fees1) {
        if (totalLiquidity() > 0) {
            pool.burn(tickLower, tickUpper, 0); // poke: realize fee growth
            (fees0, fees1) = pool.collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
        }
        StrategyLib.payFees(feeConfig, vault, token0, token1, fees0, fees1, callFeeRecipient, false);
    }

    function _pps() internal view returns (uint256) {
        uint256 supply = IVaultView(vault).totalSupply();
        return supply == 0 ? 1e18 : FullMath.mulDiv(totalLiquidity(), 1e18, supply);
    }

    /// @dev Swap idle balances toward the position's composition (one bounded
    ///      swap, price-limited to the calm band around TWAP) and mint.
    function _compound() internal {
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        if (bal0 == 0 && bal1 == 0) return;

        (uint160 sqrtPriceX96, int24 tick,,,,,) = pool.slot0();
        // Price limit = edge of the calm band around TWAP (see
        // StrategyLib.compoundSwap): never worse than the manipulation bound.
        (uint256 amountIn, bool zeroForOne, uint160 limit) = StrategyLib.compoundSwap(
            bal0, bal1, sqrtPriceX96, tick, tickLower, tickUpper, twapTick(), maxTickDeviation
        );
        if (amountIn > 0) {
            pool.swap(address(this), zeroForOne, int256(amountIn), limit, "");
            bal0 = IERC20(token0).balanceOf(address(this));
            bal1 = IERC20(token1).balanceOf(address(this));
        }

        _mintMaxLiquidity(bal0, bal1);
    }

    function _mintMaxLiquidity(uint256 amount0, uint256 amount1) internal returns (uint128 liquidity_) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        liquidity_ = StrategyLib.liquidityFor(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);
        if (liquidity_ > 0) {
            pool.mint(address(this), tickLower, tickUpper, liquidity_, "");
        }
    }

    function _exitPosition() internal {
        uint128 liquidity_ = totalLiquidity();
        if (liquidity_ > 0) {
            pool.burn(tickLower, tickUpper, liquidity_);
        }
        // Collect everything owed: burned principal plus any pending fees.
        pool.collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
    }

    /// @dev Reject inconsistent rail parameters (owner fat-finger
    ///      guard): a sub-minimum TWAP window is trivially skewed, a non-positive
    ///      calm band bricks isCalm(), and minWidth must be positive and no
    ///      greater than maxWidth or _validateTicks can never be satisfied.
    function _validateRails(uint32 twapInterval_, int24 maxTickDeviation_, int24 minTickWidth_, int24 maxTickWidth_)
        internal
        pure
    {
        if (twapInterval_ < MIN_TWAP_INTERVAL) revert BadTwapInterval();
        StrategyLib.validateBands(maxTickDeviation_, minTickWidth_, maxTickWidth_);
    }

    /// @dev Range-status checkpoint driving the permissionless fallback. Starts
    ///      outOfRangeSince when the position is out of range and clears it
    ///      (advancing lastInRange) when it is back — each only when spot AND
    ///      the manipulation-resistant reference (TWAP tick) agree, so a flash move
    ///      inside one transaction can neither plant nor reset the clock.
    ///      Maintained by the permissionless harvest and by rebalance.
    function _syncRangeStatus() internal {
        bool spotIn = inRange();
        bool refIn = _refInRange();
        if (spotIn && refIn) {
            if (outOfRangeSince != 0) outOfRangeSince = 0;
            lastInRange = block.timestamp;
        } else if (!spotIn && !refIn && outOfRangeSince == 0) {
            outOfRangeSince = uint64(block.timestamp);
        }
    }

    /// @dev The TWAP tick sits inside the position's range.
    function _refInRange() internal view returns (bool) {
        int24 ref = twapTick();
        return ref >= tickLower && ref < tickUpper;
    }

    function _validateTicks(int24 lower, int24 upper) internal view {
        StrategyLib.validateTicks(lower, upper, tickSpacing, minTickWidth, maxTickWidth);
    }

    function _positionKey() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max);
        return uint128(x);
    }
}
