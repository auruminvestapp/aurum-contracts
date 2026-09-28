// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ICLPool,
    ICLFactory,
    ISlipstreamRouter,
    IV2Pool,
    IV2PoolFactory
} from "../interfaces/ISlipstream.sol";
import {TickMath} from "../vendor/uniswap/TickMath.sol";
import {FullMath} from "../vendor/uniswap/FullMath.sol";

/// @notice One way to sell a gauge's reward token into a position token: one
///         or two hops through up33 pools. A hop is a CL pool (walked through
///         the up33 router under a TWAP price limit) or a volatile v2 pool
///         (paid directly; TWAP from its own recorded periods).
struct RewardRoute {
    address pool0;
    bool v2Pool0;
    address pool1; // zero = single hop
    bool v2Pool1;
}

/// @notice What a route needs from the strategy that runs it. Passed in whole:
///         the library holds no state.
struct RouteEnv {
    address rewardToken;
    address token0;
    address token1;
    address clFactory; // the position pool's factory; CL hops must come from it
    address v2Factory; // up33's v2 pool factory; v2 hops must come from it
    address swapRouter;
    uint32 twapInterval; // seconds, for CL hops
    uint16 slippageBps; // the strategy's maxRewardSaleSlippageBps
}

/// @notice A strategy's reward routes: the active ones in priority order and
///         at most one announced addition waiting out its timelock.
struct RouteBook {
    RewardRoute[] routes;
    RewardRoute pending;
    uint256 pendingEta; // 0 = nothing pending
}

/// @notice The strategy entry points the sale loop calls back into, each in
///         its own frame so a failing route unwinds alone.
interface IRewardRouteRunner {
    function quoteRewardRoute(uint256 index, uint256 amountIn) external view returns (uint256 fairOut, address tokenOut);
    function sellRewardsVia(uint256 index, uint256 amountIn, uint256 fairOut)
        external
        returns (uint256 amountOut, address tokenOut);
}

