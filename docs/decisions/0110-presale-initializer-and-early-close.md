# 0110: Presale initializer, sale-level hard cap, and early close

- Status: proposed; amended by [0111](0111-venue-owned-presale-pool-tiers.md): `new` takes no
  pool tier
- Date: 2026-10-08
- Amends: [0099](0099-standalone-overflow-presale.md), whose sales were created by one
  `new` call, hard-capped only inside the uncapped phase, and always ran their full window;
  [0104](0104-external-presale-migrators-and-vendor-packages.md), whose vendor `new` created a
  sale in one call; and [0106](0106-presale-partners.md), whose `set_partner` acted on a pending
  sale

## Context

A hard-capped sale that fills its raise early cannot take more Quote, yet it could settle only at
the end of its window. A sale set for a week that filled in an hour held every buyer's Quote for
six more days with nothing left to happen. Some creators still want a fixed end so the pool goes
live at an announced time.

The hard cap was also a flag on the uncapped phase, so turning it on always lifted wallet caps. A
first-come, first-served sale with per-wallet caps could not be expressed.

`blast_presale::new` took 21 arguments, and the Cetus, Bluefin, and Aftermath vendor creators
each repeated them. Every new setting changed all four signatures, the SDK builders, and every
creation test.

## Decision

**Initializer.** Creation follows the launchpad's `LaunchInitializer`
([0089](0089-migrators-own-post-migration-and-start-launches.md)):

1. A migrator's `new` reserves what its venue needs, then calls `blast_presale::new` with the
   treasury cap, its witness, the creation and fee policies, and its pool tier. That checks the
   creation policy, the asset pair, and the zero supply, snapshots Blast's rates, and returns a
   `PresaleInitializer`. The initializer is a hot potato.
2. Setters on the initializer record the creator's terms: `set_supply`,
   `set_token_allocations`, `set_participant_vesting`, `set_raise`, `set_windows`,
   `set_eligibility`, `set_uncapped_phase`, `set_hard_cap`, `set_fee_split`, and `set_partner`.
   The setters only store values.
3. `finalize` runs every check the old `new` ran, plus the hard-cap bound, then mints and seals
   the supply. It emits `PresaleCreated` and returns the pending `Presale` and its `PresaleCap`.
   `share` is unchanged.

Missing settings fail at `finalize`:
- An unset supply, raise, or window is zero, so it fails the existing positivity checks
  (`EInvalidTokenAllocation`, `EInvalidRaiseTarget`, `EInvalidWindow`).
- An unset eligibility policy or LP-fee split has no meaningful default and aborts with
  `EMissingSetting`.

A partner is named only on the initializer, so `finalize` fixes it before the sale exists. The
pending sale no longer has a `set_partner`. `set_protocol_fees` still works on the pending or
not-yet-started sale.

The Aftermath vendor splits into `new`, which returns the initializer, and `finalize`, which:
- sets its treasury-only LP-fee split, overriding any split set earlier;
- finalizes the sale;
- binds the `PoolCreation`;
- sends the `PresaleCap` to the treasury.

Both functions need its `AdminCap`. The vendor's `finalize` rejects an initializer another
migrator started (`EWrongMigrator`), reading `blast_presale::migration_witness`, the initializer's
only public projection. A vendor sale finalized directly in `blast_presale` has no
`PoolCreation`, so it cannot migrate and refunds after its LP deadline.

**Sale-level hard cap.** `HardCap { starts_after_ms, closes_when_filled }` is a sale setting
independent of the uncapped phase. `UncappedPhase` loses its `hard_cap` flag and only lifts
wallet caps.

From `starts_after_ms` into the window, a commitment takes only what is left of the raise and
returns the excess. The commitment that exactly fills the raise may be below the minimum, and a
full sale rejects Quote with `EPresaleFilled`. Before then the sale overflows. `finalize` requires
`starts_after_ms < duration_ms` (`EInvalidHardCap`).

The offset covers each shape a creator needs:

| Offset | Sale shape |
| --- | --- |
| Zero | First-come, first-served within wallet caps for the whole window |
| The uncapped phase's offset | 0099's capped overflow round, then a first-come uncapped round |
| No hard cap | Overflow for the whole window |

**Early close.** `settle` also succeeds before the window's end once all of these hold:
- the sale's hard cap has `closes_when_filled`;
- the hard cap is in force;
- total commitments reach the raise.

At that point the sale can take no more Quote. Closing early shortens the stored `duration_ms` to
the time the sale ran, so the window's end and the LP deadline both count from the close.
`PresaleFunded` gains `end_ms` and `liquidity_deadline_ms`, and `PresaleOpened` gains
`hard_cap_from_ms`, so indexers never derive the close themselves.

A sale without a hard cap never closes early: later wallets may still join at the common fill
rate, and closing would turn the overflow into a race. A sale that overflowed past its raise
before its hard cap started may close once the hard cap starts.

## Alternatives considered

- **Always close when full.** This was rejected because creators who announce a pool time need
  a fixed end.
- **Close inside the filling commitment.** This was rejected because it leaves a second path,
  `settle`, for sales that filled before their hard cap started. One permissionless `settle`
  covers both cases, and the SDK already batches settle with migrate.
- **Keep the flag on the uncapped phase and add early close beside it.** This was rejected
  because it leaves first-come sales with wallet caps inexpressible.
- **Keep the single `new` and add more arguments.** This was rejected because every setting
  would again change four signatures.

## Consequences

- **Atomic first buy.** Migration is permissionless, so the wallet that fills an early-closing
  sale can commit, settle, migrate, and buy first in one transaction. The pool's seed price is
  the same as at a timed end; only who reliably buys first changes. Creators who care choose
  `closes_when_filled = false`.
- **ABI break.** `new`, the venue and vendor creators, `UncappedPhase`, `Presale`'s layout, and
  three events change, so the package needs a fresh publish. The 2026-10-04 publication stays
  on the old ABI. SDK builders, ABI fixtures, indexers, and creation flows must move together.

## Verification

The `blast_presale` unit tests cover:
- first-come fills within wallet caps;
- hard caps from the uncapped phase;
- the early close and its event deadlines;
- migration right after an early close;
- cancellation exactly one LP window after an early close, and the abort one millisecond
  before;
- the abort for a full sale that does not close when filled;
- the abort for a hard-capped sale short of its raise;
- the abort for an overflowing sale;
- a sale overfilled before its hard cap, which closes at the hard-cap start and not a
  millisecond before;
- a sale filled at its very start, which closes with a zero-length window;
- commitments rejected after a close;
- the hard-cap bound;
- the missing-setting aborts.

The vendor tests cover the split `new` and `finalize`, the overridden LP-fee split, and the
rejected foreign initializer. The source boundary gate pins `set_partner` to the initializer and
lets only `settle` shorten a sale's window.
