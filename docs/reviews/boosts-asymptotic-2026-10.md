# Blast Boosts audit response: Asymptotic, October 2026

Asymptotic reviewed the three Boosts packages (`blast_boosts_core`,
`blast_boosts_aftermath`, `blast_boosts_products`) at commit `b549bb16` on
`main` and reported 30 confirmed findings: 0 critical, 0 high, 9 medium, 12
low, 9 advisory. Their one-line conclusion: the share and fee arithmetic is
sound, and the risk sits where the adapter meets Aftermath and its own
parameters. Most findings deny service (a vault gets stuck) rather than move
value. One finding, M-6, lets an unprivileged caller take value from holders.

This document restates every finding in plain English, maps it to the
functions in the current source, says what the fix is, and splits the work
into one ticket per finding so it can be worked step by step. Line numbers
refer to the tree this document was written against; the audited commit is
not in this clone, but every cited function was re-read and the line numbers
drift by at most a dozen lines in `operations.move` and match exactly
elsewhere.

**Three findings were already changed on `main` after the audited commit**, by
commit `ecc7c2f` and [ADR 0115](../decisions/0115-venue-policy-from-the-bound-clearing-house.md)
(2026-10-14). The status column below reflects that. Everything else was
confirmed open in the current source.

The report's own claims about Aftermath behaviour (deallocation rules, limit
order semantics, fill pricing) come from the deployed venue bytecode, not from
code in this repository; those are repeated here as the auditors stated them
and marked as such.

## How Boosts works, in one page

Read this once; the tickets lean on these words.

- **Vault.** A shared object. It owns one isolated Aftermath account holding
  USDC and one perp position (long for a Bull, short for a Bear). Holders own
  Boost coins that are pro-rata claims on it.
- **NAV.** What all the shares are worth together: venue equity (collateral
  plus unrealized profit or loss) minus the maintenance reserve.
- **Maintenance reserve.** A buffer funded by mint and redeem fees. It sits in
  the venue account but is excluded from NAV. Funding costs eat the reserve
  first; only when it is empty do holders pay. Its size is capped at a share
  of the position's notional (the "ceiling").
- **Checkpoint.** A snapshot of raw venue facts (position, collateral,
  funding snapshots, orders, lot size). The adapter stores one. Before every
  priced operation it re-reads the venue and requires the live state to equal
  the stored checkpoint, or to differ only by a funding settlement it can
  explain. Any other difference is "drift": the operation aborts and the old
  checkpoint stays.
- **Leverage band.** Policy fixes `rebalance_below < target < rebalance_above
  < max_leverage`. Inside the band nothing happens. Outside it anyone can call
  `rebalance`. Above `max_leverage` (the hard cap) a reduction is an
  "emergency" and may fill under a wider slippage bound.
- **Orders.** Every trade is one or more whole-lot market orders, each at most
  `max_order_notional` USDC (a RiskAdmin knob). At most 16 orders per call.
  After each fill the adapter checks the fill size against the cap and the
  fill price against the oracle price plus the slippage bound.
- **Margin.** Aftermath requires margin at or above `notional × IMR` to open
  or to release collateral. The effective IMR is the larger of the market's
  IMR and the vault's own `position_imr`, which the issuer sets once at
  activation and can never change.
- **Reference gas price (RGP).** Ordinary `rebalance` calls refuse gas prices
  above RGP. Under ADR 0120, shutdown `unwind` and rebalances starting strictly
  above the hard leverage cap permit higher gas; holders pay the venue's
  configured priority trading fee on those fills.
- **Shutdown.** `begin_shutdown` (ShutdownAdmin) freezes mint and redeem. Then
  anyone can call `unwind` repeatedly to close the position, `finalize_shutdown`
  to pull the cash into the vault, and holders call `redeem_shutdown` to claim
  pro rata. It is irreversible.
- **Generation.** The adapter is upgradeable. Every entry point checks that the
  shared `Protocol` generation equals the compiled `PACKAGE_VERSION`.

Paths: "adapter" means `sui/boosts/aftermath_adapter/sources/`, "core" means
`sui/boosts/core/sources/`.

## Findings at a glance

