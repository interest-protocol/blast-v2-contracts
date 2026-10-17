## Calling Blast contracts

Every Blast product is a set of Sui Move packages called from programmable
transaction blocks (PTBs). This section covers what every product shares. Each
product guide below assumes it.

### Products and packages

| Product | What users do | Packages |
| --- | --- | --- |
| Presale | commit Quote to a capped or overflow sale, claim tokens or refunds, earn LP fees and holder rewards after migration | `blast_presale`; one-off partner migrators such as `blast_aftermath_dao_presale` |
| Launchpad | launch a coin on a bonding curve, trade it, graduate it into a DEX pool | `blast_fun` (curve, lifecycle, fees), a generated coin package per launch, `blast_fun_migrators` (venue start, migration, LP vault, LP fees, holder rewards) |
| Partner codes | earn a share of Blast's fee on the flow an app brings | `blast_partners` |
| Boosts | hold a leveraged long or short coin backed by Aftermath perpetuals | `blast_boosts_core`, `blast_boosts_products`, `blast_boosts_aftermath` |
| blastSUI | stake SUI with one validator through funSUI and blastSUI | `blast_sui` |
| Administration | Blast's operators manage roles, fees, and upgrades | `blast_admin` (the presale has its own admin caps) |

Each package and what it depends on:

```text
blast_fun_migrators          -> blast_fun, blast_admin, Cetus, Bluefin
blast_fun                    -> blast_partners, blast_admin
blast_partners               -> blast_admin, blast_fun_timelock
blast_presale                -> blast_partners, blast_fun_vesting, Cetus, Bluefin
blast_aftermath_dao_presale  -> blast_presale, Aftermath AMM
blast_boosts_aftermath       -> blast_boosts_core, blast_partners, blast_admin, Aftermath perpetuals
blast_boosts_core            -> blast_admin
blast_sui                    -> blast_admin, Sui system
blast_admin                  -> blast_fun_timelock
```

The launchpad imports no DEX. A migrator package depends on the launchpad and
composes with it inside one PTB. The presale is a separate product: it shares
no state or code with the launchpad or the migrators, keeps its own admin caps
instead of `blast_admin`, and holds migrated liquidity in its own
`presale_vault::Vault`. Answer presale questions from the presale guide alone.

`blast_fun_timelock` and `blast_fun_vesting` come from Blast's public utility
repository (`interest-protocol/blast-util-contracts`); both are immutable on
mainnet.

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
- **Basis points.** Each package that takes rates defines its own validated
  `Bps` type in its `bps` module. Build one inside the PTB with that package's
  constructor, for example `blast_presale::bps::new` or `blast_fun::bps::new`,
  which aborts above 10,000. A `blast_fun` `Bps` is a different type from a
  `blast_presale` `Bps`.
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

Each package has one upgrade posture:

| Posture | Packages | What callers do |
| --- | --- | --- |
| Immutable | `blast_admin`, `blast_partners`, `blast_boosts_core`, `blast_aftermath_dao_presale` | Nothing: the code never changes. |
| Dependency-only | `blast_presale` | Presale logic is sealed; Blast can only relink newer Cetus, Bluefin, and Aftermath versions, and every generation runs identical code with no version gate. Call the latest package ID, because a venue rejects calls linked to a version it retired. |
| Version-gated | `blast_fun`, `blast_fun_migrators`, `blast_sui`, `blast_boosts_aftermath` | Mutating calls take the package's shared version object. After an upgrade advances it, calls through an older package ID abort with a version mismatch, so always call the current ID. |
| Additive | `blast_boosts_products` | Upgrades only add product tags; it holds no state. |

### Events

- Query events by their Move type, named with the `original-id`.
- `blast_fun`, `blast_sui`, and `blast_boosts_aftermath` wrap every payload in
  the `Event<T>` envelope of their own `blast_events` module (for example
  `blast_fun::blast_events::Event`), so the event type is
  `<original-id>::blast_events::Event<<original-id>::<module>::<Payload>>`.
  Every other package emits payload structs directly.
- Sui orders events by checkpoint, transaction, and event index within the
  transaction; payloads carry no sequence numbers of their own.
- The reference lists every event struct under its module with its fields.

### Errors

A failed call returns a Move abort naming the module and function that aborted
and a `u64` code. Blast uses two styles:

- **Named errors** (`#[error]` constants): `blast_presale`, `blast_partners`,
  `blast_fun_migrators`, and `blast_aftermath_dao_presale`. Sui's RPC and SDKs
  decode these into the constant's name and message; the reference lists each
  module's constants with their messages.
- **Numeric codes**: `blast_fun`, `blast_sui`, `blast_boosts_core`,
  `blast_boosts_aftermath`, and `blast_admin` abort with small integers. Look the
  number up in that package's abort-code table in the reference.

The abort names the module where it happened, which may be a package called
underneath the one you called: a migrator call can abort inside `blast_fun` or
`blast_admin`, and an abort in a Cetus, Bluefin, or Aftermath module comes from
the venue. Simulate a transaction before signing to see its abort without
spending gas.

### Network

Blast deploys only to Sui mainnet. There is no testnet deployment, faucet, or
test address. Try a transaction with a mainnet simulation (dev-inspect or dry
run) before signing it.
