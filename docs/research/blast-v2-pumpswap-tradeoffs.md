# Blast V2: PumpSwap lessons, migration incentives and scope

Research recommendation, 2026-09-05. This preserves the agreed no-swap
auto-LP flow and assesses an optional future migration route. It does not
change deployed configuration or authorize a new migration fee on other DEXes.
Read alongside [PumpSwap mechanics](pumpswap-mechanics-and-benefits.md) and the
[Sui venue comparison](sui-dex-fee-economics.md).

Subsequent user decision: build the V2 scope with a volume-based fee rate,
swap burns and separate custody for every fee allocation, including LP fees.
The [refined design](blast-v2-volume-fees-and-burn-design.md) supersedes the
fixed/time-scheduled fee and reserve-retained LP-fee recommendations below.
The PumpSwap research remains a comparison, not Blast's fee specification.

## Recommendation

Build a small two-asset constant-product AMM only if Blast wants a durable
destination for its fee-funded liquidity and the corresponding control over
fee accounting. First use it for external creator-fee reinvestment; later
offer direct graduation into it as another creator-selected route. Keep
external migration available. Neither stage needs a new V3 or DLMM engine.

The useful PumpSwap lesson is ownership of the launch-to-trading lifecycle:
the launchpad can keep liquidity, protocol revenue and creator-fee policy
working together after graduation. Pump documents a constant-product AMM,
separate LP/protocol/creator fees, canonical graduated pools and dynamic fee
tiers. Those product mechanisms do not require concentrated liquidity.
[PumpSwap technical docs](https://github.com/pump-fun/pump-public-docs/blob/main/docs/PUMP_SWAP_README.md),
[fee program](https://github.com/pump-fun/pump-public-docs/blob/main/docs/FEE_PROGRAM_README.md).

This is an architectural inference, not evidence that copying PumpSwap would
reproduce its volume. Aggregators need to integrate our pool and quote it
competitively. Ordinary transferable coins may trade elsewhere, and Blast
cannot collect unrelated pools' fees merely by originating their coin.

## What we gain and give up

| Choice | Benefit for Blast | Cost or limitation |
| --- | --- | --- |
| Existing DEX plus distributor | Existing venue execution and routing support; little new AMM custody logic | Venue fee share, external upgrades/dependencies, and different deposit behavior; Aftermath's wrapper can assess fees on offered excess |
| Own constant-product V2 | One proportional deposit implementation; reserve-retained LP fees compound with swaps; native creator/protocol allocation and optional burns; own migration incentive | Must implement and verify reserves, pricing, rounding, LP shares and fee conservation; secure aggregator integration; less local depth per unit of capital than suitably concentrated liquidity |
| Own V3/CLMM | Liquidity can be concentrated around the price to give deeper local execution with less capital | Tick traversal, per-range fee accounting, position state and management; out-of-range positions stop earning |
| Own DLMM | Bin-based liquidity placement and dynamic-fee strategies | Bin traversal, per-bin accounting and additional fee/volatility state; substantial execution and LP-management surface |

Uniswap explains the efficiency and out-of-range tradeoff of concentrated
liquidity in its [primary documentation](https://developers.uniswap.org/docs/get-started/concepts/liquidity-providers/concentrated-liquidity).
Meteora describes DLMM liquidity concentration and dynamic fees in its
[product overview](https://docs.meteora.ag/faq/how-do-i-create-a-new-farm).
The relative engineering burden is our inference from those responsibilities,
not a measured project estimate. The CPMM foundation remains nontrivial:
integer rounding, initial LP minting, reserve manipulation, fee segregation and
permanent custody still require verification. Existing virtual-reserve bonding
curve code is not itself a finished LP-share AMM.

## A zero SUI migration fee

Zero Blast migration fee for an optional SUI-to-Blast-V2 route is a reasonable
incentive: more Quote reaches liquidity, with future swap revenue replacing an
upfront protocol charge. Gas and genuine object/pool creation costs still
exist and should be disclosed separately.

However, the [recommended SUI preset](../decisions/0054-v3-dex-migrators-and-locked-lp-fees.md)
already sets `protocol_quote_migration_fee_bps = 0`. There is no incremental discount
relative to that preset. Do not introduce an external-route surcharge merely
to advertise free internal migration. Current live Blast launch settings were
not established by this research.

The current core snapshots one globally configured graduation fee into each
launch through `LaunchConfig`; `launch::partition_quote` charges that snapshot
before handing assets to the migrator. A future venue-specific waiver must be
bound to the authenticated selected route and Quote type at launch creation,
with the resulting fee disclosed and frozen. It cannot be implemented simply
by omitting a second fee inside the V2 adapter. Existing launches must not be
repriced. Recompute seed pricing and continuity from the actual net assets.

Evaluate a waiver as `foregone fee / incremental net protocol revenue rate`,
with revenue measured against the route we otherwise would have used. For
illustration only, replacing a hypothetical 10-SUI upfront fee with an extra
5 bps of protocol income needs 20,000 SUI of eligible volume before operating
costs. This is not a proposed rate, profit forecast or proof of break-even.

Pump's production [fee page](https://pump.fun/docs/fees), checked today, lists
0.015 SOL on graduation. Its current canonical pools have variable fees and
noncanonical pools total 0.30%. Historical free-migration or universal-0.25%
summaries are insufficient for a current comparison. Listed amounts exclude
some third-party/network charges and are subject to contract configuration.

## Native burns

Three mechanisms are different: locking/burning LP rights, burning a launched
Meme coin, and spending protocol revenue to buy and burn a protocol token.
The first protects liquidity ownership, the second reduces Meme supply, and
the third requires a purchase route and price execution. Pump's handling of
one does not establish the others.

For Blast, the minimal no-swap burn is an opt-in allocation of Meme already
received as a fee, or an explicitly priced sell-side Meme deduction, burned
through the native Coin Registry. Do not take it from LP reserves or silently
spend already-owned creator/protocol balances. A fee unit assigned to burning
cannot simultaneously fund LP or a payout. Quote-denominated fees cannot
become a Meme buyback without a swap; that remains outside the agreed scope.

Blast coins finalize into either `Fixed` or `BurnOnly`, irreversibly. The
pinned framework's `coin_registry::burn_balance` requires `BurnOnly` and
decrements supply. Sending fixed-supply coins to an inaccessible address is
not a native supply burn. Preserve this distinction in eligibility and events.
[Blast supply policy](../decisions/0047-coin-registry-authoritative-supply-mode.md),
[pinned framework](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move).

Immediate native burning adds mutable Currency access to a swap; a separately
custodied burn balance with permissionless batch execution is an alternative.
An on-DEX burn applies only to trades routed through that DEX, not every
ordinary transfer of the coin. Burned supply alone is not a price guarantee.

## Dynamic fees without a new liquidity engine

Yes: a CPMM can calculate a bounded fee first and apply the ordinary swap
equation to the corresponding fee-adjusted input. PumpSwap's fee program
selects tiers using Quote-denominated market capitalization for canonical
pools; noncanonical pools use a flat schedule. Dynamic fees are independent
of concentrating liquidity into ticks or bins.

For an initial Blast AMM, prefer one fixed fee policy. If dynamic fees are a
launch requirement, a bounded time schedule set at pool creation is simpler
than volatility tracking: it needs no market oracle or bin traversal and can
be quoted deterministically, but it does not react to actual market conditions.
Define total fee bounds, LP/creator/protocol/burn allocations, schedule anchors
and exact boundary/rounding behavior before implementation. A high initial
fee may deter both bots and legitimate traders; it is not proof of protection.

Market-cap tiers are also possible, but reserve-derived spot price can be
moved by trading. Select fees from defined pre-trade state, test threshold
crossing and transaction splitting, and specify the supply reference for
burnable assets. Pure spot-based tiers are policy signals, not manipulation-
resistant oracles. Volatility-adaptive fees add observation/decay state and
should be a later decision rather than a pretext to build a DLMM.

## Scope to preserve

Keep two-asset pools, proportional deposits with excess retained, exact swap
quotes and bounds, LP-share conservation, permanently committed vault shares,
separate fee custody, and SDK/aggregator composition. No deposit/withdrawal
charge is recommended for Blast's own fee-reinvestment path. Add the optional
direct-migration route after the AMM and fee-funded deposit flow are verified.
Native burn and dynamic fee policies can be independent bounded additions;
neither requires a general hook framework, a new router or a V3/DLMM engine.

These are recommendations and tradeoffs, not accepted new protocol policies.
