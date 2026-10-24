# 0084: Leverage coin design after the Perpsplexity review

- Status: proposed
- Date: 2026-09-16
- Extends: [0064](0064-aftermath-backed-leverage-coins.md),
  [0073](0073-series-one-adapter-owned-vaults.md),
  [0074](0074-aftermath-vault-activation-and-health.md)

## Sources

| Reference | Location |
| --- | --- |
| Perpsplexity bytecode and live state | [research record](../research/claude-fable-5-1-perpsplexity-comparison-2026-09-16.md) |
| Aftermath Perpetuals V2 | `0x3ec740df8428aa9c93aaef7f8cc1542ac3194fd014826b51bfe245346d64efc7`, the published-at of interface revision `f62e74a` |
| Aftermath documentation | docs.aftermath.finance, perpetuals architecture pages, read 2026-09-16 |

## Context

Perpsplexity launched on 2026-09-15 as a meme-coin launchpad whose pools are
backed by Aftermath perpetual positions. It is the closest live design to our
leverage coins and links the same Aftermath package. Its four packages are
immutable, so its bytecode is a complete statement of its design. The review
compared that design with ADRs 0064 to 0074 and with the current
`series_one` and `aftermath_adapter` sources.

Nothing in our packages is published, so layout and signature changes are
still free.

The leverage baseline this record amends is the reviewed and integrated
T-001/T-002 slice of the `blast-leverage` workflow, at commit `87357b9` on
`codex/native-dex-auto-lp`: one public maintenance band, the
`Uninitialized → Active → Unwinding → Settled` lifecycle with per-operation
data-validity predicates instead of a `ReduceOnly` state, fees split at
collection into the funding buffer and local admin cash, and one aggregate
net-funding checkpoint per synchronization (workflow decision A-002). `main`
does not yet carry that slice; the workflow's A-004 makes porting it the
first ticket.

## Decision

### D1. Keep the whole shareholder NAV and the reserve allocated as margin

Perpsplexity keeps 55% of NAV in the position, lends 44% on Suilend, and
holds 1% free, so a liquidation costs the pool at most the allocated part.
That split halves the liquidation distance at every leverage: at 2x with a 5%
maintenance ratio, 47% becomes 24%, and bankruptcy moves from a 50% gap to a
27.5% gap. Its protection matters only when the position is already bankrupt,
and it then pushes the bad debt onto Aftermath's insurance fund and the
opposite side of the market, which can include our own short Series.

Our defense against a fast move is the rebalance band and permissionless
emergency deleveraging at the hard cap, which act at 8% and about 17% from
target. Collateral held outside the position adds nothing in that regime and
weakens the position in every other. The reserve stays allocated for the same
reason: it is small, and as margin it extends the bankruptcy distance, while as
free balance it would only survive a wipe.

No lending sleeve. Suilend illiquidity blocks Perpsplexity's ordinary sells;
our redemptions must never depend on a third protocol's liquidity.

### D2. Adapter upgrade authority stays as ADR 0073 defines it

The adapter keeps the role-witnessed `authorize_upgrade`, the generation
cutover, and the three one-way ratchets `restrict_to_additive`,
`restrict_to_dependency_only`, and `make_immutable`. Disclosed custody
controls for the package-admin role remain the ADR 0064 release gate. An
on-chain delayed upgrade was proposed in this review and declined by founder
ruling on 2026-09-16.

Full adapter immutability stays rejected. Aftermath replaced its perpetuals
package after the 2026-04-29 exploit; an immutable adapter would answer such a
replacement only with shutdown.

### D3. Favorable execution accrues to existing holders

The credited mint contribution becomes
`min(nav_after - nav_before, deposit - fee)` and the redemption gross becomes
`min(nav_unwound, nav_before) - equity_keep`. A depositor never receives
shares for more than they paid, and a redeemer never receives more than their
proportional claim; any favorable difference between the two readings stays
with the remaining holders.

`max_mint_contribution_divergence_bps`, `max_redemption_gross_divergence_bps`,
their constructor guards, gates, and simulation selections are removed. Both
caps are exact and need no policy value. Non-dilution (I9, I10) still holds
because a smaller credit mints fewer shares and a smaller gross pays less. The
mint exposure range becomes `[delta(actual), delta(expected)]` because the
actual contribution can no longer exceed the expected one. On the baseline the
expected contribution is `deposit - protocol_fee`, the deposit less the admin
allocation retained locally and the buffer allocation credited to the reserve.

