# 0005: Generic, permissionless quote asset

- Status: superseded by [0025](0025-quote-whitelist-and-migration-targets.md)
- Date: 2026-08-22

> This was the earlier broad quote-asset proposal. ADR 0025 replaces it with a
> bounded administrative whitelist and per-quote migration targets, without a
> `Currency<Quote>` launch input or a blanket regulated-quote rejection.

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@ae60d06` | `ae60d065ed27576d25ac1c94145e5ffe3ddcf89e` | MystenLabs/sui |
| `cetus@ddfbdeb` | `ddfbdeba174319998b012de876ab7ec23c3ab0bc` | CetusProtocol/cetus-contracts |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |

## Context

A launch must pair the meme coin with a configurable quote `Coin<Quote>`, not a hard-coded SUI. Required
examples include MEME/SUI, MEME/USDC, MEME/sSUI, and arbitrary custom Sui coin types.

Genericity itself is proven feasible: the historical implementation was already parameterised over
`<Meme, Quote>` (`memez@00596fd:fun/sources/structs/constant_product.move:14-26`). What failed
historically was the migrator, which hard-coded `MEME_DECIMALS: u8 = 9` behind an `EInvalidDecimals`
guard, a constant `INITIALIZE_PRICE: u128 = 63901395939770060`, `TICK_SPACING: u32 = 200`, and
`FEE_RATE: u64 = 10000` (`memez@00596fd:migrators/xpump/sources/xpump.move:25-45`). A configurable quote
cannot carry a constant price.

## Decision

### Core accepts any quote, permissionlessly

`blast_fun` core accepts **any `Coin<Quote>`**, including a regulated quote coin. There is no allowlist,
no denial tier, and no privileged quote in core. Admission, routing, ranking, and UI curation are
**external to core**.

### The one structural prerequisite

The launch-time risk snapshot is read from a shared `Currency<Quote>` object. The precise, universal rule
is therefore:

> **Any quote type that has a finalized, shared Coin Registry `Currency<Quote>` can launch.**

This is a **structural prerequisite, not an allowlist**. No party grants it, Blast maintains no list, and
Blast cannot withhold it. A quote whose `Currency` object does not exist has nothing to read and the
launch aborts on a missing shared input — this ADR does not claim support that does not exist.

Two permissionless routes reach the prerequisite, both outside Blast's control:

- an **OTW-created currency awaiting promotion** — anyone may call `finalize_registration`, documented as
  "Can be performed by anyone"
  (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:348-357`);
- an **unregistered legacy coin** — anyone may call
  `migrate_legacy_metadata(registry, &CoinMetadata<Quote>, ctx)`, which shares the `Currency`
  (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:439-449`).

Supporting a quote by reading a raw `CoinMetadata<Quote>` instead is a **separately reviewed future
legacy path**, explicitly out of scope here, because it would yield a snapshot with different fields and
different trust properties.

### Immutable launch-time risk snapshot

Captured once during `launch::finish`, never mutable afterwards, and emitted in `LaunchCreated`:

| Field | Source | Note |
| --- | --- | --- |
| `quote_decimals` | `decimals<Quote>` (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:552`) | needed for display price |
| `meme_decimals` | `decimals<Meme>` | needed for display price |
| `quote_regulated_state` | `is_regulated<Quote>` plus `deny_cap_id<Quote>` (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:599-628`) | stored as a **tri-state**, see below |
| `quote_deny_cap_id` | `deny_cap_id<Quote>` | present only when regulated |
| `quote_supply_state` | `is_supply_fixed` / `is_supply_burn_only` (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:606-620`) | |
| `quote_total_supply` | `total_supply<Quote>` (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:630-638`) | `none` when the state is `Unknown` |
| `quote_treasury_cap_id` | `treasury_cap_id<Quote>` (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:590-593`) | |
| `quote_metadata_cap_state` | `metadata_cap_id<Quote>` (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:582-588`) | claimed / unclaimed / deleted |
| `quote_symbol_hash`, `quote_name_hash` | hash of `symbol<Quote>` / `name<Quote>` | hashed, not stored raw |

**This is a point-in-time disclosure.** An issuer can migrate an `Unknown` regulated state to `Regulated`
after the launch (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:471-500`). Indexers and curated clients must treat the snapshot
as launch-time disclosure and additionally watch the live `Currency<Quote>`.

### Regulated quotes are a risk fact, not a rejection rule

