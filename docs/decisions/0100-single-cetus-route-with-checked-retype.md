# 0100: One Cetus route per operation with a checked retype

- Status: accepted
- Date: 2026-09-30
- Amends: [0059](0059-production-launchpad-abi-and-sdk-parity.md) (the frozen
  `production-launchpad-v1` ABI baseline) and
  [0091](0091-fee-split-buyback-and-burn.md) (one buyback entry per coin order)

## Context

Cetus orders a pool's coin types by type name, and its pool type is
`Pool<CoinA, CoinB>` in that order. A launch knows its coins only as `Meme` and
`Quote`, so the migrators adapter exposed every Cetus operation twice:
`migrate_meme_a`/`_meme_b`, `collect_fees_meme_a`/`_meme_b`,
`settle_and_update_fee_split_meme_a`/`_meme_b`, and
`buyback_and_burn_meme_a`/`_meme_b`, each pair differing only in which side the
Meme occupies. Eight public routes doubled the frozen ABI, the source gate, and
the SDK's route selection, and every new Cetus operation would need two more.

The presale's Cetus adapter already replaced its pair of routes with one generic
route that retypes values through a dynamic field. The owner approved the same
change to the migrators on 2026-09-30, as an amendment to the frozen
`production-launchpad-v1` ABI.

## Decision

Each Cetus operation after `new` is one public route, `migrate`, `collect_fees`,
`settle_and_update_fee_split`, and `buyback_and_burn`, generic over
`<Meme, Quote, CoinA, CoinB>`. The caller names the pool's coins in Cetus's
canonical order as `CoinA` and `CoinB`; the SDK computes that order as before.

- **Guard order.** Every route checks this package's generation first.
  `migrate` then requires `factory::is_right_order<CoinA, CoinB>()`
  (`EInvalidCoinOrder`); the other routes take an existing `Pool<CoinA, CoinB>`,
  whose type Cetus already fixed in canonical order. Every route then runs the
  pure pair proof, and its existing checks follow in their former order.
- **Pair proof.** `is_meme_coin_a` compares original type names and aborts with
  `EWrongCoinPair` unless `(CoinA, CoinB)` is exactly `(Meme, Quote)` or
  `(Quote, Meme)`; it returns which side is the Meme.
- **Checked retype.** `reorder` moves a pair between Meme-and-Quote order and
  pool order (unchanged when Meme is coin A, swapped otherwise). Each value
  passes through `cast`, which adds it as a dynamic field under the sealed
  `CastKey` on a fresh transient UID and removes it under the target type; the
  UID is deleted afterwards. `dynamic_field::remove` aborts with the framework's
  `EFieldTypeMismatch` unless the stored and requested types are identical, so
  a bug in the side logic cannot mint or relabel value: the pair proof decides
  the side, and the framework is the safety net.
- **Economics unchanged.** The fixed side, seed-price orientation, swap
  direction and price limits, residual and fee routing, auto-LP, and events are
  the old routes' exactly; the venue fork reproduces every amount of both coin
  orders.

## Alternatives considered

**Keep two routes per operation.** Rejected: it doubles the public ABI, the
pinned bodies, and SDK route selection for no behavioural difference.

**One private generic helper behind two thin public wrappers per operation.**
Rejected: it removes the duplicated bodies but keeps all eight public routes,
which are the costly part for the frozen ABI and every consumer.

## Consequences

- Cetus routes take four type arguments; the SDK still computes the Cetus coin
  order and passes `[Meme, Quote, CoinA, CoinB]`.
- A reversed order aborts `migrate` with `EInvalidCoinOrder`; a foreign pair
  aborts any route with `EWrongCoinPair` (code 2).
- Each retype creates and deletes one transient UID and a dynamic field per
  value inside the transaction, so no storage is charged; a collection spends
  slightly more computation gas than before.
- The frozen `production-launchpad-v1` ABI baseline is amended: the eight
  `_meme_a`/`_meme_b` routes are replaced by the four generic routes, recorded as
  an approved amendment in the SDK baseline.

## Verification

- `sui/migrators/tests/cetus_route_tests.move` covers the pair proof for both
  orders, a foreign pair, the same coin twice, and a retype to another type
  aborting in the framework.
- The launchpad venue fork runs both coin orders through the single routes
  against real Cetus v15 bytecode, including a reversed order and a foreign pair
  at migration.
- The migrators source gate pins every route body, the pair proof, `reorder`,
  and `cast`, and permits dynamic-field removal only in `cast`.
