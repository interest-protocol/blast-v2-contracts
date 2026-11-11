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
identified only through its package one-time witness (OTW); ADR 0085 records why.

## Package one-time witnesses and domain witnesses

| Package | Role | Before | After |
| --- | --- | --- | --- |
| `blast_sui` | Publisher one-time witness | `blast::BLAST` | `blast_sui_package::BLAST_SUI_PACKAGE` |
| `blast_sui` | administration roles (ADR 0097) | `blast_sui_domain::BLAST_SUI_DOMAIN` | `blast_sui_domain::FeeAdmin`, `CancelAdmin`, `ValidatorAdmin` |
| `blast_fun` (launchpad) | Publisher one-time witness | `blast::BLAST` | `blast_fun::BLAST_FUN` |
| `blast_fun` | administration roles (ADR 0137) | `blast_fun_domain::BLAST_FUN_DOMAIN` | none of its own: product roles from `blast_core::blast_domain`; package roles `blast_admin::package_admin::UpgradeAdmin`, `PauseAdmin`, `UnpauseAdmin`, `CancelAdmin`, each typed `<BLAST_FUN>` |
| `blast_fun` | package witness (ADR 0137) | — | `blast_fun::PackageWitness` |
| `blast_migrators` | Publisher one-time witness | `package_marker::PACKAGE_MARKER` | `blast_migrators::BLAST_MIGRATORS` |
| `blast_migrators` | package witness (ADR 0137) | — | `blast_migrators::PackageWitness` |
| `blast_core` | shared product roles (ADR 0137), taken by both products, the vault, the venues' buybacks, and the core treasury; no one-time witness or Publisher | — | `blast_domain::TreasuryAdmin`, `FeeAdmin`, `ListingAdmin`, `VenueAdmin`, `RewardsAdmin`, `BuybackAdmin`, `CreatorAdmin`, `ClaimSignerAdmin`, `CancelAdmin` |
| `blast_vault` | Publisher one-time witness (ADR 0137) | — | `blast_vault_package::BLAST_VAULT_PACKAGE` |
| `blast_vault` | package witness (ADR 0137) | — | `blast_vault_package::PackageWitness` |
| `blast_boosts_aftermath` | Publisher one-time witness | `aftermath::AFTERMATH` | `blast_boosts_aftermath::BLAST_BOOSTS_AFTERMATH` |
| `blast_boosts_core` | administration roles shared with the adapter; no one-time witness or Publisher (ADR 0097) | `blast_boosts_core::BLAST_BOOSTS_CORE` | `blast_boosts_core::VaultIssuer`, `RiskAdmin`, `ShutdownAdmin`, `UpgradeAdmin` |
| `blast_partners` | administration role (ADR 0097); no one-time witness or Publisher | `blast_partners::BLAST_PARTNERS` (ADR 0095) | `blast_partners::PartnerAdmin` |
| `blast_presale` | Publisher one-time witness (ADR 0137) | — | `blast_presale_package::BLAST_PRESALE_PACKAGE` |
| `blast_presale` | administration roles (ADR 0137) | `blast_presale_admin::SuperAdminCap`, `AdminCap` (ADR 0099) | none of its own: product roles from `blast_core::blast_domain`; package roles `blast_admin::package_admin::UpgradeAdmin`, `PauseAdmin`, `UnpauseAdmin`, `CancelAdmin`, each typed `<BLAST_PRESALE_PACKAGE>` |
| `blast_presale` | package witness (ADR 0137) | — | `blast_presale_package::PackageWitness` |
| `blast_boosts_products` | Publisher one-time witness (new package) | — | `blast_boosts_products::BLAST_BOOSTS_PRODUCTS` |
| `blast_admin` | `blast_acl` shares the singleton ACL from `init`; no one-time witness | — | — |
| `launch_ticket_template` | generated package one-time witness | `meme::MEME` | unchanged name; the generated package's one-time witness, renamed per launch by the SDK template |
| `coin_template` | generated package one-time witness (ADR 0108) | — | `my_coin::MY_COIN`; renamed per coin by the SDK template |
| `presale_coin_template` | generated package one-time witness (ADR 0138) | — | `presale_coin::PRESALE_COIN`; renamed per sale token by the SDK template |

