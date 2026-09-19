# 0085: Explorer-visible type naming

- Status: accepted
- Date: 2026-09-16
- Amends: [0001](0001-sui-package-and-module-layout.md),
  [0031](0031-package-witness-and-publisher-custody.md)
- Names: the leveraged-coin packages are **Blast Boosts** on chain, the same
  word the app and deck use; "leverage" stays the descriptive term in prose.

## Context

Explorers, wallets, and indexers identify every object, coin, event, and
capability by its fully qualified type, `0xADDRESS::module::Struct<…>`. The
package `name` in `Move.toml` never appears on chain, and a hex address means
nothing to a person. The module name, the struct name, and the type arguments
are therefore the only human-readable identity a Blast type has, and they are
as permanent as the package.

Before this decision several Blast types read as generic or as someone else's.
The Aftermath leverage adapter claimed its Publisher from
`aftermath::AFTERMATH`, so its package-administration objects and Publisher
named Aftermath, not Blast. Its share currency was
`vault::Vault<…>`, which says nothing about leverage or Blast in a wallet.
The launchpad's marker was `blast::BLAST` while Blast SUI's coin was
`blast_sui::BLAST_SUI`; migrators used `package_marker::PACKAGE_MARKER`; the
distributor and vesting objects were `distributor::Distributor`,
`linear::Vesting`, and `checkpoints::Vesting`; and every wrapped event was
`events_wrapper::Event<events::…>`.

No package is published (confirmed 2026-09-16), so the renames cost no
compatibility. Once a package is published its module and struct names are
fixed forever, which is why this is decided now and recorded as an ADR.

## Decision

**Rule.** Every type a user or auditor can see on an explorer identifies
Blast by name, without relying on the address. A type satisfies the rule when
its module name, its struct name, or a type argument that is itself a Blast
type carries the identity.

**Package marker.** Every package that claims a Publisher claims it from the
module named after the package, with the one-time witness in upper snake
case: `blast_fun::BLAST_FUN`, `blast_fun_migrators::BLAST_FUN_MIGRATORS`,
`blast_boosts_aftermath::BLAST_BOOSTS_AFTERMATH`,
`blast_boosts_products::BLAST_BOOSTS_PRODUCTS`. A marker module is never
named after a venue or dependency. When the package's namesake module is its
coin, the marker is `<package>_package::<PACKAGE>_PACKAGE`; Blast SUI's marker
is `blast_sui_package::BLAST_SUI_PACKAGE` because `blast_sui::BLAST_SUI` is
the coin and a one-time witness cannot both register a currency and claim a
Publisher.

**Administration domain.** A domain witness for `blast_admin::acl` is
`<package>_domain::<PACKAGE>_DOMAIN`: `blast_sui_domain::BLAST_SUI_DOMAIN`,
`blast_fun_domain::BLAST_FUN_DOMAIN`. It stays separate from the Publisher
marker because `acl::new` consumes the witness. A package whose only one-time
witness is its domain names it after the package, so the Boosts core (Series1)
domain is `blast_boosts_core::BLAST_BOOSTS_CORE`. Where a module's name
equals its package's address name, importers that need `Self` alias it
(`Self as domain`, `Self as marker`) so package-qualified macro and
`location =` paths keep resolving to the address.

**Coins.** The `T` in `Coin<T>` is what a holder reads, so its module and
struct name the product. Blast SUI keeps `blast_sui::BLAST_SUI` and
`fun_sui::FUN_SUI`, the tickers `blastSUI` and `funSUI`. A leverage currency
is never a shared object's type: the Aftermath adapter registers each currency
on `blast_boost::BlastBoost<phantom Product> has key { id: UID }`, a
marker no value of which is ever constructed, and only that module calls
`coin_registry::new_currency`. `vault::Vault<Product>` remains the shared
custody object. Product tags are declared in the Blast-owned
`blast_boosts_products` package, one empty `drop` struct per product named
`<TICKER>_<SIDE>_<LEVERAGE>` in its namesake module, so the inner type reads
`…::blast_boosts_products::NVDA_BULL_2X`; `BEAR` names the inverse product.
A bull and bear 2X tag exist for every Aftermath perpetual market; a tag is
not a live product until an adapter issues its currency. Adding one is a
compatible upgrade of that package.