### D4. Funding is the venue's funding channel, socialized loss included

Aftermath documents that socialized bad debt is added to the funding rates of
opposing positions and settled at their next funding update. The baseline's
aggregate net-funding checkpoint (workflow decision A-002) already treats
socialized debt carried by the accumulator as part of the negative change that
the buffer absorbs before holder backing, and its classifier accepts only an
authenticated funding transition. This record confirms that rule with the
venue's own documentation and changes nothing. ADR 0064's earlier wording that
socialized loss can never be presented as funding is superseded by the
baseline and is not restored. The controlled-network evidence for premises P16
to P20 must include one reproduced socialized settlement.

### D5. Update funding before settling it

Every capture that settles funding first calls
`clearing_house::update_funding` when `market::is_time_to_update` holds for
the bound market, then `settle_position_funding`. Aftermath updates
cumulative rates lazily; without this call an idle market leaves accrued
funding out of NAV and out of the settlement the reserve absorbs. The
source-boundary gate pins the order.

### D6. Position IMR floor

The inverse-hard-cap choice below is superseded for the current source by the
conditional headroom budget in [ADR 0124](0124-margin-recovery-and-initial-headroom.md).

Premise P18 gains live evidence: Perpsplexity's 3x pool allocates exactly to
its configured per-position ratio through Aftermath's session
auto-allocation, so the ratio is settable and honored at open. Persistence
through a partial liquidation is still unproven. The adapter keeps setting the
floor at activation and rechecking it in every checkpoint. The selected value
is the inverse of the hard-cap leverage; a partial liquidation restores margin
to that ratio, which closes more of the position than the market default
would, and simulation must price that against the backstop's value.

## Alternatives considered

**On-chain 48-hour upgrade delay.** A pending digest with an execute-after
time, modelled on `acl`'s delayed root transfer, so holders could redeem
before new adapter bytecode takes custody. Declined by founder ruling; the
adapter's upgrade custody is unchanged.

**Curve pricing against the basket.** Rejected. Buyers pay above NAV and the
coin cannot serve as a quote asset with a known redemption value.

**Cash-backed exits while the venue is paused.** Rejected, as before. A
redemption paid from cash leaves the redeemer's exposure with everyone else
and breaks I11.

**Funding-coverage policy on chain.** Rejected. Projecting funding from
sampled rates, as Perpsplexity does, adds sampled state and bounds with no
enforcement value; the risk module can compute coverage from emitted
settlements off chain.

**Creator-launched markets and leverage.** Not decided here. The adapter can
issue more products through `Product<Tag>`, but each Vault carries an
immutable simulated policy, so a creator cannot pick a market or multiple
cheaply. Two products first.

**Hibernation.** Rejected. `ShutdownPending` and `ShutdownSettled` are the
only exits from exposure.

## Consequences

- `VaultPolicy` loses two fields; `policy` loses two constructors' guards, two
  assertions, two predicates, and the shared allowance helper;
  `accounting_math` caps the contribution and the gross inside the two
  canonical quotes.
- ADR 0064 I32 and the lessons file rules 1.3 and 1.12 are rewritten when
  this record is accepted; rule 1.12 keeps its transposition warning for
  `assert_mark_within_index_divergence` only. The baseline's ADR 0073 and
  0074 text on the aggregate funding checkpoint stands.
- The workflow specification carries these decisions as amendment A-004
  with requirements REQ-026 to REQ-028; its tickets T-003 to T-005 implement
  them.
- The open-from-flat primitive stays a launch gate. Perpsplexity's bytecode
  shows the failure mode it prevents: a liquidated pool that keeps minting
  against a position it never re-levers.
- Aftermath Perpetuals V2's OpenSec and Certora assessments are recorded as
  the audit-scope input to the ADR 0064 release gate; they do not close it.

## Verification

- Cap tests: a favorable fill credits exactly `deposit - fee`; a favorable
  unwind pays exactly the proportional claim; the property that remaining
  holders' NAV per share never falls holds across the exhaustive small-domain
  sweep with the caps in place.
- Source-boundary gate: `update_funding` precedes `settle_position_funding`
  in every capture path; no production caller references the removed
  divergence values.
- Evidence task: one controlled socialized-loss settlement classified as
  funding and absorbed by the reserve, recorded with the P16 to P20 fixtures.
