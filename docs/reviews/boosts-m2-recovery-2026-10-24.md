# M-2 bounded profit realization review — 2026-10-24

Scope: `codex/boosts-m2-profit-recovery` against `main` at
`10dd2e77f66b4f30bb26c04bdc8d3c41ec00bc91`. This records independent Claude
Fable review against Ticket 2 in the repository's Asymptotic audit restatement,
not review or sign-off by the original auditor. The original report is not the
source available here.

## Decision and changes

The implementation adopts the audit's explicit cash-budget check and stronger
profit-realization option. It refines the latter into separate maintenance
before a fresh redemption quote: closing and reopening the same amount preserves
remaining holders' exposure, and actual costs enter share value before payout.
The ordinary proportional redemption and user minimum payout remain authoritative.
See [ADR 0122](../decisions/0122-bounded-profit-realization-before-redemption.md).

A fresh `claude-fable-5-1` review found a terminal-builder scoping regression,
an event-collector fixture error, incomplete error-registry test coverage and a
missing preflight check for a cash shortfall that exceeds realizable gains after
costs. Each was corrected. The integrated test now checks event-vector length
and index, runs long and short separately, and includes a collateral haircut.
Core tests cover the headroom boundary, maximum input, one-atom rounding,
cost crossing the hard leverage cap and a capped sequence stopping after one
successful step consumes its headroom. Source gates pin lifecycle/gas precedence,
opening-margin validation, the two exact fills and internal market sharing.

The first report used an earlier patch and logs while verification was running;
its statements that full tests and generated references were absent describe
that snapshot. The final evidence below supersedes those statements. Both
reviews use fresh CLI sessions with no persisted conversation; returned model
metadata identifies `claude-fable-5-1`.

## Verification

The regression account has 300 cash, 700 paper profit, a 100 maintenance reserve
and 1,800 exposure. A half-share redemption owes 450 but, even after its close,
can release only 290. The new guard names this mismatch. Repeated bounded
realization then allows the exact full payout at the new share value; tests
check long/short, a haircut, checkpoint replay and remaining-holder claims.

- Full adapter: **464/464** tests.
- Full core: **658/658** tests.
- Native composition: **3/3** tests.
- Keeper transaction builder: **10/10** tests.
- ABI tooling: **11/11**; activation tooling: **19/19** self-tests.
- Both package builds, lint and source boundaries; repository Move style across
  195 modules; generated integrator references and diff checks pass.
- Live ABI/bytecode verification: **5 packages, 74 functions**, including the
  venue's `compute_free_collateral` signature and pinned position module hash.

Local fixtures replace external venue reads and fills; these are not submitted
venue trades. Existing pinned disassembly supports the cash and margin rules.
Controlled live close/reopen, both directions, full redemption, partial-fill
rollback, fees and haircut behavior remain deployment evidence gates.

## Residual limits

The full-position cost-headroom check rejects plainly hopeless conversions but
is conservative. It is checked anew on every call: capped steps can consume
headroom and cause a later call to fail even at unchanged prices. The original
review's claim that the inequality necessarily survives capped steps is not
relied on. Raising the cap, better execution, new collateral, reduced exposure
or shutdown may be needed; recovery does not create equity.

M-5 and L-5 are separate: reopening requires healthy initial margin, and the
configured margin/haircut can make the unchanged position unsupportable after
realization. Two-sided depth, accepted prices, gas admission and live cap size
can also defer recovery. Mark changes during the trades can fail the progress
check. Negative allocated collateral is handled conservatively, and the venue's
own TWAP/funding refresh may still cause its cash error after the precheck.
Private entry and price limits constrain adverse execution but do not eliminate
it across transactions. No deployment or upgrade to the live NVDA vault occurred.

## Final Fable verdict

**No production-code defect; suitable to open the PR.** Fable independently
verified all four first-review findings closed and accepted the conservative
multi-step policy with the documented exits. The final two low-priority requests
were addressed afterward: a regression pins pass-then-refuse behavior, and ADR
0122 plus the integrator guide explain cost-headroom consumption and why raising
the cap alone does not restart a stalled sequence. No production code changed
after that final review. The missing ADR 0121 index row predates this work.

## Final Fable report (verbatim, before those test/documentation follow-ups)

**Verdict: open the PR.** No code defect found in the production change or the prior-finding closures. The remaining items are one missing regression test, one ADR wording tightening, and the deployment evidence gates the ADR already names. None is a blocker.

## Prior findings, verified closed against current files

