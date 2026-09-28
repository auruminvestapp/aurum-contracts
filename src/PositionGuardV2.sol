// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool, IUniswapV3SwapCallback} from "./interfaces/IUniswapV3Pool.sol";
import {TickMath} from "./vendor/uniswap/TickMath.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    Currency,
    SwapParams,
    BalanceDelta,
    BalanceDeltaLibrary
} from "./vendor/uniswap/v4/V4Core.sol";
import {V4StateReader} from "./vendor/uniswap/v4/V4StateReader.sol";

interface IGuardVault {
    function strategy() external view returns (address);
    function token0() external view returns (IERC20);
    function token1() external view returns (IERC20);
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address receiver)
        external
        returns (uint256 out0, uint256 out1);
}

interface IGuardStrategy {
    function pool() external view returns (IUniswapV3Pool);
    function twapInterval() external view returns (uint32);
}

interface IGuardStrategyV4 {
    function poolManager() external view returns (IPoolManager);
    function poolKey() external view returns (PoolKey memory);
    function virtualCheckpoint() external view returns (int24);
    function native0() external view returns (bool);
}

interface IGuardRegistry {
    function isAurumVault(address vault) external view returns (bool);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @title PositionGuardV2 — user-signed standing exit orders on V3 AND V4 vaults.
/// @notice A payout rail that cannot steal: the designated executor decides WHEN
///         (all trigger judgment is off-chain), the user's registration decides
///         everything else — how much per side, and what payout token via which
///         route, with pool-enforced price limits (TWAP band on V3 vault pools,
///         the strategy's rate-limited checkpoint band on V4 vault pools).
///         Second-hop route pools remain V3-only and canonical-factory
///         validated. Proceeds always go to the registered owner. Ownerless,
///         immutable, no external oracle.
contract PositionGuardV2 is ReentrancyGuard, IUniswapV3SwapCallback, IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_SLIPPAGE_BPS = 500;
    uint32 public constant ROUTE_TWAP_WINDOW = 300;

    IGuardRegistry public immutable registryV3;
    /// @notice up33 (Slipstream) vaults: V3-shaped pools (same swap, callback
    ///         and observe), so they take the V3 path. Zero = none.
    IGuardRegistry public immutable registrySlipstream;
    IGuardRegistry public immutable registryV4;
    /// @dev Canonical Uniswap V3 factory used to validate route pools for
    ///      orders on V4 vaults (whose own pool carries no `.factory()`).
    ///      V3-vault orders keep deriving it from the vault's own pool.
    address public immutable v3Factory;

    struct Order {
        address executor; // the only address allowed to execute
        uint128 stopValue; // contract-opaque; convention USD cents; 0 = no stop side
        uint128 takeValue; // contract-opaque; convention USD cents; 0 = no take side
        uint16 stopExitBps; // fraction of position exited when the stop fires
        uint16 takeExitBps; // fraction of position exited when the take fires
        bool stopFired; // each side fires at most once per registration
        bool takeFired;
        address tokenOut; // 0 = in-kind payout
        address routePool; // 0 = tokenOut is a pool token; else second-hop V3 pool
        uint16 maxSlippageBps; // per-hop price-limit band, in ticks (1 tick ≈ 1 bps)
    }

    mapping(address vault => mapping(address user => Order)) public orders;

    // Set for the duration of one swap so the callback can authenticate.
    address private _expectedPool;
    IPoolManager private _expectedPM;
    bytes32 private _expectedPoolId;

    event Registered(
        address indexed vault,
        address indexed user,
        address executor,
        uint128 stopValue,
        uint16 stopExitBps,
        uint128 takeValue,
        uint16 takeExitBps,
        address tokenOut,
        address routePool,
        uint16 maxSlippageBps
    );
    event Cancelled(address indexed vault, address indexed user);
    event Executed(
        address indexed vault,
        address indexed user,
        bool isStop,
        uint256 shares,
        uint256 out0,
        uint256 out1,
        address tokenOut,
        uint256 amountOut
    );

    error NotAurumVault();
    error ZeroAddress();
    error NoSides();
    error BadExitBps();
    error NoShares();
    error BadZapConfig();
    error NoOrder();
    error NotExecutor();
    error SideUnavailable();
    error NothingToExit();
    error SharesTransferFailed();
    error NotPool();

    constructor(address registryV3_, address registrySlipstream_, address registryV4_, address v3Factory_) {
        if (registryV3_ == address(0) || registryV4_ == address(0) || v3Factory_ == address(0)) revert ZeroAddress();
        registryV3 = IGuardRegistry(registryV3_);
        registrySlipstream = IGuardRegistry(registrySlipstream_);
        registryV4 = IGuardRegistry(registryV4_);
        v3Factory = v3Factory_;
    }