“Resolved in source” records the project's implementation assessment and local
verification, not auditor sign-off or production readiness. M-4 and M-8 were
resolved in [PR #112](https://github.com/interest-protocol/blast-v2-contracts/pull/112)
under ADR 0119: 2,010 tests passed across the maintained packages, and all 626
core tests passed again after the helper rename at `a745fcc`. Their documented
recovery limits and live-exchange release gates remain.

M-9 is resolved in source through the accepted mitigation in
[PR #113](https://github.com/interest-protocol/blast-v2-contracts/pull/113)
and ADR 0120. It implements the auditor's recommended unwind exemption and
also exempts emergency rebalances. Ordinary-rebalance congestion is an
accepted residual risk. The 1,027 affected-package Move tests passed locally
at `3cf3cb4`; live priority execution and auditor sign-off remain outstanding.

| Ticket | ID | Severity | In one sentence | Status in current source |
| --- | --- | --- | --- | --- |
| 1 | M-1 | Medium | A venue event the checkpoint cannot explain blocks mint, redeem and rebalance for good | Resolved in source (ADRs 0115, 0121); RiskAdmin review and live recovery proof remain; M-5 is separate |
| 2 | M-2 | Medium | When the position has a big unrealized profit, every redemption aborts | Resolved in source through accepted mitigation (ADR 0122); margin/configuration limits and live execution proof remain |
| 3 | M-3 | Medium | Calling either `restrict_*` upgrade function makes the next upgrade freeze the whole adapter forever | Resolved in source (ADR 0123, PR #117); separate activation and repair access, no restriction paths; fresh-lineage and deployment limits remain |
| 4 | M-4 | Medium | A per-order cap worth less than one lot wedges every order path, shutdown included | Resolved in source (ADR 0119); ordinary-redemption recovery can require an administrator |
| 5 | M-5 | Medium | Once margin falls below the venue's opening requirement, the emergency rebalance that should fix it is refused | Open |
| 6 | M-6 | Medium | A caller can plant a bad quote and make `rebalance` or `unwind` fill into it at the full slippage bound, paid by holders | Atomic trading sequence blocked by [ADR 0118](../decisions/0118-limit-priced-vault-orders-and-a-widening-unwind-bound.md); price calibration and live venue proof remain |
| 7 | M-7 | Medium | Rotating or re-pointing an oracle feed freezes priced operations and the shutdown exit | Fixed (ADR 0115). Needs a regression test and a doc comment cleanup |
| 8 | M-8 | Medium | A cap-sized order aborts if it fills even slightly above the oracle price | Resolved in source (ADR 0119); live execution evidence remains a release gate |
| 9 | M-9 | Medium | Sustained above-RGP traffic on the shared objects can starve `rebalance` and `unwind` | Resolved in source through accepted mitigation (ADR 0120); ordinary-rebalance congestion remains an accepted risk |
| 10 | L-1 | Low | The live NVDA2L vault uses `min_order_lots = 1`, which makes the mint drift bound meaningless | Open (deployment parameter, plus a post-fill band check) |
| 11 | L-2 | Low | Converting the order cap to base can overflow and abort instead of saturating | Resolved in source with M-4/M-8 in PR #112 (ADR 0119) |
| 12 | L-3 | Low | A small vault below the band cannot rebalance when one lot overshoots target, and then cannot accept mints either | Open |
| 13 | L-4 | Low | Donated cash is never allocated to the position, so the core counts margin the venue does not see | Open |
| 14 | L-5 | Low | Activation accepts any non-negative `position_imr`, even one that later blocks operations inside the band | Open |
| 15 | L-6 | Low | An emergency rebalance that stops just under the cap can fail the minimum-improvement check and revert every time | Open |
| 16 | L-7 | Low | One single-key address holds all root, issuance and upgrade authority | Open (custody and deployment records) |
| 17 | L-8 | Low | Emergency rebalance is refused when the venue mark diverges from spot, even though it never uses the mark | Open |
| 18 | L-9 | Low | Increase rebalances check the hard cap against a reserve admitted at the opening notional, not the post-fill one | Open |
| 19 | L-10 | Low | Reductions are checked fill by fill on one reserve basis and completed on another, so a valid deleverage can revert | Open. Needs a decision |
| 20 | L-11 | Low | Once the position shrinks below one minimum order, nobody can redeem | Open. Must land before the next issuance |
| 21 | L-12 | Low | The funding-credit conservation check can overflow on a state that fits | Open |
| 22 | A-1 | Advisory | `ifixed_math::to_u64` is wider than its callers | Open |
| 23 | A-2 | Advisory | `needs_rebalance` prices post-settlement equity against the pre-settlement reserve | Open |
| 24 | A-3 | Advisory | `needs_rebalance` skips the venue-fee check `rebalance` enforces | Open |
| 25 | A-4 | Advisory | Settlement unwind adopts the venue checkpoint without booking funding | Partly fixed (ADR 0115): pause-mode mismatch gone; post-close funding still unbooked |
| 26 | A-5 | Advisory | Nothing in the type system forces a fill to be proven against the checkpoint | Open |
| 27 | A-6 | Advisory | The products package's UpgradeCap and Publisher are plain owned objects on the deployer key | Open |
| 28 | A-7 | Advisory | NAV above the cap can push the target notional past `u64` and abort increases | Open |
| 29 | A-8 | Advisory | `snapshot::capture` docs say a stale feed is reported, but it aborts | Open |
| 30 | A-9 | Advisory | Rebalance fills trust the order's direction, not the plan's | Open |

## Recommended order

This follows the auditors' summary, adjusted for what ADR 0115 already closed.

1. **Ticket 6 (M-6)** first. It is the only path where an unprivileged caller
   takes value from holders, and it can recur.
2. **Make shutdown a dependable backstop**, shipped together: tickets 8 (M-8),
   4 (M-4), 9 (M-9), plus the regression test in ticket 7 (M-7). After these,
   `unwind` and `finalize_shutdown` survive cap-sized close orders, a sub-lot
   order cap, above-RGP traffic and a feed rotation.
3. **Choose the position IMR once**: tickets 2 (M-2), 5 (M-5) and 14 (L-5)
   constrain the same parameter and must be designed together.
4. **Ticket 16 (L-7)**: move root and upgrade authority off the single key.
5. **Ticket 3 (M-3)** is resolved in source under ADR 0123. Follow its
   two-transaction runbook. The current source removes both restriction paths;
   historical deployed lineages still require their own upgrade-policy review.
6. The rebalance arithmetic cluster: tickets 15 (L-6), 18 (L-9), 19 (L-10),
   12 (L-3), 30 (A-9), 28 (A-7).
7. Everything else in any order. Ticket 20 (L-11) must land before another
   vault is issued because `min_order_lots` and the lot size are fixed at
   issuance.

Whatever reverts, the auditors proved that a successful mint or redemption
never dilutes the remaining holders.

## Already handled since the audited commit

Commit `ecc7c2f` ("read venue policy and oracle routing from the bound clearing
house", ADR 0115) changed three things the audit relies on:

- The checkpoint classifier now copies the pause mode, frozen flag and both
  market margin ratios from the live clearing house before comparing
  ([checkpoint::with_venue_policy_of](../../sui/boosts/aftermath_adapter/sources/checkpoint.move#L355)).
  This closes the first trigger of M-1 (Aftermath re-tunes margin ratios) and
  the "before the close" half of A-4 (the pause-mode mismatch).
- The `Binding` no longer stores oracle feed origin ids. Each capture checks
  the storages it is given against the clearing house's current parameters
  ([venue_account::assert_market_oracles](../../sui/boosts/aftermath_adapter/sources/venue_account.move#L70)),
  and the `oracle_feed_mismatch` error is gone. This closes M-7.
- The lot size is still compared exactly, by decision: a venue-side lot change
  is still reported as drift.

Two leftovers from that change belong in tickets 1 and 7: the doc comment on
`Binding` ([venue_account.move:13](../../sui/boosts/aftermath_adapter/sources/venue_account.move#L13))
still says the two feed ids are bound, and there is no regression test for a
feed re-point surviving the shutdown exit.

## Medium findings

### Ticket 1 · M-1 · A venue event the checkpoint cannot explain blocks the vault for good

**Status:** resolved in source by ADRs 0115 and
[0121](../decisions/0121-reviewed-recovery-after-a-forced-venue-reduction.md).
A RiskAdmin-reviewed same-side reduction or full close can adopt the live
checkpoint; ordinary synchronization remains fail-closed. The implementation
adopts the auditor's gated-rebaseline recommendation, with three explicit
extensions: realized gains are accepted as well as losses, locally proven
funding is booked separately, and recording recovery requires no opening-margin
headroom. Fresh Fable review found no blocking source issue; see the
[review record](boosts-m1-recovery-2026-10-24.md).
RiskAdmin must verify the cause, and real venue-event/recovery execution remains
a release gate. M-5's independent restriction on reducing trades is unchanged;
shutdown remains available. This is source resolution, not Asymptotic sign-off,
a live NVDA fix or a claim that every distressed vault can resume trading.
The historical finding and recommendation below are preserved.

**The problem.** Before every mint, redeem, rebalance or donate the adapter
re-reads the venue and insists the live state equals the stored checkpoint,
allowing only a funding settlement in between. If anything else moved, it
aborts and keeps the old checkpoint. Nothing outside shutdown ever adopts the
new state. So one persistent, unexplained change blocks all four operations
forever. The audit named two ordinary causes: Aftermath re-tuning the market's
margin ratios (now handled) and the vault's account being liquidated or
auto-deleveraged (still not handled). After a liquidation, holders cannot
exit except through the irreversible shutdown path.

**Where it is.**

- [operations::synchronize_or_fail](../../sui/boosts/aftermath_adapter/sources/operations.move#L859)
  runs before every priced operation and aborts with `unresolved_checkpoint`
  unless the stored checkpoint equals the live one.
- [operations::apply_post_capture](../../sui/boosts/aftermath_adapter/sources/operations.move#L776)
  adopts a new checkpoint only when the change is clean; otherwise it emits
  `CheckpointDrifted` and keeps the old one.
- [checkpoint::classify_preexisting](../../sui/boosts/aftermath_adapter/sources/checkpoint.move#L184)
  decides what counts as clean. Position, collateral, orders, funding
  snapshots and lot size must match exactly.
- [operations::needs_rebalance](../../sui/boosts/aftermath_adapter/sources/operations.move#L311)
  applies the same check.

**The fix.** Give a legitimate, persistent venue change a non-terminal way to
be reconciled, while still failing closed on drift nobody has looked at. The
auditors offered two routes; the second is the one that covers liquidation:

- Add a gated re-baseline. A `RiskAdmin` call (new public function in
  `operations`, say `rebaseline`) that captures the live venue, checks the
  deltas are explainable as a venue-side position change (position shrank or
  went flat, collateral fell, no resting orders, funding snapshots refreshed),
  adopts the drifted checkpoint, re-prices NAV from it and emits an event
  naming the old and new checkpoints. Mint, redeem and rebalance then work
  again on the new basis.
- Keep `synchronize_or_fail` as it is: ordinary callers still cannot build on
  drift.

**Touch.** `operations` (new `rebaseline`, and `apply_post_capture` if the
re-baseline reuses it), `checkpoint` (a classifier for the liquidation shape),
`events` (new event), `vault` (role gate). Amend ADR 0115 to say what the
re-baseline admits.

**Tests.** A liquidation fixture: after it, `mint` aborts with
`unresolved_checkpoint`; after `rebaseline`, `mint`, `redeem` and `rebalance`
succeed on the new position; `rebaseline` refuses a checkpoint whose free
collateral or orders changed in a way the liquidation shape does not explain.

### Ticket 2 · M-2 · Big unrealized profit makes every redemption abort

**Status:** resolved in source through the accepted mitigation under [ADR 0122](../decisions/0122-bounded-profit-realization-before-redemption.md) and [PR #116](https://github.com/interest-protocol/blast-v2-contracts/pull/116).
The redemption path checks the venue's cash budget and refuses an unpaid claim
with a named error. Separate permissionless maintenance closes and reopens a
bounded amount to realize gains before a fresh redemption quote, preserving the
original position and full proportional payout. Both fills must complete, stay
within existing price/cap limits, and improve cash by more than their cost.
Preflight rejects a cash gap that cannot fit within profit minus a full-position
cost allowance. This adopts the auditor's cash-check and profit-realization
options; separating maintenance from redemption is the implementation refinement.

This closure records completion of the chosen source remediation, supported by
1,125 passing Move tests, 40 tooling tests and the final independent Fable review.
It is not universal withdrawal liveness or original-auditor sign-off. Opening
margin and the position IMR/haircut choice (M-5 and L-5), economical two-sided
liquidity, cap capacity and fresh prices still matter. Several capped calls may
be needed; later calls can be refused as costs consume headroom. If the unchanged
position cannot be supported after profit is realized, new collateral, reduced
exposure or shutdown is needed. Controlled live execution remains a release gate.
The historical finding and recommendations below are preserved.

**The problem.** A redemption is priced on the vault's full equity, profit
included, and paid by asking Aftermath to release collateral. Aftermath only
releases collateral down to the position's initial-margin floor, and when it
computes free collateral it counts unrealized profit only when it is negative.
So the payout includes the profit, but the budget it is paid from does not.
Once `collateral × (1 − haircut) < notional × IMR`, the venue refuses (its
code 40) and the redemption reverts at any size. The reduce-only sell only
realizes the redeemed fraction of the profit, so selling first does not close
the gap. No attacker is needed: a favourable price move plus the ordinary
`rebalance` back to target gets there. With the position IMR at the inverse
of the hard cap (ADR 0084 D6), a 2x vault enters the window at roughly +12.5%
on the underlying for a 2.5x cap. Every holder is refused exactly when they
most want to exit. No funds are lost; a new mint, a donation, a price reversal
or the admin shutdown restores payouts.

**Where it is.**

- [operations::redeem](../../sui/boosts/aftermath_adapter/sources/operations.move#L122)
  prices on the post-sell observation, then withdraws `net + admin`.
- [venue_account::withdraw](../../sui/boosts/aftermath_adapter/sources/venue_account.move#L198)
  calls the venue's `deallocate_collateral` for whatever free cash does not
  cover and requires the exact amount back.
- [snapshot::position_economics](../../sui/boosts/aftermath_adapter/sources/snapshot.move#L185)
  computes `margin_safe` from the venue's margin figure, which includes the
  profit, so the adapter's own gate does not catch this.

**The fix.** The redemption path must be able to pay what it prices, so a
redemption admitted by `prepare_redemption` cannot fail at deallocation.

- Minimum: before withdrawing, compute what the venue will release from the
  post-sell checkpoint (free collateral plus the deallocatable part of
  allocated collateral under the effective IMR and haircut) and abort with a
  named adapter error (`redemption_exceeds_releasable`) when `net + admin`
  exceeds it. Same outcome, but a clear error instead of a venue code.
- Better: close the window at the source by choosing the position IMR with
  headroom (ticket 14) and by realizing enough profit into position collateral
  before the withdrawal, or bounding the payout by what the venue releases.
  Which of these is acceptable is a product decision: bounding the payout
  changes what a redeemer receives.

**Touch.** `operations::redeem`, `venue_account::withdraw`,
`snapshot::position_economics` (expose the releasable amount), new error in
adapter `errors`, the position IMR chosen at activation.

**Tests.** A fixture with profit past the window: `redeem` aborts with the
named adapter error rather than the venue's; a fixture just inside the window
still pays in full.

### Ticket 3 · M-3 · Restricting the upgrade policy makes the next upgrade freeze the adapter forever

**Status:** resolved in source in [PR #117](https://github.com/interest-protocol/blast-v2-contracts/pull/117); see accepted [ADR 0123](../decisions/0123-successor-activated-boosts-upgrades.md). Commit and successor activation are separate, repair authorization is version-independent, and the adapter no longer exposes policy narrowing. Deliberate difference: `make_immutable` retains the current-generation check. Verification includes 459 adapter tests, 3 composition tests and 33 localnet transactions; fresh Fable review confirmed the source remediation with no production defect. This is a fresh-lineage fix: it cannot remove unsafe historical bytecode, activation only proves version agreement, and live venue/holder-exit verification remains a deployment gate. The historical finding and recommendation below are preserved; this is not original-auditor sign-off or a deployment claim.

**The problem.** Every upgrade ends with `commit_upgrade_and_advance`, which
moves the shared generation from 1 to the compiled `NEXT_PACKAGE_VERSION` of
2. Afterwards every entry point passes only if the installed bytecode was
compiled with `PACKAGE_VERSION = 2`. Nothing checks that the successor
actually was. Two things break it:

- After either `restrict_*` call, the next upgrade cannot change the constant
  inlined into `assert_current`: dependency-only permits only relinks,
  additive forbids changing existing function bodies. The relink advances the
  generation and the bytecode still says 1.
- Under any policy, a successor built with the wrong `PACKAGE_VERSION`, or
  without bumping `NEXT_PACKAGE_VERSION`, leaves the same mismatch.

Then every generation-gated entry aborts: mint, redeem, redeem_shutdown,
withdraw_admin_fees, begin_shutdown, and `authorize_upgrade` itself, so no
repair upgrade can be authorized. The collateral in every vault becomes
permanently unreachable, shutdown included. A test in the audit reproduces
the restriction branch. The trigger is a privileged action or a mis-built
upgrade, not a permissionless call.

**Where it is.**

- [package_admin::commit_upgrade_and_advance](../../sui/boosts/aftermath_adapter/sources/package_admin.move#L60)
  commits the receipt and advances in one call.
- [package_admin::restrict_to_additive](../../sui/boosts/aftermath_adapter/sources/package_admin.move#L73)
  and [package_admin::restrict_to_dependency_only](../../sui/boosts/aftermath_adapter/sources/package_admin.move#L84).
- [package_admin::authorize_upgrade](../../sui/boosts/aftermath_adapter/sources/package_admin.move#L45)
  and [package_admin::make_immutable](../../sui/boosts/aftermath_adapter/sources/package_admin.move#L95)
  both call `assert_current` first, so they are unreachable once the
  generation is wrong.
- [blast_boosts_aftermath::assert_current](../../sui/boosts/aftermath_adapter/sources/blast_boosts_aftermath.move#L51),
  [assert_next](../../sui/boosts/aftermath_adapter/sources/blast_boosts_aftermath.move#L56),
  [advance](../../sui/boosts/aftermath_adapter/sources/blast_boosts_aftermath.move#L61),
  and the two constants at lines 21 and 24.

**The fix.** The generation must only advance to a value the installed
bytecode satisfies, and upgrade authorization must stay reachable if it does
not.

- Preferred: move the advance out of `commit_upgrade_and_advance` into a
  successor-side activation function. The new bytecode calls it after the
  upgrade; it checks `generation + 1 == PACKAGE_VERSION` of the code that is
  running, then advances. A mis-built successor can never advance the
  generation, and the old bytecode keeps serving until it does.
- Make `authorize_upgrade` and `make_immutable` independent of
  `assert_current`, so a repair upgrade is always possible.
- Remove both `restrict_*` functions, as the auditors note the launchpad and
  migrators packages already do.

**Touch.** `package_admin` (split commit from advance, drop the two restrict
functions, drop `assert_current` from the two custody calls),
`blast_boosts_aftermath` (activation that reads its own compiled version),
deployment runbook in `deployments/README.md`. Record it as an ADR since it
changes the upgrade decision.

**Tests.** Upgrade then activate from the right version succeeds; activate
from the wrong version aborts and the old generation keeps serving;
`authorize_upgrade` works while the generation is mismatched.

### Ticket 4 · M-4 · A per-order cap below one lot wedges every order path

**Status:** resolved in source with M-8 under the ADR 0119 closing exception and recovery limits; see [ADR 0119](../decisions/0119-execution-priced-order-caps-and-minimum-lot-closes.md). Seed and cap updates validate live capacity for the minimum proportional operation. Opening orders remain strictly capped. Closing orders admit exactly one live lot above the cap, still under the execution-price bound. Ordinary redemption can still exceed the 16-order budget after price or lot growth; raising the cap or administrator-triggered shutdown followed by repeated permissionless unwind calls is required. The historical finding and auditor suggestions below are preserved.

**The problem.** `max_order_notional` is a RiskAdmin knob in atomic USDC. Any
positive value is accepted, in any lifecycle state, with no delay. But every
order is sized in whole lots at the live oracle price, and if the cap is worth
less than one lot the derived order size is zero and the order loop aborts
with `fill_mismatch`, which looks like a real fill problem. The zero floor is
reachable three ways: a unit mistake (typing 250 meaning 250 USDC gives 250
atoms), a base price rise under a cap set just above one lot, or Aftermath
raising the lot size. While it holds, nobody can mint, redeem, rebalance or
unwind; after `begin_shutdown` the exit is blocked too. A related case: a cap
too small for one call's 16 orders to cover `min_order_lots` lots aborts every
non-flat redemption.

**Where it is.**

- [vault::set_max_order_notional](../../sui/boosts/aftermath_adapter/sources/vault.move#L200)
  and [state::set_max_order_notional](../../sui/boosts/core/sources/state.move#L787)
  accept any positive value.
- [state::max_order_base](../../sui/boosts/core/sources/state.move#L259),
  [state::seed_terms](../../sui/boosts/core/sources/state.move#L163) and
  [state::unwind_constraints](../../sui/boosts/core/sources/state.move#L696)
  derive the whole-lot size, which floors to zero.
- [orders::active_order_size](../../sui/boosts/aftermath_adapter/sources/orders.move#L368)
  aborts on `max_order_base == 0` with `fill_mismatch`; the seed path's
  [orders::order_sizes](../../sui/boosts/aftermath_adapter/sources/orders.move#L321)
  aborts with its own code.

**The fix.** Bound the per-order size where it is computed, not only in the
setter, because price and lot size change under a fixed cap.

- Clamp the derived order size up to at least one lot in `max_order_base`,
  `seed_terms` and `unwind_constraints`. Note the interaction with ticket 8:
  a one-lot order can then exceed the cap in notional, so the post-fill cap
  check must admit at least one lot too.
- Or validate against a live floor of `lot_size × min_order_lots` worth of
  collateral, which also covers the 16-order budget case.
- Also validate the setter before writing (as `set_nav_cap` does), ideally
  with a short delay; document the atomic-collateral unit; and raise a
  distinct error for a zero per-order size instead of `fill_mismatch`.

**Touch.** `state::max_order_base`, `state::seed_terms`,
`state::unwind_constraints`, `state::set_max_order_notional`,
`orders::active_order_size`, a new core error.

**Tests.** With a cap below one lot, mint, redeem and unwind still trade one
lot; the setter rejects a value that cannot cover one minimum order at the
current price.

### Ticket 5 · M-5 · Below the opening margin, the emergency rebalance that should fix it is refused

**Status:** open. Design together with tickets 2 and 14.

**The problem.** Every priced path, including `rebalance` and its fills,
`donate`, `mint` and `redeem`, builds its observation through
`into_observation`, which aborts with `venue_not_ready` whenever the venue's
margin is below the opening requirement (`notional × mark × max(position IMR,
market IMR)`). The core plans an emergency reduction exactly when leverage is
above the hard cap, but the adapter refuses to produce the observation that
reduction needs once margin drops below the opening bound. With the position
IMR set to the inverse of the hard cap (ADR 0084 D6), those two bounds sit on
the same line, so the emergency path is refused the moment it is needed. The
venue itself would accept a reducing trade. The only remedy left is the
irreversible shutdown.

**Where it is.**

- [snapshot::into_observation](../../sui/boosts/aftermath_adapter/sources/snapshot.move#L117)
  requires `margin_safe`.
- [snapshot::position_economics](../../sui/boosts/aftermath_adapter/sources/snapshot.move#L185)
  computes it with the effective IMR.
- [operations::rebalance](../../sui/boosts/aftermath_adapter/sources/operations.move#L270)
  and [operations::donate](../../sui/boosts/aftermath_adapter/sources/operations.move#L337)
  go through it. [state::prepare_rebalance](../../sui/boosts/core/sources/state.move#L501)
  decides `emergency`.
- [operations::assert_position_imr](../../sui/boosts/aftermath_adapter/sources/operations.move#L512)
  checks only the sign at activation.

**The fix.** Deleveraging must stay possible on a venue that is only below the
opening margin requirement.

- Let the emergency (reduce-only) rebalance step and `donate` proceed below
  the opening margin, gated on the weaker conditions the shutdown path already
  uses: not paused, no pending orders, feeds bound. In practice: split
  `into_observation` into the strict priced form and a reducing form without
  the margin gate, and let `rebalance` fall back to the reducing form only
  when the plan is a reduction.
- Independently, at issuance require the effective initial-margin floor to
  leave headroom over `max_leverage_bps` instead of equalling its inverse. No
  module holds both values today, so this needs a public core predicate next
  to the policy validation, or `position_imr` passed into the core issuance
  terms (ticket 14).

**Touch.** `snapshot::into_observation`, `operations::rebalance`,
`operations::donate`, `operations::initialize`, core `policy`.

**Tests.** Margin just below the opening requirement: emergency rebalance
places its reducing order; `mint` still refuses; `donate` succeeds.

### Ticket 6 · M-6 · A caller can make `rebalance` and `unwind` fill into a planted quote

**Status:** the audited atomic trading sequence is blocked by
[ADR 0118](../decisions/0118-limit-priced-vault-orders-and-a-widening-unwind-bound.md):
private entry maintenance shares the clearing house internally, blocking the
audited trading-session handoff and subsequent reuse; every order is an
immediate-or-cancel limit order priced inside its bound before placement,
an emergency reduction sells only what restores the hard
cap, and a shutdown close starts at the ordinary bound and widens to the
emergency bound over a day. Cross-transaction manipulation and liquidity
already on the book remain bounded price risks. Per-issuance bound calibration
and live venue fill evidence remain open. The description below is the finding
as audited.

**The problem.** `rebalance` is permissionless and takes no price or size. Its
orders go to the venue as unpriced market orders, and the only price check
runs after the fill: any average price within `max_slippage_bps` of the oracle
is accepted, or within `emergency_max_slippage_bps` when the plan began above
the hard cap. The next order is predictable from state and the oracle,
`rebalance` takes the shared `ClearingHouse` by value, and the venue's public
trading calls return it. So in one transaction a caller can take the better
liquidity off the book, rest their own quote sized to the vault's order just
inside the bound, and then call `rebalance` against it. No gate inspects the
book. The same holds for `unwind`, where every close order runs under the
emergency bound, repeated until flat. Holders alone bear the loss: the fill
comes out of NAV and the caller stakes nothing. Per call the loss is at most
the bound times the executed notional over up to 16 cap-sized orders. The
deployed NVDA2L policy sets 30 bps ordinary and 100 bps emergency, and the
policy is immutable, so only an adapter upgrade can tighten it.

**Where it is.**

- [orders::place_order](../../sui/boosts/aftermath_adapter/sources/orders.move#L406)
  is the shared fix point: it calls
  [venue_account::execute_order](../../sui/boosts/aftermath_adapter/sources/venue_account.move#L152),
  which places a `place_market_order` with no price, then checks the fill
  with [state::assert_execution](../../sui/boosts/core/sources/state.move#L271).
- [state::next_rebalance_order](../../sui/boosts/core/sources/state.move#L513)
  sizes the emergency order to the full cap and the whole order is judged
  under the wide bound.
- [orders::close_orders](../../sui/boosts/aftermath_adapter/sources/orders.move#L199)
  hard-codes `emergency = true` for every shutdown order.
- [operations::assert_gas_price](../../sui/boosts/aftermath_adapter/sources/operations.move#L638)
  is the only other gate, and it does not look at the book.

**The fix.** The accepted slippage must not be a price the composer chooses.

- Rebalance: fix each order's price limit before placement, well inside the
  policy guard, by placing a limit order at `oracle × (1 ± tight bound)` with
  immediate-or-cancel semantics instead of an unpriced market order. The
  vendored interface exposes `clearing_house::place_limit_order` with a
  price and an order type. Keep `assert_execution` as the outer guard. Apply
  the emergency bound only to the notional needed to get back under the hard
  cap, not to a full cap-sized order.
- Unwind: enforce a caller-independent bound tighter than the emergency band,
  and keep the wide band only as an eventual liveness fallback, for example a
  bound that widens with time since `begin_shutdown`, or a keeper-only window
  before `unwind` becomes permissionless.
- Set both bounds near venue costs at issuance. Vaults already issued with
  wide bounds need the adapter upgrade to enforce the tighter bound.
- Alternatively restrict callers, which trades the permissionless property
  for safety; the limit-price route keeps it.

**Touch.** `orders::place_order`, `venue_account::execute_order_with_cap`
(limit order plumbing), `state::next_rebalance_order`, `orders::close_orders`,
possibly `policy::new_rebalance_policy` for a new bound, and an ADR amending
0084.

**Tests.** A resting quote at the bound: `rebalance` either fills inside the
tight limit or makes no progress, never at the planted price; the emergency
order stops at the cap; unwind under a widening bound.

### Ticket 7 · M-7 · Oracle feed rotation freezes priced operations and the shutdown exit

**Status:** fixed on `main` by ADR 0115. Remaining work is a regression test
and a comment cleanup.

**The problem as reported.** At the audited commit every capture required the
origin objects of the market's price feeds to equal ids stored in the vault's
`Binding` at activation, and the binding had no setter. Aftermath rotating a
feed, the venue operator re-pointing a market's oracle source, or a feed
re-created under a new origin would abort every capture, including the
terminal-path capture used by `unwind_settlement` and `finalize_shutdown`,
which needs no live price. Holder collateral would stay in the venue account
until an adapter upgrade.

**What changed.** The `Binding` now holds only the account, registry and
clearing house ids. Each capture checks the storages it is handed against the
clearing house's current storage ids
([venue_account::assert_market_oracles](../../sui/boosts/aftermath_adapter/sources/venue_account.move#L70))
and reads the feed at the market's current source id
([snapshot::capture](../../sui/boosts/aftermath_adapter/sources/snapshot.move#L77)).
The terminal path
([snapshot::capture_checkpoint](../../sui/boosts/aftermath_adapter/sources/snapshot.move#L45))
reads no feed at all. A removed feed still aborts the live-price `capture`,
which is fail-closed and intended.

**The fix.** Close the ticket with evidence:

- Add a regression test: re-point the market's base oracle source (new
  storage, new source id), then `mint`, `unwind_settlement` and
  `finalize_shutdown` succeed.
- Correct the stale doc comment on `Binding`
  ([venue_account.move:13](../../sui/boosts/aftermath_adapter/sources/venue_account.move#L13)),
  which still says the two feed ids are bound.
- Tell the auditors the finding is resolved by `ecc7c2f`.

### Ticket 8 · M-8 · Cap-sized orders abort on any fill above the oracle price

**Status:** resolved in source with M-4; see [ADR 0119](../decisions/0119-execution-priced-order-caps-and-minimum-lot-closes.md). Every sizing site reserves its actual execution bound and sell-rounding headroom. The harness prices actual filled quote and checks unwind fills. Local regressions cover both directions and the narrow closing exception. Live venue execution evidence remains a release gate. The historical finding and auditor suggestions below are preserved.

**The problem.** Each order is sized to the largest whole-lot base worth at
most `max_order_notional` at the oracle price, with no slippage discount.
After the fill, the adapter reprices the fill at the executed quote and checks
it against the same cap, before the slippage gate runs. The only headroom is
the sub-lot remainder from flooring, which is about 0.0009 to 0.09 bps on the
NVDA2L policy against 30 bps of ordinary and 100 bps of emergency slippage. A
cap-sized order that fills even 1 bp above the oracle aborts with
`order_notional_exceeds_maximum`, although the slippage policy would accept
it. No loop retries smaller, and changing the cap does not help because the
slack is at most one lot at any cap. Anyone can trigger it through `mint` and
`redeem`; rebalance and unwind hit it too. The sharp case is shutdown: a short
vault's close orders are full-cap bids under the emergency bound, so on a
dislocated book every close aborts before the emergency bound is even
consulted, `unwind` makes no progress and holders cannot withdraw. For users,
one mint or redemption is effectively limited to a bit less than one order,
contradicting the stated design that the cap does not limit deposits.

**Where it is.**

- [state::max_order_base](../../sui/boosts/core/sources/state.move#L259) and
  [state::unwind_constraints](../../sui/boosts/core/sources/state.move#L709)
  size with [rebalance_math::base_for_oracle_notional_down](../../sui/boosts/core/sources/lib/rebalance_math.move#L33)
  at the oracle price; [state::seed_terms](../../sui/boosts/core/sources/state.move#L173)
  and the headroom in [rebalance_math::increase_base_down](../../sui/boosts/core/sources/lib/rebalance_math.move#L69)
  do the same.
- [orders::place_order](../../sui/boosts/aftermath_adapter/sources/orders.move#L432)
  checks the executed notional with
  [state::assert_order_notional_allowed](../../sui/boosts/core/sources/state.move#L264)
  one line before [state::assert_execution](../../sui/boosts/core/sources/state.move#L271).
- [orders::close_orders](../../sui/boosts/aftermath_adapter/sources/orders.move#L199)
  closes with full-cap orders under the emergency bound.

**The fix.** Make per-order sizing and the post-fill notional check agree on
the slippage the policy admits, at every sizing site. Either:

- size each order to `max_order_notional` reduced by the slippage bound of its
  execution gate (ordinary or emergency); or
- check the fill against the cap widened by that same bound.

The first keeps the "no order exceeds the cap" invariant exact and is the
safer choice. Also change the core test adapter to price fills at the
executed quote, and make the shutdown harness run the notional check on the
unwind path so the emergency close is covered.

**Touch.** `state::max_order_base`, `state::seed_terms`,
`state::unwind_constraints`, `rebalance_math::increase_base_down`,
`state::assert_order_notional_allowed`, `orders::place_order`, the core test
adapter and the shutdown test harness.

**Tests.** A cap-sized order filled 1 bp above the oracle succeeds; a fill
beyond the slippage bound still aborts; unwind on a book trading above the
index makes progress.

### Ticket 9 · M-9 · Above-RGP traffic can starve `rebalance` and `unwind`

**Status:** resolved in source through the accepted mitigation under [ADR 0120](../decisions/0120-priority-gas-for-emergency-reductions-and-unwind.md) and [PR #113](https://github.com/interest-protocol/blast-v2-contracts/pull/113). Shutdown unwind and rebalances whose authenticated starting leverage is strictly above the hard cap admit priority gas. Ordinary rebalances retain the restriction and can still be delayed; this is an accepted residual risk under the auditor's recommended policy. Holders accept the venue's configured extra trading fee for those emergency or shutdown fills; all price, sizing and progress checks remain. This status records completion of the chosen source remediation, not elimination of all congestion risk or auditor sign-off. Local admission tests do not prove live priority execution, which remains a release gate. The historical finding and auditor options below are preserved.

**The problem.** `rebalance` and `unwind` abort any transaction priced above
the reference gas price so Aftermath's priority taker fee never lands on
holders. Under Sui's local fee market, writers to a congested shared object
are ordered by gas price, so any above-RGP writer goes first. The `Vault` and
the market `ClearingHouse` have permissionless, uncapped writers:
`sync_health`, `donate`, `mint`, `redeem` on the vault, and Aftermath's own
`update_twaps`, `update_funding`, `settle_position_funding`,
`donate_to_insurance_fund` on the clearing house. Sustained above-RGP traffic
therefore defers or cancels `rebalance` and `unwind`, and nobody can outbid it
because the cap reads the whole transaction's gas price. Shutdown is the sharp
case: only `unwind` flattens the position, at most 16 orders per call, so a
large position needs several capped transactions while `sync_health` stays
uncapped. While an attacker pays priority gas on every commit, holder
collateral cannot be withdrawn by any path. No value is extracted and exit
resumes when the traffic stops.

**Where it is.**

- [operations::assert_gas_price](../../sui/boosts/aftermath_adapter/sources/operations.move#L638).
- Called from [operations::rebalance](../../sui/boosts/aftermath_adapter/sources/operations.move#L283)
  and [operations::unwind](../../sui/boosts/aftermath_adapter/sources/operations.move#L409).

**The fix.** Decide whether maintenance and shutdown close-out should yield to
above-RGP traffic, fixing the shutdown path first because `unwind` gates every
holder's exit. Options, from the auditors:

- Remove the cap from `unwind` (and `rebalance`) and accept the priority-fee
  pass-through to holders.
- Keep the cap on `rebalance` and exempt `unwind`. This is the smallest change
  that unblocks the exit, and is the recommended default.
- Add an admin- or keeper-authorised uncapped close-out variant.

If the cap stays anywhere, document that those calls yield to above-RGP
traffic. Capping `sync_health` alone is insufficient because the clearing
house writers are outside this protocol.

**Touch.** `operations::unwind`, possibly `operations::rebalance`,
`docs/llms/boosts.md`, and an ADR line recording the decision.

**Tests.** `unwind` at a priority gas price succeeds (if exempted);
`rebalance` at a priority gas price still aborts.

## Low findings

### Ticket 10 · L-1 · The live vault's one-lot minimum voids the mint drift bound

**Status:** open. Mostly a deployment parameter; one code change.

**The problem.** Each mint rounds its added base down to whole lots, so a mint
can leave up to one lot of its target unopened. ADR 0064 I26 turns this into
a bounded cumulative leverage drift only through `min_order_lots`. The
deployed NVDA2L vault runs `min_order_lots = 1`, a value no simulation in the
repository selects, so the drift cap is not enforced. At seed scale about 100
public one-lot mints move accounting leverage from 2.00x to the 1.8x band
edge. The caller gains nothing (shares are priced at NAV); every holder just
carries lower leverage until a rebalance. The only backstop is the pre-trade
band check in `prepare_mint`; `complete_mint` checks only the hard cap after
the fill.

**Where it is.**

- [accounting_math::mint_base_to_buy_down](../../sui/boosts/core/sources/lib/accounting_math.move#L226).
- [state::prepare_mint](../../sui/boosts/core/sources/state.move#L292) band
  gate before the trade; [state::complete_mint](../../sui/boosts/core/sources/state.move#L365)
  checks only the hard cap after.

**The fix.**

- For any successor vault, select `min_order_lots` from the I26 simulation
  before issuance and reject policies whose cumulative drift bound is vacuous.
  Record the chosen value in the deployment record.
- Enforce the leverage band after the fill in `state::complete_mint`, not
  only before the trade, so no single mint can leave the band the policy
  promises.

**Tests.** A mint whose rounded order would leave the band aborts in
`complete_mint`.

### Ticket 11 · L-2 · Cap-to-base conversion aborts on overflow instead of saturating

**Status:** resolved in source by [PR #112](https://github.com/interest-protocol/blast-v2-contracts/pull/112) and [ADR 0119](../decisions/0119-execution-priced-order-caps-and-minimum-lot-closes.md). Cap conversion rounds in wide arithmetic and saturates to the largest representable whole-lot base before narrowing. Regressions cover maximum caps and low prices; the complete core suite passed again with PR #114. This status records the source fix and local verification, not auditor sign-off or live release evidence. It addresses cap conversion, not every separate target-notional conversion or arithmetic limit. The historical finding follows.

**The problem.** Converting `max_order_notional` into whole-lot base at the
current price aborts with `arithmetic_overflow` when the result exceeds `u64`.
Every order-sizing path runs it, so mint, redeem, rebalance and a live-market
unwind abort together once the cap is worth more than about 1.8e10 base tokens
at the live price. A `u64::MAX` cap, which the setter accepts, aborts for any
base priced under about one thousand USDC. Nothing bounds the cap against
current prices, so a cap that converted safely at seeding can overflow later
from price drift alone. A `RiskAdmin` can recover by lowering the cap.

**Where it is.**

- [rebalance_math::base_for_oracle_notional_down](../../sui/boosts/core/sources/lib/rebalance_math.move#L46)
  asserts the result fits.
- Callers: [state::max_order_base](../../sui/boosts/core/sources/state.move#L259),
  [state::reduction_order](../../sui/boosts/core/sources/state.move#L945),
  [state::seed_terms](../../sui/boosts/core/sources/state.move#L173),
  [state::unwind_constraints](../../sui/boosts/core/sources/state.move#L709).
- [state::set_max_order_notional](../../sui/boosts/core/sources/state.move#L787)
  accepts any positive value.

**The fix.** Make the conversion saturate: clamp the converted base to
`u64::MAX` before flooring to lots, or bound the cap by the position-scale
amount being traded (as `increase_base_down` already does). A cap larger than
any representable order then simply means no pacing. The clamp is lossless
for reachable states since any position the adapter can represent fits in
`u64` base atoms. Optionally reject unreasonably large values in the setter.

**Tests.** A `u64::MAX` cap at a low base price sizes orders to the position
scale and does not abort.

### Ticket 12 · L-3 · A small vault below the band cannot rebalance, which then blocks mints

**Status:** open.

**The problem.** `prepare_rebalance` admits any position outside the band
without checking that a whole-lot order can move it toward the band. On the
increase side the sizing returns the largest whole-lot buy that stays at or
under target after cost, and zero if a single lot overshoots. Then no order is
placed and completion aborts with `rebalance_no_progress`. This happens once a
position holds fewer than about `L / (T − B)` lots (leverage, target, lower
band edge), a size that ordinary redemptions can reach. While it lasts the
permissionless `rebalance` cannot run, `needs_rebalance` keeps reporting true,
and `prepare_mint` refuses deposits outside the band even though a deposit
would cure it. Redemptions still work. The lock clears only when price moves
leverage back into the band or someone donates enough NAV.

**Where it is.**

- [state::prepare_rebalance](../../sui/boosts/core/sources/state.move#L476).
- [rebalance_math::increase_base_down](../../sui/boosts/core/sources/lib/rebalance_math.move#L53)
  returns zero when one lot overshoots.
- [orders::rebalance_orders](../../sui/boosts/aftermath_adapter/sources/orders.move#L155)
  places nothing; [state::complete_rebalance](../../sui/boosts/core/sources/state.move#L589)
  aborts.
- [state::prepare_mint](../../sui/boosts/core/sources/state.move#L292) band
  gate; [state::needs_rebalance](../../sui/boosts/core/sources/state.move#L467).

**The fix.** A band breach that no whole-lot rebalance can close should not
lock the vault. Have `prepare_rebalance` and `needs_rebalance` treat a zero
first order as not actionable (a distinct abort code, and `false` from the dry
run), and relax `prepare_mint`'s band gate for that case so deposits are
allowed when they move leverage toward the band. Document a minimum position
size, in lots relative to the band width, for the sizing gates.

**Tests.** Five lots at 1.67x with a 1.8x lower edge and 2.0x target:
`needs_rebalance` is false, `rebalance` aborts with the new code, `mint`
succeeds.

### Ticket 13 · L-4 · Donated cash is never allocated to the position

**Status:** open.

**The problem.** `donate` deposits the coin into the Aftermath account's free
balance and stops. Unlike `fund_mint`, nothing allocates it to the position,
and the completion proof explicitly rejects an allocation. The core still
counts the donation as margin-backing value: it credits the reserve up to the
ceiling and any excess becomes NAV, because snapshot equity includes free
collateral. But Aftermath's margin, funding and liquidation, and the adapter's
own `margin_safe` gate, count only allocated collateral. ADR 0084 D1 requires
NAV and the reserve to stay allocated as margin; as free balance the reserve
only survives a wipe. Consequences: funding drains position margin while the
reserve sits idle, above-ceiling donations inflate the NAV that increase
rebalances size against, and as allocated margin degrades `margin_safe` fails
and mint, redeem and rebalance abort while equity looks healthy.

**Where it is.**

- [operations::donate](../../sui/boosts/aftermath_adapter/sources/operations.move#L357)
  calls only `deposit`.
- [operations::fund_mint](../../sui/boosts/aftermath_adapter/sources/operations.move#L608)
  is the deposit-and-allocate pattern to copy.
- [operations::complete_donation](../../sui/boosts/aftermath_adapter/sources/operations.move#L761)
  proves with [checkpoint::assert_deposit_checkpoint](../../sui/boosts/aftermath_adapter/sources/checkpoint.move#L101);
  the allocated variant is [checkpoint::assert_allocated_deposit_checkpoint](../../sui/boosts/aftermath_adapter/sources/checkpoint.move#L109).
- [state::donate](../../sui/boosts/core/sources/state.move#L659) credits the
  reserve.

**The fix.** Allocate the donation in the same call, as `fund_mint` does, and
prove it with `assert_allocated_deposit_checkpoint`. If a free buffer is
intended instead, record that in ADR 0084/0086 and exclude free collateral
from exposure-sizing equity. Either way add a test that donated cash ends up
as allocated position collateral.

### Ticket 14 · L-5 · Activation accepts any non-negative position IMR

**Status:** open. Design together with tickets 2 and 5.

**The problem.** `initialize` takes `position_imr` as a free issuer input,
checks only that it is non-negative and unchanged by the seed orders, then
seals the admin cap so it can never change. Nothing ties it to the vault's
policy, and neither the fixtures nor the activation builder check it. The
effective venue IMR is `max(position_imr, market_imr)`, and it drives the
venue's increase and deallocation checks and the `margin_safe` gate on mint,
redeem, rebalance and donate. The design notes intend the inverse of the hard
cap, yet the 2x/2.5x fixture accepts up to about 0.55 against an intended 0.4.
A larger ratio means an adverse move blocks mint, redeem and the reducing
rebalance while the core still considers the position inside its band; a
lower ratio widens the profit-side redemption window of ticket 2.

**Where it is.**

- [operations::initialize](../../sui/boosts/aftermath_adapter/sources/operations.move#L41)
  and [operations::assert_position_imr](../../sui/boosts/aftermath_adapter/sources/operations.move#L512).
- [operations::fund_venue_account](../../sui/boosts/aftermath_adapter/sources/operations.move#L548)
  sets it on the venue.
- The hard cap lives in core `policy` and `max_leverage_bps` is
  `public(package)` there, so the adapter cannot read it today.

**The fix.** Bound `position_imr` against the rebalance policy (or derive it
from the policy and drop the parameter), and mirror the bound in the
activation builder. Use an equality or a tight two-sided band around the
cap's inverse, not a one-sided floor. Needs a core-side change: either expose
the hard-cap bps across the package boundary or move the check into
`state::activate`, which sees both the policy and the activation terms.

**Tests.** 0.55 on a 2.5x cap is rejected at activation; 0.4 is accepted; the
builder refuses to compose a mismatched value.

### Ticket 15 · L-6 · Emergency rebalance can trap a vault just above the hard cap

**Status:** open.

**The problem.** `complete_rebalance` ignores the plan's `emergency` flag and
completes a reduction only if leverage moved toward target by at least
`min_leverage_improvement_bps`, otherwise the whole call reverts, fills
included. But `next_rebalance_order` deliberately ends an emergency plan as
soon as leverage is at or below `max_leverage_bps`, and each order is capped.
Policy creation only checks the minimum is positive, and changing the order
cap never re-checks it, so the minimum can exceed what a plan can deliver. A
vault pushed just above its hard cap places one order, stops at the cap, and
reverts; every retry does the same. With the repository's deployment values
the window is live once NAV exceeds about a hundred order caps, up to about
100 bps above the cap, and during it nobody can rebalance and `prepare_mint`
refuses new mints. The same arithmetic reverts a 16-order budget-limited
ordinary reduction on a large vault.

**Where it is.**

- [state::complete_rebalance](../../sui/boosts/core/sources/state.move#L583)
  discards `emergency` and requires
  [rebalance_math::reduction_is_sufficient](../../sui/boosts/core/sources/lib/rebalance_math.move#L107).
- [state::next_rebalance_order](../../sui/boosts/core/sources/state.move#L526)
  stops the emergency plan at the cap.
- [policy::new_rebalance_policy](../../sui/boosts/core/sources/policy.move#L102)
  checks only `min_leverage_improvement_bps > 0`.

**The fix.** Any plan that makes the progress its stopping rule and order
budget allow must be able to complete.

- Preferred: branch `complete_rebalance` on `emergency`. An emergency
  reduction that ends at or below `max_leverage_bps` with less base succeeds;
  ordinary rebalances keep the minimum-improvement check that guards against
  fee churn.
- Make the ordinary check capacity-aware: at policy creation and whenever
  `max_order_notional` changes, bound `min_leverage_improvement_bps` by the
  leverage effect of 16 cap-sized orders at `nav_cap`, not by the band gap.

**Tests.** A vault 1 bp above the cap with one capped order completes; a
budget-limited ordinary reduction from 3.0x with a 9,000 bps minimum is
rejected at policy creation.

### Ticket 16 · L-7 · One single-key address holds every Boosts authority

**Status:** open. Custody and records, not a code defect.

**The problem.** The mainnet deployer address holds the `SuperAdminCap`, the
only `AdminCap` (roles `VAULT_ISSUER` and `PACKAGE_ADMIN`) and the products
`UpgradeCap`. Its transactions carry a single Ed25519 signature, so it is one
key, not a multisig. With `PACKAGE_ADMIN` that key alone can authorize,
perform and commit an adapter upgrade, and on 2026-10-14 it did so with no
delay and no deployment record. The adapter holds every vault's venue-account
admin capability, so upgraded adapter code could redirect holder collateral.
ADR 0064 requires disclosed multisig and delay controls; neither exists.
Separately, nothing ties deployed bytecode to reviewed source: the mainnet
record was built from a dirty tree with no `sourceDigest`, the `blast_admin`
digest gate never runs, and the immutable core has no digest check.

**Where it is.** `deployments/sui/mainnet/2026-09-22-nvda-alpha-boosts.json`
and the `blast_admin` package (out of audit scope).

**The fix.**

- Move the `SuperAdminCap` and the `AdminCap` carrying `PACKAGE_ADMIN` to a
  disclosed multisig and put a delay on adapter upgrades, as ADR 0064
  requires. Hold the products `UpgradeCap` under the same custody. The
  existing rotation primitives suffice without a code change.
- Amend the deployment records with each holder's signer structure and
  threshold, and record the 2026-10-14 adapter upgrade.
- Verify the deployed `blast_admin` and `blast_boosts_core` bytecode against
  a clean checkout of the reviewed commit, record each `sourceDigest`, and
  add a core digest gate mirroring the `blast_admin` one.

**Tests.** None in Move; the deliverable is the custody change and the
records.

### Ticket 17 · L-8 · Emergency rebalance is refused on mark-versus-spot divergence it never uses

**Status:** open.

**The problem.** Every priced operation aborts when the venue's composite mark
price differs from the spot base oracle by more than `max_mark_divergence_bps`,
an immutable policy value with no floor tied to the venue's own index-TWAP
tolerance. The gate runs on mint, redeem, donate, initialize and rebalance,
including the risk-reducing emergency rebalance, yet the mark never enters the
core pricing of these operations: the position is priced from the base and
collateral oracles and the fill is bounded by the sealed oracle price. The
exit path skips the gate on purpose. The mark is a TWAP composite, so its gap
to spot widens during a fast move with no attacker. During that window the
emergency deleveraging of a position above the hard cap is refused. Liveness
only; it heals when the TWAP catches up.

**Where it is.**

- [state::assert_observation_priced](../../sui/boosts/core/sources/state.move#L998),
  the divergence call at line 1003, through
  [state::validated_active_position](../../sui/boosts/core/sources/state.move#L959).
- [policy::max_mark_divergence_bps](../../sui/boosts/core/sources/policy.move#L645).
- [state::unwind_constraints](../../sui/boosts/core/sources/state.move#L705)
  uses only the freshness checks, which is the pattern to copy.

**The fix.** Exempt the emergency rebalance from the divergence check, as the
exit path already is, so the gate guards only operations whose share pricing
or fill price depends on the mark. Alternatively or additionally, floor
`max_mark_divergence_bps` at issuance at the venue's index-TWAP divergence
limit. Deleveraging must not be refused on an input it does not consume.

**Tests.** Mark 2x the bound away from spot: emergency rebalance proceeds;
`mint` still aborts.

### Ticket 18 · L-9 · Increase rebalances check the cap on the opening-notional reserve

**Status:** open.

**The problem.** The increase branch of `accept_rebalance_fill` checks the
post-fill notional against NAV priced with the plan's `reserve_priced`, which
`prepare_rebalance` fixed as `min(stored_reserve, ceiling(before.notional))`.
The reserve ceiling grows with notional, so when the stored reserve exceeds
the ceiling at plan open, the next checkpoint admits a larger reserve and a
smaller NAV. The hard-cap and target checks then pass on a NAV the post-fill
position will not have, and `complete_rebalance` commits no clamp.
`complete_mint`, by contrast, checks final leverage on the reserve clamped at
the post-operation position. A stored reserve above the ceiling arises from an
unclamped funding credit in `settle_funding`, or from a reduction that left
the reserve unclamped before a price reversal. Example from the audit: equity
1,000,000, stored reserve 400,000, 20% ceiling, opening notional 300,000: a
fill to 1,880,000 is accepted at 2.0x while the fresh leverage is 3.013x,
above a 3x cap. The overshoot is bounded by the ceiling rate times the added
notional; at realistic ceilings it is a target overshoot inside the band that
the next rebalance corrects.

**Where it is.**

- [state::accept_rebalance_fill](../../sui/boosts/core/sources/state.move#L567)
  increase branch, using `plan.reserve_priced`.
- [state::prepare_rebalance](../../sui/boosts/core/sources/state.move#L489)
  fixes it. [state::admitted_reserve](../../sui/boosts/core/sources/state.move#L905).
- [state::complete_mint](../../sui/boosts/core/sources/state.move#L349) is the
  correct pattern.

**The fix.** Check the increase branch's hard cap and target against the
reserve the ceiling admits at the post-fill notional, as `complete_mint` does,
or commit the reserve clamp at plan completion, so a rebalance increase cannot
finish above the hard cap on the NAV later operations use. Update ADR 0086,
whose "difference is harmless" argument describes superseded code.

**Tests.** The audit's numeric example: the fill to 1,880,000 is rejected.

### Ticket 19 · L-10 · Emergency deleveraging reverts on the plan-start reserve basis

**Status:** open. Needs a decision on the reserve basis.

**The problem.** `complete_rebalance` prices the final position against the
plan's `reserve_priced`, fixed at the pre-rebalance notional, while each
reduction fill is validated only against the admitted reserve at its own,
smaller notional. A reduction can pass every fill check yet abort at
completion with `maintenance_reserve_exceeds_equity`, or earlier in
`next_rebalance_order` on the same basis, reverting the whole transaction.
An adverse price move that thins equity triggers it, and the reverting call is
the permissionless `rebalance`. Near leverage `1/c`, with `c` the execution
cost the policy tolerates, every policy-sized reduction either fails the
progress check or breaches the plan-start basis. Retrying re-fixes the same
basis, so emergency deleveraging above the hard cap reverts for every caller
until prices recover. The deployed NVDA2L vault cannot reach this window
(position IMR 0.10 keeps holder NAV at plan open at least about 3.9% of
notional while an emergency reduction costs at most about 2%), hence Low;
issuances where emergency slippage, venue fee, mark divergence and the
reserve ceiling together exceed the effective IMR are exposed, and policy
validation admits them.

**Where it is.**

- [state::complete_rebalance](../../sui/boosts/core/sources/state.move#L591)
  computes before and after NAV on `reserve_priced`.
- [state::next_rebalance_order](../../sui/boosts/core/sources/state.move#L515)
  the same. [rebalance_math::reduction_is_sufficient](../../sui/boosts/core/sources/lib/rebalance_math.move#L107).
- [state::accept_rebalance_fill](../../sui/boosts/core/sources/state.move#L544)
  reduce branch does no reserve check.

**The fix.** Decide and document the reserve basis reductions complete
against, so fills that pass cannot be refused at completion and emergency
deleveraging cannot be reverted by its own permitted execution cost.
Candidates:

- price completion against the admitted reserve at the current notional; or
- keep the fixed basis for ordinary maintenance and let the emergency path
  accept any genuine notional decrease.

Keep the progress check's before and after NAV on one basis. Until the core
can change, reject such policies at issuance. If the fixed basis is kept, also
check `reserve_priced` on the reduce branch of `accept_rebalance_fill` and
refuse reserve-crossing fills there with a dedicated error.

**Tests.** A thin-equity fixture: an emergency reduction that passes every
fill completes; the policy-validation rejection for exposed issuances.

### Ticket 20 · L-11 · Once the position shrinks below one minimum order, nobody can redeem

**Status:** open. Must land before the next vault is issued, because
`min_order_lots` and the lot size are fixed at issuance.

**The problem.** Every ordinary redemption must reduce base by at least
`lot_size × min_order_lots` or leave the position flat. Seed shares are locked,
so the largest ordinary burn is `total_supply − locked_shares`. Once base is
non-zero but `base × (supply − locked) / supply` is below the minimum, no burn
amount passes and every `redeem` aborts for every holder. A price drawdown
followed by the permissionless `rebalance`, whose reduction order has no
minimum-order check, can shrink base into this range. Holders stay locked
until someone deposits more than the current NAV, the price recovers and a
rebalance increases base, or the `ShutdownAdmin` begins shutdown. The doc
comment cites a health transition, but the only production caller of
`is_base_above_min_order` is `activate`. The trapped value is the vault's
whole NAV, at most about one minimum order's margin; keeping that small is a
deployment obligation the code does not enforce.

**Where it is.**

- [state::prepare_redemption](../../sui/boosts/core/sources/state.move#L382)
  through [accounting_math::redemption_base_bounds](../../sui/boosts/core/sources/lib/accounting_math.move#L378),
  which aborts with `order_below_min_lots`.
- [state::reduction_order](../../sui/boosts/core/sources/state.move#L939) has
  no minimum-order check.
- [accounting_math::is_base_above_min_order](../../sui/boosts/core/sources/lib/accounting_math.move#L92),
  called only from [state::activate](../../sui/boosts/core/sources/state.move#L228).

**The fix.** Give ordinary holders a way out of a sub-minimum position without
admin action, either:

- let a redemption close all remaining base when base is at or below
  `lot_size × min_order_lots`, since the I26 drift bound has nothing left to
  protect at that size; or
- add a permissionless terminal trigger keyed on `is_base_above_min_order`
  being false.

**Tests.** Base shrunk below the minimum by a reduction: a redemption that
closes the position succeeds (or the terminal trigger fires).

### Ticket 21 · L-12 · The funding-credit conservation check can overflow on a fitting state

**Status:** open.

**The problem.** `settle_funding` books a credit by repaying the uncovered
deficit first and sending the remainder to the reserve. The new reserve uses
`checked_add`, which aborts only when the post-state does not fit. The
following invariant check evaluates `maintenance_reserve + restored ==
reserve_before + amount` with both `u64` sums unprotected. When
`reserve_before + amount` exceeds `u64::MAX` while a deficit is open, it
aborts with a generic arithmetic error although the post-state fits. Reaching
it needs a reserve rebuilt while a deficit is open, then one net credit near
`u64::MAX` atoms (about 1.8e13 USDC), which no real venue reports. If reached,
the whole product freezes: `apply_post_capture` settles funding first, so
mint, redeem, rebalance, donate, `sync_health` and unwind all revert, and
reverted transactions never advance the checkpoint.

**Where it is.**

- [state::settle_funding](../../sui/boosts/core/sources/state.move#L650), the
  `assert_invariant` on the credit branch.

**The fix.** Evaluate the conservation check in a width that cannot overflow
(`u128`, as `assert_holders_not_diluted` does) or restate it against the
post-state `checked_add` already computed. Keep `checked_add` as the guard.
Add a test with an open deficit, a sum above `u64::MAX` and a fitting
post-state that must succeed.

## Advisory findings

### Ticket 22 · A-1 · `ifixed_math::to_u64` is wider than its callers

**Where.** [ifixed_math::to_u64](../../sui/boosts/aftermath_adapter/sources/lib/ifixed_math.move#L27)
is `public(package)` but only `fixed_to_u64_down` and `fixed_to_u64_up` in the
same module call it (verified by grep).

**Fix.** Narrow it to a private `fun`. No test or entry point is affected.

### Ticket 23 · A-2 · `needs_rebalance` pairs post-settlement equity with a pre-settlement reserve

**The problem.** The keeper's dry run captures the venue without settling
funding, then asks the core the band question using the stored reserve. If
another caller settled Aftermath funding since the last sync, equity reflects
it and the reserve does not, so the dry run and `rebalance` evaluate different
(equity, reserve) pairs. A funding cost makes the dry run understate NAV and
report out of band where `rebalance` finds in band (the keeper's call aborts
with `rebalance_inside_band`); a credit does the reverse and a due rebalance
is skipped. The error is one interval's funding and zero at the reserve cap.

**Where.** [operations::needs_rebalance](../../sui/boosts/aftermath_adapter/sources/operations.move#L311)
and [state::needs_rebalance](../../sui/boosts/core/sources/state.move#L467).

**Fix.** Apply the classified pre-existing funding to a local copy of the
reserve before the band test, so the dry run prices the same pair as
`rebalance`, or state the mismatch explicitly in the function's documentation.

### Ticket 24 · A-3 · `needs_rebalance` omits the venue-fee abort that `rebalance` enforces

**The problem.** `rebalance` reads the market's taker fee and aborts with
`venue_fee_unusable` when it exceeds 1.0; the dry run never makes that call,
so on such a market it returns true while `rebalance` aborts before any order.
Only keeper tooling is affected.

**Where.** [operations::needs_rebalance](../../sui/boosts/aftermath_adapter/sources/operations.move#L311)
versus [orders::live_venue_fee_bps](../../sui/boosts/aftermath_adapter/sources/orders.move#L107),
called by [operations::rebalance](../../sui/boosts/aftermath_adapter/sources/operations.move#L289).

**Fix.** Call `live_venue_fee_bps` in the dry run so both abort on the same
market state, or narrow its documentation to what it checks.

### Ticket 25 · A-4 · Settlement unwind adopts the venue checkpoint without booking funding

**Status:** partly fixed by ADR 0115 (the pause-mode mismatch before the close
no longer classifies as `Unexpected`). The post-close half is open.

**The problem.** When `unwind` finds the market paused for settlement,
`unwind_settlement` closes the position at the venue's settlement prices and
`complete_unwind` adopts the new checkpoint unconditionally. Funding settled
inside the venue's close is never classified, so it bypasses `settle_funding`
and the `FundingSettled` event, leaving the reserve and deficit books stale.
Holder payouts are unaffected: finalization zeroes the reserve and seals
recovered cash for pro-rata claims. The impact is confined to the core's
funding books and event stream.

**Where.** [operations::unwind_settlement](../../sui/boosts/aftermath_adapter/sources/operations.move#L881)
and [operations::complete_unwind](../../sui/boosts/aftermath_adapter/sources/operations.move#L957).

**Fix.** Before `complete_unwind` adopts the post-close checkpoint, classify
it against the stored one (funding snapshots refreshed, collateral moved by
the settlement) and book the net through `settle_net_funding`, so every venue
funding change reaches the books and the event stream exactly once.

**Tests.** A paused-market fixture with funding owed at close: `FundingSettled`
is emitted and the reserve moves by the settled amount.

### Ticket 26 · A-5 · Nothing forces a fill to be proven against the checkpoint

**The problem.** `place_order` returns a `Fill` with `drop`, and the proof
`assert_checkpoint` only borrows it. The three order loops run the proof by
convention. A future edit that dropped the call would compile and advance the
checkpoint on an unproven fill. No impact today: every current path runs the
proof and `Fill` never leaves the module.

**Where.** [orders::Fill](../../sui/boosts/aftermath_adapter/sources/orders.move#L32),
[orders::place_order](../../sui/boosts/aftermath_adapter/sources/orders.move#L406),
[orders::assert_checkpoint](../../sui/boosts/aftermath_adapter/sources/orders.move#L444).

**Fix.** Let the type system enforce the proof: `place_order` returns an
ability-less value that only the proof can consume, and the proof yields the
proven fill amounts the loops use. The adapter is published, so `Fill`'s
abilities cannot change in an upgrade; add a new type rather than removing
`drop`. Both functions are private, so a compatible upgrade carries it.

### Ticket 27 · A-6 · Products package custody is undecided

**The problem.** The products package's `UpgradeCap` (compatible policy) and
`Publisher` are plain objects owned by the deployer address. Publication
neither called `make_immutable` (as the core did) nor applied the README's
additive-only restriction. The holder can publish new public functions,
structs and modules under the official package address. Impact is limited to
label spoofing: the core and adapter do not depend on this package, the tags
carry no authority, and market identity comes from the adapter's issuer-gated
initialization. The same key holds the adapter's root authority (ticket 16).

**Where.** [blast_boosts_products::init](../../sui/boosts/products/sources/blast_boosts_products.move#L184)
uses `claim_and_keep`; the record in
`deployments/sui/mainnet/2026-09-22-nvda-alpha-boosts.json` lists the
`upgradeCapId` and `publisherId`.

**Fix.** Settle the posture, by one of: make the package immutable once the
tag set is final; move the `UpgradeCap` and `Publisher` into a custody object
as the adapter does; or record the owner-held posture in a decision record.
Restricting to additive upgrades alone does not close the new-public-surface
path.

### Ticket 28 · A-7 · NAV above the cap can push the target notional past `u64`

**The problem.** `assert_nav_cap_valid` checks that `nav_cap × max_leverage`
fits in `u64`, and the cap is enforced only at mint. NAV can exceed the cap
through profit or a venue credit. The increase path computes
`nav × target_leverage / 10_000` and aborts on overflow, so while NAV stays
above `u64::MAX × 10_000 / target_leverage`, every increase rebalance aborts
and the vault stays under-levered. Reductions, emergency reductions and
redemptions still work. The threshold is at least 1.84e11 whole USDC, so no
realistic vault reaches it.

**Where.** [policy::assert_nav_cap_valid](../../sui/boosts/core/sources/policy.move#L348),
[accounting_math::target_notional_down](../../sui/boosts/core/sources/lib/accounting_math.move#L179),
[state::increase_order](../../sui/boosts/core/sources/state.move#L928).

**Fix.** Make the target computation hold for live NAV, not only the cap:
bound live NAV against the `u64` limit the target leverage implies, or
saturate or guard the target in `target_notional_down` and the increase path.

### Ticket 29 · A-8 · `snapshot::capture` docs say a stale feed is carried, but it aborts

**The problem.** The doc comment says only source-identity problems abort and
that an unserviceable venue is carried as a fact for health synchronization to
report. But `capture` calls the venue's price functions with the clock, which
(per the venue bytecode) abort when a feed is older than the market's
tolerance or when the collateral index and TWAP diverge. `venue_operational`
covers only pause and freeze, so a stale feed aborts `capture` inside the
venue and `sync_health` aborts instead of reporting. No measurable impact; the
inaccurate contract could mislead a future caller.

**Where.** [snapshot::capture](../../sui/boosts/aftermath_adapter/sources/snapshot.move#L58)
doc comment; the venue price calls at lines 80 to 82.

**Fix.** Amend the doc comment: a stale feed or an index/TWAP divergence
aborts `capture`, so health synchronization aborts rather than reports, and
callers that must not depend on a live price use `capture_checkpoint`.

### Ticket 30 · A-9 · Rebalance fills are validated against the order's direction, never the plan's

**The problem.** `accept_rebalance_fill` derives every direction-dependent
check from the `RebalanceOrder` it is handed (expected post-fill base, and the
leverage gate that applies only to increases). It never reads
`plan.increase` and discards the order's `emergency` flag, trusting rather
than enforcing the pairing. A mismatched order would move base the wrong way
or skip the leverage gate, and `complete_rebalance` checks only net
improvement. No caller can trigger it today: `State` is exposed only through
`public(package)` accessors and the sole production path builds each order
from the plan it advances.

**Where.** [state::accept_rebalance_fill](../../sui/boosts/core/sources/state.move#L552),
[orders::rebalance_orders](../../sui/boosts/aftermath_adapter/sources/orders.move#L171).

**Fix.** Take direction and emergency status from the plan inside
`accept_rebalance_fill`, or reject orders whose values differ from
`plan.increase` and `plan.emergency`, so the core enforces order/plan pairing
itself.

## What this document does not establish

- Aftermath's actual deallocation, fill and settlement behaviour. The vendored
  interfaces are stubs; the auditors derived those claims from the deployed
  bytecode, and tickets 2, 6, 8 and 29 depend on them.
- The exact thresholds for tickets 2, 5, 15 and 19. They depend on the venue's
  haircut, market IMR and the reserve ceiling, which the repository does not
  fix.
- Whether the deployed bytecode matches the reviewed source (ticket 16).
