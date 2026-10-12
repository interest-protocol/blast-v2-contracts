# 0090: A minimal launchpad surface

- Status: accepted
- Date: 2026-09-24
- Amends: [0047](0047-coin-registry-authoritative-supply-mode.md),
  [0088](0088-reusable-launch-accounting-and-atomic-migration.md), and
  [0089](0089-migrators-own-post-migration-and-start-launches.md)

## Context

The founder asked on 2026-09-24 for every launchpad module to be as succinct as
possible, without code that adds no value, and ruled on specific cuts: public
getters no package calls, the channel-role allocation plan, the one pre-share
purchase limit, and the rule that a pre-share purchase cannot graduate. Less code
must not mean fewer features: Blast account claims, cap deletion, Blast's
rounded-up allocation, duplicate-route rejection, and no-op setter aborts stay.

## Decision

**Public surface.** A function is public only when a transaction or another
package calls it. Reads used only inside the launchpad are `public(package)`;
reads nothing in production calls exist only as `#[test_only]` seams, which
never deploy. Off-chain readers decode the objects and the events. Role numbers
are constants they pin.

**Allocation plan.** A plan holds the curve's Meme share, the pool's Meme and
Quote shares, and up to sixteen recipients (address, Meme share, Quote share).
The creator's plan leaves Blast out; finalization adds Blast's allocation from
`LaunchConfig` as the first recipient and requires each asset to sum to 10,000.
Channel roles, channel IDs, parallel weight tables, and the check that the
creator restated Blast's allocation are removed. Blast's share rounds up; every
other part takes its floor plus one leftover unit by largest remainder, earlier
parts first. Recipients are paid when migration begins, and only the pool's
share goes to the adapter.

**Launch.** Before the launch is shared its owner may buy any number of times,
and a purchase may reach the graduation target. There is no separate pre-share
purchase: `buy` treats an unshared launch as unprotected, since only the
creation transaction can reach it. As amended for Asymptotic L-5 (2026-10-12),
`new`, every initializer setter, `finalize`, and `share` each check
`PackageVersion` first. The initializer cannot leave its transaction, but that
transaction can mix current and superseded bytecode; intake alone is insufficient. The lifecycle is `Live`, `MigrationReady`, `Migrated`. **One
migration call.** `migrate` pays the recipients, disposes of the unsold Meme, sets `Migrated`, and hands the pool's
share to the adapter; the `Migration` hot potato and `complete_migration` are
removed. The launch could not verify what an adapter reported about its pool:
the allowlisted adapter is the only caller, the version and witness were
already checked, and Balance linearity already conserves the handoff. The
residuals and the position's liquidity move to the migrators' `VaultCreated`,
and the vault refuses a position without liquidity. The launch stores the creator
recipient directly, derives "shared" from the protection end, and keeps only the
atomic protection limits.

**Configuration.** Each allow/disallow pair is one setter (`set_quote` with zero
disallowing, since replaced by ADR 0092's `set_quote_allowed`, `set_meme_decimals_allowed`, `set_migration_witness_allowed`), and
an empty signer key revokes account claims. A setter called with the value
already in place aborts: with one shared `unchanged` error, or, for the decimals
and migration-witness sets, with the set's own insert or remove abort. The
migration-witness capacity limit is removed.

**Events and errors.** Each allow/disallow pair emits one event, a purchase
before sharing emits `Bought` like any other, protection settings move into
`LaunchCreated`, and fields an indexer can derive (channel IDs, revoked cap IDs, running totals,
supply already in `LaunchTicketCreated`) are dropped; `Migrated` carries no
supply-mode flag, since `LaunchCreated.ticket_id` leads to
`LaunchTicketCreated.burnable`. Errors that could not fire or duplicated another
are removed, and the registry is renumbered. A named check that only precedes a
framework abort on the same condition is removed too: a missing initializer
setting, Blast allocation, or account-claim attestation aborts in `std::option`,
an unadmitted Quote in `sui::dynamic_field`, and a wrong-length signature fails
verification. Package administration leaves Publisher and UpgradeCap provenance
to `blast_admin`.

## Consequences

- The launchpad ABI, event layouts, and error codes change; the SDK, the
  indexer's decoders, and the harnesses must follow.
- A creator can graduate a launch before sharing it; it then migrates like any
  other launch.
