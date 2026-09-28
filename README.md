# Aurum contracts

The Solidity source of [Aurum Invest](https://earn.auruminvest.app): agent-managed liquidity vaults on Robinhood Chain.

Each vault holds one concentrated-liquidity position in one pool. Depositors get vault shares; an agent chooses and moves the position's range and harvests its earnings, within limits the contracts enforce. The agent can never withdraw funds, and withdrawals stay open in every vault state.

| Contract | What it does |
| --- | --- |
| `AurumVault` | The vault: shares, deposits and withdrawals, pause and emergency exit |
| `AurumStrategyUniV3`, `AurumStrategyUniV4`, `AurumStrategySlipstream` | One position per vault on Uniswap V3, Uniswap V4 or up33 (Slipstream): harvest, rebalance within the rails, staking on up33 |
| `AurumFactory`, `AurumFactoryV4`, `AurumFactorySlipstream` | Create vault and strategy pairs (EIP-1167 clones) |
| `AurumZapV2` | Deposit and withdraw with a single token |
| `FeeConfig` | Performance fee per vault, capped at 15% |
| `PositionGuardV2` | Standing exit orders a user registers for their own shares |
| `libraries/` | Shared strategy logic and up33 reward-sale routes |
| `vendor/` | Uniswap maths and V4 types, under their own licences |

This repository holds the contracts that are deployed today. They are verified on [Blockscout](https://robinhoodchain.blockscout.com). How the vaults and the agent work: [docs.auruminvest.app](https://docs.auruminvest.app).

## Deployed on Robinhood Chain

Chain ID 4663, deployed 2026-09-25. Vaults and their strategies are EIP-1167 clones of the implementations below, created by the factories; the app lists every vault.

| Contract | Role | Address |
| --- | --- | --- |
| `AurumFactory` | Uniswap V3 vaults | [`0x535E4F94e944319f661867812812C1B270b0d591`](https://robinhoodchain.blockscout.com/address/0x535E4F94e944319f661867812812C1B270b0d591) |
| `AurumFactoryV4` | Uniswap V4 vaults | [`0x17C5553Ba43F43C1Ee73472dD4f5f41c17AEcbb8`](https://robinhoodchain.blockscout.com/address/0x17C5553Ba43F43C1Ee73472dD4f5f41c17AEcbb8) |
| `AurumFactorySlipstream` | up33 (Slipstream) vaults | [`0x83378363f33De8F60054b633cd76177cDCaF8166`](https://robinhoodchain.blockscout.com/address/0x83378363f33De8F60054b633cd76177cDCaF8166) |
| `AurumVault` | implementation every vault clones | [`0x85Df85C3757f9Dbbc5bE822b4B35A788364b1c1F`](https://robinhoodchain.blockscout.com/address/0x85Df85C3757f9Dbbc5bE822b4B35A788364b1c1F) |
| `AurumStrategyUniV3` | implementation | [`0x3Aea8013727CA4604C679841A1e4c990a6e2C35c`](https://robinhoodchain.blockscout.com/address/0x3Aea8013727CA4604C679841A1e4c990a6e2C35c) |
| `AurumStrategyUniV4` | implementation | [`0x6bb9c02BB039B2B0730C0718A05c269cd3c70f94`](https://robinhoodchain.blockscout.com/address/0x6bb9c02BB039B2B0730C0718A05c269cd3c70f94) |
| `AurumStrategySlipstream` | implementation | [`0xA4bbA5518f9B611f100D68b3d1678af91220B5B9`](https://robinhoodchain.blockscout.com/address/0xA4bbA5518f9B611f100D68b3d1678af91220B5B9) |
| `AurumZapV2` | single-token deposits and withdrawals | [`0xC7F233088A228D9a8b3b7271c2965AbA25859a77`](https://robinhoodchain.blockscout.com/address/0xC7F233088A228D9a8b3b7271c2965AbA25859a77) |
| `FeeConfig` | performance fees | [`0x664DD5CC5aB0e9da51767fc13b49117B41600fCA`](https://robinhoodchain.blockscout.com/address/0x664DD5CC5aB0e9da51767fc13b49117B41600fCA) |
| `PositionGuardV2` | exit orders | [`0x3801c7158d22eEf8eD4c354ea327423692992038`](https://robinhoodchain.blockscout.com/address/0x3801c7158d22eEf8eD4c354ea327423692992038) |
| `StrategyLib` | linked library | [`0x667f04C1D0C083CC72Fb4b74394b90fAd8146f27`](https://robinhoodchain.blockscout.com/address/0x667f04C1D0C083CC72Fb4b74394b90fAd8146f27) |
| `SlipstreamRewardRoutes` | linked library | [`0xD5Da2b8E2ad03aCC024ED051898BeC0DA397a7Cf`](https://robinhoodchain.blockscout.com/address/0xD5Da2b8E2ad03aCC024ED051898BeC0DA397a7Cf) |

## Licence

Aurum's own contracts are under the Business Source License 1.1 (see each file's SPDX header). Files in `src/vendor/` keep their original MIT or GPL-2.0-or-later licences.
