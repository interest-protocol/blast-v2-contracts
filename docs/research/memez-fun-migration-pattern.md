# Memez.Fun migration authorization pattern

Status: supporting research
Reviewed: 2026-08-24

## Source pin

This note reviews Interest Protocol's
[`interest-protocol/memez-gg`](https://github.com/interest-protocol/memez-gg/tree/00596fdac4dd11f427c7bc594e566ce36160db93)
at full commit
[`00596fdac4dd11f427c7bc594e566ce36160db93`](https://github.com/interest-protocol/memez-gg/commit/00596fdac4dd11f427c7bc594e566ce36160db93).
That commit was also the repository's `main`/`HEAD` when rechecked on
2026-08-24.

## Conclusion

Memez.Fun authorizes a migration **implementation type**, not a DEX cost
policy and not a caller address:

1. An admin adds the external migrator module's sealed witness type to a
   `VecSet<TypeName>` in core configuration.
2. A launch constructor checks that the selected witness type is in the set and
   snapshots its `TypeName` into the new launch.
3. At graduation, core returns a linear `MemezMigrator<Meme, Quote>` containing
   only the migration identity and the two migration balances.
4. The external migrator unlocks that payload by passing its module-owned
   witness. Core compares the supplied witness type to the snapshotted type.
5. The dependency-bearing DEX migrator is a separate Move package that depends
   inward on core; core has no dependency on it or on the DEX.

This supports replacing `venue_cost_policies` with a whitelist of migrator
witness `TypeName`s. It does not support retaining a Quote-denominated venue
cost field in core.

## Whitelist representation

Core's shared `MemezConfig` is an otherwise empty UID object. Its migrator
registry is a dynamic field keyed by
`MigratorWitnessKey<ConfigWitness>()`; the dynamic-field value is a
`VecSet<TypeName>`. Admin-gated generic functions add and remove
`type_name::get<MigratorWitness>()`, so core can register a type declared in an
external package without importing that package:

- key and config object:
  [`fun/sources/config.move:L15-L29`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/config.move#L15-L29)
- admin add/remove:
  [`fun/sources/config.move:L104-L117`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/config.move#L104-L117)
- `VecSet<TypeName>` membership check:
  [`fun/sources/config.move:L167-L177`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/config.move#L167-L177)
- generic set storage helpers:
  [`fun/sources/config.move:L190-L210`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/config.move#L190-L210)

The registry is scoped by `ConfigWitness`: different configuration families
can have different allowed migrator sets. That extra namespace is a Memez.Fun
design choice, not essential to the witness pattern.

## Where approval is verified

Each public launch constructor has a `MigrationWitness` type parameter and
checks it before launch creation:

- Pump:
  [`fun/sources/pump.move:L58-L75`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/pump.move#L58-L75)
- Stable:
  [`fun/sources/stable.move:L61-L78`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/stable.move#L61-L78)
- Auction:
  [`fun/sources/auction.move:L64-L80`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/auction.move#L64-L80)

The common constructor converts that type to `TypeName` and stores it in the
launch:
[`fun/sources/memez_fun.move:L122-L169`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/memez_fun.move#L122-L169).
The negative launch test confirms an unregistered type aborts with
`EMigratorWitnessNotSupported`:
[`fun/tests/pump.move:L1232-L1271`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/tests/pump.move#L1232-L1271).

Approval is therefore checked and snapshotted at **launch creation**, not read
again during migration. From the code, removing a witness from the live config
prevents future launches from selecting it but does not revoke it from launches
that already stored its `TypeName`.

## Witness redemption and the core boundary

The external XPump package declares `public struct Witness() has drop` in its
own module and exposes no constructor. Its module can construct `Witness()`,
while unrelated modules cannot forge the value under Move's module-private
struct construction rules:
[`migrators/xpump/sources/xpump.move:L47-L54`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/migrators/xpump/sources/xpump.move#L47-L54).

Core's public `destroy` function accepts `Witness: drop` and compares
`type_name::get<Witness>()` with the launch's snapshotted witness type. A
mismatch aborts; a match emits the migration event and releases the assets:
[`fun/sources/memez_fun.move:L71-L87`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/memez_fun.move#L71-L87).
The invalid-witness regression test is
[`fun/tests/memez_fun.move:L428-L461`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/tests/memez_fun.move#L428-L461).

This authorizes code identity, not a privileged sender. The core `migrate`
function and XPump entry point are public; anyone may drive migration, but only
the selected adapter module can construct the witness needed to release the
payload.

## Values crossing from core to the migrator

The opaque handoff is:

```move
public struct MemezMigrator<phantom Meme, phantom Quote> {
    witness: TypeName,
    memez_fun: address,
    dev: address,
    quote_balance: Balance<Quote>,
    meme_balance: Balance<Meme>,
}
```

Source:
[`fun/sources/memez_fun.move:L48-L54`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/memez_fun.move#L48-L54).
It has no abilities, so it cannot be copied, dropped, or stored. Core marks the
launch migrated and constructs this single-use payload from the selected Meme
liquidity and Quote liquidity:
[`fun/sources/memez_fun.move:L503-L518`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/memez_fun.move#L503-L518).

For Pump, core first withdraws terminal Quote, selects the Meme liquidity
balance, takes its protocol migration fee, and only then creates the payload:
[`fun/sources/pump.move:L194-L217`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/pump.move#L194-L217).
Successful witness redemption returns exactly
`(dev, Balance<Meme>, Balance<Quote>)`; launch address and witness type are used
for the core migration event.

DEX-specific objects do **not** cross this core handoff. XPump receives its own
config, Bluefin config, clock, metadata, treasury-standard reference, and pool
creation fee coin directly in the adapter call. It redeems the core payload,
then performs Bluefin pool creation and liquidity addition:
[`migrators/xpump/sources/xpump.move:L177-L266`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/migrators/xpump/sources/xpump.move#L177-L266).
The historical adapter's separate `fee: Coin<CoinTypeFee>` is passed directly
to Bluefin; core does not store a route cost, cap it, or subtract it from the
terminal Quote payload.

XPump also splits its own configured `reward_value` from the Quote balance
after witness redemption and before adding liquidity
([`xpump.move:L192-L204`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/migrators/xpump/sources/xpump.move#L192-L204)).
That is adapter reward logic, not a core DEX-opening cost, and is not part of
the reusable authorization pattern.

## Package boundary

The core and XPump migrator live in the same repository but are separate Move
packages:

- Core manifest:
  [`fun/Move.toml:L1-L16`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/Move.toml#L1-L16)
- XPump manifest:
  [`migrators/xpump/Move.toml:L1-L12`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/migrators/xpump/Move.toml#L1-L12)

`XPumpMigrator` depends on both `MemezFun` and the Bluefin interface. `MemezFun`
does not depend on XPump or Bluefin. The minimal dummy migrator demonstrates the
same external-package boundary without DEX logic:
[`migrators/dummy/sources/dummy.move:L1-L21`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/migrators/dummy/sources/dummy.move#L1-L21).

The reusable architectural pattern is therefore:

```text
DEX package
    ↑ dependency
external migrator package  ────────→  launch core
  owns sealed Witness                 owns TypeName allowlist
  owns DEX calls                      owns linear asset handoff
```

## Copy caveat

Copy the boundary pattern, not the historical event call verbatim. The
`destroy` call passes Quote amount before Meme amount
([`memez_fun.move:L79-L84`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/memez_fun.move#L79-L84)),
while the event helper names those positions `meme_amount` then `quote_amount`
([`events.move:L180-L193`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/events.move#L180-L193)).
