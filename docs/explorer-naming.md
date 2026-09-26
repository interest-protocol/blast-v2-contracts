# Explorer-visible type names

Explorers, wallets, and indexers show every object, coin, event, and
capability as `0xADDRESS::module::Struct<…>`. The `name` in `Move.toml` never
appears on chain, and a hex address identifies nothing to a person. The rule
decided in [ADR 0085](decisions/0085-explorer-visible-type-naming.md) is that
every type a user or auditor can see must say it belongs to Blast without the
address. This page is the survey that rule was applied to and the record of
what each type reads as now. Source is authoritative; regenerate this table
when a visible type is added or renamed.

"Identified by" names the component of the type string that carries the Blast
identity: the module, the struct, or a type parameter that is itself a Blast
type. A row marked *residual* still shows no Blast name of its own and is
identified only through its package marker; ADR 0085 records why.

## Package markers and domain witnesses

| Package | Role | Before | After |
| --- | --- | --- | --- |
| `blast_sui` | Publisher marker | `blast::BLAST` | `blast_sui_package::BLAST_SUI_PACKAGE` |
| `blast_sui` | administration domain | `blast_sui_domain::BLAST_SUI_DOMAIN` | unchanged |
| `blast_fun` (launchpad) | Publisher marker | `blast::BLAST` | `blast_fun::BLAST_FUN` |
| `blast_fun` | administration domain, shared with migrators | `launchpad_domain::LAUNCHPAD_DOMAIN` | `blast_fun_domain::BLAST_FUN_DOMAIN` |
| `blast_fun_migrators` | Publisher marker | `package_marker::PACKAGE_MARKER` | `blast_fun_migrators::BLAST_FUN_MIGRATORS` |
| `blast_boosts_aftermath` | Publisher marker | `aftermath::AFTERMATH` | `blast_boosts_aftermath::BLAST_BOOSTS_AFTERMATH` |
| `blast_boosts_core` | administration domain and only OTW; no Publisher is claimed | `series_one_domain::SERIES_ONE_DOMAIN` | `blast_boosts_core::BLAST_BOOSTS_CORE` |
| `blast_boosts_products` | Publisher marker (new package) | — | `blast_boosts_products::BLAST_BOOSTS_PRODUCTS` |
| `blast_admin` | none: library package with no `init` | — | — |
| `meme_template` | generated package one-time witness | `meme::MEME` | unchanged name; the generated package's one-time witness, renamed per launch by the SDK template |

The Publisher object shows `module_name` of the claiming module, and
`PackageAdmin`/`PackageVersion` show `UpgradeCustody<Marker>` and
`OperationalVersion<Marker>`, so the marker name is what an auditor reads on
every package-administration object.

## Coin types

| Package | Coin `T` before | After | Identified by |
| --- | --- | --- | --- |
| `blast_sui` | `blast_sui::BLAST_SUI` | unchanged | module and struct |
| `blast_sui` | `fun_sui::FUN_SUI` | unchanged | ticker `funSUI`, the blast.fun quote coin |
| `blast_boosts_aftermath` | `vault::Vault<Product>` | `blast_boost::BlastBoost<Product>` | module and struct; `Product` is a `blast_boosts_products` tag |
| `meme_template` | `meme::MEME` | unchanged | module and struct; the generated package one-time witness |

## Key objects

