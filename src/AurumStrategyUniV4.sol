// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAurumStrategy} from "./interfaces/IAurumStrategy.sol";
import {FullMath} from "./vendor/uniswap/FullMath.sol";
import {FeeMath} from "./vendor/uniswap/FeeMath.sol";
import {StrategyLib} from "./libraries/StrategyLib.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    Currency,
    ModifyLiquidityParams,
    SwapParams,
    BalanceDelta,
    BalanceDeltaLibrary
} from "./vendor/uniswap/v4/V4Core.sol";
import {V4StateReader} from "./vendor/uniswap/v4/V4StateReader.sol";

interface IVaultView {
    function isActive() external view returns (bool);
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function totalSupply() external view returns (uint256);
}

interface IFeeConfigView {
    function getFees(address vault) external view returns (uint256 totalBps, uint256 callerBps, address treasury);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title AurumStrategyUniV4 — position mechanics for a hookless Uniswap V4 pool.
/// @notice Talks to the singleton PoolManager directly (unlock + modifyLiquidity/
///         swap/settle/take — no PositionManager, no router, zero standing
///         approvals). V4 hookless pools carry no oracle, so the calm rails are
///         anchored to an internal rate-limited checkpoint: it can only drift
///         toward spot at `checkpointRatePerMinute`, with credited elapsed time
///         capped and one update limited to a quarter of the calm band, so a
///         flash move can shift the reference only that far — however long
///         the checkpoint sat idle. The emergency exit performs zero swaps
///         and zero oracle reads.
contract AurumStrategyUniV4 is IAurumStrategy, Initializable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    struct RailsV4 {
        uint16 checkpointRatePerMinute; // max ticks/min the checkpoint may move
        uint32 checkpointElapsedCap; // max seconds credited per update
        int24 maxTickDeviation;
        uint256 rebalanceCooldown;
        int24 minTickWidth;
        int24 maxTickWidth;
        uint256 fallbackRebalanceDelay;
    }

    uint256 internal constant BPS = 10_000;
    bytes32 internal constant SALT = bytes32(0);
    int256 internal constant MAX_STEP_BAND_DIVISOR = 4; // one checkpoint update ≤ a quarter of the calm band

    IPoolManager public poolManager;
    PoolKey internal _poolKey;
    bytes32 public poolId;
    address public vault;
    address public override token0;
    address public override token1;
    /// @notice True when the pool's currency0 is native ETH. token0 is then
    ///         the WETH address (the ERC20 face); conversion happens only at
    ///         the PoolManager settle/take boundary (see _settleOrTake).
    bool public native0;
    address public weth;
    int24 public tickSpacing;
    int24 public tickLower;
    int24 public tickUpper;

    // Rails — changeable only by the vault owner.
    uint16 public checkpointRatePerMinute;
    uint32 public checkpointElapsedCap;
    int24 public maxTickDeviation;
    uint256 public rebalanceCooldown;
    int24 public minTickWidth;
    int24 public maxTickWidth;
    uint256 public fallbackRebalanceDelay;

    int24 internal checkpointTick_;
    uint64 internal checkpointTime_;

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
    event RailsSet(
        uint16 ratePerMinute,
        uint32 elapsedCap,
        int24 maxTickDeviation,
        uint256 cooldown,
        int24 minWidth,
        int24 maxWidth,
        uint256 fallbackDelay
    );
    event CheckpointPoked(int24 checkpointTick, int24 spotTick);

    error NotVault();
    error NotVaultOwner();
    error NotKeeperNorFallback();
    error NotPoolManager();
    error VaultNotActive();
    error NotCalm();
    error CooldownActive();
    error BadTicks();
    error HookTookPrincipal();
    error RangeMustBracketPrice();
    error ZeroAddress();
    error BadPool();
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

