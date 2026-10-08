# 0111: Venue-owned presale pool tiers

- Status: proposed
- Date: 2026-10-08
- Amends: [0099](0099-standalone-overflow-presale.md) and
  [0110](0110-presale-initializer-and-early-close.md), whose `blast_presale::new` took a pool
  tier and whose `Presale` and `PresaleCreated` carried it

## Context

`blast_presale::new` took `tick_spacing` and `pool_fee_rate`, the presale stored them, and
`PresaleCreated` emitted them. Only the Cetus and Bluefin migrations read them back, through the
package-only `pool_tier`.

Not every venue has a tier. The Aftermath vendor's 50/50 weighted pool has no ticks or fee tier,
and its fees are constants in its own module, so it passed `0, 0`. Every Aftermath sale then
stored and announced a meaningless "tick spacing 0, fee 0" tier. That put venue terms into the
venue-neutral sale.

## Decision

The pool tier belongs to the venue.

- **Presale.** `blast_presale::new` drops `tick_spacing` and `pool_fee_rate`. `Presale` and
  `PresaleCreated` lose both fields, and `pool_tier` is removed.
- **Cetus.** `cetus::new` still takes the creator's `tick_spacing`. It records it in the shared
  `VenueConfig` under `cetus::TickSpacingKey<Meme>`, next to the pool-creation capability it
  already reserves there. It then emits `cetus::PoolTierReserved<Meme, Quote>` with the tick
  spacing and the fee rate Cetus sets for it. `cetus::migrate` reads the tick spacing back.
- **Bluefin.** `bluefin::new` still takes the creator's `tick_spacing` and `pool_fee_rate`,
  checked against Bluefin's bounds as before. It now also takes `&mut VenueConfig`, records a
  `bluefin::PoolTier` under `bluefin::PoolTierKey<Meme>`, and emits
  `bluefin::PoolTierReserved<Meme, Quote>`. `bluefin::migrate` takes `&VenueConfig` and reads the
  tier back.
- **Vendors.** A vendor whose venue has no tier passes none.
- **`VenueConfig`.** It gains package-only `add_value` and `value` for plain dynamic fields beside
  its object fields. It stays write-once: nothing removes or replaces a value.

The tier is keyed by the sale token's type alone. A sale token has exactly one sale: `new`
requires a zero-supply `TreasuryCap`, and `finalize` seals the supply. The launchpad migrators
already key Cetus reservations the same way, under their own `VenueConfig`.

## Alternatives considered

- **`Option` tier in the sale.** This removes the zeros but keeps venue terms in the
  venue-neutral sale. Every new venue with different pool terms would change the presale ABI
  again. Rejected.
- **A tier object owned by the sale.** This adds an object and a lifecycle for two numbers. The
  shared `VenueConfig` already holds each Cetus reservation. Rejected.

## Consequences

- Indexers read a sale's tier from its venue's `PoolTierReserved`, emitted in the creation
  transaction before `PresaleCreated` and typed by the same `<Meme, Quote>`, or from
  `VenueConfig`.
- **ABI.** `blast_presale::new`, `bluefin::new`, and `bluefin::migrate` change signature, and the
  layouts of `Presale` and `PresaleCreated` change. Together with ADR 0110, this ships in the
  fresh `blast_presale` and vendor publications.

## Verification

- The `blast_presale` unit tests check that `bluefin::new` emits its tier and records it in
  `VenueConfig`.
- They check that `PresaleCreated` carries no tier.
- `cetus::new` and `cetus::migrate` need live Cetus objects, so the mainnet E2E rerun on the
  fresh publication covers the recorded tick spacing. E2E-011 migrates a Cetus sale.
