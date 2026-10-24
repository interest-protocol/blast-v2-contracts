# M-5, L-4 and L-5 margin recovery review — 2026-10-24

Scope: `codex/boosts-m5-margin-recovery` against `main` at
`ee9f56f2a02227608b3c50e7759be2ba27987213`. The review uses Tickets 5, 13 and
14 in the repository’s Asymptotic audit restatement. The original report is
not available here; this is not review or acceptance by the original auditor.

## Decision and audit alignment

M-5 follows the recommendation to separate opening margin from reducing
admission, including each fill and partial donations. Core chooses the direction;
callers cannot request an exemption. Ordinary above-band reductions also qualify.
The keeper hint uses that same distinction, so it can actually trigger recovery.
L-4 follows the deposit-and-allocate recommendation with exact custody proof.

L-5 refines the inverse-hard-cap equality/tight-band recommendation to meet
M-5’s headroom requirement. The live market remains the lower bound. Core’s
policy-owned upper budget includes the collateral haircut, emergency price
bound, allowed mark movement, and positive ordinary plus optional priority fees.
The calculation is conservative for both directions and assumes fully realized,
fully allocated equity at the hard cap without reserve credit. See
[ADR 0124](../decisions/0124-margin-recovery-and-initial-headroom.md) for the
formula, its assumptions and remaining risks. It is a configuration check, not a
permanent margin guarantee. The builder mirrors it; Move reads current rates.

## Independent review and corrections

A fresh CLI session using `claude-fable-5-1` reviewed the implementation, audit
restatement, repository standards, transitive callers, tests and evidence. Both
initial and follow-up model metadata identify that model; follow-up used the
same independent session after corrections.

Fable identified two low-severity findings:

1. The keeper dry run still used strict opening admission, hiding reductions
   the real call now accepts. Corrected with captured-margin readiness and a
   core read-only predicate that filters increases only. Regression tests cover
   both directions, ordinary/emergency reductions, unsafe and safe increases,
   inside-band positions and paused venue rejection. The source gate pins the
   actual entry-point wiring and checkpoint-drift rejection. No execution plan
   is created or discarded by the hint; actual trading still rechecks admission.
2. Error descriptions did not cover all new validation failures. The haircut
   range uses the existing normalization error, while the initial-margin and fee
   descriptions now match their checks. Exact-abort and precedence tests pass.

The follow-up independently verified both findings closed, found no new defect,
and approved opening this as a source-fix PR with the deployment gates retained.
Fable independently rederived the headroom inequality and accepted the L-5
refinement. It checked that the read-only core query cannot grant trading
authority or hide a needed reduction.

One wording correction to the raw follow-up report: the dry run now validates
price, side and NAV before checking checkpoint drift; previously those core
checks followed drift. Both still abort. The real rebalance order is unchanged
by this read-only query refinement. This is not a promise that a true hint
will produce a successful trade.

## Final evidence

- Core: **674/674** Move tests; adapter: **488/488**; composition: **3/3**.
- Both package builds, lint with warnings as errors, source boundaries and diff
  checks pass. Repository Move style covers **198** modules; its **10** mutation
  tests pass.
- Initial-margin admission, numerical stress and activation-builder tests:
  **16/16**; keeper tests: **10/10**; existing minimum-size simulation: **6/6**.
- ABI self-tests: **11/11**; live ABI: **5 packages / 75 functions**, including
  the priority-fee getter. Activation proof self-tests: **19/19**.
- Integrator references regenerated and checked. Composition and generated
  checks finished after Fable read the in-progress log; the final results here
  supersede that snapshot. Live ABI evidence is in `final-gates.log`, a separate
  earlier successful run; the getter and ABI inputs did not change afterward.

Full prompts, returned model metadata, reports and logs are retained in workspace
`outputs/verification/2026-10-24-boosts-m5-margin/`. `fable-fixes-gates.log` is the
final post-review test log. No production code changed after Fable’s follow-up.

## Release limits

Local interfaces are ABI stubs. Captured-state tests replace external reads and
fills while exercising real admission, planning and accounting. They do not prove
that an exchange order executes. The configuration budget can reject settings
that work in milder conditions; accumulated losses or fees and later venue
changes can exhaust the margin of accepted settings.

Controlled live evidence must cover below-opening-margin limit-order reductions
in both directions, the venue’s own margin-to-requirement tolerance, repeated
partial recovery, allocated donation custody, priority fees and actual seed
acceptance/rejection. Liquidity, pauses, insolvency, accepted prices and existing
progress rules still constrain recovery. No inside-band rescue is added; profit
realization’s reopening remains strict. Fresh publication follows ADR 0115.
No deployment, original-auditor acceptance or change to historical bytecode is
claimed. Audit statuses remain source fix under review until the PR is accepted.
