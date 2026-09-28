// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager, PoolKey} from "./V4Core.sol";

/// extsload reads of PoolManager pool state — the storage layout of
/// v4-core's Pool.State, pinned by the live-fork parity test. Offsets match
/// v4-core StateLibrary: pools mapping at slot 6; within a pool's state:
/// slot0 (+0), feeGrowthGlobal0 (+1), feeGrowthGlobal1 (+2), liquidity (+3),
/// ticks mapping (+4), tickBitmap (+5), positions mapping (+6).
library V4StateReader {
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    function poolIdFor(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
    }

    function _stateSlot(bytes32 poolId) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, POOLS_SLOT));
    }

    function getSlot0(IPoolManager pm, bytes32 poolId)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        bytes32 data = pm.extsload(_stateSlot(poolId));
        // packed: sqrtPriceX96 (160) | tick (24) | protocolFee (24) | lpFee (24)
        sqrtPriceX96 = uint160(uint256(data));
        tick = int24(int256(uint256(data) >> 160));
        protocolFee = uint24(uint256(data) >> 184);
        lpFee = uint24(uint256(data) >> 208);
    }

    function getFeeGrowthGlobals(IPoolManager pm, bytes32 poolId)
        internal
        view
        returns (uint256 g0, uint256 g1)
    {
        bytes32 s = _stateSlot(poolId);
        g0 = uint256(pm.extsload(bytes32(uint256(s) + 1)));
        g1 = uint256(pm.extsload(bytes32(uint256(s) + 2)));
    }

    function getLiquidity(IPoolManager pm, bytes32 poolId) internal view returns (uint128) {
        return uint128(uint256(pm.extsload(bytes32(uint256(_stateSlot(poolId)) + 3))));
    }

    /// Tick info lives in the pool's `ticks` mapping at state slot +4. Each
    /// entry packs liquidityGross|liquidityNet in word 0 and holds the two
    /// far-side fee accumulators in words +1 and +2. Reading them is what makes
    /// uncollected fees computable without touching the position.
    function getTickFeeGrowthOutside(IPoolManager pm, bytes32 poolId, int24 tick)
        internal
        view
        returns (uint256 outside0, uint256 outside1)
    {
        bytes32 ticksMapping = bytes32(uint256(_stateSlot(poolId)) + 4);
        bytes32 t = keccak256(abi.encodePacked(int256(tick), ticksMapping));
        outside0 = uint256(pm.extsload(bytes32(uint256(t) + 1)));
        outside1 = uint256(pm.extsload(bytes32(uint256(t) + 2)));
    }

    /// Position: liquidity (slot +0), feeGrowthInside0Last (+1), feeGrowthInside1Last (+2).
    function getPositionInfo(IPoolManager pm, bytes32 poolId, bytes32 posKey)
        internal
        view
        returns (uint128 liquidity, uint256 inside0Last, uint256 inside1Last)
    {
        bytes32 positionsMapping = bytes32(uint256(_stateSlot(poolId)) + 6);
        bytes32 p = keccak256(abi.encodePacked(posKey, positionsMapping));
        liquidity = uint128(uint256(pm.extsload(p)));
        inside0Last = uint256(pm.extsload(bytes32(uint256(p) + 1)));
        inside1Last = uint256(pm.extsload(bytes32(uint256(p) + 2)));
    }
}
