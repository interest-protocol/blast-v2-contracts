# 0104: External presale migrators and vendor packages

- Status: proposed
- Date: 2026-10-05
- Amends: [0099](0099-standalone-overflow-presale.md), which kept every presale
  adapter inside `blast_presale`, and [0102](0102-presale-creation-allowlists.md),
  whose witness allowlist could not admit a third venue
- Amended: 2026-10-05 (owner decision, after the presale audit): the vendor
  package is published immutable instead of sending a full `UpgradeCap` to its
  treasury, and witness admission also rejects framework (`0x1`, `0x2`) types
- Amended by: [0110](0110-presale-initializer-and-early-close.md): `new` returns a
  `PresaleInitializer`, and the vendor creates a sale through its own `new` and
  `finalize`

## Context

Under ADR 0099 only the Cetus and Bluefin modules inside `blast_presale` could
create or migrate a sale: `presale::new` and `presale::migrate` were package-only,
and the dependency-only upgrade policy means the package can never gain a venue.
Partners now ask for custom migrations, starting with an Aftermath pool wrapped
in Aftermath's DAO-fee pool, that Blast builds once for them and does not want in
the core presale package.

## Decision

**Public creation and migration.** `blast_presale::new` and `migrate` are public.
A migrator in any package calls them with its own `drop` witness. `new` already
aborts unless the shared `CreationPolicy` allows that witness, and a sale releases
its liquidity only to `migrate` called with the witness stored at creation. A
struct's constructor is private to its defining module, so the witness, not the
caller, is the authority, and the presale `AdminCap` decides which migrators may
open sales. Since this generation changes presale logic, it is a new publication
of `blast_presale`, not a dependency-only upgrade.

**Witness admission.** Any caller can construct a primitive, a vector of
droppable values, or a framework struct with a public constructor, such as
`TypeName`, `Option<T>`, or `ID`. So `set_migration_witness_allowed` rejects
allowing a primitive, a vector, or any type defined at `0x1` or `0x2`, with
`EInvalidMigrationWitness`, as the launchpad's admission does. Before allowing
any other struct, the administrator verifies its module keeps the constructor
private and is the reviewed migrator.

**Vendor packages.** One-off partner contracts live under `sui/vendors/<name>/`,
each its own package with its own interface stubs, gates, and publish script, and
each depending inward on Blast packages.

**First vendor: `blast_aftermath_dao_presale`.**

- `init` sends the package's only `AdminCap` to the publisher, and the publish
  script makes the package immutable in the publish transaction. A compiled
  `TREASURY` receives everything else the package hands out.
- Its `new` takes the `AdminCap` and the `CreatePoolCapV2` of a fresh LP coin
  `Lp`. It creates the sale with its `Witness` and an LP-fee split naming the
  treasury as the only recipient, the true destination of the pool's fees, sends
  the treasury the sale's `PresaleCap`, and shares a key-only `PoolCreation<Lp>`
  binding that cap to the new presale.
- Its permissionless `migrate` takes the sale and its `PoolCreation`, checks the
  binding (`EWrongPresale`), and consumes it, so the migration caller chooses
  no economic input, not even the LP coin. It creates a 50/50, flatness-zero
  Aftermath pool from every LP token and Quote unit and checks the pool holds
  them. It wraps the pool in a DAO-fee pool charging a compiled 2% to the
  treasury and checks both values. It shares the DAO-fee pool, sends the
  treasury the pool's `OwnerCap`, and sends the LP coin Aftermath returned, the
  complete LP balance, to `0x0`. The base pool keeps Aftermath's minimum 0.01%
  swap-in fee.
- No one can sign for `0x0`, so no transaction, even after an upgrade, can use
  that LP coin, and the LP is locked forever. With an `OwnerCap` the treasury
  changes its pool's DAO fee or recipient directly through Aftermath.

## Alternatives considered

- **Add each partner venue to `blast_presale`.** Rejected: every venue would need
  a new presale generation and would widen core's dependency graph.
- **Allow external witnesses without making `new` public.** Not possible: only
  package code can call a package function.
- **Let the migration caller supply the `CreatePoolCapV2`.** Rejected: whoever
  migrates first would choose the LP coin, including its name and metadata, for
  a pool the treasury then holds. Binding the cap at creation fixes it.
- **Collect DAO fees in a shared `Config` that anyone forwards to a treasury the
  `AdminCap` can move.** Rejected for this partner: the treasury holds every
  pool's `OwnerCap`, so it redirects a pool's fees itself, and a claim function
  and shared configuration add nothing.
- **Give the treasury the LP.** Rejected: the treasury could withdraw the
  liquidity. Owned by `0x0`, the LP coin can never be used.
- **Wrap the LP in a package object.** Rejected: owned by `0x0`, the bare coin is
  already as locked as any wrapper, and freezing a wrapper would leave it
  readable by reference, which a later upgrade could build on.
- **Send the treasury the vendor's `UpgradeCap` (the first version).** Rejected
  after the audit (owner, 2026-10-05): under the compatible policy an upgrade
  could replace `migrate` and send a funded sale's raise and LP tokens anywhere,
  while its participants cannot exit before the LP deadline. A dependency-only
  cap would have kept relinking to new Aftermath versions; the owner chose
  immutability.

## Consequences

- Blast can admit a partner's migrator without republishing the presale package;
  a compromised presale `AdminCap` can now admit a hostile migrator for new sales,
  as it could already admit an unvetted Quote type, but cannot touch a live sale.
- Vendor sales skip `presale_vault::Vault`, so Blast's LP-fee rates and holder rewards do
  not apply to them; Blast's raise and token shares still do.
- The treasury sets every vendor pool's DAO fee, from 0% to 100%, and its
  recipient. The vendor package is immutable, so nobody can change how a sale
  migrates or release a migrated pool's LP. If Aftermath retires the AMM or
  DAO-fee version it links to, its migrations abort and its sales refund at
  their LP deadline; new sales then need a new vendor package.
- The SDK classifies `new` and `migrate` as Move composition and builds
  `set_migration_witness_allowed` for any witness type.

## Verification

- Presale tests: the admission guard rejects a primitive, a vector, and
  framework structs at `0x1` and `0x2`; disallowing a primitive is an unchanged
  allowance; and the AdminCap check precedes the type check.
- Vendor tests: the `AdminCap` delivered to the publisher; sale creation through
  the allowed witness, its fee split to the treasury, and its `PresaleCap`
  delivered there; the shared `PoolCreation` bound to its sale; `migrate`
  rejecting another sale's `PoolCreation`; rejection of an unlisted witness;
  Aftermath's coin order; and a vendor sale naming a Blast partner before its
  share.
- Release: the vendor's `check_mainnet_abi.mjs` live gate and a mainnet
  dev-inspect of `migrate` in both coin orders before the first sale migrates.
