# 0104: External presale migrators and vendor packages

- Status: proposed
- Date: 2026-10-05
- Amends: [0099](0099-standalone-overflow-presale.md), which kept every presale
  adapter inside `blast_presale`, and [0102](0102-presale-creation-allowlists.md),
  whose witness allowlist could not admit a third venue

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

**Witness admission.** Any caller can construct a primitive or a vector of
droppable values, so `set_migration_witness_allowed` rejects allowing one with
`EInvalidMigrationWitness`. Before allowing a struct, the administrator verifies
its module keeps the constructor private and is the reviewed migrator.

**Vendor packages.** One-off partner contracts live under `sui/vendors/<name>/`,
each its own package with its own interface stubs, gates, and publish script, and
each depending inward on Blast packages.

**First vendor: `blast_aftermath_dao_presale`.**

- It has no administrator and no shared state. A compiled `TREASURY` receives
  everything the package hands out; the publish script sends it the `UpgradeCap`
  in the publish transaction.
- Its `new` creates sales with its `Witness` and an LP-fee split naming the
  treasury as the only recipient, the true destination of the pool's fees.
- Its permissionless `migrate` creates a 50/50, flatness-zero Aftermath pool from
  every LP token and Quote unit, using the caller's fresh LP coin, and checks the
  pool holds them. It wraps the pool in a DAO-fee pool charging a compiled 2% to
  the treasury and checks both values. It shares the DAO-fee pool and sends the
  treasury the pool's `OwnerCap` and a `LockedLiquidity` holding the complete LP
  balance. The base pool keeps Aftermath's minimum 0.01% swap-in fee.
- `LockedLiquidity` has `key` and `store`, so the treasury can move it, but no
  function releases its LP. With an `OwnerCap` the treasury changes its pool's
  DAO fee or recipient directly through Aftermath.

## Alternatives considered

- **Add each partner venue to `blast_presale`.** Rejected: every venue would need
  a new presale generation and would widen core's dependency graph.
- **Allow external witnesses without making `new` public.** Not possible: only
  package code can call a package function.
- **Collect DAO fees in a shared `Config` that anyone forwards to a treasury an
  `AdminCap` can move.** Rejected for this partner: the treasury holds every
  pool's `OwnerCap`, so it redirects a pool's fees itself, and a claim function,
  admin capability, and shared object add nothing.
- **Freeze the locked liquidity.** Rejected for this partner, which wants to hold
  its position object: freezing would make the LP unmovable even by an upgrade,
  but no function releases it either way.

## Consequences

- Blast can admit a partner's migrator without republishing the presale package;
  a compromised presale `AdminCap` can now admit a hostile migrator for new sales,
  as it could already admit an unvetted Quote type, but cannot touch a live sale.
- Vendor sales skip `PresaleVault`, so Blast's LP-fee rates and holder rewards do
  not apply to them; Blast's raise and token shares still do.
- The treasury sets every vendor pool's DAO fee, from 0% to 100%, and its
  recipient. As the vendor's `UpgradeCap` holder it also controls how unmigrated
  sales reach the venue, and an upgrade could add a way to release the LP it holds.
- The SDK classifies `new` and `migrate` as Move composition and builds
  `set_migration_witness_allowed` for any witness type.

## Verification

- Presale tests: the new admission guard rejects a primitive and a vector,
  disallowing either is an unchanged allowance, and the AdminCap check precedes
  the type check.
- Vendor tests: sale creation through the allowed witness and its fee split to
  the treasury, rejection of an unlisted witness, and Aftermath's coin order.
- Release: the vendor's `check_mainnet_abi.mjs` live gate and a mainnet
  dev-inspect of `migrate` in both coin orders before the first sale migrates.