The Publisher object shows `module_name` of the claiming module. The launch
stack's `blast_admin::package_admin::PackageAdmin<OTW>`,
`blast_admin::package_version::PackageVersion<OTW>` and `Publication<OTW>`
take the OTW as their type argument, while `blast_sui` and boosts objects
show it inside `UpgradeCustody<OTW>` and `OperationalVersion<OTW>` until
they adopt the generic administration (#191, #205). Either way the OTW name
is what an auditor reads on every package-administration object.

## Coin types

| Package | Coin `T` before | After | Identified by |
| --- | --- | --- | --- |
| `blast_sui` | `blast_sui::BLAST_SUI` | unchanged | module and struct |
| `blast_sui` | `fun_sui::FUN_SUI` | unchanged | ticker `funSUI`, the blast.fun quote coin |
| `blast_boosts_aftermath` | `vault::Vault<Product>` | `blast_boost::BlastBoost<Product>` | module and struct; `Product` is a `blast_boosts_products` tag |
| `launch_ticket_template` | `meme::MEME` | unchanged | module and struct; the generated package one-time witness |
| `coin_template` | — | `my_coin::MY_COIN` | module and struct; the generated package one-time witness, not a Blast type |

## Key objects

| Package | Type | After | Identified by |
| --- | --- | --- | --- |
| `blast_admin` | `acl::Authority<Domain>` | `blast_acl::ACL`, one shared singleton | module |
| `blast_admin` | `acl::SuperAdminCap<Domain>` | `blast_acl::SuperAdminCap` | module |
| `blast_admin` | `acl::AdminCap<Domain>` | `blast_acl::AdminCap`; its roles are listed in the ACL | module |
| `blast_sui` | `vault::Vault` | unchanged | *residual*; package OTW |
| `blast_sui` | `deposit_receipt::BlastSuiDepositReceipt` | unchanged | struct |
| `blast_sui` | `package_admin::PackageAdmin` | `blast_admin::package_admin::PackageAdmin<BLAST_SUI_PACKAGE>` | generic administration, ADR 0136 |
| `blast_sui` | `package_version::PackageVersion` | `blast_admin::package_version::PackageVersion<BLAST_SUI_PACKAGE>` | generic administration, ADR 0136 |
| `blast_fun` | `launch::Launch<Meme, Quote>` | unchanged | *residual*; `Quote` is usually `fun_sui::FUN_SUI` |
| `blast_fun` | `launch_config::LaunchConfig` | unchanged | *residual* |
| `blast_fun` | `runtime_config::RuntimeConfig` | unchanged | *residual* |
| `blast_fun` | `launch_ticket::LaunchTicket<Meme>` | unchanged | *residual*, wallet-held |
| `blast_core` | `sealed_treasury_cap::SealedTreasuryCap<Coin>` (ADR 0138) | — | *residual*, wallet-held beside the launch ticket or alone for a sale token; the `Coin` parameter names the generated coin |
| `blast_fun` | `creator_authority::CurveFeeCap<Meme>` | unchanged | *residual*, wallet-held |
| `blast_fun` | `creator_authority::CreatorMetadataCap<Meme>` | unchanged | struct |
| `blast_fun` | `launch::LaunchRegistry` | new (ADR 0137); shared singleton from which each launch's ID derives | *residual* |
| `blast_fun` | `package_admin::PackageAdmin` | `blast_admin::package_admin::PackageAdmin<BLAST_FUN>` (ADR 0137) | OTW |
| `blast_fun` | `package_version::PackageVersion` | `blast_admin::package_version::PackageVersion<BLAST_FUN>` (ADR 0137) | OTW |
| `blast_fun` | `blast_fun::Publication` | `blast_admin::package_version::Publication<BLAST_FUN>` (ADR 0137); deployer-owned until custody intake | OTW |
| `blast_migrators` | `venue_config::VenueConfig` | unchanged | *residual* |
| `blast_migrators` | `package_admin::PackageAdmin` | `blast_admin::package_admin::PackageAdmin<BLAST_MIGRATORS>` (ADR 0137) | OTW |
| `blast_migrators` | `package_version::PackageVersion` | `blast_admin::package_version::PackageVersion<BLAST_MIGRATORS>` (ADR 0137) | OTW |
| `blast_core` | `blast_treasury::Treasury` | new (ADR 0137); shared singleton | module |
| `blast_vault` | `vault::Vault<Meme, Quote>` | new (ADR 0137); shared, one per migrated sale of either product | *residual* |
| `blast_vault` | `holder_rewards::Round<Meme, Quote>` | new (ADR 0137); shared, one per published round | *residual* |
| `blast_vault` | `blast_vault_package::VaultRegistry` | new (ADR 0137); shared singleton from which each vault's ID derives | module |
| `blast_vault` | `blast_admin::package_admin::PackageAdmin<BLAST_VAULT_PACKAGE>`, `blast_admin::package_version::PackageVersion<BLAST_VAULT_PACKAGE>` | new (ADR 0137) | OTW |
| `blast_boosts_aftermath` | `vault::Vault<Product>` (shared custody) | unchanged | `Product` is a `blast_boosts_products` tag |
| `blast_boosts_aftermath` | `protocol::Protocol` | `blast_boosts_aftermath::Protocol` | module; holds `OperationalVersion<BLAST_BOOSTS_AFTERMATH>` |
| `blast_boosts_aftermath` | `package_admin::PackageAdmin` | unchanged | holds `UpgradeCustody<BLAST_BOOSTS_AFTERMATH>` |
| `blast_boosts_aftermath` | `blast_boost::BlastBoost<Product>` | new; never instantiated | module and struct |
| `blast_partners` | `blast_partners::Partner` | new (ADR 0095) | module |
| `blast_partners` | `blast_partners::PartnerCap` | new (ADR 0095); wallet-held, one per company | module |
| `blast_presale` | `blast_presale::Presale<SaleToken, Quote>` | new (ADR 0099) | module |
| `blast_presale` | `blast_presale::PresaleCap` | new (ADR 0099); wallet-held, one per presale | module |
| `blast_presale` | `blast_presale::PresaleRegistry` | new (ADR 0137); shared singleton from which each presale's ID derives | module |
| `blast_presale` | `package_admin::PackageAdmin` | `blast_admin::package_admin::PackageAdmin<BLAST_PRESALE_PACKAGE>` (ADR 0137) | OTW |
| `blast_presale` | `blast_presale_package::PackageVersion` | `blast_admin::package_version::PackageVersion<BLAST_PRESALE_PACKAGE>` (ADR 0137) | OTW |
| `blast_presale` | `creation_policy::CreationPolicy` | new (ADR 0102); shared, one per package | *residual* |
| `blast_presale` | `fee_policy::FeePolicy` | new (ADR 0137); shared, one per package | *residual* |
| `blast_aftermath_dao_presale` | `blast_aftermath_dao_presale::AdminCap` | new (ADR 0104); publisher-held, one per package | module |
| `blast_aftermath_dao_presale` | `blast_aftermath_dao_presale::PoolCreation<Lp, SaleToken>` | new (ADRs 0104 and 0137); shared, one per prepared sale token | module |

`blast_boosts_core` defines no `key` type; its `State<Product>` is a
`store` value nested in the adapter Vault.

## Event types

| Package | Outermost event type before | After | Identified by |
| --- | --- | --- | --- |
| `blast_sui` | `events_wrapper::Event<events::X>` | `blast_events::Event<events::X>` | envelope module |
| `blast_fun` | `events_wrapper::Event<events::X>` | `events::X` (direct emission; the envelope is dropped, ADR 0137) | *residual*; package OTW |
| `blast_boosts_aftermath` | `events_wrapper::Event<events::X<Product>>` | `blast_events::Event<events::X<Product>>` | envelope module and `Product` |
| `blast_migrators` | `events::X` (direct emission) | `events::CetusPoolReserved<Meme, Quote>` and `events::BluefinPoolTierRecorded<Meme, Quote>`; vault and LP-fee events are `blast_vault`'s | *residual*; package OTW |
| `blast_core` | — | `blast_core_events::ProtocolFeesPaid<Meme, Quote>` (direct emission, ADR 0137) | module |
| `blast_vault` | — | `blast_vault_events::X` (direct emission, ADR 0137): vault creation, fee collection, auto-LP, buyback, owner-claim, and holder-reward events | module |
| `blast_admin` | `events::X<Domain>` | `blast_admin_events::X`; custody, version and pause events (`Paused<OTW>`, `Unpaused<OTW>`) keep `<OTW>`, the one pause event of every launch-stack package | module |
| `blast_partners` | — | `blast_partners::PartnerUpdated` and `blast_partners::PartnerPaid<T>` (direct emission, ADR 0095); each product's partner list emits `partner_list::PartnerAdded`, `PartnerRemoved` and `PartnerListDestroyed` (ADR 0137) | module |
| `blast_presale` | — | `blast_presale::PresaleCreated` and `events::X` for commitment, settlement, migration, claim, and recovery (direct emission, ADRs 0099 and 0137); partner admission is `blast_partners::partner_list`'s, Blast's fee payments `blast_core_events::ProtocolFeesPaid`, and vault and LP-fee events are `blast_vault`'s | module for creation; *residual* for `events` |
| `blast_aftermath_dao_presale` | — | `blast_aftermath_dao_presale::PoolCreationReserved<Lp, SaleToken, Quote>` and `Migrated<Lp, SaleToken, Quote>` (direct emission, ADR 0104) | module |
| `blast_boosts_aftermath` | — | `blast_events::Event<events::PartnerAdded>` and `blast_events::Event<events::PartnerRemoved>` (ADR 0095; protocol-wide, no `Product`) | envelope module |

Payload struct names inside the envelopes (`Bought`, `Migrated`,
`VaultSynced`, `Minted<Product>`, …) are unchanged.
The protected Boost exit adds `events::ProtectedShutdownBegun<Product>` and
protected reserve/seed amounts to `events::ShutdownFinalized<Product>` inside
the same `blast_events::Event<T>` envelope (ADR 0130).

## Phantom tags and dynamic-field keys

| Package | Type | After | Note |
| --- | --- | --- | --- |
| `blast_admin` | `Role` parameter of `AdminWitness` | — | always a role declared in a Blast `*_domain` module above, or one of `package_admin`'s package roles typed by a Blast OTW, such as `package_admin::UpgradeAdmin<BLAST_VAULT_PACKAGE>` (ADR 0137) |
| `blast_admin` | `OTW` parameter of `Publication`, `PackageVersion`, `PackageAdmin`, the package roles and the custody, version and pause events | — | always a Blast OTW above |
| `blast_sui` | `vault::TreasuryKey<CoinType>`, `vault::CapabilityKey<Capability>` | unchanged | dynamic-field keys under `Vault` |
| `blast_migrators` | `cetus::Venue`, `bluefin::Venue` | unchanged | the shared venue witnesses of both products (ADR 0137); appear as `TypeName` values in `LaunchConfig`, `CreationPolicy`, `VaultRegistry` and events, and type the vault's position keys; the module names the venue |
| `blast_migrators` | `cetus::CreationCapKey<Meme>` | unchanged | dynamic-object-field key under `VenueConfig` for the Meme type's Cetus `PoolCreationCap`; the cap keeps its own object ID |
| `blast_migrators` | `cetus::CastKey` | new (ADR 0100) | transient dynamic-field key on a UID created and deleted within one Cetus route call; retypes a coin or balance between Meme/Quote and pool coin order |
| `blast_migrators` | `cetus::PoolTierKey<Meme>`, `bluefin::PoolTierKey<Meme>` | new (ADR 0137) | dynamic-field keys under `VenueConfig` for a Meme type's recorded tier: the Cetus tick spacing or the Bluefin `bluefin::PoolTier` |
| `blast_aftermath_dao_presale` | `blast_aftermath_dao_presale::Venue` | new (ADRs 0104 and 0137) | sealed external venue witness a presale fixes at creation; listed only in `CreationPolicy`, never in `VaultRegistry` |
| `blast_vault` | `vault::PositionKey<Venue>`, `vault::AutoLpPositionKey<Venue>` | new (ADR 0137) | dynamic-object-field keys under `Vault` for the venue's migration and auto-LP positions |
| `blast_fun`, `blast_presale`, `blast_vault` | `launch::LaunchKey<Meme>`, `blast_presale::PresaleKey<SaleToken>`, `vault::VaultKey` | new (ADR 0137) | derived-object keys under `LaunchRegistry`, `PresaleRegistry` and `VaultRegistry`: one launch or presale per coin, one vault per sealing package witness and sale |
| `blast_boosts_aftermath` | `vault::TreasuryKey<Product>`, `vault::MetadataKey<Product>`, `vault::AdminCashKey`, `vault::TerminalCashKey` | unchanged | dynamic-field keys under `Vault` |
| `blast_boosts_aftermath` | `protocol::PartnerKey` | `blast_boosts_aftermath::PartnerKey` (ADR 0095) | dynamic-field key under `Protocol`, one per Blast partner Boosts accepts; the value is the time it stops being accepted |
| `blast_boosts_products` | `<TICKER>_<SIDE>_<LEVERAGE>` tags such as `NVDA_BULL_2X` | bull and bear 2X per Aftermath market | inner type of every Boost coin |

## Parked packages

The [scratch DEX](../scratch-sui/README.md) sits outside the product surface.
Its fee-tier registry is `BlastDexFeeTiers` and its ACL role is
`blast_fun_dex_domain::BlastDexFeeTierAdmin`. Its one-time witness,
`blast_fun_dex::BLAST_FUN_DEX`, identifies the generic package administration,
version, and roles. The same module defines the `PackageWitness` pinned at
publication.

Presale activation (ADR 0137) types the generic `Publication`, `PackageVersion`
and `PackageAdmin` by `blast_presale_package::BLAST_PRESALE_PACKAGE`. The
separate provenance module avoids cycles between the economic module and policy
modules that must borrow PackageVersion.
