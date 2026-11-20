## Calling Blast contracts

Every Blast product is a set of Sui Move packages called from programmable
transaction blocks (PTBs). This section covers what every product shares. Each
product guide below assumes it.

### Products and packages

| Product | What users do | Packages |
| --- | --- | --- |
| Presale | commit Quote to a capped or overflow sale, claim tokens or refunds, earn LP fees and holder rewards after migration | `blast_presale`; the shared venues `blast_migrators`; one-off partner venues such as `blast_aftermath_dao_presale`; `blast_vault` (LP vault, holder rewards) |
| Launchpad | launch a coin on a bonding curve, trade it, graduate it into a DEX pool | `blast_fun` (curve, lifecycle, fees), a generated coin package per launch, `blast_migrators` (Cetus and Bluefin venues for both products: venue start, migration, LP fees), `blast_vault` (LP vault, holder rewards) |
| Partner codes | earn a share of Blast's fee on the flow an app brings | `blast_partners` |
| Boosts | hold a leveraged long or short coin backed by Aftermath perpetuals | `blast_boosts_core`, `blast_boosts_products`, `blast_boosts_aftermath` |
| blastSUI | stake SUI across a short validator list through funSUI and blastSUI | `blast_sui` |
| Administration | Blast's operators manage roles, fees, and upgrades | `blast_admin` |

Each package and what it depends on:

```text
blast_migrators              -> blast_core, blast_vault, blast_admin, Cetus, Bluefin
blast_aftermath_dao_presale  -> blast_core, Aftermath AMM
blast_fun                    -> blast_core, blast_partners, blast_admin
blast_presale                -> blast_core, blast_partners, blast_admin
blast_vault                  -> blast_core, blast_partners, blast_admin
blast_core                   -> blast_partners, blast_admin, blast_fun_vesting
blast_partners               -> blast_admin
blast_boosts_aftermath       -> blast_boosts_core, blast_partners, blast_admin, Aftermath perpetuals
blast_boosts_core            -> blast_admin
blast_sui                    -> blast_admin, Sui system
blast_admin                  -> Sui framework only
```

No product imports a venue or the vault, and no venue imports a product. They
compose inside one PTB through `blast_core` values: a venue's `prepare` returns
the `VenueTicket` the product's creation call redeems, and at migration the
product's `migrate` returns the `Migration` that the next command passes to the
stored venue's `migrate`, which locks the liquidity in a
`blast_vault::vault::Vault`.
Use the presale guide for presale calls.

