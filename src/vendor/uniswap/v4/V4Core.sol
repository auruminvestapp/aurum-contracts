// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Minimal Uniswap V4 core types + PoolManager surface — vendored so the
/// protocol carries no external v4-core dependency. Semantics pinned by the
/// live-fork parity test in AurumV4Fork.t.sol.
///
/// Sign conventions (V4, differs from V3):
///  - SwapParams.amountSpecified: NEGATIVE = exact input.
///  - BalanceDelta: positive = credit owed TO the caller (take);
///    negative = caller owes the PoolManager (sync/transfer/settle).

type Currency is address;

type BalanceDelta is int256;

library BalanceDeltaLibrary {
    function amount0(BalanceDelta d) internal pure returns (int128) {
        return int128(BalanceDelta.unwrap(d) >> 128);
    }

    function amount1(BalanceDelta d) internal pure returns (int128) {
        return int128(BalanceDelta.unwrap(d));
    }
}

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta swapDelta);
    function sync(Currency currency) external;
    function settle() external payable returns (uint256 paid);
    function take(Currency currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
