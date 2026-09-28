// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title Minimal vendored interfaces for the up33 (Aerodrome Slipstream clone)
///        deployment on Robinhood Chain. Signatures verified against the
///        verified sources of the live contracts:
///        - CLPool impl        0x11725976BF1F38c4aB78d1F480bc5883d70D9dc3
///        - NFPM               0x07F44c47743A2f36414A82b9F558ECFCf0EEdCEf
///        - CLGauge (CASHCAT)  0x34e626Eca01615a752F859DED5ac2b2779433797
///        - SwapRouter         0xC062b870E813fcA720f1e002c234369Ab3aB9415
///        - Voter              0x7F749fDD351C1Ceed82d76d7699CB631Eb8332a7
///        - CLFactory          0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3
///        - v2 PoolFactory     0xFA5429AEBa338BEa2BFcc1b9a889862Ee395bc28
///        - v2 Pool (UP/USDG)  0x87086329B677c94dF4dA5DFE9a8DA90C73c535bf

/// @notice V3-shaped CL pool with Slipstream extensions. slot0 has SIX fields
///         (no feeProtocol); swap/observe keep the Uniswap V3 callbacks/ABI.
interface ICLPool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function fee() external view returns (uint24);
    function gauge() external view returns (address);
    function liquidity() external view returns (uint128);
    function stakedLiquidity() external view returns (uint128);
    function unstakedFee() external view returns (uint24);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

/// @notice Slipstream CLFactory — pools are keyed by (tokenA, tokenB, tickSpacing).
interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

/// @notice up33's classic (Aerodrome v2) constant-product pool. Swaps are
///         pay-first: transfer the input to the pool, then call swap() with
///         the output amount (getAmountOut already nets the fee). quote()
///         averages the output over `granularity` recorded periods of
///         periodSize (30 min) — a TWAP, excluding the fee.
interface IV2Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function stable() external view returns (bool);
    function factory() external view returns (address);
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
    function quote(address tokenIn, uint256 amountIn, uint256 granularity) external view returns (uint256 amountOut);
    function observationLength() external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IV2PoolFactory {
    function isPool(address pool) external view returns (bool);
    function getFee(address pool, bool stable) external view returns (uint256); // bps
}

/// @notice Slipstream CLGauge: stakes NFPM tokenIds, pays the emissions token.
///         deposit collects pending NFT fees to the caller, then pulls the NFT
///         (requires ERC-721 approval); withdraw claims rewards + returns the
///         NFT via safeTransferFrom. No admin gates on withdraw.
interface ICLGauge {
    function rewardToken() external view returns (address);
    function voter() external view returns (address);
    function rewardRate() external view returns (uint256);
    function periodFinish() external view returns (uint256);
    function earned(address account, uint256 tokenId) external view returns (uint256);
    function stakedContains(address depositor, uint256 tokenId) external view returns (bool);
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function getReward(uint256 tokenId) external;
}

interface IVoter {
    function gauges(address pool) external view returns (address);
    function isAlive(address gauge) external view returns (bool);
}

/// @notice Slipstream NonfungiblePositionManager. Positions are keyed by
///         tickSpacing (not fee). While an NFT is staked in its pool's gauge,
///         increaseLiquidity is gauge-only and decrease/collect/burn require
///         ownership — the strategy must unstake before touching liquidity.
interface ISlipstreamNFPM {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96; // 0 = pool must already exist
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function burn(uint256 tokenId) external payable;

    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Slipstream SwapRouter — exactInputSingle routes by tickSpacing.
interface ISlipstreamRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
