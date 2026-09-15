# 0054: V3 DEX migrators, exact seed pricing, and locked LP fees

> Amended by [ADR 0067](0067-retire-full-sail-migrator.md), which retires all
> Full Sail routes and dependencies before the first recorded production release.
> Amended by
> [ADR 0069](0069-consolidate-launch-graduation-and-move-migration-math.md),
> which moves seed-price, deviation, utilization, and residual arithmetic into
> the aggregate migrators package as package-only operations.
> Amended by [ADR 0081](0081-separate-lp-fee-share-policy.md), which splits LP
> fees on a separate `LpFeePolicy` with per-project pins instead of the trade
> share in `RuntimeConfig`.

- Status: accepted
- Date: 2026-08-29
- Amends: [0010](0010-migration-and-venue-adapters.md),
  [0011](0011-event-schema-and-replay.md),
  [0012](0012-flywheel-features.md), and
  [0028](0028-hot-cold-runtime-configuration.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `bluefin@91ce930` | `91ce930575b2aa3decab9b7e129b8002deba80c1` | `fireflyprotocol/bluefin-spot-contract-interface` |
| `cetus@ddfbdeb` | `ddfbdeba174319998b012de876ab7ec23c3ab0bc` | `CetusProtocol/cetus-contracts` |
| `mmt@e27d14c` | `e27d14caed53e1b7c4e1c12ea89b2ff87c58ee82` | `mmt-finance/mmt-contract-interface` |
| `turbos@cff6932` | `cff693265bfc41c7de2233afe31c9d7428adc9e1` | `turbos-finance/turbos-sui-move-interface` |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | `MystenLabs/sui` |
| `integer-mate@06660f7` | `06660f704c4ac1d443ab62346a46b5b60d49df33` | `CetusProtocol/integer-mate` |
| `integer-mate@09a12d9` | `09a12d9b171122883d9350039d4ed6e8400033b9` | `CetusProtocol/integer-mate` |
| `integer-library@8a534bd` | `8a534bd1c0b334cd3937c27987f3147a06ba6a18` | `fireflyprotocol/integer-library` |
| `move-stl@0681fec` | `0681fec63a310ae753d03a06f7c05d3e2925bb09` | `CetusProtocol/move-stl` |

Full Sail does not publish a Move source repository. Its production dependency
is pinned from mainnet instead:

| Fact | Value |
| --- | --- |
| Original package id | `0xe74104c66dd9f16b3096db2cc00300e556aa92edc871be4bc052b5dfb80db239` |
| Latest package revision | `4` at `0x497a144ba3d93ae44d9fd23d4ff4761c329d87a505136d2269c743b2297fa881` |
| Latest package digest | `CWkTsBks7SsYsvDQ9QQxkHqgDAKdvuDkh4DAd9DHo3nF` |
| Upgrade transaction | `3rbk2g4FuuqFGKBLyNYLkqJjv2XKvgnSans6EpPaRCSd` |
| SDK cross-check | `@fullsailfinance/sdk@11.0.0`, integrity `sha512-Xdp6aigtv6GPw1hNyCVqptksSzN7VgO7Egf4IKZO1o+i/xJTx2i99EgFdui6YjG9o2VJ9cRfigxQwv7Diqw1+w==` |

The official contracts page still lists revision 3. Mainnet lineage and the
current SDK both identify revision 4. The adapter uses a minimal local
interface reconstructed from the normalized revision-4 ABI; its bodies are
compile-time link stubs, not venue code.

The product comparison uses current first-party documentation for
[Memez.Fun migration](https://docs.interestprotocol.com/overview/sui/memez.gg/memez.fun/migrators),
[Raydium LaunchLab](https://docs.raydium.io/products/launchlab/bonding-curve),
[Pump graduation](https://pump.fun/docs/bonding-curve), and
[Hop.fun](https://docs.hop.fun/). These sources are context for presets and
disclosure. They are not copied contract policy.

## Context

Blast core already returns one witness-bound terminal payload containing the
real Meme provision and net Quote balance. Bluefin, MMT, Cetus, Turbos, and
Full Sail use concentrated-liquidity pools. In these pools the initial square-root price is an
explicit creation input; supplying two balances does not determine the price.

The implementation must prevent four failures:

1. reversing the pair and initializing the reciprocal price;
2. applying display-decimal scaling to an atomic-unit pool price;
3. seeding a pre-existing pool whose current price is hostile; and
4. making a locked position transferable or allowing fee collection to reduce
   principal.

## Decision

### Package boundary

All five venues are modules in one independently deployed package below
`sui/migrators/`. Each venue module owns one sealed `Witness() has drop`, its
venue-specific pool creation or adoption calls, and a sealed venue marker. The
package owns one shared vault implementation. Each venue module calls guarded
`launch::migrate` and witness-gated `launch::redeem_migration` in one Move call.
Core imports no venue package.

This is one shared vault *type*, not one global vault object. Every migrated
launch creates its own `LpVault<Meme, Quote>` so unrelated fee collection does
not contend on one shared Sui object. The aggregate package accepts the cost of
an all-venues dependency and release gate in exchange for one custody and claim
surface.

The two packages expose only the venue-neutral primitives needed synchronously
by adapters:

- the migrators package owns exact seed-price, price-deviation, utilization,
  and residual arithmetic; and
- the core package exposes the existing dual-asset fee ledger through a
  live-share accrual seam.

These primitives authorize or conserve assets during an adapter transition and
therefore meet the consensus-minimal rule. Forecast valuations remain in the
SDK.

### Canonical seed price

Let `M` be the real Meme atomic units and `Q` the net Quote atomic units released
by the core payload. Both must be positive. Every adapter derives the target
price from these balances; there is no caller-supplied price and no oracle.

CLMM square-root price represents atomic `coin_b / coin_a` in Q64.64:

```text
if Meme is coin A: ratio_q128 = floor((Q << 128) / M)
if Meme is coin B: ratio_q128 = floor((M << 128) / Q)

sqrt_price_x64 = floor(sqrt(ratio_q128))
```

The calculation uses `u256`. A bounded integer square root returns the greatest
`s` for which `s * s <= ratio_q128`. Meme and Quote display decimals never enter
this calculation. A UI converts the atomic ratio to a human ratio afterward.

For a new pool, the derived `sqrt_price_x64` is the exact initialization input.
The adapter checks the venue's inclusive or exclusive price limits before the
external call. For an adopted Cetus, Turbos, or Full Sail pool, the current squared price
must be within 50 basis points of the exact rational target:

```text
abs(current_sqrt^2 - ratio_q128) * 10_000
    <= ratio_q128 * 50
```

The check runs immediately before adding liquidity in the same atomic
transaction. Bluefin and MMT create new pools and do not adopt an arbitrary
existing pool.

### Full-range principal and utilization

Each adapter derives full-range tick bounds through the venue's pinned tick
helpers and aligns both bounds to the selected tick spacing. It does not accept
caller-selected ticks.

The source payload amounts define the opening valuation. Venue rounding may
return residuals, but a successful new-pool migration must consume at least
99.99% of each nonzero source balance. An adopted pool uses the same minimum.
The adapter checks returned residuals or supplies equivalent venue minimums.
Failure aborts the complete Sui transaction and leaves the launch migration
right unconsumed.

### Permanent `LpVault`

Every successful route creates and shares one
`LpVault<Meme, Quote>` containing:

- the venue pool id; and
- one core `FeeLedger<Meme, Quote>` for collected LP fees.

The venue position or position NFT is attached to the vault UID as exactly one
dynamic **object** field keyed by a sealed venue marker. All supported position
types have `key + store`; `dynamic_object_field` preserves the child object and
its identity. The vault module exposes package-only typed borrow operations for
fee collection, but exposes no remove operation.

The vault does not duplicate migration amounts or the derived opening square
root. The core `Migrated` event already commits the Meme and Quote amounts, and
the opening square root is deterministically reconstructed from those primitive
facts plus the venue orientation. This keeps derived convenience state out of
the contract.

No public or package-visible function returns the position, transfers it,
closes it, burns it, decreases liquidity, or calls a venue principal-removal
function. Source-boundary checks reject those calls. The only mutable position
operation exposed by the adapter is fee collection.

That source boundary is not permanent while the migrators package remains
upgradeable: a compatible upgrade could add a new extraction function. Each
production package must therefore pass every venue's published-package ABI and
dev-inspect checks and then destroy its single `UpgradeCap`. No deployment may be
described as permanently locked before this irreversible immutability step.

Fee collection reads venue liquidity immediately before and after the external
collection call and aborts unless they are equal. The completed event records
only the verified final principal value. New Meme and Quote fees are split
using the current global `protocol_fee_share_bps`. Protocol
amounts round up and creator amounts receive the exact remainder, matching
bonding-curve trade fees. Later changes affect only later collections; already
accrued ownership never changes.

The independently deployed migrators package emits its replay-complete venue
events as direct, strongly typed Sui events. It does not wrap them in the core
package's generic event envelope. This preserves native payload filtering and
does not change the core package's event ABI.

The vault exposes separate composable claims:

- `CreatorCap<Meme>` drains only creator Meme and Quote fees;
- `AdminWitness` drains protocol Meme and Quote fees plus migration residuals.

Neither claim calls the venue or touches the position.

### Protocol residual custody

After venue liquidity creation, every returned Meme or Quote residual stays in
the per-launch `LpVault` as protocol-owned custody. The existing
`AdminWitness`-gated protocol claim drains those balances together with accrued
protocol LP fees. No adapter stores a payout address, burns a nonzero residual,
or sends migration residuals to `0x0`. The launch's earlier Fixed/BurnOnly
terminal-disposal policy remains unchanged and separate.

### Venue routes

| Venue | New pool | Existing pool | Position custody | Special guard |
| --- | --- | --- | --- | --- |
| Bluefin | `pool::create_pool_with_liquidity` | never adopted; a new pool is created | `bluefin_spot::position::Position` | Meme is always coin A and Quote is always coin B; `config::get_pool_creation_fee_amount<Quote>` must report supported and exactly zero; the adapter supplies a zero Quote balance |
| MMT | `create_pool::new`, `pool::initialize`, add liquidity, then `pool::transfer` | never adopted | `mmt_v3::position::Position` | `create_pool::check_coin_order` must agree with the selected entry function |
| Cetus | `pool_creator::create_pool_v3` for an unpermissioned pair | accepted only through the explicit adoption entry and 50-bps check | `cetus_clmm::position::Position` | canonical pair ordering and `pool_creator::full_range_tick_range` are mandatory; permission-pair creation needs its separate creation-cap path and is not guessed |
| Turbos | `pool_factory::deploy_pool_and_mint_with_return_` | accepted only through the explicit adoption entry and 50-bps check | `turbos_clmm::position_nft::TurbosPositionNFT` | exact fee-object type, registry pair ordering, deadline, and `math_tick` full-range bounds are mandatory |
| Full Sail | `factory::create_pool_with_liquidity` | accepted only through an explicit adoption entry and 50-bps check | `clmm_pool::position::Position` | canonical order, revision-4 ABI, full-range tick bounds, and the live config/rewarder objects are mandatory |

Bluefin has one deterministic `Pool<Meme, Quote>` route because it creates the
pool and its pinned bytecode imposes no pair sorter. Other venues get two typed
entry functions only when a mandatory venue sorter or an existing pool can put
Meme in either generic slot. Each such function verifies the venue's canonical
or existing order before redeeming the payload. A caller never chooses an
economic price orientation: Meme remains the base asset and all fee output is
normalized to `(Meme, Quote)`.

### Dependency and release gate

All direct and overridden transitive Git dependencies use the full commits in
the source table. Cetus's reviewed source manifest has no `published-at`, so a
minimal local interface preserves its original type address while linking the
adapter to mainnet revision 14 at
`0x25ebb9a7c50eb17b3fa9c5a30fb8b5ad8f97caaf4928943acbcff7153dfee5e3`
(digest `FEdn2yRh28atu7tANr6gCWQ3gtDSD2EZmyEeryTuokoi`). Bluefin, Cetus,
Turbos, and Full Sail interface bodies contain local `abort 0`
link stubs; adapters may ship only after a mainnet dry run proves that the
published package ids resolve those calls. Full Sail also has a GraphQL lineage
and normalized-ABI gate against the latest mainnet bytecode. Turbos' upstream mutable `testnet`
framework pin is overridden by `sui@06734f6`.

Local tests cover core math, runtime treasury, fee ownership, structural absence
of dynamic-field removal or principal withdrawal, and the aggregate package build. Mainnet publication remains
blocked until package-id verification and dev-inspect fixtures pass for all
venue routes. After those checks, the aggregate package's single `UpgradeCap`
is destroyed and the resulting immutable-package evidence is recorded.

## Migration valuation and launchpad comparison

Blast names three different Quote-denominated valuations:

```text
opening curve valuation = floor(S * V / C)
terminal curve valuation = floor(S * (V + T) / R)
DEX opening valuation = floor(S * net_quote / pool_meme_provision)
```

The DEX value is the authoritative migrated value because it is backed by the
two assets actually sent to the venue. Memez's current Bluefin migrator likewise
derives its V3 initialization price from the balances being added. Raydium can
make its curve-to-CPMM handoff mechanically seamless because its remaining
effective reserves become the pool reserves. Blast cannot transfer virtual
Quote, so it must not present virtual value as DEX principal.

Blast can still choose a continuity-preserving preset. With the fixed one-billion
Meme supply, zero terminal fees, 20% Meme LP provision, and `V = T`, the curve
sells 40% of supply and both terminal valuations equal `5 * T`.

The recommended SUI production lane is therefore:

```text
virtual_quote = 8_000 SUI
migration_quote_target = 8_000 SUI
protocol_quote_migration_fee_bps = 0
protocol_meme_graduation_fee_bps = 0
meme_liquidity_provision_bps = 2_000

opening curve valuation = 10_000 SUI
terminal curve valuation = 40_000 SUI
DEX opening valuation = 40_000 SUI
curve-released supply = 40%
locked LP Meme supply = 20%
```

With zero protocol Quote migration fee, the lane makes up to 8,000 SUI of Quote-side
pool principal available before venue rounding and residuals. The comparison is
operational guidance, not an oracle rule. The admin must review the
Quote-denominated preset before enabling a production Quote lane, and the UI
must show native-Quote values without promising a stable USD threshold.

## Consequences

- The opening price cannot be substituted by an SDK or migration caller.
- Pair reversal and decimal scaling become testable integer invariants.
- The locked position remains economically useful through creator and protocol
  fee claims without exposing principal.
- A live treasury can receive small venue residuals without changing launch
  economics or adding an adapter-owned administrator.
- Exact curve-to-DEX continuity is available through the recommended zero-terminal-fee
  preset, but arbitrary future launch parameters continue to disclose distinct
  terminal values.
- Five external venues expand release work and require on-chain integration
  evidence beyond local unit tests.

## Verification

- Core price vectors cover both token orders, exact and inexact square roots,
  one-unit and `u64::MAX` balances, zero rejection, and 50-bps boundaries.
- Runtime tests cover initial treasury, zero and unchanged rejection, admin
  authorization, package-version precedence, and change events.
- Fee-ledger tests prove prospective live-share changes and creator/protocol
  claim isolation for externally accrued LP fees.
- The aggregate package builds against exact compatible pins and has a
  source-boundary check that rejects dynamic-field removal, principal-removal,
  and position-transfer calls.
- The production migrators package records destruction of its single
  `UpgradeCap` after all five venue routes pass the mainnet checks.
- `node docs/vectors/check-graduation-vector.mjs` reads the migration vector and
  proves the recommended SUI lane has equal 40,000-SUI terminal curve and DEX
  valuations.
- Mainnet GraphQL checks prove each original package resolves to the recorded
  latest revision and that its bytecode-backed normalized ABI matches the
  adapter. Mainnet dev-inspect tests prove zero Bluefin
  creation fee, deterministic Meme-A/Quote-B ordering, tick bounds, residual tolerance, and
  fee-collection principal equality.
