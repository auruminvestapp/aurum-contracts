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

interface IZapVault {
    function strategy() external view returns (address);
    function token0() external view returns (IERC20);
    function token1() external view returns (IERC20);
    function deposit(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address receiver)
        external
        returns (uint256 shares);
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address receiver)
        external
        returns (uint256 out0, uint256 out1);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IZapStrategy {
    function pool() external view returns (IUniswapV3Pool);
}

interface IZapStrategyV4 {
    function poolManager() external view returns (IPoolManager);
    function poolKey() external view returns (PoolKey memory);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IAurumRegistry {
    function isAurumVault(address vault) external view returns (bool);
}

/// @title AurumZapV2 — single-token entry/exit for V3 AND V4 Aurum vaults.
/// @notice Stateless executor: every transaction ends with a zero balance and
///         all leftovers refunded. Swaps happen directly against the vault's
///         own pool (V3 pool contract, or the V4 PoolManager via unlock — no
///         router, no arbitrary call targets). Vault flavor is decided by
///         which factory registered it, never by duck-typing the strategy.
///         The split between `swapAmountIn` and the rest is computed
///         off-chain; the end-to-end user guards are `minSwapOut` and
///         `minShares`/`minAmountOut`.
contract AurumZapV2 is ReentrancyGuard, IUniswapV3SwapCallback, IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    IAurumRegistry public immutable registryV3;
    /// @notice up33 (Slipstream) vaults. Their pools are V3-shaped — same
    ///         swap, callback and observe — so they take the V3 path. Zero =
    ///         no Slipstream vaults.
    IAurumRegistry public immutable registrySlipstream;
    /// @notice Every V4 factory generation (v4, v4b, v4c, …) — a vault is a
    ///         Aurum V4 vault iff ANY of them registered it.
    IAurumRegistry[] private _registriesV4;
    address public immutable weth;

    // Set for the duration of one swap so the callback can authenticate.
    address private _expectedPool;
    IPoolManager private _expectedPM;
    bytes32 private _expectedPoolId;

    event ZapIn(address indexed vault, address indexed user, address tokenIn, uint256 amountIn, uint256 shares);
    event ZapOut(address indexed vault, address indexed user, address tokenOut, uint256 shares, uint256 amountOut);

    error NotAurumVault();
    error BadToken();
    error ZeroAmount();
    error SlippageSwap();
    error SlippageOut();
    error NotPool();
    error BadValue();
    error ZeroAddress();
    error SharesTransferFailed();

    constructor(address registryV3_, address registrySlipstream_, address[] memory registriesV4_, address weth_) {
        if (registryV3_ == address(0) || weth_ == address(0) || registriesV4_.length == 0) revert ZeroAddress();
        registryV3 = IAurumRegistry(registryV3_);
        registrySlipstream = IAurumRegistry(registrySlipstream_);
        for (uint256 i = 0; i < registriesV4_.length; i++) {
            if (registriesV4_[i] == address(0)) revert ZeroAddress();
            _registriesV4.push(IAurumRegistry(registriesV4_[i]));
        }
        weth = weth_;
    }

    function registriesV4() external view returns (IAurumRegistry[] memory) {
        return _registriesV4;
    }

    function _isAurum(address vault) internal view returns (bool) {
        return registryV3.isAurumVault(vault) || _isSlipstream(vault) || _isV4(vault);
    }

    function _isSlipstream(address vault) internal view returns (bool) {
        return address(registrySlipstream) != address(0) && registrySlipstream.isAurumVault(vault);
    }

    function _isV4(address vault) internal view returns (bool) {
        for (uint256 i = 0; i < _registriesV4.length; i++) {
            if (_registriesV4[i].isAurumVault(vault)) return true;
        }
        return false;
    }

    /// @notice Deposit a single token. `swapAmountIn` of `tokenIn` is swapped
    ///         into the other pool token (quote computed off-chain), then both
    ///         balances go into the vault. Shares mint straight to `receiver`;
    ///         every unused wei of both tokens is refunded to the caller.
    ///         Send native ETH (tokenIn = WETH, amountIn = msg.value) to auto-wrap.
    function zapIn(
        address vault,
        address tokenIn,
        uint256 amountIn,
        uint256 swapAmountIn,
        uint256 minSwapOut,
        uint256 minShares,
        address receiver
    ) external payable nonReentrant returns (uint256 shares) {
        if (!_isAurum(vault)) revert NotAurumVault();
        if (amountIn == 0 || swapAmountIn > amountIn) revert ZeroAmount();

        IERC20 token0 = IZapVault(vault).token0();
        IERC20 token1 = IZapVault(vault).token1();
        bool inIsToken0 = tokenIn == address(token0);
        if (!inIsToken0 && tokenIn != address(token1)) revert BadToken();

        // Fund the zap: native ETH wraps to WETH, ERC-20 pulls from the caller.
        if (msg.value > 0) {
            if (tokenIn != weth || msg.value != amountIn) revert BadValue();
            IWETH9(weth).deposit{value: msg.value}();
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        if (swapAmountIn > 0) {
            uint256 out = _vaultPoolSwap(vault, inIsToken0, swapAmountIn);
            if (out < minSwapOut) revert SlippageSwap();
        }

        // Deposit whatever the swap produced; the vault pulls only what fits.
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        if (bal0 > 0) token0.forceApprove(vault, bal0);
        if (bal1 > 0) token1.forceApprove(vault, bal1);
        shares = IZapVault(vault).deposit(bal0, bal1, minShares, receiver);
        if (bal0 > 0) token0.forceApprove(vault, 0);
        if (bal1 > 0) token1.forceApprove(vault, 0);

        _refund(token0, token1);
        emit ZapIn(vault, msg.sender, tokenIn, amountIn, shares);
    }

    /// @notice Redeem shares and receive a single token: the in-kind withdrawal
    ///         lands here, the unwanted side is swapped in the pool, everything
    ///         is sent to `receiver`. Caller must approve the zap for shares.
    function zapOut(address vault, uint256 shares, address tokenOut, uint256 minAmountOut, address receiver)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (!_isAurum(vault)) revert NotAurumVault();
        if (shares == 0) revert ZeroAmount();

        IERC20 token0 = IZapVault(vault).token0();
        IERC20 token1 = IZapVault(vault).token1();
        bool outIsToken0 = tokenOut == address(token0);
        if (!outIsToken0 && tokenOut != address(token1)) revert BadToken();

        if (!IZapVault(vault).transferFrom(msg.sender, address(this), shares)) revert SharesTransferFailed();
        IZapVault(vault).withdraw(shares, 0, 0, address(this));

        // Swap the entire unwanted side into the requested token.
        IERC20 sellToken = outIsToken0 ? token1 : token0;
        uint256 sellBal = sellToken.balanceOf(address(this));
        if (sellBal > 0) {
            _vaultPoolSwap(vault, !outIsToken0, sellBal);
        }

        amountOut = IERC20(tokenOut).balanceOf(address(this));
        if (amountOut < minAmountOut) revert SlippageOut();
        IERC20(tokenOut).safeTransfer(receiver, amountOut);

        _refund(token0, token1); // dust on the sold side, if any
        emit ZapOut(vault, msg.sender, tokenOut, shares, amountOut);
    }