    function initialize(
        IPoolManager poolManager_,
        PoolKey calldata key,
        address vault_,
        int24 tickLower_,
        int24 tickUpper_,
        address feeConfig_,
        address weth_,
        RailsV4 calldata rails
    ) external initializer {
        if (address(poolManager_) == address(0) || vault_ == address(0) || feeConfig_ == address(0)) {
            revert ZeroAddress();
        }
        // Hook policy lives in the factory (trustedHooks allowlist) — the
        // factory is the only initializer of registered clones, and a
        // self-cloned strategy is unregistered and harmless. The strategy
        // stays hook-agnostic: it holds and uses whatever PoolKey it is given.
        //
        // Native currency0 is supported through the WETH face: token0 becomes
        // WETH, idle inventory is always held wrapped, and only the
        // settle/take boundary converts (see _settleOrTake).
        native0 = Currency.unwrap(key.currency0) == address(0);
        if (native0 && weth_ == address(0)) revert ZeroAddress();
        _validateRails(rails);

        poolManager = poolManager_;
        _poolKey = key;
        poolId = V4StateReader.poolIdFor(key);
        vault = vault_;
        weth = weth_;
        token0 = native0 ? weth_ : Currency.unwrap(key.currency0);
        token1 = Currency.unwrap(key.currency1);
        tickSpacing = key.tickSpacing;
        feeConfig = feeConfig_;

        checkpointRatePerMinute = rails.checkpointRatePerMinute;
        checkpointElapsedCap = rails.checkpointElapsedCap;
        maxTickDeviation = rails.maxTickDeviation;
        rebalanceCooldown = rails.rebalanceCooldown;
        minTickWidth = rails.minTickWidth;
        maxTickWidth = rails.maxTickWidth;
        fallbackRebalanceDelay = rails.fallbackRebalanceDelay;

        (uint160 sqrtPriceX96, int24 spot,,) = V4StateReader.getSlot0(poolManager_, poolId);
        if (sqrtPriceX96 == 0) revert BadPool();

        _validateTicks(tickLower_, tickUpper_);
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        checkpointTick_ = spot;
        checkpointTime_ = uint64(block.timestamp);
        lastInRange = block.timestamp;
    }

    // ------------------------------------------------------ checkpoint oracle

    function checkpointTick() public view returns (int24) {
        return checkpointTick_;
    }

    function checkpointTime() public view returns (uint64) {
        return checkpointTime_;
    }

    /// @notice The rate-limited reference tick, evaluated as of now (no write).
    function virtualCheckpoint() public view returns (int24) {
        (, int24 spot,,) = V4StateReader.getSlot0(poolManager, poolId);
        return _virtualCheckpoint(spot);
    }

    /// @dev The checkpoint may only drift toward spot by ratePerMinute ticks
    ///      per elapsed minute, and elapsed time credited per update is capped
    ///      so a long-unpoked checkpoint can never teleport to a manipulated
    ///      spot in one step.
    ///
    ///      The spot this drifts toward may have been moved in the very
    ///      transaction reading it, so one update is further limited to
    ///      1/MAX_STEP_BAND_DIVISOR of the calm band: whatever idle time has
    ///      built up, a flash move can widen the effective band by at most
    ///      that fraction. (A second update in the same transaction sees zero
    ///      elapsed time.) Drift keeps its full rate as long as pokes come
    ///      at least every (maxTickDeviation / 4) * 60 / ratePerMinute seconds
    ///      (300 s at 800 ticks and 40/min); sparser pokes catch up slower.
    function _virtualCheckpoint(int24 spot) internal view returns (int24) {
        uint256 elapsed = block.timestamp - checkpointTime_;
        if (elapsed > checkpointElapsedCap) elapsed = checkpointElapsedCap;
        int256 step = int256(elapsed * checkpointRatePerMinute) / 60;
        int256 maxStep = int256(maxTickDeviation) / MAX_STEP_BAND_DIVISOR;
        if (maxStep == 0) maxStep = 1;
        if (step > maxStep) step = maxStep;
        int256 diff = int256(spot) - int256(checkpointTick_);
        if (diff > step) diff = step;
        if (diff < -step) diff = -step;
        return int24(int256(checkpointTick_) + diff);
    }