`RegulatedState::Regulated { cap, allow_global_pause, variant }` with a live `DenyCapV2`
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:139-148, 263-278`) means the quote issuer can deny-list an address or globally
pause that coin. If the curve's `Balance<Quote>` sits behind a deny list, user exits can be frozen by a
third party. Core discloses this; it does not prevent it. The limits of Blast's own pause against a
third-party freeze are stated in [ADR 0007](0007-acl-pause-and-versioning.md).

### Regulated tri-state fidelity

A currency created through `migrate_legacy_metadata` has `regulated: RegulatedState::Unknown` and
`treasury_cap_id: none` (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:718-719`), and `is_regulated` returns **false** for
`Unknown` (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:623-628`). `Unknown` is **not** `Unregulated`.

The snapshot therefore stores the **raw tri-state**, never a boolean, so a curated client can distinguish
"verified unregulated" from "unknown, nobody has checked", and an indexer is never told a legacy quote is
safe when the truth is that its status was never established.

### Pair immutability

The selected `(Meme, Quote)` pair is fixed at launch and **never changes** — through bonding, migration,
and settlement. Migration may select a *route*; it may never select a different pair. This is an
invariant with a dedicated negative test, not a convention.

### Decimals

The on-chain initial sqrt price is derived from **atomic reserve amounts**, so **no extra decimal
correction is applied in the on-chain raw-ratio calculation**:

```text
sqrt_price_x64 = isqrt( (quote_atomic << 128) / meme_atomic )     // meme is coin A
sqrt_price_x64 = isqrt( (meme_atomic  << 128) / quote_atomic )    // meme is coin B
```

Decimals do **not** disappear. Any human-readable price still requires **both** decimal values:

```text
display_price_quote_per_meme = (quote_atomic / 10^quote_decimals) / (meme_atomic / 10^meme_decimals)
                             = raw_ratio * 10^(meme_decimals - quote_decimals)
```

[`../vectors/quote-decimals.json`](../vectors/quote-decimals.json) demonstrates the point: across four
decimal combinations the raw ratio differs by three orders of magnitude in each direction while the
display price is identical at `0.000015453604` quote per meme. That is why both decimals are captured in
the snapshot and emitted — an indexer never has to fetch them separately or guess.

### Venue support is a property of the adapter, not of core

Core does not promise that any venue supports any pair. The per-venue support predicate and route
selection live in [ADR 0010](0010-migration-and-venue-adapters.md). An adapter **may reject an
unsupported pair**, and core records that rejection with a reason rather than implying universal
coverage.

Cetus specifically gates its *reservation* primitive on the quote asset: `register_permission_pair`
requires the quote coin type to be in `allowed_pair_config` for the chosen tick spacing, and only a Cetus
pool-manager role can add it (`cetus@ddfbdeb:packages/cetus_clmm/sources/factory.move:517-560, 649-700`).
That determines **which migration route is available**, not whether the pair may launch.

### Type and object boundaries

- `Launch<Meme, Quote>` holds `Balance<Quote>` for curve reserves and a **separate** `Balance<Quote>` for
  accrued fees; a creator contribution claim is a third, separately named balance
  ([ADR 0006](0006-fees-and-launch-paths.md)).
- `MigrationPayload<Meme, Quote>` carries the pair; an adapter cannot re-derive or reorder it.
- Every economic event carries the quote type and both atomic amounts.

## Alternatives considered

**Quote allowlist governed by Blast.** Rejected: it makes Blast the gatekeeper of which assets may be
used, contradicts the permissionless requirement, and grows persistent state.

**Deny regulated quotes.** Rejected: a regulated quote is a disclosed risk, not an invalid input, and
denial would exclude legitimate assets such as regulated stablecoins.

**Store a boolean `is_regulated`.** Rejected: it collapses `Unknown` into `Unregulated` and would report
an unchecked legacy coin as safe.

**Hard-code SUI as quote.** Rejected by the requirement, and by the historical migrator's failure mode.

**Configure a human-readable initial price.** Rejected: it reintroduces the decimal dependency that
deriving from atomic reserves removes.

## Consequences

- Any coin with a finalized `Currency` can be a quote; the launch surface is as wide as the registry.
- Some pairs will have no reservation route and therefore a front-runnable graduation
  ([ADR 0010](0010-migration-and-venue-adapters.md)).
- Curated clients carry the responsibility for warning about regulated or unknown quotes.
- Risk facts are launch-time only; live monitoring is an indexer obligation, stated in
  [ADR 0011](0011-event-schema-and-replay.md).
- A quote with no `Currency` object cannot launch until someone completes its permissionless migration.

## Verification

- [`../vectors/quote-decimals.json`](../vectors/quote-decimals.json) — four decimal combinations, both
  orientations, exact `sqrt_price_x64` integers, and the identical display price.
- Range test: every vectored `sqrt_price_x64` lies strictly inside the venue bounds
  `[4295048016, 79226673515401279992447579055]`.
- Pair-immutability test: no transition, route, or recovery path can change `Meme` or `Quote`.
- Snapshot-immutability test: no function mutates the risk snapshot after `launch::finish`.
- Tri-state test: a launch against a legacy-migrated quote records `Unknown`, not `Unregulated`.
- Missing-currency test: a launch against a quote with no shared `Currency` aborts.
- Premise **P5** — which quote assets Cetus currently admits to `allowed_pair_config`. Test: mainnet read
  of the `PermissionPairManager`.
- Premise **P9** — whether an adapter can determine pair support before consuming the payload. Test: read
  each venue's pool-key and fee-tier predicates on mainnet.
