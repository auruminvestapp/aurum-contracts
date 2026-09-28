// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IAurumStrategy} from "./interfaces/IAurumStrategy.sol";
import {IUniswapV3SwapCallback} from "./interfaces/IUniswapV3Pool.sol";
import {ICLPool, ICLGauge, IVoter, ISlipstreamNFPM, ISlipstreamRouter} from "./interfaces/ISlipstream.sol";
import {RewardRoute, RouteEnv, RouteBook, SlipstreamRewardRoutes} from "./libraries/SlipstreamRewardRoutes.sol";
import {StrategyLib} from "./libraries/StrategyLib.sol";
import {FullMath} from "./vendor/uniswap/FullMath.sol";

interface IVaultView {
    function isActive() external view returns (bool);
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function totalSupply() external view returns (uint256);
}

interface IFeeConfigView {
    function getFees(address vault) external view returns (uint256 totalBps, uint256 callerBps, address treasury);
}

/// @title AurumStrategySlipstream — position mechanics for an up33 CL pool
///        (Aerodrome Slipstream clone), gauge-staked by default.
/// @notice The position lives as an NFPM tokenId. In `stakedMode` the NFT sits
///         in the pool's CLGauge and earns UP emissions instead of swap fees;
///         unstaked it earns (unstaked-fee-discounted) swap fees like a plain
///         V3 position. Harvest claims rewards, sells them into a pool token
///         along the first of an ordered list of reward routes that clears its
///         TWAP-referenced guards, and compounds. Routes are fixed at creation;
///         the vault owner can remove one at once or add one after a 48h
///         timelock, never anything outside up33's own pool factories. The up33 NFPM forbids touching liquidity of a staked
///         NFT (increase is gauge-only, decrease needs ownership), so every
///         liquidity mutation transparently unstakes and restakes around the
///         call — gauge withdraw has no admin gates, restake is skipped (never
///         reverts) when the gauge has been killed. Exits (divest,
///         emergencyExit) perform zero swaps and zero oracle reads.
contract AurumStrategySlipstream is
    IAurumStrategy,
    Initializable,
    ReentrancyGuard,
    IUniswapV3SwapCallback,
    IERC721Receiver
{
    using SafeERC20 for IERC20;

    struct RailsSS {
        uint32 twapInterval;
        int24 maxTickDeviation;
        uint256 rebalanceCooldown;
        int24 minTickWidth;
        int24 maxTickWidth;
        uint256 fallbackRebalanceDelay;
        uint16 maxRewardSaleSlippageBps; // TWAP-referenced bound on the reward→pool-token leg
    }

    uint256 internal constant BPS = 10_000;
    uint32 internal constant MIN_TWAP_INTERVAL = 30; // seconds — a shorter window is trivially skewed
    uint16 internal constant MAX_REWARD_SALE_SLIPPAGE_BPS = 500; // 5% — wider would hollow out the reward-sale guards
    uint256 public constant MAX_REWARD_ROUTES = SlipstreamRewardRoutes.MAX_ROUTES;
    // UP has 18 decimals. Ignore only sub-milli-UP rounding residue so a
    // microscopic direct transfer cannot keep deposits closed indefinitely.
    uint256 public constant MAX_UNSOLD_UP_DUST = 1e15;
    /// @notice Delay between announcing a new reward route and using it. A
    ///         route the owner adds could lead through a pool it can steer, so
    ///         the change is visible long enough for holders and the agent to
    ///         react; removing a route (which can only reduce options) is
    ///         immediate.
    uint256 public constant REWARD_ROUTE_TIMELOCK = SlipstreamRewardRoutes.TIMELOCK;

    ICLPool public pool;
    address public vault;
    address public override token0;
    address public override token1;
    int24 public tickSpacing;
    int24 public tickLower;
    int24 public tickUpper;

    ISlipstreamNFPM public nfpm;
    ISlipstreamRouter public swapRouter;
    ICLGauge public gauge;
    IVoter public voter;
    address public rewardToken;
    address public clFactory; // the position pool's factory; CL hops must come from it
    address public v2Factory; // up33's v2 pool factory; v2 hops must come from it

    RouteBook internal _routes; // active routes in priority order + one pending addition

    uint256 public tokenId; // 0 = no position NFT yet
    bool public stakedMode; // desired mode; actual staking may lag if the gauge dies

    // Rails — changeable only by the vault owner.
    uint32 public twapInterval; // seconds
    int24 public maxTickDeviation; // calm-period bound, in ticks
    uint256 public rebalanceCooldown; // seconds between rebalances (also rate-limits mode switches)
    int24 public minTickWidth;
    int24 public maxTickWidth;
    uint256 public fallbackRebalanceDelay; // out-of-range duration after which rebalance goes permissionless
    uint16 public maxRewardSaleSlippageBps;

    address public feeConfig;
    uint256 public lastRebalance;
    uint256 public lastInRange;
    uint256 public lastModeSwitch;
    uint256 public maxRewardSaleAmount; // 0 = sell the full UP balance
    // When the position most recently LEFT its range (0 while in range). The
    // permissionless fallback measures real out-of-range duration from this,
    // not from lastInRange (which only advances on harvest/rebalance and could
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
        uint32 twapInterval,
        int24 maxTickDeviation,
        uint256 cooldown,
        int24 minWidth,
        int24 maxWidth,
        uint256 fallbackDelay,
        uint16 maxRewardSaleSlippageBps
    );
    event ModeSwitched(bool stakedMode);
    event RewardsSold(uint256 indexed route, uint256 amountIn, uint256 amountOut);
    /// @dev `reason` is the failing hop's error selector (e.g. SaleOutOfBand,
    ///      RouteTooThin), for monitoring which route is breaking and why.
    event RewardRouteFailed(uint256 indexed route, bytes4 reason);
    event RewardSaleSkipped(uint256 amountHeld);
    event RewardRouteProposed(RewardRoute route, uint256 eta);
    event RewardRouteCancelled();
    event RewardRouteAdded(uint256 index, RewardRoute route);
    event RewardRouteRemoved(uint256 index);
    event MaxRewardSaleAmountSet(uint256 amount);

    error NotVault();
    error NotVaultOwner();
    error NotKeeper();
    error NotKeeperNorFallback();
    error NotPool();
    error NotNFPM();
    error VaultNotActive();
    error NotCalm();
    error CooldownActive();
    error BadTicks();
    error RangeMustBracketPrice();
    error ZeroAddress();
    error BadTwapInterval();
    error BadRails();
    error BadRewardRoute();
    error GaugeNotAlive();
    error NotSelf();
    error SaleOutOfBand();
    error RouteTooThin();
    error BelowBestRoute();
    error TooManyRoutes();
    error BadRouteIndex();
    error NoPendingRoute();
    error RouteTimelockActive();
    error UnsoldRewards(uint256 amount);

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

    /// @param routes Reward-sale routes in priority order. Required (1..4) when
    ///        the pool has a gauge whose reward token is not a position token;
    ///        must be empty otherwise.
    function initialize(
        address pool_,
        address vault_,
        address nfpm_,
        address swapRouter_,
        address v2Factory_,
        RewardRoute[] calldata routes,
        int24 tickLower_,
        int24 tickUpper_,
        address feeConfig_,
        RailsSS calldata rails
    ) external initializer {
        if (pool_ == address(0) || vault_ == address(0) || nfpm_ == address(0) || feeConfig_ == address(0)) {
            revert ZeroAddress();
        }
        _validateRails(rails);

        pool = ICLPool(pool_);
        vault = vault_;
        nfpm = ISlipstreamNFPM(nfpm_);
        swapRouter = ISlipstreamRouter(swapRouter_);
        token0 = pool.token0();
        token1 = pool.token1();
        tickSpacing = pool.tickSpacing();
        clFactory = pool.factory();
        v2Factory = v2Factory_;
        feeConfig = feeConfig_;

        twapInterval = rails.twapInterval;
        maxTickDeviation = rails.maxTickDeviation;
        rebalanceCooldown = rails.rebalanceCooldown;
        minTickWidth = rails.minTickWidth;
        maxTickWidth = rails.maxTickWidth;
        fallbackRebalanceDelay = rails.fallbackRebalanceDelay;
        maxRewardSaleSlippageBps = rails.maxRewardSaleSlippageBps;

        address gauge_ = pool.gauge();
        if (gauge_ != address(0)) {
            gauge = ICLGauge(gauge_);
            voter = IVoter(gauge.voter());
            rewardToken = gauge.rewardToken();
            stakedMode = voter.isAlive(gauge_);
        }

        if (_needsRewardSale()) {
            // The dust cap below is denominated in 18-decimal UP units.
            // Reject a different reward precision instead of silently making
            // that cap economically meaningless for future gauges.
            if (IERC20Metadata(rewardToken).decimals() != 18) revert BadRewardRoute();
            SlipstreamRewardRoutes.init(_routes, routes, _routeEnv());
        } else if (routes.length != 0) {
            revert BadRewardRoute();
        }

        _validateTicks(tickLower_, tickUpper_);
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        lastInRange = block.timestamp;
    }

    // ---------------------------------------------------------------- views

    function totalLiquidity() public view override returns (uint128 liquidity_) {
        if (tokenId == 0) return 0;
        (,,,,,,, liquidity_,,,,) = nfpm.positions(tokenId);
    }

    function inRange() public view override returns (bool) {
        (, int24 tick,,,,) = pool.slot0();
        return tick >= tickLower && tick < tickUpper;
    }

    /// @notice Spot tick within `maxTickDeviation` of the TWAP tick.
    function isCalm() public view override returns (bool) {
        (, int24 tick,,,,) = pool.slot0();
        int24 twap = twapTick();
        int24 diff = tick > twap ? tick - twap : twap - tick;
        return diff <= maxTickDeviation;
    }

    function twapTick() public view returns (int24) {
        return StrategyLib.twapTick(address(pool), twapInterval);
    }

    function rewardRouteCount() external view returns (uint256) {
        return _routes.routes.length;
    }

    function rewardRoute(uint256 index) external view returns (RewardRoute memory) {
        return _routes.routes[index];
    }

    function pendingRewardRoute() external view returns (RewardRoute memory route, uint256 eta) {
        return (_routes.pending, _routes.pendingEta);
    }

    /// @notice What selling `amountIn` of the reward token along route `index`
    ///         is worth at the TWAPs, net of pool fees, and the position token
    ///         it lands in. Reverts when an oracle on the route can't serve or
    ///         a hop is too thin to sell into (RouteTooThin) — exactly the
    ///         routes a harvest would pass over.
    function quoteRewardRoute(uint256 index, uint256 amountIn) external view returns (uint256 fairOut, address tokenOut) {
        return SlipstreamRewardRoutes.quote(_routes.routes[index], _routeEnv(), amountIn);
    }

    /// @notice True when the position NFT currently sits in the gauge.
    function isStaked() public view returns (bool) {
        if (tokenId == 0 || address(gauge) == address(0)) return false;
        return nfpm.ownerOf(tokenId) == address(gauge);
    }

    function quoteDeposit(uint256 amount0Max, uint256 amount1Max)
        external
        view
        override
        returns (uint256 used0, uint256 used1, uint128 liquidity)
    {
        _requireNoUnsoldRewards();
        (uint160 sqrtPriceX96,,,,,) = pool.slot0();
        return StrategyLib.quoteDeposit(sqrtPriceX96, tickLower, tickUpper, amount0Max, amount1Max);
    }

    // ------------------------------------------------------------ vault flow

    function invest(uint256 amount0, uint256 amount1) external override onlyVault nonReentrant returns (uint128 liquidityAdded) {
        _requireNoUnsoldRewards();
        liquidityAdded = _addLiquidity(amount0, amount1);
        // Unstaking the NFT inside _addLiquidity can claim another UP balance.
        // Never mint new shares against rewards released by that round trip.
        _requireNoUnsoldRewards();
    }

    function divest(uint256 shares, uint256 totalShares, address receiver)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        // Snapshot idle BEFORE unstaking: the gauge round trip collects pending
        // fees (and rewards) onto the strategy, and those belong to all holders
        // for the next harvest — not to this withdrawal's idle cut.
        uint256 idle0 = FullMath.mulDiv(IERC20(token0).balanceOf(address(this)), shares, totalShares);
        uint256 idle1 = FullMath.mulDiv(IERC20(token1).balanceOf(address(this)), shares, totalShares);

        uint128 liquidity_ = totalLiquidity();
        uint128 burnLiquidity = uint128(FullMath.mulDiv(liquidity_, shares, totalShares));
        if (burnLiquidity > 0) {
            // Pro-rata slice of the position principal, collected straight to
            // the receiver. No swaps, no oracle reads — the gauge withdraw has
            // no admin gates, and the restake is skipped rather than reverting
            // if the gauge has been killed, so the gauge can never block an
            // exit. (A pool token that refuses the transfer still can.)
            bool wasStaked = _unstakeIfStaked();
            (uint256 burned0, uint256 burned1) = nfpm.decreaseLiquidity(
                ISlipstreamNFPM.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: burnLiquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
            if (burned0 > 0 || burned1 > 0) {
                // Collect exactly the burned principal; pending fees stay on
                // the NFT for the next harvest (V3 parity).
                (uint256 c0, uint256 c1) = nfpm.collect(
                    ISlipstreamNFPM.CollectParams({
                        tokenId: tokenId,
                        recipient: receiver,
                        amount0Max: _u128(burned0),
                        amount1Max: _u128(burned1)
                    })
                );
                out0 += c0;
                out1 += c1;
            }
            if (wasStaked) _restakeIfWanted();
        }

        // Pro-rata slice of idle balances (compound dust, post-panic holdings).
        if (idle0 > 0) IERC20(token0).safeTransfer(receiver, idle0);
        if (idle1 > 0) IERC20(token1).safeTransfer(receiver, idle1);
        out0 += idle0;
        out1 += idle1;
    }

    // -------------------------------------------------------------- keeper

    /// @notice Permissionless compounding: claim gauge rewards (staked) or
    ///         collect swap fees (unstaked), sell rewards into a pool token
    ///         under the TWAP-referenced price limit, split the performance
    ///         fee (caller / treasury), swap toward the position ratio and
    ///         reinvest.
    /// @inheritdoc IAurumStrategy
    /// @dev PARTIAL on this strategy, and deliberately so. Two caveats a keeper
    ///      must know:
    ///
    ///      1. Only fees the NFPM has already REALIZED (tokensOwed) are counted.
    ///         Growth accrued since the position was last poked is not: reading
    ///         it needs the CL pool's tick-level accumulators, which ICLPool
    ///         does not expose. So this under-reports and never over-promises.
    ///      2. While staked the position earns gauge EMISSIONS instead of swap
    ///         fees, in a third token that harvest sells into the pool. That
    ///         cannot be stated in token0/token1 terms without pricing the
    ///         sale, so it is absent here — see pendingRewards().
    ///
    ///      A keeper on this strategy should read both.
    function pendingFees()
        external
        view
        override
        returns (uint256 fees0, uint256 fees1, uint256 callerFee0, uint256 callerFee1)
    {
        if (tokenId != 0 && !isStaked()) {
            (,,,,,,,,,, uint128 owed0, uint128 owed1) = nfpm.positions(tokenId);
            fees0 = owed0;
            fees1 = owed1;
        }
        (, uint256 callerBps,) = IFeeConfigView(feeConfig).getFees(vault);
        callerFee0 = (fees0 * callerBps) / BPS;
        callerFee1 = (fees1 * callerBps) / BPS;
    }

    /// @notice Gauge emissions the next harvest would claim, in `rewardToken`.
    /// @dev The other half of pendingFees() for this strategy. Harvest sells
    ///      this balance into a pool token and the proceeds join the same fee
    ///      split, so a caller earns callerBps of whatever the sale returns —
    ///      quoting that sale is the keeper's job, not this contract's.
    function pendingRewards() external view returns (address token, uint256 amount) {
        token = rewardToken;
        if (tokenId != 0 && isStaked()) amount = gauge.earned(address(this), tokenId);
    }

    function harvest(address callFeeRecipient) external override nonReentrant {
        if (!IVaultView(vault).isActive()) revert VaultNotActive();
        (uint256 fees0, uint256 fees1) = _harvest(callFeeRecipient);
        // Compounding runs a swap; only do it while calm, as V3/V4 do. Rewards
        // are claimed and sold either way; when not calm the proceeds wait
        // idle for a calmer harvest. Never reverts on price, so permissionless
        // harvesting is not griefable.
        if (isCalm()) _compound();
        _syncRangeStatus();
        emit Harvest(callFeeRecipient, fees0, fees1, _pps());
    }

    /// @notice Move the range. Keeper-only inside the rails; permissionless
    ///         once the position has sat out of range past the fallback delay.
    ///         Choreography: harvest → (unstake) → decrease-all → collect →
    ///         burn NFT → mint at the new range → (restake).
    function rebalance(int24 newTickLower, int24 newTickUpper) external override nonReentrant {
        if (!IVaultView(vault).isActive()) revert VaultNotActive();
        // Refresh the out-of-range clock first: a position that only just
        // exited has outOfRangeSince == now and cannot yet be force-rebalanced.
        _syncRangeStatus();

        bool viaFallback = false;
        if (msg.sender != IVaultView(vault).keeper()) {
            // Anyone may re-center a long-abandoned position — the protocol
            // must degrade gracefully if the agent disappears — but only after
            // it has ACTUALLY sat out of range for the full delay. The
            // permissionless harvest maintains outOfRangeSince, so anyone can
            // start the clock on an abandoned position.
            if (
                inRange() || _refInRange() || outOfRangeSince == 0
                    || block.timestamp < outOfRangeSince + fallbackRebalanceDelay
            ) revert NotKeeperNorFallback();
            viaFallback = true;
        }

        if (block.timestamp < lastRebalance + rebalanceCooldown) revert CooldownActive();
        if (!isCalm()) revert NotCalm();
        _validateTicks(newTickLower, newTickUpper);
        // The new range must bracket the current price — same invariant and
        // rationale as the V3 strategy (bounds what a compromised keeper or
        // fallback caller can extract via the mandatory compound swap).
        (, int24 spotTick,,,,) = pool.slot0();
        if (spotTick < newTickLower || spotTick >= newTickUpper) revert RangeMustBracketPrice();

        (uint256 hf0, uint256 hf1) = _harvest(msg.sender);

        // Exit the whole position and retire the NFT; the compound below mints
        // a fresh one at the new range.
        if (tokenId != 0) {
            _unstakeIfStaked();
            uint128 liquidity_ = totalLiquidity();
            if (liquidity_ > 0) {
                nfpm.decreaseLiquidity(
                    ISlipstreamNFPM.DecreaseLiquidityParams({
                        tokenId: tokenId,
                        liquidity: liquidity_,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp
                    })
                );
            }
            nfpm.collect(
                ISlipstreamNFPM.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            nfpm.burn(tokenId);
            tokenId = 0;
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

    /// @notice Switch between gauge-staked (UP emissions) and unstaked (swap
    ///         fees) mode. Keeper-only, rate-limited by the rebalance cooldown.
    ///         Pure custody move — liquidity, range and PPS are untouched.
    function setStakedMode(bool stakedMode_) external nonReentrant {
        if (msg.sender != IVaultView(vault).keeper()) revert NotKeeper();
        if (block.timestamp < lastModeSwitch + rebalanceCooldown) revert CooldownActive();
        lastModeSwitch = block.timestamp;
        stakedMode = stakedMode_;
        if (stakedMode_) {
            if (address(gauge) == address(0) || !voter.isAlive(address(gauge))) revert GaugeNotAlive();
            _restakeIfWanted();
        } else {
            _unstakeIfStaked();
        }
        emit ModeSwitched(stakedMode_);
    }

    // ------------------------------------------------------------ emergency

    /// @dev Zero swaps, zero oracle reads — must work mid-manipulation. The
    ///      gauge withdraw is owner-of-deposit with no admin gates.
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

    function setRails(RailsSS calldata rails) external onlyVaultOwner {
        _validateRails(rails);
        twapInterval = rails.twapInterval;
        maxTickDeviation = rails.maxTickDeviation;
        rebalanceCooldown = rails.rebalanceCooldown;
        minTickWidth = rails.minTickWidth;
        maxTickWidth = rails.maxTickWidth;
        fallbackRebalanceDelay = rails.fallbackRebalanceDelay;
        maxRewardSaleSlippageBps = rails.maxRewardSaleSlippageBps;
        emit RailsSet(
            rails.twapInterval,
            rails.maxTickDeviation,
            rails.rebalanceCooldown,
            rails.minTickWidth,
            rails.maxTickWidth,
            rails.fallbackRebalanceDelay,
            rails.maxRewardSaleSlippageBps
        );
    }

    /// @notice Cap each UP sale while working down a balance too large for
    ///         any route's depth limit. Zero restores full-balance sales.
    ///         The owner already controls route removal; this recovery control
    ///         cannot be used by an arbitrary harvest caller to select routes.
    function setMaxRewardSaleAmount(uint256 amount) external onlyVaultOwner {
        maxRewardSaleAmount = amount;
        emit MaxRewardSaleAmountSet(amount);
    }

    /// @notice Announce a reward route; usable after REWARD_ROUTE_TIMELOCK.
    ///         Replaces any route still pending.
    ///         Must end in the same position token as the active routes.
    function proposeRewardRoute(RewardRoute calldata route) external onlyVaultOwner {
        if (!_needsRewardSale()) revert BadRewardRoute();
        SlipstreamRewardRoutes.propose(_routes, route, _routeEnv());
    }

    function cancelRewardRoute() external onlyVaultOwner {
        SlipstreamRewardRoutes.cancel(_routes);
    }

    /// @notice Append the announced route once its timelock has run. Anyone
    ///         may call it: the decision was the owner's, 48 hours ago. The
    ///         route is validated again — its pools must still be up33's and
    ///         its output the active routes' token.
    function activateRewardRoute() external {
        SlipstreamRewardRoutes.activate(_routes, _routeEnv());
    }

    /// @notice Drop a route at once, keeping the others' order. With none left
    ///         rewards are held (and retried) until a route is added; the
    ///         keeper can meanwhile switch the position to earning fees.
    function removeRewardRoute(uint256 index) external onlyVaultOwner {
        SlipstreamRewardRoutes.remove(_routes, index);
    }

    // ------------------------------------------------------------- callbacks

    /// @dev Only the strategy's own pool may demand payment — the ratio swap in
    ///      `_compound` runs directly on the pool. The reward sale goes through
    ///      the router, which handles its own callback.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        if (msg.sender != address(pool)) revert NotPool();
        if (amount0Delta > 0) IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    /// @dev The gauge returns the staked NFT via safeTransferFrom on withdraw.
    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != address(nfpm)) revert NotNFPM();
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------- internals

    /// @dev Claim yield and split the performance fee. Staked: gauge rewards,
    ///      claimed in place (no unstake needed) and sold into a pool token.
    ///      Unstaked: NFPM fee collection. Charged on harvested yield only —
    ///      never on principal.
    function _harvest(address callFeeRecipient) internal returns (uint256 fees0, uint256 fees1) {
        if (tokenId != 0) {
            if (isStaked()) {
                gauge.getReward(tokenId); // emissions accrue instead of fees while staked
            } else if (totalLiquidity() > 0) {
                (fees0, fees1) = nfpm.collect(
                    ISlipstreamNFPM.CollectParams({
                        tokenId: tokenId,
                        recipient: address(this),
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                );
            }
        }

        // Sell the reward balance, or the owner-set recovery tranche while
        // working down an oversized backlog. Proceeds join the fee split.
        // See SlipstreamRewardRoutes.sellBest.
        (uint256 sold, address soldInto) = SlipstreamRewardRoutes.sellBest(_routes, _routeEnv(), maxRewardSaleAmount);
        if (sold > 0) {
            if (soldInto == token0) fees0 += sold;
            else fees1 += sold;
        }

        StrategyLib.payFees(feeConfig, vault, token0, token1, fees0, fees1, callFeeRecipient, false);
    }

    /// @notice One reward-sale attempt along route `index`, priced at
    ///         `fairOut` just before. Self-call only — external so a failing
    ///         route reverts just this frame.
    /// @dev Guards, per hop: a CL hop is price-limited to
    ///      `maxRewardSaleSlippageBps` around its TWAP (1 tick ≈ 1 bp) and
    ///      skipped when spot already sits outside that band; a v2 hop's
    ///      output must clear its TWAP quote by the same margin; each hop
    ///      demands its TWAP-implied output minus the allowance. Over the
    ///      whole route: the output must clear `fairOut` minus ONE allowance,
    ///      so two in-band hops cannot compound into two.
    function sellRewardsVia(uint256 index, uint256 amountIn, uint256 fairOut)
        external
        returns (uint256 amountOut, address tokenOut)
    {
        if (msg.sender != address(this)) revert NotSelf();
        return SlipstreamRewardRoutes.sell(_routes.routes[index], _routeEnv(), amountIn, fairOut);
    }

    /// @dev The gauge pays a token the position doesn't hold, so it must be sold.
    function _needsRewardSale() internal view returns (bool) {
        return rewardToken != address(0) && rewardToken != token0 && rewardToken != token1;
    }

    function _requireNoUnsoldRewards() internal view {
        if (!_needsRewardSale()) return;
        uint256 held = IERC20(rewardToken).balanceOf(address(this));
        if (held > MAX_UNSOLD_UP_DUST) revert UnsoldRewards(held);
    }

    function _routeEnv() internal view returns (RouteEnv memory) {
        return RouteEnv({
            rewardToken: rewardToken,
            token0: token0,
            token1: token1,
            clFactory: clFactory,
            v2Factory: v2Factory,
            swapRouter: address(swapRouter),
            twapInterval: twapInterval,
            slippageBps: maxRewardSaleSlippageBps
        });
    }

    function _pps() internal view returns (uint256) {
        uint256 supply = IVaultView(vault).totalSupply();
        return supply == 0 ? 1e18 : FullMath.mulDiv(totalLiquidity(), 1e18, supply);
    }

    /// @dev Swap idle balances toward the position's composition (one bounded
    ///      swap, price-limited to the calm band around TWAP) and add them to
    ///      the position.
    function _compound() internal {
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        if (bal0 == 0 && bal1 == 0) return;

        (uint160 sqrtPriceX96, int24 tick,,,,) = pool.slot0();
        (uint256 amountIn, bool zeroForOne, uint160 limit) = StrategyLib.compoundSwap(
            bal0, bal1, sqrtPriceX96, tick, tickLower, tickUpper, twapTick(), maxTickDeviation
        );
        if (amountIn > 0) {
            pool.swap(address(this), zeroForOne, int256(amountIn), limit, "");
            bal0 = IERC20(token0).balanceOf(address(this));
            bal1 = IERC20(token1).balanceOf(address(this));
        }

        _addLiquidity(bal0, bal1);
    }

    /// @dev Add `amount0`/`amount1` to the position NFT — minting it if there
    ///      is none — unstaking/restaking transparently around the call, since
    ///      the up33 NFPM refuses liquidity changes on a staked NFT. Skips
    ///      entirely (no gauge round trip) when the amounts round to zero
    ///      liquidity. Approvals are per-call and reset to zero.
    function _addLiquidity(uint256 amount0, uint256 amount1) internal returns (uint128 liquidityAdded) {
        (uint160 sqrtPriceX96,,,,,) = pool.slot0();
        uint128 expected = StrategyLib.liquidityFor(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);
        if (expected == 0) return 0;

        // Approve the full balance, not just the request: the pool rounds owed
        // amounts up by a wei vs. the NFPM's round-down liquidity math.
        IERC20(token0).forceApprove(address(nfpm), IERC20(token0).balanceOf(address(this)));
        IERC20(token1).forceApprove(address(nfpm), IERC20(token1).balanceOf(address(this)));

        if (tokenId == 0) {
            (uint256 newId, uint128 liq,,) = nfpm.mint(
                ISlipstreamNFPM.MintParams({
                    token0: token0,
                    token1: token1,
                    tickSpacing: tickSpacing,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0Desired: amount0,
                    amount1Desired: amount1,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp,
                    sqrtPriceX96: 0
                })
            );
            tokenId = newId;
            liquidityAdded = liq;
            _restakeIfWanted();
        } else {
            bool wasStaked = _unstakeIfStaked();
            (liquidityAdded,,) = nfpm.increaseLiquidity(
                ISlipstreamNFPM.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: amount0,
                    amount1Desired: amount1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
            if (wasStaked || stakedMode) _restakeIfWanted();
        }

        IERC20(token0).forceApprove(address(nfpm), 0);
        IERC20(token1).forceApprove(address(nfpm), 0);
    }

    /// @dev Pull the NFT out of the gauge. The gauge claims pending rewards and
    ///      collects pending fees to the strategy as side effects. No admin
    ///      gates: works even when the gauge is killed.
    function _unstakeIfStaked() internal returns (bool wasStaked) {
        if (!isStaked()) return false;
        gauge.withdraw(tokenId);
        return true;
    }

    /// @dev Put the NFT (back) into the gauge when staked mode wants it there.
    ///      Deliberately a no-op — never a revert — when the gauge is dead or
    ///      the position is empty, so deposits and exits keep working after a
    ///      gauge kill; the position then simply earns fees unstaked.
    function _restakeIfWanted() internal {
        if (!stakedMode || tokenId == 0 || address(gauge) == address(0)) return;
        if (isStaked()) return;
        if (!voter.isAlive(address(gauge))) return;
        if (totalLiquidity() == 0) return;
        nfpm.approve(address(gauge), tokenId);
        gauge.deposit(tokenId);
    }

    /// @dev (Unstake and) empty the position into the strategy. Keeps the NFT
    ///      for later re-entry. Zero swaps, zero oracle reads.
    function _exitPosition() internal {
        if (tokenId == 0) return;
        _unstakeIfStaked();
        uint128 liquidity_ = totalLiquidity();
        if (liquidity_ > 0) {
            nfpm.decreaseLiquidity(
                ISlipstreamNFPM.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity_,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }
        // Collect everything owed: burned principal plus any pending fees.
        nfpm.collect(
            ISlipstreamNFPM.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    function _validateTicks(int24 lower, int24 upper) internal view {
        StrategyLib.validateTicks(lower, upper, tickSpacing, minTickWidth, maxTickWidth);
    }

    /// @dev Owner fat-finger guard (see StrategyLib.validateBands), plus the
    ///      TWAP window floor and the reward-sale slippage ceiling.
    function _validateRails(RailsSS calldata rails) internal pure {
        if (rails.twapInterval < MIN_TWAP_INTERVAL) revert BadTwapInterval();
        if (rails.maxRewardSaleSlippageBps > MAX_REWARD_SALE_SLIPPAGE_BPS) revert BadRails();
        StrategyLib.validateBands(rails.maxTickDeviation, rails.minTickWidth, rails.maxTickWidth);
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

    function _u128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max);
        return uint128(x);
    }
}