    /// @notice Materialize the virtual checkpoint. Permissionless — pokes only
    ///         ever move the checkpoint within its rate limit.
    /// @dev When the rate limit forces zero movement this call (e.g. too little
    ///      time elapsed for `step` to reach 1 tick — routine on sub-second-
    ///      block chains where a poke can see elapsed == 1s and floor(rate/60)
    ///      == 0), the clock is deliberately NOT reset. Otherwise frequent
    ///      pokes (griefing, or just busy deposit/harvest traffic) would floor
    ///      every step to zero and freeze the checkpoint, bricking deposits and
    ///      rebalances after a genuine move. Leaving `checkpointTime_` intact
    ///      lets `elapsed` accumulate until a whole tick of drift is due, so
    ///      total drift over wall-clock time is independent of poke frequency.
    function pokeCheckpoint() public {
        // Maintain the range-status clock on every poke — this is the
        // permissionless hook that lets anyone start the fallback timer on an
        // abandoned out-of-range position (runs before the drift early-return).
        _syncRangeStatus();
        (, int24 spot,,) = V4StateReader.getSlot0(poolManager, poolId);
        int24 next = _virtualCheckpoint(spot);
        if (next == checkpointTick_ && spot != checkpointTick_) return;
        checkpointTick_ = next;
        checkpointTime_ = uint64(block.timestamp);
        emit CheckpointPoked(next, spot);
    }

    /// @dev Range-status checkpoint driving the permissionless fallback. Starts
    ///      outOfRangeSince when the position is out of range and clears it
    ///      (advancing lastInRange) when it is back — each only when spot AND
    ///      the manipulation-resistant reference (rate-limited checkpoint) agree, so a flash move
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

    /// @dev The rate-limited checkpoint sits inside the position's range.
    function _refInRange() internal view returns (bool) {
        int24 ref = virtualCheckpoint();
        return ref >= tickLower && ref < tickUpper;
    }

    /// @notice Spot within `maxTickDeviation` of the rate-limited checkpoint.
    function isCalm() public view override returns (bool) {
        (, int24 spot,,) = V4StateReader.getSlot0(poolManager, poolId);
        int24 cp = _virtualCheckpoint(spot);
        int24 diff = spot > cp ? spot - cp : cp - spot;
        return diff <= maxTickDeviation;
    }

    // ---------------------------------------------------------------- views

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function totalLiquidity() public view override returns (uint128 liquidity_) {
        (liquidity_,,) = V4StateReader.getPositionInfo(
            poolManager, poolId, V4StateReader.positionKey(address(this), tickLower, tickUpper, SALT)
        );
    }

    function inRange() public view override returns (bool) {
        (, int24 tick,,) = V4StateReader.getSlot0(poolManager, poolId);
        return tick >= tickLower && tick < tickUpper;
    }

    function quoteDeposit(uint256 amount0Max, uint256 amount1Max)
        external
        view
        override
        returns (uint256 used0, uint256 used1, uint128 liquidity)
    {
        (uint160 sqrtPriceX96,,,) = V4StateReader.getSlot0(poolManager, poolId);
        return StrategyLib.quoteDeposit(sqrtPriceX96, tickLower, tickUpper, amount0Max, amount1Max);
    }

    // ----------------------------------------------------------------- admin

    function setRails(RailsV4 calldata rails) external onlyVaultOwner {
        _validateRails(rails);
        checkpointRatePerMinute = rails.checkpointRatePerMinute;
        checkpointElapsedCap = rails.checkpointElapsedCap;
        maxTickDeviation = rails.maxTickDeviation;
        rebalanceCooldown = rails.rebalanceCooldown;
        minTickWidth = rails.minTickWidth;
        maxTickWidth = rails.maxTickWidth;
        fallbackRebalanceDelay = rails.fallbackRebalanceDelay;
        emit RailsSet(
            rails.checkpointRatePerMinute,
            rails.checkpointElapsedCap,
            rails.maxTickDeviation,
            rails.rebalanceCooldown,
            rails.minTickWidth,
            rails.maxTickWidth,
            rails.fallbackRebalanceDelay
        );
    }