1. **Terminal builder** `sui/boosts/aftermath_adapter/scripts/active_ptb.mjs:108-114` now declares `operation` before use. Keeper log shows 10/10 passing.
2. **Integrated adapter test** `tests/operations_tests.move:4382-4385` collects the vector, asserts length equals steps plus one, and reads index `steps`. Long, short, and 10 percent haircut variants pass in the full adapter run (464/464) and the focused run (11/11).
3. **Core registry** `tests/errors_tests.move:79-84` carries both new macros and asserts 66 sequential codes. Singletons removed. Core full run 657/657.
4. **Hopeless-account admission** closed by `core/sources/state.move:685-688`. Boundary tests at 555_597 passing and 555_598 failing match my recomputation: cost basis points are 222, full-position cost 44_400, headroom 555_600, minus three atoms.

## The challenge: does the preflight survive capped steps?

You are right, and my prior claim was wrong. Let S be shortfall, P profit, N notional, and c_i the actual cost of step i. Realizing fraction f at fixed prices gives S' = S − fP + c, P' = (1−f)P. Substituting into the guard for the next call, the fP terms cancel and the condition becomes:

```
S + 3 + Σ c_i  <=  P − full_cost
```

So the guard at step k is the initial guard with cumulative actual costs added. A sequence completes at unchanged prices exactly when initial slack (P − full_cost − S − 3) covers the fees actually paid. Near equality, step one passes and step two aborts with code 65. The full-cost term is correct, not an artifact: after each reopen the remaining profit spreads over the whole aggregated position, so realizing it all again costs a full close and reopen. Multi-step recovery is intrinsically dearer than one-step recovery, and no cap-independent on-chain inequality can promise sequence completion.

**Why this is acceptable.** Each call still proves, individually: strictly smaller shortfall, allocated-cash gain above actual equity cost, cost under the worst-case bound, unchanged base and side, final leverage at or below the hard cap. A stalled sequence leaves holders with more cash, identical exposure, and total equity loss bounded by initial slack plus one capped step's cost. After a stall the account is in the band where actual costs could still clear the gap but the worst-case bound cannot prove it. Exits remain: price reversal, mint or donation, band-exceeding reduction, shutdown. A cap raise shortens future sequences but does not change the guard. When the shortfall does reach zero, a proportional redemption of any size is payable, because cash margin covers the requirement independently of the redeemed fraction. That is the useful, bounded operation the ADR describes. I would not trade it for a tighter reachability guard, which would either refuse more recoverable accounts or depend on the cap and on prices that change between transactions.

## Findings

1. **Low, missing regression test.** No test pins the documented pass-then-refuse behavior. Add to `core/tests/state_tests.move`: standard fixture, shortfall 555_597, complete with venue equity one atom lower, then call prepare again with shortfall `555_597 − realized + 1` and profit `600_000 − realized`. Expect code 65 at `blast_boosts_core::state`.
2. **Low, ADR wording.** `docs/decisions/0122-...md:42` says hopeless conversions are refused. The guard refuses conversions that cannot be proven under the worst-case cost allowance, which includes some recoverable accounts. Replace with the slack statement above and note that a code 65 after earlier successes means the sequence stalled and an administrator, depositor, or price move is needed. Mirror one sentence in `docs/llms/boosts.md` and regenerate.
3. **Nit, pre-existing.** `docs/decisions/README.md` has no row for ADR 0121, which exists. Not introduced by this branch.

## Production shape, independently rechecked

The adapter shortfall mirrors the venue's own free-collateral rule and precedes deallocation at `operations.move:159-161`. Both recovery legs reuse the exact-fill checkpoint proof at `orders.move:213-220`. The before and after captures use the margin-requiring observation at `snapshot.move:214-216`, so an unsafe reopen aborts with the venue-not-ready code, which keeps M-5 fail-closed without authorizing anything new. The completion proves cash gain above cost in the adapter and cost under bound plus hard cap in the core before the single checkpoint replacement and emission. Arithmetic widths hold: the u128 subtraction at line 686 is protected by the preceding half-profit assert, and the u64 maximum test covers the u256 sizing path.

## Evidence status

Post-fix gates present and passing: core 657, adapter 464, composition 3, keeper 10, ABI live 5 packages and 74 functions, ABI self-test 11, style, source boundaries for both packages, documentation regeneration. The lint logs show no failures. Two notes. The file final-gates.log contains only the core result line. The file final-review.patch is slightly stale for llms-full.txt, which lacks the new headroom sentence in the patch but has it in the worktree, where the three documentation files agree.

**Deployment gates, unchanged from the ADR and not code defects:** controlled mainnet close and reopen followed by redemption in both directions, partial-fill rollback, live fee attribution, haircut behavior, price-bound calibration, and venue twap behavior at the deallocation boundary. Local fills are fixtures, and the ABI gate pins signatures, not execution.
