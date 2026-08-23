# 0010: Migration routes and venue adapters

- Status: proposed
- Date: 2026-08-22

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@ae60d06` | `ae60d065ed27576d25ac1c94145e5ffe3ddcf89e` | MystenLabs/sui |
| `cetus@ddfbdeb` | `ddfbdeba174319998b012de876ab7ec23c3ab0bc` | CetusProtocol/cetus-contracts |
| `bluefin@91ce930` | `91ce930575b2aa3decab9b7e129b8002deba80c1` | fireflyprotocol/bluefin-spot-contract-interface |
| `turbos@cff6932` | `cff693265bfc41c7de2233afe31c9d7428adc9e1` | turbos-finance/turbos-sui-move-interface |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |

## Context

At the terminal threshold the curve must hand its reserves to a venue exactly once. Three risks shape the
design: a third party pre-creating the graduation pool at a hostile price; a venue that does not support
the selected pair; and adapter code that could alter launch economics.

## Decision

### Invariant first

**The selected `(Meme, Quote)` pair is fixed at launch and never changes** — through bonding, migration,
recovery, and settlement. Migration selects a *route*; it never selects a different pair
([ADR 0005](0005-quote-asset-generalisation.md)).

### Core / adapter boundary

Core produces a single-use, non-droppable `MigrationPayload<Meme, Quote>` and accepts back only a sealed
settlement built through an adapter-witness-gated constructor. This adapts the historical typed handoff,
which checked `type_name::get<Witness>() == witness` before releasing balances
(`memez@00596fd:fun/sources/memez_fun.move:71-88`), narrowed so an adapter can neither mutate launch
economics nor retain unaccounted assets.

Core knows nothing venue-specific. Per
[ADR 0001](0001-sui-package-and-module-layout.md) it imports no venue package; composition happens in the
transaction.

An adapter **may reject an unsupported pair**. Core records the rejection with a reason code and does not
pretend universal coverage (premise **P9**).

### Route selection

**Route A — preflight reservation before the curve opens.** Where a venue offers a reservation
primitive, it runs in **command 2 of the launch transaction**
([ADR 0002](0002-coin-creation-and-currency-authority.md)), inside the adapter package, before any
trading.

On Cetus: `factory::mint_pool_creation_cap<Meme>(config, pools, &mut TreasuryCap<Meme>, ctx)`
(`cetus@ddfbdeb:packages/cetus_clmm/sources/factory.move:607-621`) followed by
`register_permission_pair<A, B>(config, pools, tick_spacing, &cap, ctx)`
(`cetus@ddfbdeb:packages/cetus_clmm/sources/factory.move:649-670`), which requires the **quote** coin type to be present in
`allowed_pair_config` for that tick spacing — a Cetus pool-manager-gated list
(`cetus@ddfbdeb:packages/cetus_clmm/sources/factory.move:517-560`, `EQuoteCoinTypeNotInAllowedPairConfig`).

The adapter seals the resulting `PoolCreationCap` id into the `RouteCommitment`; `launch::finish` verifies
it and records the reservation, and the cap is custodied by the protocol. At migration the adapter calls
`create_pool_v3_with_creation_cap` (`cetus@ddfbdeb:packages/cetus_clmm/sources/pool_creator.move:95-139`),
which asserts the cap matches the registered permission pair (`ECapNotMatchWithPoolKey`). Front-running
the graduation pool is then impossible for that pair and tick spacing. **If `finish` aborts, the whole
transaction reverts and no reservation survives.**

**Route B — fresh pool creation** when no pool exists at migration and no reservation was possible:
`pool_creator::create_pool_v3` (`cetus@ddfbdeb:packages/cetus_clmm/sources/pool_creator.move:155-198`),
`pool::create_pool_with_liquidity` (`bluefin@91ce930:sources/pool.move:247-273`), or
`pool_factory::deploy_pool_and_mint_with_return_`
(`turbos@cff6932:clmm/sources/pool_factory.move:68-90`).

**Route C — adopt an existing pool, only within a bounded acceptance band.** If a pool for the exact
fixed pair already exists, the adapter reads its live state and adopts it **only if every one** of these
holds:

| Check | Source of truth |
| --- | --- |
| live sqrt price within `ACCEPT_BAND_BPS` of the curve-derived target | `pool::current_sqrt_price` (`bluefin@91ce930:sources/pool.move:675`), venue equivalent elsewhere |
| `tick_spacing` equals the configured value | `pool::get_tick_spacing` (`bluefin@91ce930:sources/pool.move:782`) |
| fee rate equals the configured value | `pool::get_fee_rate` (`bluefin@91ce930:sources/pool.move:773`) |
| pool not paused or disabled where the venue exposes it | venue getter |
| orientation matches the computed side | `factory::is_right_order` (`cetus@ddfbdeb:packages/cetus_clmm/sources/factory.move:1111-1140`) |

Any mismatch is an **atomic abort**: no partial migration, no liquidity added, launch state unchanged.

### Fallback semantics

On abort the launch stays in `MigrationPending` with **exactly one** migration right outstanding — never
two. A bounded retry window permits re-attempt after conditions change. If the window expires the launch
enters `Recovery`, a named, explicitly governed state that cannot redirect assets outside the approved
policy (`../architecture.md`). Route selection, abort reason, and each retry are evented.

### A venue switch must first release the reservation

A Route A reservation is **state held inside the venue**, not inside Blast: `register_permission_pair`
writes the pair into Cetus's `PermissionPairManager`, and only the matching `PoolCreationCap` can undo it
(`cetus@ddfbdeb:packages/cetus_clmm/sources/factory.move:673-681`). Switching venues after a failed Route
A attempt would therefore strand a live permission pair on Cetus plus an orphaned `PoolCreationCap` in
Blast custody — a pair no one can use and no one can clear, because the cap that unregisters it is now
attached to a launch that settled elsewhere.

**Rule: a retry may not target a different venue while a reservation is held.** Before any venue switch
the launch must first execute, atomically and in this order:

1. `factory::unregister_permission_pair<A, B>(config, pools, tick_spacing, &cap)`
   (`cetus@ddfbdeb:packages/cetus_clmm/sources/factory.move:673-681`);
2. dispose of the `PoolCreationCap` according to the recorded disposition policy;
3. emit `ReservationReleased` carrying venue, `reservation_id`, tick spacing, orientation, and reason
   ([ADR 0011](0011-event-schema-and-replay.md)), so the release is auditable from events alone;
4. clear the reservation from launch state.

Only then may a retry select a different venue. A same-venue retry keeps the reservation and does not
release it. Release is `AdminCap`-gated and forbidden once a settlement exists
([ADR 0007](0007-acl-pause-and-versioning.md)).

`MigrationAborted` carries `reservation_still_held`, so an indexer can tell a retryable same-venue abort
from one that requires a release first, without reading state.

### Orientation and price

Cetus enforces a canonical order derived from defining-id type-name bytes:
`is_right_order` returns false when A's first differing byte is lower than B's, and `new_pool_key` asserts
`EInvalidCoinTypeSequence` (`cetus@ddfbdeb:packages/cetus_clmm/sources/factory.move:1074-1140`). The meme's fully-qualified type
name embeds its freshly published package address, which is unpredictable, so **the meme can land on
either side** and the adapter must handle both orientations, inverting the initial sqrt price on one
branch.

All three venues use the same Uniswap-V3 X64 convention with byte-identical bounds —
`MIN_SQRT_PRICE_X64 = 4295048016`, `MAX_SQRT_PRICE_X64 = 79226673515401279992447579055`, tick bound
`443636` (`cetus@ddfbdeb:packages/cetus_clmm/sources/math/tick_math.move:7-11`;
`turbos@cff6932:clmm/sources/lib/math_tick.move:12-14`) — so one shared vector set covers all three
([`../vectors/quote-decimals.json`](../vectors/quote-decimals.json)).

The initial price is **derived from the terminal atomic reserves**, never configured
([ADR 0005](0005-quote-asset-generalisation.md)). The historical migrator hard-coded it, together with
decimals, tick spacing and fee rate (`memez@00596fd:migrators/xpump/sources/xpump.move:25-45`).

### Terminal ordering

1. seed the venue position;
2. return residual coins to the launch;
3. burn remaining non-migrated meme inventory;
4. consume the `TreasuryCap` into `make_supply_burn_only`;
5. `delete_metadata_cap`;
6. record settlement and emit.

Steps 3 and 4 cannot be reordered: `make_supply_burn_only` consumes the cap that step 3 needs
([ADR 0003](0003-treasury-cap-lifetime-and-burn.md)).

### LP ownership

The position is locked in a Blast-owned `LpVault<Meme, Quote>` with defined fee-collection rights. It is
**not** transferred to `@0x0`; the historical `DEAD_ADDRESS: address = @0x0` disposal
(`memez@00596fd:migrators/xpump/sources/xpump.move:22`) is exactly what `../protocol-scope.md` rejects as
disposal without economic semantics. Locking also preserves the creator fee stream that
[ADR 0012](0012-flywheel-features.md) depends on.

### Venue compatibility matrix

| | Cetus `ddfbdeb` | Bluefin `91ce930` | Turbos `cff6932` |
| --- | --- | --- | --- |
| Live creation entry | `pool_creator::create_pool_v3[_with_creation_cap]` | `pool::create_pool_with_liquidity<A,B,Fee>` | `pool_factory::deploy_pool_and_mint_with_return_<A,B,Fee>` |
| Deprecated / non-composable | all `create_pool_v2*` abort `EMethodDeprecated` (`cetus@ddfbdeb:packages/cetus_clmm/sources/pool_creator.move:37, 58, 78`) | — | `deploy_pool*` entry variants are non-composable (`turbos@cff6932:clmm/sources/pool_factory.move:44, 91`) |
| Requires `&CoinMetadata` | no — v3 removed it | no — symbol, decimals and url are raw `vector<u8>` parameters (`bluefin@91ce930:sources/pool.move:191-196`) | no |
| Coin Registry compatible | yes | yes | yes |
| Pool creation fee | — | `Balance<CoinTypeFee>`, amount from `config::get_pool_creation_fee_amount` (`bluefin@91ce930:sources/config.move:66`) | — |
| Route A available | **yes** — `PoolCreationCap` + permission pair; quote must be allowlisted | none found in interface (**P4**) | none found in interface (**P4**) |
| Route C inputs | pool getters | `current_sqrt_price` (`bluefin@91ce930:sources/pool.move:675`), `get_fee_rate` (`:773`), `get_tick_spacing` (`:782`) | `get_pool_tick_spacing` (`turbos@cff6932:clmm/sources/pool.move:191-195`) |
| Pair ordering | canonical type-name order enforced (**P3**) | to verify (**P4**) | to verify (**P4**) |
| sqrt price | X64, bounds above | X64 `u128` | X64, identical constants |
| LP artifact | `Position` (`key, store`) | `Position` | `TurbosPositionNFT` |
| Returns residuals | `(Position, Coin<A>, Coin<B>)` | `(ID, Position, u64, u64, Balance<A>, Balance<B>)` | `(NFT, Coin<A>, Coin<B>, ID)` |

### Dependency exemptions and release gates

`../../AGENTS.md` requires immutable full-commit pins and forbids production functions whose intended path
is `abort`. Every venue integration violates one or both. Each is recorded here as a narrow exemption or
an exclusion; **an exclusion gates a release, never the architecture** — all three adapters are fully
specified above.

| Venue | Violation | Exemption / gate |
| --- | --- | --- |
| Cetus | `rev = "mainnet-v1.3.0"` is a tag, not a commit (`cetus@ddfbdeb:packages/cetus_clmm/Move.toml:7-8`) | vendor a SHA-pinned manifest and verify the published package id before release |
| Bluefin | tag-pinned git dependencies (`bluefin@91ce930:Move.toml:7-9`) plus interface bodies that `abort 0` — 52 in `pool.move`, including `create_pool` itself at `bluefin@91ce930:sources/pool.move:202` — declared against `published-at = 0xd075338d…` (`bluefin@91ce930:Move.toml:4`) | same, plus a documented interface-abort exemption: the aborting bodies are a dependency's link stubs resolved to the published package, never Blast production paths |
| Turbos | pins the **Sui framework to `rev = "testnet"`, a mutable branch** (`turbos@cff6932:clmm/Move.toml:7`); **and** ships interface bodies that `abort 0` — five in the creation module alone, at `turbos@cff6932:clmm/sources/pool_factory.move:65, 88, 99, 105, 114`, and the same pattern in the getters, e.g. `get_pool_tick_spacing` at `turbos@cff6932:clmm/sources/pool.move:194`; package version `0.1.8`, `published-at = 0xa5a0c25c…` (`turbos@cff6932:clmm/Move.toml:3-4`), last updated 2025-10-05 | **release blocker.** Both the mutable framework pin and the interface-abort exemption must be resolved: replace the branch pin with a commit, and verify the published id so the aborting local bodies are provably link stubs rather than executed code. |

Release order follows evidence quality: Cetus, then Bluefin, then Turbos.

## Alternatives considered

**Reserve at migration instead of at launch.** Rejected: the pool can be created by anyone during the
whole bonding period, so reserving at the end reserves nothing.

**Clamp or accept any existing pool price.** Rejected: adopting a hostile price transfers the curve's
reserves to whoever set it. The acceptance band plus atomic abort is the minimum safe behaviour.

**Let core call the adapter.** Rejected: it inverts the dependency direction and makes core unbuildable
without a venue dependency.

**Ship only Cetus and omit the other adapters' design.** Rejected: architecture is specified for all
three; only releases are gated.

**Transfer the LP position to `@0x0`.** Rejected: disposal without economic semantics, and it destroys the
creator fee stream.

## Consequences

- Eligible pairs graduate into a pool nobody else could have created.
- Ineligible pairs graduate through Route B or C and carry a disclosed front-running risk.
- A hostile pre-created pool costs a failed migration and a retry, never a bad settlement.
- The `LpVault` is a permanent protocol-owned object per graduated launch.
- Turbos cannot ship until its framework pin is fixed, and that is recorded as a gate rather than a gap.

## Verification

- Route A/B/C decision table executed as tests, including every acceptance-band boundary
  (just inside, exactly at, just outside, on both sides).
- Orientation tests for both sides, with the inverted sqrt price asserted against
  [`../vectors/quote-decimals.json`](../vectors/quote-decimals.json).
- Range test: computed `sqrt_price_x64` strictly inside the venue bounds; out-of-range aborts.
- Duplicate-migration test: a second `begin_migration` or `settle_migration` aborts.
- Atomicity test: reservation succeeds and settlement aborts, leaving no orphaned cap or pair.
- Terminal-ordering test: attempting to lock supply before the terminal burn makes the burn impossible.
- Pair-immutability test: no route, retry, or recovery path changes `Meme` or `Quote`.
- Recovery test: after the retry window expires the launch enters `Recovery` with exactly one migration
  right still outstanding.
- Reservation-cleanup tests: a retry targeting a different venue while a reservation is held aborts; the
  release sequence unregisters the pair, disposes the cap, emits `ReservationReleased`, and clears launch
  state atomically; a same-venue retry does **not** release; release after settlement aborts; and an
  events-only reducer can determine, for every launch, whether a Cetus permission pair is still held.
- Premise **P3** — Cetus ordering direction. Test: unit test over `is_right_order` with both orderings and
  equal-prefix cases.
- Premise **P4** — Bluefin and Turbos front-run and ordering behaviour. Test: read live mainnet bytecode
  or SDK, then a testnet dry run.
- Premise **P5** — Cetus `allowed_pair_config` contents. Test: mainnet read of `PermissionPairManager`.
- Premise **P9** — pre-consumption pair-support detection. Test: read each venue's pool-key and fee-tier
  predicates.