    function _isAurum(address vault) internal view returns (bool) {
        return registryV3.isAurumVault(vault) || registryV4.isAurumVault(vault) || _isSlipstream(vault);
    }

    function _isSlipstream(address vault) internal view returns (bool) {
        return address(registrySlipstream) != address(0) && registrySlipstream.isAurumVault(vault);
    }

    function _isV4(address vault) internal view returns (bool) {
        return registryV4.isAurumVault(vault);
    }

    /// @notice Sign a standing exit order. Overwrites any existing order for
    ///         (vault, caller) — this is also the update path; fired flags reset.
    function register(
        address vault,
        address executor,
        uint128 stopValue,
        uint16 stopExitBps,
        uint128 takeValue,
        uint16 takeExitBps,
        address tokenOut,
        address routePool,
        uint16 maxSlippageBps
    ) external {
        if (!_isAurum(vault)) revert NotAurumVault();
        if (executor == address(0)) revert ZeroAddress();
        if (stopValue == 0 && takeValue == 0) revert NoSides();
        if ((stopValue == 0) != (stopExitBps == 0)) revert BadExitBps();
        if ((takeValue == 0) != (takeExitBps == 0)) revert BadExitBps();
        if (stopExitBps > BPS || takeExitBps > BPS) revert BadExitBps();
        if (IGuardVault(vault).balanceOf(msg.sender) == 0) revert NoShares();

        _validateZap(vault, tokenOut, routePool, maxSlippageBps);

        orders[vault][msg.sender] = Order({
            executor: executor,
            stopValue: stopValue,
            takeValue: takeValue,
            stopExitBps: stopExitBps,
            takeExitBps: takeExitBps,
            stopFired: false,
            takeFired: false,
            tokenOut: tokenOut,
            routePool: routePool,
            maxSlippageBps: maxSlippageBps
        });

        emit Registered(
            vault, msg.sender, executor, stopValue, stopExitBps, takeValue, takeExitBps, tokenOut, routePool, maxSlippageBps
        );
    }

    function cancel(address vault) external {
        delete orders[vault][msg.sender];
        emit Cancelled(vault, msg.sender);
    }

    /// @notice Fire one side of a standing order. Executor-only; the contract
    ///         cannot price-check WHY (that is the executor's off-chain duty) —
    ///         what it enforces is the user-signed fraction and payout plan.
    ///         `inKind = true` forces the raw two-token payout even when a zap
    ///         is configured (the guaranteed-floor fallback).
    function executeExit(address vault, address user, bool isStop, bool inKind)
        external
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        Order memory o = orders[vault][user];
        if (o.executor == address(0)) revert NoOrder();
        if (msg.sender != o.executor) revert NotExecutor();

        uint128 sideValue = isStop ? o.stopValue : o.takeValue;
        bool alreadyFired = isStop ? o.stopFired : o.takeFired;
        if (sideValue == 0 || alreadyFired) revert SideUnavailable();
        uint16 exitBps = isStop ? o.stopExitBps : o.takeExitBps;

        IGuardVault v = IGuardVault(vault);
        uint256 bal = v.balanceOf(user);
        uint256 allow = v.allowance(user, address(this));
        uint256 base = allow < bal ? allow : bal;
        uint256 shares = (base * exitBps) / BPS;
        if (shares == 0) revert NothingToExit();

        // Effects before interactions: a truly full exit (100% AND allowance
        // covered the whole balance) or the second side firing removes the
        // order entirely; anything partial leaves the other side armed.
        // (Audit finding: an allowance-capped "100%" exit must not strand a
        // still-armed second side by over-deleting.)
        bool fullExit = exitBps == BPS && base == bal;
        bool otherSpent = isStop ? (o.takeValue == 0 || o.takeFired) : (o.stopValue == 0 || o.stopFired);
        if (fullExit || otherSpent) {
            delete orders[vault][user];
        } else if (isStop) {
            orders[vault][user].stopFired = true;
        } else {
            orders[vault][user].takeFired = true;
        }

        if (!v.transferFrom(user, address(this), shares)) revert SharesTransferFailed();
        // min0 = min1 = 0 is safe: pro-rata in-kind, no swap, no price-dependent amount.
        (out0, out1) = v.withdraw(shares, 0, 0, address(this));

        address paidToken = address(0);
        uint256 amountOut = 0;
        if (!inKind && o.tokenOut != address(0)) {
            (paidToken, amountOut) = _zap(vault, v, o);
        }
        _payAll(v.token0(), v.token1(), paidToken, user);

