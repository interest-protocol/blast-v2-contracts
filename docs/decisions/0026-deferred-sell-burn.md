# 0026: Deferred sell burn custody

- Status: accepted
- Date: 2026-08-24
- Amends: [0003](0003-treasury-cap-lifetime-and-burn.md), [0004](0004-bonding-curve.md), [0023](0023-generated-coin-supply-and-metadata-custody.md)
- Amended by: [0043](0043-versioned-launch-trading-and-atomic-migration.md), [0077](0077-fixed-creator-selected-sell-burn.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui |

## Context

The sell curve designates a creator-selected fixed portion of meme input for burn
before calculating how much input is effective against the curve. Destroying
that amount on every sell would require a mutable shared `Currency<Meme>` input
on every sell and would add repeated Coin Registry writes to the hot trading
path.

Sending coins to `0x0` is not a supply burn. The coins would continue to exist,
total supply would remain unchanged, and an event reducer could not truthfully
report them as destroyed.

## Decision

On every launch, each sell separates the curve-designated amount into a
dedicated `pending_burn: Balance<Meme>` owned by `Launch<Meme, Quote>`. The
amount does not enter the meme curve reserve and is not a fee, claim, migration
asset, or withdrawable balance.

During bonding, `Sold` records the pending-burn delta and final pending-burn
total. It does not report a supply decrease. At migration, after trading is
closed, Blast disposes of pending burn plus terminal curve residual in one step.
A `BurnOnly` launch passes the balance to `Currency<Meme>.burn_balance`, which
decreases registry supply
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:399-411`).
A `Fixed` launch transfers the same balance to `0x0`. That balance becomes
inaccessible, but the event records fixed disposal rather than native supply
destruction and total supply remains unchanged.

The curve arithmetic and seller outcome do not change: the meme fee is removed
first, the fixed burn allocation is removed second, and only the effective
meme amount is priced and joined to the curve reserve. Until terminal burn, the
Coin Registry total supply remains unchanged.

## Alternatives considered

**Burn on every sell.** Safe but rejected for the initial implementation because
it adds a Coin Registry shared-object dependency and supply mutation to every
sell rather than one terminal operation.

**Report fixed `0x0` disposal as native burn.** Rejected: the transfer is
irrecoverable custody, not native supply destruction. ADR 0043 accepts the
transfer only with distinct event semantics and unchanged total supply.

**Join the designated amount to the curve reserve.** Rejected: the seller would
receive a quote calculated from a smaller effective input while the full input
changed future curve pricing.

## Consequences

- Sell transactions mutate only launch-owned balances.
- BurnOnly supply decreases once at migration; Fixed supply remains unchanged.
- Event consumers distinguish pending custody, native burn, and `0x0` disposal.
- Migration must reconcile curve inventory, fees, pending burn, and quote
  reserves as separate named balances.

## Verification

- Sell tests prove the designated amount enters only `pending_burn` and never
  the curve reserve or fee ledger.
- Sequence tests prove pending-burn totals equal the sum of sell deltas.
- Burnable migration decreases Coin Registry total supply by exactly that total
  and leaves a zero pending balance.
- Fixed migration transfers its exact disposal balance to `0x0`, reports no
  native supply burn, and leaves total supply unchanged.
- Conservation tests include pending burn as custody before migration and as
  destroyed supply only after migration.