    // ------------------------------------------------------------ unlock core

    uint8 internal constant ACTION_MODIFY = 0;
    uint8 internal constant ACTION_SWAP = 1;

    struct Action {
        uint8 kind;
        int256 liquidityDelta; // MODIFY: signed liquidity change (0 = fee poke)
        address recipient; // MODIFY: where principal goes (fees always land here on the strategy)
        bool zeroForOne; // SWAP
        uint256 amountIn; // SWAP: exact input
        uint160 sqrtPriceLimit; // SWAP
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Action memory a = abi.decode(data, (Action));

        if (a.kind == ACTION_MODIFY) {
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
                _poolKey, ModifyLiquidityParams(tickLower, tickUpper, a.liquidityDelta, SALT), ""
            );
            // Principal component = callerDelta − feesAccrued. Fees always land
            // on the strategy (compounded at the next harvest); principal goes
            // to `recipient` (the strategy itself, or the withdrawer on divest).
            int128 p0 = callerDelta.amount0() - feesAccrued.amount0();
            int128 p1 = callerDelta.amount1() - feesAccrued.amount1();
            _settleOrTake(_poolKey.currency0, p0, a.recipient);
            _settleOrTake(_poolKey.currency1, p1, a.recipient);
            if (feesAccrued.amount0() > 0) {
                _settleOrTake(_poolKey.currency0, feesAccrued.amount0(), address(this));
            }
            if (feesAccrued.amount1() > 0) {
                _settleOrTake(_poolKey.currency1, feesAccrued.amount1(), address(this));
            }
            return abi.encode(callerDelta, feesAccrued);
        }

