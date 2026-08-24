# 0023: Generated coin supply and metadata custody

- Status: accepted
- Date: 2026-08-23
- Amends: [0002](0002-coin-creation-and-currency-authority.md), [0003](0003-treasury-cap-lifetime-and-burn.md), [0006](0006-fees-and-launch-paths.md), [0007](0007-acl-pause-and-versioning.md), [0013](0013-creator-fee-authority-and-x-claims.md), [0014](0014-typed-creator-cap-and-diagnostic-modules.md), [0018](0018-authority-module-separation.md), [0019](0019-consuming-creator-authority-and-cap-return.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui |

## Context

Blast creates a new meme coin for every launch. The generated coin does not need deny-list authority,
legacy metadata migration, or a mint capability that survives initialization. Supporting those paths would
add state and authority that the product does not want.

The coin owner does need two supply choices with materially different semantics:

- a fixed coin, whose supply can neither increase nor decrease; or
- a burnable coin, whose supply can decrease but can never increase.

Sui Coin Registry represents those choices as `SupplyState::Fixed` and `SupplyState::BurnOnly`.
`make_supply_fixed` and `make_supply_burn_only` each consume the unique `TreasuryCap`, making the
loss of mint authority irreversible
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:293-317`).

The Coin Registry separately returns a native `MetadataCap<Meme>`. Blast must
custody it until the authenticated one-time creator claim, but it is a different
concern from creator fee authority. Once claimed, its holder should call the
Coin Registry metadata API directly without a Blast wrapper or proxy.

## Decision

### Current unregulated Coin Registry path only

Every generated meme package uses `coin_registry::new_currency_with_otw` and does not call
`make_regulated`. Blast does not implement a legacy `CoinMetadata` migration path and never creates or
accepts a `DenyCap` for a generated meme
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:204-237,263-278`).

The owner selects the mode while generating the one-launch coin package, and the
generated package records that immutable selection in its Blast launch ticket.
Its OTW `init` creates the currency with zero supply and places the empty
`TreasuryCap<Meme>` and unique `MetadataCap<Meme>` in that ticket. It does not
mint inside `init`.

After the permissionless `coin_registry::finalize_registration<Meme>` transaction
promotes `Currency<Meme>` to its shared address, launch validates the ticket and
currency, mints the complete initial supply exactly once, and consumes the
treasury capability through exactly one owner-selected transition:

- `Currency<Meme>.make_supply_fixed(treasury_cap)` for a non-burnable coin; or
- `Currency<Meme>.make_supply_burn_only(treasury_cap)` for a burnable coin.

The `TreasuryCap<Meme>` enters Blast only as the empty, linear launch-ticket
resource needed to mint and finalize supply. It does not survive launch state,
enter a migration adapter, or support any public or package mint path afterward.

### One-billion whole-coin ceiling

The initial supply is nonzero and no greater than **1,000,000,000 whole coins**.
Core validates the requested atomic-unit amount against:

```text
1_000_000_000 * 10^meme_decimals
```

The comparison uses widened arithmetic or an equivalent overflow-proof bound.
Before minting, launch proves that the treasury cap's total supply is zero. After
minting, the complete new inventory enters launch and the registry's total supply
must equal that inventory; no minted balance may remain outside launch intake.

### Burn mode is the registry state

The launch reads the owner-selected mode from the ticket, consumes the treasury
cap into the matching `Fixed` or `BurnOnly` registry transition, and records the
result. It does not accept a second caller-supplied mode that could disagree with
the generated package's committed selection.

- A `Fixed` launch must have `max_burn_bps == 0`. Sell-side and terminal burns are unreachable.
- A `BurnOnly` launch may configure the separately bounded sell-side burn policy. Burns execute through
  the shared `Currency<Meme>`; minting remains impossible.

For a fixed launch, every terminal meme unit must be deployed to the selected venue or returned through
an explicitly accounted residual path. For a burnable launch, terminal residual inventory may instead be
burned and evented. Neither mode permits silent balance disposal.

### Metadata capability is returned separately

`CurrencyInitializer<Meme>.finalize` returns the unique `MetadataCap<Meme>`
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:319-344`).
That capability moves through the Blast launch intake and remains inside launch
state while `CreatorAuthority<Meme>` is unclaimed.

The successful one-time creator claim consumes both the creator authority and
the stored metadata capability, then returns two independent objects:

```move
(CreatorCap<Meme>, MetadataCap<Meme>)
```

`CreatorCap<Meme>` authorizes creator economics only. `MetadataCap<Meme>` remains
the native Coin Registry capability, so its holder can call native metadata
setters, transfer it, freeze it, or delete it according to the framework API.
Blast exposes no metadata extraction method and no proxy setters because it does
not wrap the capability. Metadata-cap custody changes never consume or invalidate
creator fee authority, and migration cannot seize either creator-owned object.

### Quote policy remains separate

This decision governs the newly generated `Meme` currency. It does not justify a generic quote-risk
snapshot module or add regulated/legacy quote support. The initial quote-asset admission rule must be
approved with the launch-state slice before `Launch<Meme, Quote>` is committed.

## Alternatives considered

**Retain `TreasuryCap` during bonding.** Rejected: the owner selected final supply semantics at coin
creation, and carrying mint authority through the protocol adds a larger capability surface solely to
support an older reservation design.

**Always use `Fixed`.** Rejected: the owner is allowed to choose a deflationary coin whose supply can
decrease while minting remains permanently disabled.

**Always use `BurnOnly`.** Rejected: some owners want a truly fixed supply with no protocol or
third-party burn path.

**Wrap `MetadataCap` inside `CreatorCap`.** Rejected: it couples unrelated
authorities and forces Blast-specific metadata proxy methods and UI. The native
capability is already the correct authorization object.

**Keep `MetadataCap` in the shared launch forever.** Rejected: authenticated
claim should deliver the creator's native authority, not force every future
metadata update through shared Blast state.

## Consequences

- Every generated coin is current-registry and unregulated. Its treasury cap is
  empty at ticket creation, then irreversibly consumed during launch so no mint
  authority survives in Blast state.
- Fixed and burnable launches have different reachable burn transitions, enforced from the registry
  state rather than a caller assertion.
- Migration adapters must not receive or require meme mint authority.
- `CreatorCap<Meme>` remains the transferable creator-economic authority;
  `MetadataCap<Meme>` remains the separate native metadata authority.
- A creator may claim before or after migration; unclaimed metadata authority remains in launch state.
- Quote admission remains an explicit gate for the next launch-state decision.

## Verification

- Current Coin Registry creation tests cover the zero-supply ticket and both
  launch-time supply transitions, proving no `TreasuryCap` remains after either
  one.
- Launch intake accepts exact supplies of one atomic unit and one billion whole coins, and rejects zero,
  one atomic unit above the normalized ceiling, partial inventory, regulated currencies, legacy-migrated
  currencies, and `Unknown` supply state.
- A fixed launch rejects every nonzero burn parameter before constructing launch state.
- A burnable launch executes a sell burn through `Currency<Meme>` and decreases registry total supply.
- Structural checks reject a surviving `TreasuryCap`, every `DenyCap`, and legacy
  migration calls from launch state, adapters, and generated production templates.
- Creator-claim tests prove the function returns `CreatorCap<Meme>` and
  `MetadataCap<Meme>` separately and that callers can route the two objects to
  different recipients. Fee tests prove creator claims depend only on the
  creator cap.
- Build, strict lint, full tests, Move coverage, and structural source checks remain release gates.