**Single-module and product-named modules.** A package whose visible types
live in one module names that module after the package:
`blast_fun_distributor::Distributor`. A package with several user-held object
modules names each after its product: `blast_fun_linear_vesting::Vesting`,
`blast_fun_checkpoint_vesting::Vesting`.

**Events.** The module that names the outermost emitted type is
`blast_events`. In packages that wrap payloads, the envelope module is
`blast_events` and payloads stay in `events`
(`blast_events::Event<events::Bought>`); in migrators, which emits directly,
the payload module is `blast_events`. Distributor and vesting events already
live in their renamed modules.

**Internal modules.** `vault`, `state`, `policy`, `operations`, `launch`,
`acl`, and the other modules that own shared singletons or nested values keep
short names. Their types are reached from a package whose Publisher,
`PackageAdmin`, and `PackageVersion` carry the Blast marker, and a `Domain`,
`PackageMarker`, or `Product` type argument carries the identity where one is
present. The residual types that show no Blast name of their own are listed in
[explorer-naming.md](../explorer-naming.md); the wallet-held ones
(`LaunchTicket`, `CurveFeeCap`, `LpFeeCap`) are the candidates if the rule is
later tightened to struct names.

**Test and generated types.** Test-only witnesses and fixtures are exempt.
`meme_template::meme::MEME` is the creator's coin; the SDK renames it per
launch and it must not read as Blast.

## Alternatives considered

- **Keep `vault::Vault<P>` as the currency and rename the vault.** Rejected:
  the shared object and the coin are different things a holder sees in
  different places; giving the coin its own marker names both correctly and
  costs one never-instantiated struct.
- **Merge the domain witness into the Publisher marker.** Rejected where a
  Publisher is claimed: both consume the witness. Applied where no Publisher
  exists (Series1).
- **Rename the envelope struct to `BlastEvent<T>` instead of its module.**
  Rejected: a module rename covers wrapped and direct emitters with one rule
  and leaves the `Event` name every consumer already parses.
- **Prefix every struct with `Blast`.** Rejected for now: it would rename
  `Launch`, `Vault`, and every capability across the SDK for little gain when
  the package marker already identifies the package; the wallet-held caps are
  recorded as the follow-up candidates.
- **Keep `aftermath::AFTERMATH` because the address is Blast's.** Rejected: the
  rule is precisely that the address is not identity.

## Consequences

- Every Publisher, `PackageAdmin`, `PackageVersion`, `Authority<Domain>`,
  `AdminCap<Domain>`, coin, distributor, vesting, and event type now names
  Blast in its type string.
- SDK, indexer, and script type strings for `events_wrapper`, `distributor`,
  `linear`, `checkpoints`, and the Boost currency change; the frozen SDK
  ABI artifacts are regenerated under this ADR's approval line.
- The adapter's `operations.move` hash pinned by the activation fixture is
  re-pinned; its dev-inspect fixtures carry the new event and currency
  strings.
- `blast_boosts_products` is a new, initially empty package with its own
  Publisher; product issuance gains no authority from it.
- Historical ADRs and research keep the names they were written with.

## Verification

- `sui move test` passes in every package under `sui/`, including the new
  `blast_boosts_products`, and every package boundary script accepts the
  renamed modules and file names.
- The adapter boundary script requires the currency to be registered on
  `BlastBoost<Product>` from `blast_boost.move` and rejects any
  construction of the marker.
- The adapter script self-tests and PTB tests pass with the re-pinned
  operations hash and the renamed event and currency strings.
- A repository grep for the retired names (`events_wrapper`,
  `launchpad_domain`, `LAUNCHPAD_DOMAIN`, `package_marker::PACKAGE_MARKER`,
  `series_one_domain`, `SERIES_ONE_DOMAIN`, `aftermath::AFTERMATH`,
  `blast_leverage`, `BlastLeverage`, `leverage_coins`,
  `blast::BLAST`, `::distributor::`, `::linear::`, `::checkpoints::`,
  `Coin<Vault<`) finds no live hit outside historical decisions and research.
- SDK typecheck, tests, and the regenerated ABI check pass; indexer tests
  pass.