        emit Executed(vault, user, isStop, shares, out0, out1, paidToken, amountOut);
    }

    // ------------------------------------------------------------ internals

    /// @dev Payout plan rules: all-zero = in-kind (the only plan for a
    ///      native-currency V4 vault). Otherwise the band must be
    ///      sane, and a non-pool tokenOut needs a route pool that contains it
    ///      AND bridges through one of the vault's own pool tokens. Route
    ///      pools are ALWAYS V3 pools, validated against the canonical V3
    ///      factory — for V4 and Slipstream vaults the immutable `v3Factory`
    ///      (a Slipstream pool's own factory keys pools by tick spacing, not
    ///      fee), for V3 vaults the factory their own pool reports.
    function _validateZap(address vault, address tokenOut, address routePool, uint16 maxSlippageBps) internal view {
        if (tokenOut == address(0)) {
            if (routePool != address(0) || maxSlippageBps != 0) revert BadZapConfig();
            return;
        }
        if (maxSlippageBps == 0 || maxSlippageBps > MAX_SLIPPAGE_BPS) revert BadZapConfig();
        // The V4 swap leg here settles ERC-20s only. A native-ETH V4 vault
        // (WETH face over a native currency0) would revert every one-token
        // payout, so it gets in-kind orders only.
        if (_isV4(vault) && IGuardStrategyV4(IGuardVault(vault).strategy()).native0()) revert BadZapConfig();

        address t0 = address(IGuardVault(vault).token0());
        address t1 = address(IGuardVault(vault).token1());
        if (tokenOut == t0 || tokenOut == t1) {
            if (routePool != address(0)) revert BadZapConfig();
            return;
        }
        if (routePool == address(0)) revert BadZapConfig();
        address r0 = IUniswapV3Pool(routePool).token0();
        address r1 = IUniswapV3Pool(routePool).token1();
        if (tokenOut != r0 && tokenOut != r1) revert BadZapConfig();
        address bridge = tokenOut == r0 ? r1 : r0;
        if (bridge != t0 && bridge != t1) revert BadZapConfig();

        // The route pool must be a REAL pool from the canonical V3 factory —
        // duck-typed token0/token1 views are not enough. (Audit finding: a
        // fake "pool" could reenter the swap callback and drain the
        // registrant's own in-flight exit — phishing surface.)
        address canonicalFactory = _isV4(vault) || _isSlipstream(vault)
            ? v3Factory
            : IGuardStrategy(IGuardVault(vault).strategy()).pool().factory();
        if (IUniswapV3Factory(canonicalFactory).getPool(r0, r1, IUniswapV3Pool(routePool).fee()) != routePool) {
            revert BadZapConfig();
        }
    }

    /// @dev Run the user-signed payout plan: sell the unwanted vault-pool side,
    ///      optionally bridge one hop, all with price-pinned limits. Any
    ///      residue (price-limit leftovers) is swept in-kind by _payAll.
    function _zap(address vault, IGuardVault v, Order memory o)
        internal
        returns (address paidToken, uint256 amountOut)
    {
        address t0 = address(v.token0());
        address t1 = address(v.token1());

        // Hop-1 target inside the vault pool: tokenOut itself when it is a pool
        // token, else the bridge (the route-pool token shared with the vault pool).
        address bridge = address(0);
        address hop1Target = o.tokenOut;
        if (o.routePool != address(0)) {
            IUniswapV3Pool rp = IUniswapV3Pool(o.routePool);
            address r0 = rp.token0();
            bridge = r0 == o.tokenOut ? rp.token1() : r0;
            hop1Target = bridge;
        }

        // Hop 1: sell the entire non-target side in the vault's own pool.
        address sell = hop1Target == t0 ? t1 : t0;
        uint256 sellBal = IERC20(sell).balanceOf(address(this));
        if (sellBal > 0) {
            if (_isV4(vault)) {
                _boundedSwapV4(vault, sell == t0, sellBal, o.maxSlippageBps);
            } else {
                // Window floored at ROUTE_TWAP_WINDOW (audit L-1): a strategy's
                // rails allow intervals as short as 30s, too cheap to hold
                // skewed on a thin pool.
                IGuardStrategy strat = IGuardStrategy(v.strategy());
                uint32 hop1Window = strat.twapInterval();
                if (hop1Window < ROUTE_TWAP_WINDOW) hop1Window = ROUTE_TWAP_WINDOW;
                _boundedSwap(strat.pool(), sell == t0, sellBal, hop1Window, o.maxSlippageBps);
            }
        }

        // Hop 2: bridge → tokenOut in the (always-V3) route pool.
        if (bridge != address(0)) {
            IUniswapV3Pool rp = IUniswapV3Pool(o.routePool);
            uint256 bridgeBal = IERC20(bridge).balanceOf(address(this));
            if (bridgeBal > 0) {
                _boundedSwap(rp, bridge == rp.token0(), bridgeBal, ROUTE_TWAP_WINDOW, o.maxSlippageBps);
            }
        }

        paidToken = o.tokenOut;
        amountOut = IERC20(o.tokenOut).balanceOf(address(this));
    }

    /// @dev V3 exact-input swap that the pool itself refuses to fill beyond
    ///      TWAP ± band ticks. A partial fill simply leaves input tokens here;
    ///      a spot already past the band makes the pool revert (SPL).
    function _boundedSwap(IUniswapV3Pool pool_, bool zeroForOne, uint256 amountIn, uint32 window, uint16 bandTicks)
        internal
    {
        int24 twap = _twapTick(pool_, window);
        uint160 limit = zeroForOne
            ? TickMath.getSqrtRatioAtTick(twap - int24(uint24(bandTicks)))
            : TickMath.getSqrtRatioAtTick(twap + int24(uint24(bandTicks)));
        _expectedPool = address(pool_);
        pool_.swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(pool_.token0(), pool_.token1()));
        _expectedPool = address(0);
    }

    /// @dev V4 exact-input swap price-limited to the strategy's checkpoint
    ///      band — the V4 analog of the TWAP band: the checkpoint is rate-
    ///      limited on-chain, so a flash-skewed spot cannot move the limit.
    function _boundedSwapV4(address vault, bool zeroForOne, uint256 amountIn, uint16 bandTicks) internal {
        IGuardStrategyV4 s = IGuardStrategyV4(IGuardVault(vault).strategy());
        IPoolManager pm = s.poolManager();
        PoolKey memory key = s.poolKey();
        int24 refTick = s.virtualCheckpoint();
        // Clamp to the tick domain so a pool priced near an extreme can't make
        // getSqrtRatioAtTick revert (bricking the zap; the executor can still
        // fall back to inKind).
        int24 lo = _clampTick(refTick - int24(uint24(bandTicks)));
        int24 hi = _clampTick(refTick + int24(uint24(bandTicks)));
        uint160 limit = zeroForOne ? TickMath.getSqrtRatioAtTick(lo) : TickMath.getSqrtRatioAtTick(hi);

        _expectedPM = pm;
        _expectedPoolId = V4StateReader.poolIdFor(key);
        pm.unlock(abi.encode(key, zeroForOne, amountIn, limit));
        _expectedPM = IPoolManager(address(0));
        _expectedPoolId = bytes32(0);
    }

    function _clampTick(int24 tick) internal pure returns (int24) {
        if (tick < TickMath.MIN_TICK) return TickMath.MIN_TICK;
        if (tick > TickMath.MAX_TICK) return TickMath.MAX_TICK;
        return tick;
    }

    function _twapTick(IUniswapV3Pool pool_, uint32 window) internal view returns (int24 tick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = pool_.observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        tick = int24(delta / int56(uint56(window)));
        if (delta < 0 && (delta % int56(uint56(window)) != 0)) tick--;
    }

    /// @dev Sweep every relevant balance to the user. The guard never keeps funds.
    function _payAll(IERC20 t0, IERC20 t1, address extra, address user) internal {
        _pay(t0, user);
        _pay(t1, user);
        if (extra != address(0) && extra != address(t0) && extra != address(t1)) _pay(IERC20(extra), user);
    }

    function _pay(IERC20 token, address user) internal {
        uint256 bal = token.balanceOf(address(this));
        if (bal > 0) token.safeTransfer(user, bal);
    }

    // ------------------------------------------------------------- callbacks

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata data) external {
        if (msg.sender != _expectedPool) revert NotPool();
        (address t0, address t1) = abi.decode(data, (address, address));
        if (d0 > 0) IERC20(t0).safeTransfer(msg.sender, uint256(d0));
        if (d1 > 0) IERC20(t1).safeTransfer(msg.sender, uint256(d1));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(_expectedPM)) revert NotPool();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit) =
            abi.decode(data, (PoolKey, bool, uint256, uint160));
        if (V4StateReader.poolIdFor(key) != _expectedPoolId) revert NotPool();

        BalanceDelta d = _expectedPM.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        Currency cin = zeroForOne ? key.currency0 : key.currency1;
        Currency cout = zeroForOne ? key.currency1 : key.currency0;
        int128 owed = zeroForOne ? d.amount0() : d.amount1();
        if (owed < 0) {
            _expectedPM.sync(cin);
            IERC20(Currency.unwrap(cin)).safeTransfer(address(_expectedPM), uint256(uint128(-owed)));
            _expectedPM.settle();
        }
        int128 got = zeroForOne ? d.amount1() : d.amount0();
        if (got > 0) _expectedPM.take(cout, address(this), uint256(uint128(got)));
        return "";
    }
}