    // ------------------------------------------------------------ callbacks

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata data) external {
        if (msg.sender != _expectedPool) revert NotPool();
        (address t0, address t1) = abi.decode(data, (address, address));
        if (d0 > 0) IERC20(t0).safeTransfer(msg.sender, uint256(d0));
        if (d1 > 0) IERC20(t1).safeTransfer(msg.sender, uint256(d1));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(_expectedPM)) revert NotPool();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        if (V4StateReader.poolIdFor(key) != _expectedPoolId) revert NotPool();

        BalanceDelta d = _expectedPM.swap(
            key,
            SwapParams(
                zeroForOne,
                -int256(amountIn),
                zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            ),
            ""
        );
        Currency cin = zeroForOne ? key.currency0 : key.currency1;
        Currency cout = zeroForOne ? key.currency1 : key.currency0;
        int128 owed = zeroForOne ? d.amount0() : d.amount1();
        // Native-c0 pools convert at this boundary only: the zap's inventory
        // is always WETH (see the vault's wrap-at-the-edge design).
        if (Currency.unwrap(cin) == address(0)) {
            IWETH9(weth).withdraw(uint256(uint128(-owed)));
            _expectedPM.settle{value: uint256(uint128(-owed))}();
        } else {
            _expectedPM.sync(cin);
            IERC20(Currency.unwrap(cin)).safeTransfer(address(_expectedPM), uint256(uint128(-owed)));
            _expectedPM.settle();
        }
        uint256 got = uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
        if (got > 0) {
            _expectedPM.take(cout, address(this), got);
            if (Currency.unwrap(cout) == address(0)) IWETH9(weth).deposit{value: got}();
        }
        return abi.encode(got);
    }

    // ------------------------------------------------------------ internals

    /// @dev Swap inside the vault's own pool, whichever protocol it lives on.
    function _vaultPoolSwap(address vault, bool zeroForOne, uint256 amountIn) internal returns (uint256 amountOut) {
        if (_isV4(vault)) {
            IZapStrategyV4 s = IZapStrategyV4(IZapVault(vault).strategy());
            IPoolManager pm = s.poolManager();
            PoolKey memory key = s.poolKey();
            _expectedPM = pm;
            _expectedPoolId = V4StateReader.poolIdFor(key);
            bytes memory res = pm.unlock(abi.encode(key, zeroForOne, amountIn));
            _expectedPM = IPoolManager(address(0));
            _expectedPoolId = bytes32(0);
            return abi.decode(res, (uint256));
        }
        IUniswapV3Pool pool = IZapStrategy(IZapVault(vault).strategy()).pool();
        _expectedPool = address(pool);
        (int256 a0, int256 a1) = pool.swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            abi.encode(pool.token0(), pool.token1())
        );
        _expectedPool = address(0);
        amountOut = uint256(-(zeroForOne ? a1 : a0));
    }

    /// @dev The zap never keeps a balance: whatever remains goes back to the caller.
    function _refund(IERC20 token0, IERC20 token1) internal {
        uint256 b0 = token0.balanceOf(address(this));
        uint256 b1 = token1.balanceOf(address(this));
        if (b0 > 0) token0.safeTransfer(msg.sender, b0);
        if (b1 > 0) token1.safeTransfer(msg.sender, b1);
    }
    /// @notice ETH is accepted only from WETH (unwrap during a native swap
    ///         leg) and from the PoolManager (take of a native output). In
    ///         normal use both are transient — wrapped back to WETH within the
    ///         same transaction, and the zap only ever pays out ERC-20. NOTE:
    ///         this chain's WETH has a public withdrawTo, so a third party can
    ///         force stray ETH here; it is the griefer's own loss (the zap is
    ///         stateless and never reads its ETH balance) and affects no user.
    receive() external payable {
        if (msg.sender != weth && msg.sender != address(_expectedPM)) revert NotPool();
    }
}
