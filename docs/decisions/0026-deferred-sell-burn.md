# 0026: Deferred sell burn custody

- Status: accepted
- Date: 2026-08-24
- Amends: [0003](0003-treasury-cap-lifetime-and-burn.md), [0004](0004-bonding-curve.md), [0023](0023-generated-coin-supply-and-metadata-custody.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui |

## Context

The sell curve designates a progress-dependent portion of meme input for burn
before calculating how much input is effective against the curve. Destroying
that amount on every sell would require a mutable shared `Currency<Meme>` input
on every sell and would add repeated Coin Registry writes to the hot trading
path.

Sending coins to `0x0` is not a supply burn. The coins would continue to exist,
total supply would remain unchanged, and an event reducer could not truthfully
report them as destroyed.

## Decision

On a burnable launch, each sell separates the curve-designated amount into a
dedicated `pending_burn: Balance<Meme>` owned by `Launch<Meme, Quote>`. The
amount does not enter the meme curve reserve and is not a fee, claim, migration
asset, or withdrawable balance.

During bonding, `Sold` records the pending-burn delta and final pending-burn
total. It does not report a supply decrease. At migration, after trading is
closed and before final settlement, launch passes the complete accumulated
balance to `Currency<Meme>.burn_balance`. One `MemeBurnedAtMigration` event
records the destroyed amount and resulting total supply. The pinned framework
accepts a `Balance<T>` directly, requires `BurnOnly`, and decreases registry
supply (`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:399-411`).

A fixed-supply launch requires `max_burn_bps == 0`, so its pending-burn balance
always remains zero. Fixed launches neither strand coins nor transfer them to
`0x0`. Their complete non-fee meme inventory follows the explicitly accounted
migration or residual-return path.

The curve arithmetic and seller outcome do not change: the meme fee is removed
first, the progress burn allocation is removed second, and only the effective
meme amount is priced and joined to the curve reserve. Until terminal burn, the
Coin Registry total supply remains unchanged.

## Alternatives considered

**Burn on every sell.** Safe but rejected for the initial implementation because
it adds a Coin Registry shared-object dependency and supply mutation to every
sell rather than one terminal operation.

**Send fixed-supply coins to `0x0`.** Rejected: it is irrecoverable custody, not
a supply burn, and makes total-supply accounting disagree with burn events.

**Join the designated amount to the curve reserve.** Rejected: the seller would
receive a quote calculated from a smaller effective input while the full input
changed future curve pricing.

## Consequences

- Sell transactions mutate only launch-owned balances.
- Burnable supply decreases once, at migration, by the exact accumulated total.
- Event consumers distinguish pending burn custody from completed supply burn.
- Migration must reconcile curve inventory, fees, pending burn, and quote
  reserves as separate named balances.

## Verification

- Sell tests prove the designated amount enters only `pending_burn` and never
  the curve reserve or fee ledger.
- Sequence tests prove pending-burn totals equal the sum of sell deltas.
- Burnable migration decreases Coin Registry total supply by exactly that total
  and leaves a zero pending balance.
- Fixed launch construction rejects nonzero `max_burn_bps`; every fixed-launch
  test observes a zero pending balance and no burn event.
- Conservation tests include pending burn as custody before migration and as
  destroyed supply only after migration.