`blast_fun_vesting` (used by `blast_core` for vesting payouts) lives in this repository at
`sui/utilities/vesting` and is immutable on mainnet. The standalone
OTC package lives at `sui/utilities/otc`. See the [utility integration guide](https://github.com/interest-protocol/blast-v2-contracts/blob/main/docs/utilities.md).

### Time values

Timestamp parameters ending in `_at_ms` are points in time measured in Unix
milliseconds. Duration parameters ending in `_duration_ms` are lengths of time;
`_delay_ms` parameters are offsets from the documented anchor. For example,
`commitment_starts_at_ms + commitment_duration_ms` is the commitment window's
end timestamp. Stored fields and event payloads retain their published names;
read their documented meaning rather than assuming every `_ms` value is a
timestamp. Framework calls such as `Clock::timestamp_ms` retain their native
names.

### Building a call

- **Target.** A call is `moveCall` with target
  `<package-id>::<module>::<function>`. Use the package ID (`published-at`) from
  the deployment table.
- **Type arguments.** Pass fully qualified type strings. A Blast type is named by
  the package that first defined it (`original-id`), even after an upgrade.
- **`TxContext`.** A trailing `ctx: &TxContext` or `&mut TxContext` parameter is
  supplied by Sui. Leave it out of the arguments.
- **Shared objects.** Pass a shared object by ID. A `&` parameter takes it
  read-only, `&mut` or by value takes it mutably; mutable access orders the
  transaction through consensus with every other writer of that object.
- **System objects.** `Clock` is `0x6` (always `&Clock`), the Sui system state is
  `0x5`, and the Coin Registry is `0xc`.
- **Coins in.** A function that takes `Coin<T>` by value consumes it whole. Split
  the exact amount first (`SplitCoins`; for SUI, split from the gas coin) and
  merge several coins first when needed (`MergeCoins`).
- **Values out.** Most Blast functions return coins and objects instead of
  transferring them. Every returned value without the `drop` ability must be used
  before the PTB ends: transfer it (`TransferObjects`), pass it to a later call,
  or merge it. A value with no abilities at all (a "hot potato", such as a
  launch initializer or a migration handoff) can only be consumed by the specific
  later call that accepts it, so the whole sequence must sit in one PTB.
- **Basis points.** The launch products and the vault share one validated
  `Bps` type, `blast_core::bps::Bps`. Build one inside the PTB with
  `blast_core::bps::new`, which aborts above 10,000.
- **Options.** Pass `Option<T>` arguments with `0x1::option::some` or
  `0x1::option::none` calls, or as pure BCS-encoded options.

### Reading state

- **Getters** are public functions that take `&` objects and return values. Run
  them through a dev-inspect or simulated transaction to read without signing
  or paying.
- **Object fields** can be read directly from a full node and decoded with BCS.
  The API reference prints every struct with its fields in declaration order,
  which is the BCS order. Fields are readable on chain even though Move code
  outside the module cannot access them.
- **Per-user records** (commitments, claims) usually live in dynamic fields
  keyed by a small key struct the reference lists; read them with the
  dynamic-field RPC calls.
- **Events** reconstruct history; contract state and completed events are the
  source of truth, and any off-chain preview is an estimate.

### Versions and upgrades

Upgrade rules depend on the package lineage.

| Posture | Packages | What callers do |
| --- | --- | --- |
| Shared UpgradeCap manager | `blast_admin`, `blast_partners`, `blast_core`, `blast_aftermath_dao_presale` | The manager holds the compatible UpgradeCaps. Each upgrade or immutability request waits 48 hours. The Blast multisig holds the controller. |
| Immutable | `blast_boosts_core`, `blast_upgrade_cap_manager` | The code never changes. |
| Dependency-only | Historical presale publications | These older lineages can relink venue packages and do not use a version object. |
| Version-gated | `blast_presale`, `blast_fun`, `blast_vault`, `blast_migrators`, `blast_sui`, `blast_boosts_aftermath` | Mutating calls take the package's shared version object (for the launch packages, `blast_admin::package_version::PackageVersion<OTW>`). After an upgrade advances it, calls through an older package ID abort with a version mismatch, so always call the current ID. `blast_vault` is made immutable after its audit. |
| Additive | `blast_boosts_products` | Upgrades only add product tags; it holds no state. |

### Events

- Query events by their Move type, named with the `original-id`.
- `blast_sui` and `blast_boosts_aftermath` wrap every payload in the `Event<T>`
  envelope of their own `blast_events` module (for example
  `blast_sui::blast_events::Event`), so the event type is
  `<original-id>::blast_events::Event<<original-id>::<module>::<Payload>>`.
  Every other package, the launchpad included, emits payload structs directly.
- Sui orders events by checkpoint, transaction, and event index within the
  transaction; payloads carry no sequence numbers of their own.
- The reference lists every event struct under its module with its fields.

### Errors

A failed call returns a Move abort naming the module and function that aborted
and a `u64` code. Blast uses two styles:

- **Named errors** (`#[error]` constants): `blast_aftermath_dao_presale`. Sui's RPC and SDKs
  decode these into the constant's name and message; the reference lists each
  module's constants with their messages.
- **Numeric codes**: `blast_admin`, `blast_partners`, `blast_core`, `blast_vault`,
  `blast_fun`, `blast_presale`, `blast_migrators`, `blast_sui`, `blast_boosts_core`,
  and `blast_boosts_aftermath` abort with small integers. Look the
  number up in that package's abort-code table in the reference.

The abort names the module where it happened, which may be a package called
underneath the one you called: a migrator call can abort inside `blast_core`,
`blast_vault` or `blast_admin`, and an abort in a Cetus, Bluefin, or Aftermath
module comes from the venue. Simulate a transaction before signing to see its abort without
spending gas.

### Network

Blast deploys only to Sui mainnet. There is no testnet deployment, faucet, or
test address. Try a transaction with a mainnet simulation (dev-inspect or dry
run) before signing it.