/// @title SlipstreamRewardRoutes — validation, TWAP pricing and execution of
///        reward-sale routes for AurumStrategySlipstream.
/// @notice An external library, so the strategy stays under the contract size
///         limit. Everything runs by DELEGATECALL in the strategy's context:
///         `address(this)` is the strategy, which pays the pools, receives the
///         output, owns the RouteBook and emits the events.
library SlipstreamRewardRoutes {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_ROUTES = 4;
    uint256 internal constant TIMELOCK = 48 hours;
    /// @dev A hop is refused unless its pool holds this multiple of the
    ///      expected output: a thin pool's TWAP is cheap to steer.
    uint256 internal constant ROUTE_DEPTH_MULTIPLE = 50;
    /// @dev v2 TWAP window in recorded periods (30 min each on up33).
    uint256 internal constant V2_TWAP_PERIODS = 2;

    event RewardsSold(uint256 indexed route, uint256 amountIn, uint256 amountOut);
    /// @dev `reason` is the failing hop's error selector (e.g. SaleOutOfBand,
    ///      RouteTooThin), for monitoring which route is breaking and why.
    event RewardRouteFailed(uint256 indexed route, bytes4 reason);
    event RewardSaleSkipped(uint256 amountHeld);
    event RewardRouteProposed(RewardRoute route, uint256 eta);
    event RewardRouteCancelled();
    event RewardRouteAdded(uint256 index, RewardRoute route);
    event RewardRouteRemoved(uint256 index);

    error BadRewardRoute();
    error SaleOutOfBand();
    error RouteTooThin();
    error BelowBestRoute();
    error TooManyRoutes();
    error BadRouteIndex();
    error NoPendingRoute();
    error RouteTimelockActive();

    // ------------------------------------------------------------ route book

    /// @notice Install the initial routes (1..MAX_ROUTES), all validated and
    ///         all ending in the same position token.
    function init(RouteBook storage book, RewardRoute[] memory routes, RouteEnv memory env) external {
        if (routes.length == 0 || routes.length > MAX_ROUTES) revert BadRewardRoute();
        address out = _validate(routes[0], env);
        for (uint256 i = 0; i < routes.length; ++i) {
            if (i > 0 && _validate(routes[i], env) != out) revert BadRewardRoute();
            book.routes.push(routes[i]);
        }
    }

    /// @notice Announce a route, usable after TIMELOCK. Replaces any route
    ///         still pending.
    function propose(RouteBook storage book, RewardRoute memory route, RouteEnv memory env) external {
        _checkAddable(book, route, env);
        book.pending = route;
        uint256 eta = block.timestamp + TIMELOCK;
        book.pendingEta = eta;
        emit RewardRouteProposed(route, eta);
    }

    function cancel(RouteBook storage book) external {
        if (book.pendingEta == 0) revert NoPendingRoute();
        delete book.pending;
        book.pendingEta = 0;
        emit RewardRouteCancelled();
    }

    /// @notice Append the announced route once its timelock has run, checked
    ///         again against the routes active now.
    function activate(RouteBook storage book, RouteEnv memory env) external {
        uint256 eta = book.pendingEta;
        if (eta == 0) revert NoPendingRoute();
        if (block.timestamp < eta) revert RouteTimelockActive();
        RewardRoute memory route = book.pending;
        _checkAddable(book, route, env);
        delete book.pending;
        book.pendingEta = 0;
        book.routes.push(route);
        emit RewardRouteAdded(book.routes.length - 1, route);
    }

    /// @notice Drop a route, keeping the others' order.
    function remove(RouteBook storage book, uint256 index) external {
        RewardRoute[] storage routes = book.routes;
        uint256 n = routes.length;
        if (index >= n) revert BadRouteIndex();
        for (uint256 i = index; i + 1 < n; ++i) {
            routes[i] = routes[i + 1];
        }
        routes.pop();
        emit RewardRouteRemoved(index);
    }

    /// @dev Room for one more, a valid route, and the same output token as the
    ///      routes already active: fair values are compared across routes as
    ///      raw amounts, which only means something within one token.
    function _checkAddable(RouteBook storage book, RewardRoute memory route, RouteEnv memory env) private view {
        RewardRoute[] storage routes = book.routes;
        if (routes.length >= MAX_ROUTES) revert TooManyRoutes();
        address out = _validate(route, env);
        if (routes.length > 0 && _validate(routes[0], env) != out) revert BadRewardRoute();
    }

    // ------------------------------------------------------------------ sale

    /// @notice Sell the reward balance — at most `cap` of it when `cap` is
    ///         set — along the first route that clears its guards.
    /// @dev Every route is priced first, at its TWAPs and only if its pools are
    ///      deep enough (quoteRewardRoute); a route whose value falls short of
    ///      the best route's by more than the slippage allowance is passed
    ///      over, because its own TWAP may be what is wrong — a pool steered
    ///      over time looks "fair" to its own oracle. All routes end in the
    ///      same token, so the values compare directly. Each sale attempt runs
    ///      in its own call frame (sellRewardsVia), so a route that fails
    ///      unwinds completely and the next is tried. When none clears, the
    ///      rewards are held and retried next harvest: never sold at a bad
    ///      price, never allowed to brick harvesting.
    function sellBest(RouteBook storage book, RouteEnv memory env, uint256 cap)
        external
        returns (uint256 amountOut, address tokenOut)
    {
        uint256 n = book.routes.length;
        if (n == 0) return (0, address(0));
        uint256 held = IERC20(env.rewardToken).balanceOf(address(this));
        if (held == 0) return (0, address(0));
        uint256 amountIn = cap == 0 || held < cap ? held : cap;

        IRewardRouteRunner self = IRewardRouteRunner(address(this));
        uint256[] memory fair = new uint256[](n);
        uint256 best;
        for (uint256 i = 0; i < n; ++i) {
            try self.quoteRewardRoute(i, amountIn) returns (uint256 f, address) {
                fair[i] = f;
                if (f > best) best = f;
            } catch (bytes memory reason) {
                emit RewardRouteFailed(i, _selector(reason));
            }
        }

        uint256 floor = FullMath.mulDiv(best, BPS - env.slippageBps, BPS);
        for (uint256 i = 0; i < n; ++i) {
            if (fair[i] == 0) continue; // unpriceable, already reported
            if (fair[i] < floor) {
                emit RewardRouteFailed(i, BelowBestRoute.selector);
                continue;
            }
            try self.sellRewardsVia(i, amountIn, fair[i]) returns (uint256 out, address outToken) {
                emit RewardsSold(i, amountIn, out);
                return (out, outToken);
            } catch (bytes memory reason) {
                emit RewardRouteFailed(i, _selector(reason));
            }
        }
        emit RewardSaleSkipped(held);
    }

    function _selector(bytes memory reason) private pure returns (bytes4) {
        return reason.length >= 4 ? bytes4(reason) : bytes4(0);
    }

    // ---------------------------------------------------------------- routes

    /// @notice Every hop an up33 pool (CL from the position pool's own factory,
    ///         v2 volatile from up33's v2 factory), the token chain starting at
    ///         the reward token and ending in a position token.
    ///         Returns that position token.
    function validate(RewardRoute memory route, RouteEnv memory env) external view returns (address tokenOut) {
        return _validate(route, env);
    }

    function _validate(RewardRoute memory route, RouteEnv memory env) private view returns (address tokenOut) {
        tokenOut = _validateHop(route.pool0, route.v2Pool0, env.rewardToken, env);
        if (route.pool1 != address(0)) {
            tokenOut = _validateHop(route.pool1, route.v2Pool1, tokenOut, env);
        } else if (route.v2Pool1) {
            revert BadRewardRoute();
        }
        if (tokenOut != env.token0 && tokenOut != env.token1) revert BadRewardRoute();
    }

    /// @notice A route's value for `amountIn` of the reward token at its hops'
    ///         TWAPs, net of each pool's fee. Reverts RouteTooThin when a hop
    ///         can't carry the sale: no active liquidity, a zero value, or a
    ///         pool holding less than ROUTE_DEPTH_MULTIPLE× the hop's output.
    function quote(RewardRoute memory route, RouteEnv memory env, uint256 amountIn)
        external
        view
        returns (uint256 fairOut, address tokenOut)
    {
        (fairOut, tokenOut) = _quoteHop(route.pool0, route.v2Pool0, env.rewardToken, amountIn, env);
        if (route.pool1 != address(0)) {
            (fairOut, tokenOut) = _quoteHop(route.pool1, route.v2Pool1, tokenOut, fairOut, env);
        }
    }

    /// @notice Sell `amountIn` of the reward token along `route`, priced at
    ///         `fairOut` just before.
    /// @dev Guards, per hop: a CL hop is price-limited to `slippageBps` around
    ///      its TWAP (1 tick ≈ 1 bp) and refused when spot already sits
    ///      outside that band; a v2 hop's output must clear its TWAP quote by
    ///      the same margin; each hop demands its TWAP-implied output minus the
    ///      allowance. Over the whole route: the output must clear `fairOut`
    ///      minus ONE allowance, so two in-band hops cannot compound into two.
    function sell(RewardRoute memory route, RouteEnv memory env, uint256 amountIn, uint256 fairOut)
        external
        returns (uint256 amountOut, address tokenOut)
    {
        (amountOut, tokenOut) = _sellHop(route.pool0, route.v2Pool0, env.rewardToken, amountIn, env);
        if (route.pool1 != address(0)) {
            (amountOut, tokenOut) = _sellHop(route.pool1, route.v2Pool1, tokenOut, amountOut, env);
        }
        if (amountOut < FullMath.mulDiv(fairOut, BPS - env.slippageBps, BPS)) revert SaleOutOfBand();
    }

    // ------------------------------------------------------------- internals

    function _sellHop(address hopPool, bool isV2, address tokenIn, uint256 amountIn, RouteEnv memory env)
        private
        returns (uint256 amountOut, address tokenOut)
    {
        if (isV2) {
            IV2Pool p = IV2Pool(hopPool);
            uint256 fairOut;
            (fairOut, tokenOut) = _quoteV2Hop(p, tokenIn, amountIn, env);
            amountOut = p.getAmountOut(amountIn, tokenIn);
            if (amountOut < FullMath.mulDiv(fairOut, BPS - env.slippageBps, BPS)) revert SaleOutOfBand();
            IERC20(tokenIn).safeTransfer(hopPool, amountIn);
            (uint256 out0, uint256 out1) = tokenIn == p.token0() ? (uint256(0), amountOut) : (amountOut, uint256(0));
            p.swap(out0, out1, address(this), "");
        } else {
            ICLPool p = ICLPool(hopPool);
            bool zeroForOne = tokenIn == p.token0();
            tokenOut = zeroForOne ? p.token1() : p.token0();
            int24 twap = _observedTick(p, env.twapInterval);
            int24 slippageTicks = int24(uint24(env.slippageBps));
            int24 limitTick = zeroForOne ? twap - slippageTicks : twap + slippageTicks;
            (, int24 spot,,,,) = p.slot0();
            if (zeroForOne ? spot <= limitTick : spot >= limitTick) revert SaleOutOfBand();
            uint256 fairOut = _clFairOut(p, zeroForOne, twap, amountIn);

            IERC20(tokenIn).forceApprove(env.swapRouter, amountIn);
            // amountOutMinimum is for the FULL input: a fill cut short by the
            // price limit reverts the route rather than selling part of it.
            amountOut = ISlipstreamRouter(env.swapRouter).exactInputSingle(
                ISlipstreamRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    tickSpacing: p.tickSpacing(),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: FullMath.mulDiv(fairOut, BPS - env.slippageBps, BPS),
                    sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(_clampTick(limitTick))
                })
            );
            IERC20(tokenIn).forceApprove(env.swapRouter, 0);
        }
    }

    function _quoteHop(address hopPool, bool isV2, address tokenIn, uint256 amountIn, RouteEnv memory env)
        private
        view
        returns (uint256 fairOut, address tokenOut)
    {
        if (isV2) {
            (fairOut, tokenOut) = _quoteV2Hop(IV2Pool(hopPool), tokenIn, amountIn, env);
        } else {
            ICLPool p = ICLPool(hopPool);
            if (p.liquidity() == 0) revert RouteTooThin();
            bool zeroForOne = tokenIn == p.token0();
            tokenOut = zeroForOne ? p.token1() : p.token0();
            fairOut = _clFairOut(p, zeroForOne, _observedTick(p, env.twapInterval), amountIn);
        }
        if (fairOut == 0) revert RouteTooThin();
        if (IERC20(tokenOut).balanceOf(hopPool) < fairOut * ROUTE_DEPTH_MULTIPLE) revert RouteTooThin();
    }

    /// @dev quote() averages the output over recorded periods (a TWAP of the
    ///      reserves, price impact included) but excludes the fee.
    function _quoteV2Hop(IV2Pool p, address tokenIn, uint256 amountIn, RouteEnv memory env)
        private
        view
        returns (uint256 fairOut, address tokenOut)
    {
        address t0 = p.token0();
        tokenOut = tokenIn == t0 ? p.token1() : t0;
        uint256 twapOut = p.quote(tokenIn, amountIn, V2_TWAP_PERIODS);
        uint256 feeBps = IV2PoolFactory(env.v2Factory).getFee(address(p), false);
        fairOut = FullMath.mulDiv(twapOut, BPS - feeBps, BPS);
    }

    function _clFairOut(ICLPool p, bool zeroForOne, int24 twap, uint256 amountIn) private view returns (uint256) {
        uint160 sqrtTwap = TickMath.getSqrtRatioAtTick(twap);
        uint256 gross = zeroForOne
            ? FullMath.mulDiv(FullMath.mulDiv(amountIn, sqrtTwap, 1 << 96), sqrtTwap, 1 << 96)
            : FullMath.mulDiv(FullMath.mulDiv(amountIn, 1 << 96, sqrtTwap), 1 << 96, sqrtTwap);
        return FullMath.mulDiv(gross, 1e6 - p.fee(), 1e6); // CL fees are in pips
    }

    function _validateHop(address hopPool, bool isV2, address tokenIn, RouteEnv memory env)
        private
        view
        returns (address tokenOut)
    {
        if (hopPool == address(0)) revert BadRewardRoute();
        address a;
        address b;
        if (isV2) {
            if (env.v2Factory == address(0) || !IV2PoolFactory(env.v2Factory).isPool(hopPool)) revert BadRewardRoute();
            IV2Pool p = IV2Pool(hopPool);
            if (p.stable()) revert BadRewardRoute(); // stable-curve pricing is out of scope
            (a, b) = (p.token0(), p.token1());
        } else {
            if (env.swapRouter == address(0)) revert BadRewardRoute();
            ICLPool p = ICLPool(hopPool);
            (a, b) = (p.token0(), p.token1());
            if (ICLFactory(env.clFactory).getPool(a, b, p.tickSpacing()) != hopPool) revert BadRewardRoute();
        }
        if (a == tokenIn) return b;
        if (b == tokenIn) return a;
        revert BadRewardRoute();
    }

    /// @dev Arithmetic-mean tick over `interval`, rounded toward negative
    ///      infinity like Uniswap's OracleLibrary.
    function _observedTick(ICLPool p, uint32 interval) private view returns (int24 tick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = interval;
        (int56[] memory tickCumulatives,) = p.observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        tick = int24(delta / int56(uint56(interval)));
        if (delta < 0 && (delta % int56(uint56(interval)) != 0)) tick--;
    }

    function _clampTick(int24 tick) private pure returns (int24) {
        if (tick < TickMath.MIN_TICK) return TickMath.MIN_TICK;
        if (tick > TickMath.MAX_TICK) return TickMath.MAX_TICK;
        return tick;
    }
}
