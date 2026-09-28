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

## Licence

Aurum's own contracts are under the Business Source License 1.1 (see each file's SPDX header). Files in `src/vendor/` keep their original MIT or GPL-2.0-or-later licences.