        // ACTION_SWAP — exact input (negative amountSpecified in V4).
        BalanceDelta d =
            poolManager.swap(_poolKey, SwapParams(a.zeroForOne, -int256(a.amountIn), a.sqrtPriceLimit), "");
        _settleOrTake(_poolKey.currency0, d.amount0(), address(this));
        _settleOrTake(_poolKey.currency1, d.amount1(), address(this));
        return abi.encode(d);
    }

    /// @dev Positive delta: PoolManager owes us — take to `to`. Negative: we owe —
    ///      sync/transfer/settle from the strategy's own balance.
    ///      Native currency0 converts at this boundary only: pay by unwrapping
    ///      exactly the owed WETH into the settle{value}; receive by taking
    ///      native to the strategy, wrapping, and forwarding WETH when the
    ///      recipient is someone else. Users therefore only ever see WETH.
    function _settleOrTake(Currency currency, int128 amount, address to) internal {
        bool isNative = native0 && Currency.unwrap(currency) == address(0);
        if (amount > 0) {
            if (isNative) {
                poolManager.take(currency, address(this), uint128(amount));
                IWETH9(weth).deposit{value: uint128(amount)}();
                if (to != address(this)) IERC20(weth).safeTransfer(to, uint128(amount));
            } else {
                poolManager.take(currency, to, uint128(amount));
            }
        } else if (amount < 0) {
            if (isNative) {
                IWETH9(weth).withdraw(uint128(-amount));
                poolManager.settle{value: uint128(-amount)}();
            } else {
                poolManager.sync(currency);
                IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), uint128(-amount));
                poolManager.settle();
            }
        }
    }

    function _modify(int256 liquidityDelta, address recipient)
        internal
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        bytes memory res =
            poolManager.unlock(abi.encode(Action(ACTION_MODIFY, liquidityDelta, recipient, false, 0, 0)));
        (callerDelta, feesAccrued) = abi.decode(res, (BalanceDelta, BalanceDelta));
    }

    function _swap(bool zeroForOne, uint256 amountIn, uint160 sqrtPriceLimit) internal {
        poolManager.unlock(abi.encode(Action(ACTION_SWAP, 0, address(0), zeroForOne, amountIn, sqrtPriceLimit)));
    }

    // ------------------------------------------------------------ vault flow

    function invest(uint256 amount0, uint256 amount1) external override onlyVault nonReentrant returns (uint128 liquidityAdded) {
        pokeCheckpoint();
        // A deposit must not spend pre-existing idle principal. The vault
        // prices that idle separately before minting the depositor's shares.
        liquidityAdded = _mintLiquidity(amount0, amount1);
    }

    function divest(uint256 shares, uint256 totalShares, address receiver)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        // Snapshot idle BEFORE the burn: fees collected by the burn stay for
        // harvest (V3 parity) and must not leak into this withdrawal's idle cut.
        uint256 idle0 = FullMath.mulDiv(IERC20(token0).balanceOf(address(this)), shares, totalShares);
        uint256 idle1 = FullMath.mulDiv(IERC20(token1).balanceOf(address(this)), shares, totalShares);

        uint128 liquidity_ = totalLiquidity();
        uint128 burnLiquidity = uint128(FullMath.mulDiv(liquidity_, shares, totalShares));
        if (burnLiquidity > 0) {
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _modify(-int256(uint256(burnLiquidity)), receiver);
            // Principal component of the remove. On a hookless pool this is
            // always >= 0; a hook taking a delta on remove could push it
            // negative, and the unchecked uint128 cast would wrap to ~2^128 —
            // silently defeating the withdrawer's min0/min1 slippage floor.
            // Trusted hooks must be ZERO_DELTA on liquidity ops; enforce it.
            int128 p0 = callerDelta.amount0() - feesAccrued.amount0();
            int128 p1 = callerDelta.amount1() - feesAccrued.amount1();
            if (p0 < 0 || p1 < 0) revert HookTookPrincipal();
            out0 += uint128(p0);
            out1 += uint128(p1);
            // V4 pays out the position's ENTIRE pending fee accrual on any
            // modifyLiquidity — V3 could leave fees in the pool for the next
            // harvest, V4 cannot. Split the performance fee here (all to the
            // treasury; there is no harvest caller) so divest timing can't
            // bypass it. Still zero swaps and zero oracle reads, and the
            // treasury transfer never reverts (payFees): a frozen treasury
            // cannot block this exit.
            StrategyLib.payFees(
                feeConfig,
                vault,
                token0,
                token1,
                feesAccrued.amount0() > 0 ? uint128(feesAccrued.amount0()) : 0,
                feesAccrued.amount1() > 0 ? uint128(feesAccrued.amount1()) : 0,
                address(0),
                true
            );
        }

        if (idle0 > 0) IERC20(token0).safeTransfer(receiver, idle0);
        if (idle1 > 0) IERC20(token1).safeTransfer(receiver, idle1);
        out0 += idle0;
        out1 += idle1;
    }

    // -------------------------------------------------------------- keeper

    /// @notice Permissionless compounding: collect fees, split the performance
    ///         fee (caller / treasury), swap the rest toward the position
    ///         ratio and reinvest.
    /// @inheritdoc IAurumStrategy
    /// @dev V4 keeps no tokensOwed term: fees live entirely in the growth
    ///      delta until a modifyLiquidity realizes them, so the delta IS the
    ///      whole answer here.
    function pendingFees()
        external
        view
        override
        returns (uint256 fees0, uint256 fees1, uint256 callerFee0, uint256 callerFee1)
    {
        (uint128 liq, uint256 inside0Last, uint256 inside1Last) = V4StateReader.getPositionInfo(
            poolManager, poolId, V4StateReader.positionKey(address(this), tickLower, tickUpper, SALT)
        );

        if (liq > 0) {
            (, int24 tickNow,,) = V4StateReader.getSlot0(poolManager, poolId);
            (uint256 g0, uint256 g1) = V4StateReader.getFeeGrowthGlobals(poolManager, poolId);
            (uint256 lo0, uint256 lo1) = V4StateReader.getTickFeeGrowthOutside(poolManager, poolId, tickLower);
            (uint256 up0, uint256 up1) = V4StateReader.getTickFeeGrowthOutside(poolManager, poolId, tickUpper);
            fees0 = FeeMath.feesEarned(
                FeeMath.feeGrowthInside(g0, lo0, up0, tickNow, tickLower, tickUpper), inside0Last, liq
            );
            fees1 = FeeMath.feesEarned(
                FeeMath.feeGrowthInside(g1, lo1, up1, tickNow, tickLower, tickUpper), inside1Last, liq
            );
        }

        (, uint256 callerBps,) = IFeeConfigView(feeConfig).getFees(vault);
        callerFee0 = (fees0 * callerBps) / BPS;
        callerFee1 = (fees1 * callerBps) / BPS;
    }

    function harvest(address callFeeRecipient) external override nonReentrant {
        if (!IVaultView(vault).isActive()) revert VaultNotActive();
        pokeCheckpoint();
        (uint256 fees0, uint256 fees1) = _harvest(callFeeRecipient);
        // Compounding runs a swap; only do it while calm — otherwise a
        // manipulated spot could force the compound trade to the edge of the
        // price band. Fees are already collected either way; when not calm they
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
            // outOfRangeSince is maintained by the permissionless pokeCheckpoint,
            // so anyone can start the clock on an abandoned position.
            if (
                inRange() || _refInRange() || outOfRangeSince == 0
                    || block.timestamp < outOfRangeSince + fallbackRebalanceDelay
            ) revert NotKeeperNorFallback();
            viaFallback = true;
        }

        if (block.timestamp < lastRebalance + rebalanceCooldown) revert CooldownActive();
        pokeCheckpoint();
        if (!isCalm()) revert NotCalm();
        _validateTicks(newTickLower, newTickUpper);
        // The new range must bracket the current price — same invariant and
        // rationale as the V3 strategy (bounds what a compromised keeper or
        // fallback caller can extract via the mandatory compound swap).
        (, int24 spotTick,,) = V4StateReader.getSlot0(poolManager, poolId);
        if (spotTick < newTickLower || spotTick >= newTickUpper) revert RangeMustBracketPrice();

        (uint256 hf0, uint256 hf1) = _harvest(msg.sender);

        uint128 liquidity_ = totalLiquidity();
        if (liquidity_ > 0) _modify(-int256(uint256(liquidity_)), address(this));

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
        pokeCheckpoint();
        if (!isCalm()) revert NotCalm();
        _compound();
        emit Reinvested(totalLiquidity());
    }

    // ------------------------------------------------------------- internals

    /// @dev Collect all pending fees (V4 pays them out on any modifyLiquidity,
    ///      including a 0-delta poke) and split the performance fee. Charged on
    ///      harvested yield only — never on principal.
    function _harvest(address callFeeRecipient) internal returns (uint256 fees0, uint256 fees1) {
        if (totalLiquidity() > 0) {
            (, BalanceDelta feesAccrued) = _modify(0, address(this)); // poke: fees → strategy
            fees0 = feesAccrued.amount0() > 0 ? uint128(feesAccrued.amount0()) : 0;
            fees1 = feesAccrued.amount1() > 0 ? uint128(feesAccrued.amount1()) : 0;
        }
        StrategyLib.payFees(feeConfig, vault, token0, token1, fees0, fees1, callFeeRecipient, false);
    }

    /// @dev Swap idle balances toward the position's composition (one bounded
    ///      swap, price-limited to the calm band around the checkpoint) and mint.
    function _compound() internal {
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        if (bal0 == 0 && bal1 == 0) return;

        (uint160 sqrtPriceX96, int24 tick,,) = V4StateReader.getSlot0(poolManager, poolId);
        // Price limit = edge of the calm band around the checkpoint (see
        // StrategyLib.compoundSwap): never worse than the manipulation bound.
        (uint256 amountIn, bool zeroForOne, uint160 limit) = StrategyLib.compoundSwap(
            bal0, bal1, sqrtPriceX96, tick, tickLower, tickUpper, _virtualCheckpoint(tick), maxTickDeviation
        );
        if (amountIn > 0) _swap(zeroForOne, amountIn, limit);

        _mintMaxLiquidity();
    }

    /// @dev Mint the maximum liquidity the current balances allow. One wei per
    ///      side is held back: V4 rounds owed amounts up on adds, and the
    ///      strategy must never over-commit its actual balance.
    function _mintMaxLiquidity() internal returns (uint128 liquidity_) {
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        return _mintLiquidity(bal0, bal1);
    }

    function _mintLiquidity(uint256 amount0, uint256 amount1) internal returns (uint128 liquidity_) {
        (uint160 sqrtPriceX96,,,) = V4StateReader.getSlot0(poolManager, poolId);
        liquidity_ = StrategyLib.liquidityFor(
            sqrtPriceX96, tickLower, tickUpper, amount0 > 0 ? amount0 - 1 : 0, amount1 > 0 ? amount1 - 1 : 0
        );
        if (liquidity_ > 0) _modify(int256(uint256(liquidity_)), address(this));
    }

    function _exitPosition() internal {
        uint128 liquidity_ = totalLiquidity();
        if (liquidity_ > 0) _modify(-int256(uint256(liquidity_)), address(this));
    }

    // ------------------------------------------------------------- internals

    /// @dev Reject inconsistent rail parameters (owner fat-finger
    ///      guard): a zero checkpoint rate/cap breaks the oracle, a non-positive
    ///      calm band bricks isCalm(), and minWidth must be positive and no
    ///      greater than maxWidth or _validateTicks can never be satisfied.
    function _validateRails(RailsV4 calldata rails) internal pure {
        if (rails.checkpointRatePerMinute == 0 || rails.checkpointElapsedCap == 0) revert BadRails();
        StrategyLib.validateBands(rails.maxTickDeviation, rails.minTickWidth, rails.maxTickWidth);
    }

    function _validateTicks(int24 lower, int24 upper) internal view {
        StrategyLib.validateTicks(lower, upper, tickSpacing, minTickWidth, maxTickWidth);
    }

    function _pps() internal view returns (uint256) {
        uint256 supply = IVaultView(vault).totalSupply();
        return supply == 0 ? 1e18 : FullMath.mulDiv(totalLiquidity(), 1e18, supply);
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max);
        return uint128(x);
    }

    /// @notice Accept ETH only from the PoolManager (take of a native leg) and
    ///         WETH (unwrap during a settle) — both transient within one
    ///         transaction. NOTE: this chain's WETH exposes a public
    ///         withdrawTo, so a third party CAN force stray ETH here. It is
    ///         inert — accounting always reads the WETH balance, never
    ///         address(this).balance — and wrapStrayEth() folds it into yield.
    ///         WETH checked first so the common unwrap path warms one SLOAD.
    receive() external payable {
        if (msg.sender != weth && msg.sender != address(poolManager)) revert NotPoolManager();
    }

    /// @notice Fold any stray native ETH into the vault as WETH: it becomes
    ///         idle inventory and compounds into the position at the next
    ///         harvest. Permissionless — it can only ever move value INTO the
    ///         vault, so griefed ETH donations turn into shareholder yield.
    function wrapStrayEth() external nonReentrant {
        uint256 bal = address(this).balance;
        if (bal > 0 && weth != address(0)) IWETH9(weth).deposit{value: bal}();
    }
}
