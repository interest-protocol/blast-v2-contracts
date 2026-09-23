# 0043: Versioned launch trading and atomic migration

> Versioning update (2026-08-28): [ADR 0045](0045-single-package-version.md)
> removes the redundant per-Launch version. Only
> `RuntimeConfig.package_version` gates Launch mutations.
> Migration authorization update (2026-08-28):
> [ADR 0046](0046-witness-authorized-migration-redemption.md) moves the sealed
> witness value from permissionless `migrate` to payload redemption.
> Supply-mode update (2026-08-29):
> [ADR 0047](0047-coin-registry-authoritative-supply-mode.md) removes the cached
> `burnable` fields and makes `Currency<Meme>` authoritative at migration.
> Cutover update (2026-08-29):
> [ADR 0049](0049-audit-hardened-package-version-and-launch-intake.md) moves the
> only operational version to `PackageVersion`, gates every mutable core shared
> object, and separates native receipt commit from checked activation.
> Sell-burn update (2026-09-12):
> [ADR 0077](0077-fixed-creator-selected-sell-burn.md) replaces the progress ramp
> with a fixed creator-selected rate capped at 5,000 basis points.

- Status: accepted; amended by [0088](0088-reusable-launch-accounting-and-atomic-migration.md)
- Date: 2026-08-28
- Amends: [0004](0004-bonding-curve.md),
  [0007](0007-acl-pause-and-versioning.md),
  [0010](0010-migration-and-venue-adapters.md),
  [0011](0011-event-schema-and-replay.md),
  [0025](0025-quote-whitelist-and-migration-targets.md),
  [0026](0026-deferred-sell-burn.md),
  [0027](0027-graduation-economics-and-migration-witnesses.md),
  [0033](0033-meme-liquidity-provision.md),
  [0037](0037-remove-redundant-ticket-burn-mode.md),
  [0039](0039-deterministic-quote-valuations.md),
  [0040](0040-normalized-launch-state-intake.md), and
  [0042](0042-key-only-shared-launch.md)

## Decision

`RuntimeConfig` stores the current Blast package version. Every launch mutation
and package-administration operation checks that value before other work. A
successful native package-upgrade commit advances it exactly once; the wrapped
`UpgradeCap.version()` remains the independent native upgrade counter.

Each `Launch` snapshots the deployer-selected `sell_burn_bps` carried by its
`LaunchTicket`. The ticket constructor irreversibly selects native `Fixed` or
`BurnOnly` supply and accepts any sell-burn rate through 5,000 basis points,
including zero. Coin Registry is the only supply-mode authority. Ticket
redemption copies only the rate into the launch, so the launcher cannot
substitute another rate.

`launch.move` owns the public stateful lifecycle. `buy` and `sell` consume one
input coin, enforce minimum output against the exact returned coin, invoke the
package-only curve arithmetic, move reserves and pending burn, accrue both fee
assets under the live protocol share, and return the output coin. A final buy
accepts only the gross Quote needed to reach the exact net target and returns
the remainder as a Quote coin. Reaching that target changes `Live` to
`MigrationReady`; sells are then closed.

`migrate` is atomic and permissionless. It accepts the native `Currency<Meme>`,
checks the selected migrator witness type, reads the authoritative native supply
mode, partitions the terminal Quote, and returns a non-droppable typed payload.
`redeem_migration` requires a value of that exact witness type. Both modes
migrate only the reserved Meme provision. BurnOnly launches destroy terminal
curve residual plus accumulated pending burn through Coin Registry. Fixed
launches transfer the same terminal disposal balance to `0x0`; this makes it
inaccessible but does not reduce native total supply. Every other native state
aborts before asset mutation. The event schema distinguishes native destruction
from fixed-supply disposal. The launch is marked `Migrated` before returning the
payload; failure to redeem or consume it aborts the transaction and rolls the
state change back.

No `buy`, `sell`, `migrate`, or standalone version module is added. Pure curve,
fee-ledger, and graduation calculations remain package-only helpers.

## Verification

- Package-version mismatch aborts before launch lifecycle and economic checks.
- Ticket construction rejects a sell-burn rate above 5,000 bps. BurnOnly
  terminal supply destruction and Fixed terminal `0x0` disposal each conserve
  the complete Meme balance under their distinct native supply semantics.
- Buy and sell tests pin coin movement, slippage, fee accrual, reserves, and the
  threshold lifecycle transition.
- Migration tests prove witness binding, single use, Fixed conservation, and
  BurnOnly destruction through Coin Registry.
- Full lint, tests, coverage, and source-boundary checks remain mandatory.