| Package | Type | After | Identified by |
| --- | --- | --- | --- |
| `blast_admin` | `acl::Authority<Domain>` | unchanged | `Domain` is a Blast domain witness |
| `blast_admin` | `acl::SuperAdminCap<Domain>` | unchanged | `Domain` |
| `blast_admin` | `acl::AdminCap<Domain>` | unchanged | `Domain` |
| `blast_sui` | `vault::Vault` | unchanged | *residual*; package marker |
| `blast_sui` | `deposit_receipt::BlastSuiDepositReceipt` | unchanged | struct |
| `blast_sui` | `package_admin::PackageAdmin` | unchanged | holds `UpgradeCustody<BLAST_SUI_PACKAGE>` |
| `blast_sui` | `package_version::PackageVersion` | unchanged | holds `OperationalVersion<BLAST_SUI_PACKAGE>` |
| `blast_fun` | `launch::Launch<Meme, Quote>` | unchanged | *residual*; `Quote` is usually `fun_sui::FUN_SUI` |
| `blast_fun` | `launch_config::LaunchConfig` | unchanged | *residual* |
| `blast_fun` | `runtime_config::RuntimeConfig` | unchanged | *residual* |
| `blast_fun` | `launch_ticket::LaunchTicket<Meme>` | unchanged | *residual*, wallet-held |
| `blast_fun` | `creator_authority::CurveFeeCap<Meme>` | unchanged | *residual*, wallet-held |
| `blast_fun` | `creator_authority::BlastMetadataCap<Meme>` | unchanged | struct |
| `blast_fun` | `launch::BlastPresaleBid` | new; owned by its launch's address until delivery | struct |
| `blast_fun` | `package_admin::PackageAdmin` | unchanged | holds `UpgradeCustody<BLAST_FUN>` |
| `blast_fun` | `package_version::PackageVersion` | unchanged | holds `OperationalVersion<BLAST_FUN>` |
| `blast_fun_migrators` | `vault::LpVault<Meme, Quote>` | unchanged | *residual* |
| `blast_fun_migrators` | `venue_config::VenueConfig` | unchanged | *residual* |
| `blast_fun_migrators` | `package_admin::PackageAdmin` | unchanged | holds `UpgradeCustody<BLAST_FUN_MIGRATORS>` |
| `blast_fun_migrators` | `package_version::PackageVersion` | unchanged | holds `OperationalVersion<BLAST_FUN_MIGRATORS>` |
| `blast_fun_migrators` | `lp_fee_policy::LpFeePolicy` | unchanged | *residual* |
| `blast_fun_migrators` | `blast_holder_rewards::Round<Meme, Quote>` | new | module |
| `blast_boosts_aftermath` | `vault::Vault<Product>` (shared custody) | unchanged | `Product` is a `blast_boosts_products` tag |
| `blast_boosts_aftermath` | `protocol::Protocol` | unchanged | holds `OperationalVersion<BLAST_BOOSTS_AFTERMATH>` |
| `blast_boosts_aftermath` | `package_admin::PackageAdmin` | unchanged | holds `UpgradeCustody<BLAST_BOOSTS_AFTERMATH>` |
| `blast_boosts_aftermath` | `blast_boost::BlastBoost<Product>` | new; never instantiated | module and struct |

`blast_boosts_core` defines no `key` type; its `State<Product>` is a
`store` value nested in the adapter Vault.

## Event types

| Package | Outermost event type before | After | Identified by |
| --- | --- | --- | --- |
| `blast_sui` | `events_wrapper::Event<events::X>` | `blast_events::Event<events::X>` | envelope module |
| `blast_fun` | `events_wrapper::Event<events::X>` | `blast_events::Event<events::X>` | envelope module |
| `blast_boosts_aftermath` | `events_wrapper::Event<events::X<Product>>` | `blast_events::Event<events::X<Product>>` | envelope module and `Product` |
| `blast_fun_migrators` | `events::X` (direct emission) | `blast_events::X` | module |
| `blast_admin` | `events::X<Domain>` | unchanged | `Domain` or `PackageMarker` is a Blast witness |

Payload struct names inside the envelopes (`Bought`, `Migrated`,
`VaultSynced`, `Minted<Product>`, …) are unchanged.

## Phantom tags and dynamic-field keys

| Package | Type | After | Note |
| --- | --- | --- | --- |
| `blast_admin` | `Domain` parameter of every ACL type | — | always a Blast domain witness above |
| `blast_admin` | `PackageMarker` parameter of `OperationalVersion` and `UpgradeCustody` | — | always a Blast marker above |
| `blast_sui` | `vault::TreasuryKey<CoinType>`, `package_admin::CapabilityKey<Capability>` | unchanged | dynamic-field keys under `Vault` and `PackageAdmin` |
| `blast_fun_migrators` | `cetus::Venue`, `bluefin::Venue` | unchanged | sealed venue witnesses used as `PositionKey<Venue>` and `TierKey<Venue>` keys inside Blast objects; the module names the venue the migrator targets |
| `blast_fun_migrators` | `cetus::Witness`, `bluefin::Witness` | unchanged | the only migration witnesses; appear as `TypeName` values in `LaunchConfig` and events |
| `blast_fun_migrators` | `cetus::CreationCapKey<Meme>` | unchanged | dynamic-object-field key under `VenueConfig` for the Meme type's Cetus `PoolCreationCap`; the cap keeps its own object ID |
| `blast_fun_migrators` | `cetus::ReservationKey<Meme, Quote>` | unchanged | dynamic-field key under `VenueConfig` naming one reserved Meme/Quote pair; the value is its reserved tick spacing |
| `blast_boosts_aftermath` | `vault::TreasuryKey<Product>`, `vault::MetadataKey<Product>`, `vault::AdminCashKey`, `vault::TerminalCashKey` | unchanged | dynamic-field keys under `Vault` |
| `blast_boosts_products` | `<TICKER>_<SIDE>_<LEVERAGE>` tags such as `NVDA_BULL_2X` | bull and bear 2X per Aftermath market | inner type of every Boost coin |

## Parked packages

`scratch-sui/dex` and `scratch-sui/auto_lp` are on hold outside every build
and gate. Their references to the launchpad domain follow the rename
(`BLAST_FUN_DOMAIN`); their own markers (`package_marker::PACKAGE_MARKER`,
`dex_domain::DEX_DOMAIN`) and modules (`pool`, `migration`, `vault`) are
renamed when they return to `sui/`.
