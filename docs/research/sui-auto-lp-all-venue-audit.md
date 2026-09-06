# Auto-LP across every supported migration venue

Research snapshot: 2026-09-05. This corrects the earlier two-venue feasibility
answer. All five migration venues were examined, including Aftermath's DAO
wrapper. No executable contracts or deployed settings were changed.

## Evidence and limits

Read pinned first-party source/interfaces, fetched public function signatures
and module bytecode from the official Sui mainnet GraphQL endpoint, and
disassembled relevant published modules with `sui move disassemble`. Queries
from original package IDs resolved to the repository's pinned revisions:
Bluefin 17, MMT 5, Cetus 14, Turbos 22, Aftermath AMM 3, and DAO wrapper 2.

[Evidence JSON](sui-auto-lp-venue-evidence.json) records addresses, package
digests, module hashes, normalized deposit signatures and important bytecode
excerpts. This is interface and bytecode inspection, not executed deposits or
end-to-end vault tests. Actual pool settings, pause behavior, gas, rounding
and repeated deposits under vault custody still require integration fixtures.

## Existing-position deposit coverage

| Venue | Published operation | Excess and sizing | Integration work |
| --- | --- | --- | --- |
| Bluefin | `pool::add_liquidity` or `add_liquidity_with_fixed_amount` | Mutates `Position`; returns actual paid amounts and both residual balances. Caller supplies a liquidity amount or fixed asset amount and must size against both holdings. Slippage checks belong to the caller. | Dependency already exposes both methods. Extend verification beyond creation to repeated increases, bounds and custody. |
| MMT | `liquidity::add_liquidity` | Mutates `Position`; accepts both coins and returns both refunds. Bytecode calls the pool operation, checks minimum amounts and returns remaining balances as coins. | Operation is already imported. Verify first deposit and subsequent increases under the shared vault. |
| Cetus | `add_liquidity_fix_coin`, receipt accessor, `repay_add_liquidity` | Receipt states both exact payments. Choose a supported fixed side/amount, settle the receipt and retain unused balances. Oversized requests abort; this is not a catch-and-retry quote API. | Already in the minimal interface. Verify limiting-side math and rounding in both orientations. |
| Turbos | `position_manager::increase_liquidity_with_return_` | Mutates the NFT; accepts desired/minimum amounts and returns residual coins. The similarly named entry function transfers refunds to the sender. | Published v22 and upstream expose it; our minimal interface omits it. Add signature and ABI coverage; test NFT-address versus legacy sender position-key branches. |
| Aftermath DAO wrapper | `deposit::all_coin_deposit_2_coins` | Accepts both coins by mutable reference, leaves proportional-deposit excess in them, and returns `Coin<Lp>`. Wrapper and base protocol-fee processing happen before proportional sizing. | Our minimal interfaces omit deposits and supporting fee-object types. Add the wrapper path, retain new LP units and size offered coins before fee assessment. |

Source anchors: [Bluefin](https://github.com/fireflyprotocol/bluefin-spot-contract-interface/blob/91ce930575b2aa3decab9b7e129b8002deba80c1/sources/pool.move),
[MMT](https://github.com/mmt-finance/mmt-contract-interface/blob/e27d14caed53e1b7c4e1c12ea89b2ff87c58ee82/mmt_v3/sources/liquidity.move),
[Cetus](https://github.com/CetusProtocol/cetus-contracts/blob/ddfbdeba174319998b012de876ab7ec23c3ab0bc/packages/cetus_clmm/sources/pool.move),
[Turbos](https://github.com/turbos-finance/turbos-sui-move-interface/blob/cff693265bfc41c7de2233afe31c9d7428adc9e1/clmm/sources/position_manager.move),
[Aftermath base deposits](https://github.com/AftermathFinance/move-amm-public/blob/9431920dd04ca3125e8a351a377a4399aa9193ce/packages/amm/sources/internal/deposit.move).
Wrapper behavior is established by published bytecode in the evidence.

## Aftermath changes the simple implementation

The proportional function exists on both the base AMM and the DAO wrapper.
Ordinary `deposit_2_coins` differs: it consumes both inputs and calculates LP
output for a potentially imbalanced deposit. Do not substitute it for the
proportional function merely because both accept two coins.

The wrapper first calls `collect_dao_fee` on each complete offered coin, then
forwards the remaining coins to the base pool. Its formula is
`floor(offered_amount * fee_bps / 10_000)`. At our compiled 200-bps policy,
offering 100 units incurs a 2-unit DAO charge even if much of the remaining
98 cannot participate in the deposit. Offering the leftover in a later
successful deposit charges it again.

That DAO fee goes to the original launch LP vault's configured recipient and
then follows Blast's creator/protocol split. It is not all lost to Aftermath,
but neither is it cost-free recycling for the auto-LP vault. Configured base
protocol fees can add another charge. Conservation must include assessed fees.

Offer only fee-aware, ratio-matched portions and retain unneeded funds outside
the venue call. Skip before entering the wrapper when no positive deposit is
possible. The DAO wrapper's inner-pool borrow functions are package-restricted:
base-pool getters alone do not establish external on-chain sizing access.
Resolve that exact read/quote path or constrain transaction-supplied amounts;
the deposit function's existence alone does not settle this integration.

## Alternative destination and an owned V2-style AMM

The user subsequently clarified the intended Blast V2 role: receive reinvested
creator fees while the original migration stays on its chosen external DEX.
The [updated design](sui-auto-lp-distributor-design.md) records that proposal.
Making Blast V2 the default migration venue, discussed below as an alternative,
is not the requested change.

Creator-fee source and new-LP destination can differ. At enrollment the cap
holder could commit a supported pool on another DEX with the same asset pair.
Source claims still use the existing cap; the new vault owns only newly funded
LP. Existing permanently locked migration liquidity cannot move through this
feature. New pools also require validated initialization prices and fee policy.

Aggregators split trades between supported pools, not LP ownership or fee
rights. A new Blast AMM needs pool discovery, quoting and transaction adapters
plus competitive execution to receive volume. [Aftermath's routing model](https://docs.aftermath.finance/trade/smart-order-router)
explicitly describes API integration and sufficient liquidity.

A small constant-product AMM is credible if Blast wants to own its future
migration destination and fees. Balanced deposits can calculate supported
amounts from reserves and return excess. The LP portion of swap fees can remain
in reserves and compound as swaps execute, without a claim-and-redeposit call.
Separately claimable creator/protocol fees require explicit accounting outside
LP reserves and cannot also be counted as LP backing. External creator fees
still need a transaction and compatible asset balances to enter liquidity.

Ownership controls fees on swaps through that AMM; it cannot force ordinary
transferable coins to trade only there. A bounded proposal is two-asset
constant-product pools, composable swaps and balanced deposits, LP custody,
explicit fee accounting and migration/aggregator adapters. No concentrated
ranges, balancing swaps or routing engine are needed for this proposal.
See the [V2 reference](https://docs.uniswap.org/whitepaper.pdf) and
[fee economics](sui-dex-fee-economics.md).

This is a migration-architecture choice, not a prerequisite for external
auto-LP. Compare net routed revenue and engineering/verification cost; nominal
venue cuts alone do not establish which destination earns more.
