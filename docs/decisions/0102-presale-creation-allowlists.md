# 0102: Presale creation allowlists

- Status: proposed
- Date: 2026-10-02
- Amends: [0099](0099-standalone-overflow-presale.md), which let a creator raise any Quote type
  through either venue
- Amended by: [0104](0104-external-presale-migrators-and-vendor-packages.md): `presale::new` is
  public, so the witness allowlist admits migrators in other packages and rejects primitive types;
  [0106](0106-presale-partners.md): the policy also lists the Blast partners new presales may name

## Context

Under ADR 0099 a creator chose the Quote coin and the migration venue freely. Blast cannot vouch
for every coin a sale might raise, and it needs a way to stop new sales on a venue whose
integration is broken without an upgrade, which the package's dependency-only policy rules out.

The launchpad already gates new launches this way: `launch_config::set_quote_allowed` and
`set_migration_witness_allowed` admit Quote types and migration adapters, and existing launches
keep theirs.

## Decision

**Policy.** The package shares one `creation_policy::CreationPolicy` at publication. It holds two
sets of original-ID type names, both empty at initialization: `allowed_quotes` and
`allowed_migration_witnesses`. The presale `AdminCap` (ADR 0099) changes them with
`set_quote_allowed<Quote>` and `set_migration_witness_allowed<MigrationWitness>`, each taking an
`allowed` flag, rejecting a no-op (`EAllowanceUnchanged`), and emitting `QuoteSet` or
`MigrationWitnessSet`. The names and shapes match the launchpad's.

**Checked once, at creation.** `presale::new` takes `&CreationPolicy` and aborts unless both the
Quote type (`EQuoteNotAllowed`) and the venue's migration witness (`EMigrationWitnessNotAllowed`)
are allowed. Both `cetus::new` and `bluefin::new` pass it through. Nothing else reads the policy,
so disallowing a type never affects a live sale: its commitments, settlement, migration, claims,
and LP-fee collection proceed as before.

**Witnesses.** Only `cetus::new` and `bluefin::new` can call `presale::new`, each with its own
sealed `Witness`, and dependency-only upgrades cannot add a venue. The witness allowlist therefore
switches those two venues on and off for new sales; it cannot admit a third.

## Alternatives considered

- **Store the sets in `FeePolicy`.** Rejected so the economic rates and the listing decision stay
  separate objects, each with its own events, as in the launchpad.
- **Also check at commitment.** Rejected because a delisting could then freeze an open sale with
  locked commitments, which ADR 0099's refund liveness rules out.
- **Abort natively on a no-op, as the launchpad's `VecSet` setters do.** Rejected in favour of the
  explicit error that `FeePolicy`'s setters use.

## Consequences

- A freshly published package creates no presales until the `AdminCap` allows at least one Quote
  type and one migration witness.
- Off-chain builders must pass the shared `CreationPolicy` to every venue's `new`.
- A compromised `AdminCap` can block new presales or admit a Quote type Blast has not vetted; it
  cannot touch an existing sale.

## Verification

- Policy tests cover the empty initial state, allowing and disallowing both kinds with their
  events, one type not implying another, and every no-op update.
- Presale tests cover a venue's `new` rejecting an unlisted Quote type and an unlisted migration
  witness through the real Bluefin adapter.
- The presale venue fork allows the route's Quote and witness with the published `AdminCap`
  before creating each sale.
