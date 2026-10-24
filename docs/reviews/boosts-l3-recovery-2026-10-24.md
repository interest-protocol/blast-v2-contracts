# L3 small-vault recovery review

Scope: L3 in the Asymptotic October audit restatement. Base main
`a96ff24d42de79fd58a9d5ede750393e50b52e04`. This is the project's source
assessment; the original audit report and original auditor acceptance are not
available in this task.

## Auditor alignment and invariants

The auditor recommends detecting an impossible whole-lot rebalance and allowing
helpful deposits. ADR 0125 implements that goal with a safe one-lot band landing
first, then an explicitly sized deposit-funded catch-up when no standalone buy
fits. It intentionally requires full in-band completion rather than accepting a
merely improving deposit. Ordinary proportional mints alone would not reliably
repair leverage, and L1's final band rule must remain intact.

Core owns sizing, plan flags and completion. The adapter supplies the current
market fee and retains custody, opening margin, price, checkpoint, bounded-order
and actual-fill checks. No public transaction endpoint or market handoff changes.
Ordinary rebalance buys retain their target ceiling. Only a sealed one-lot order
may cross target, and its actual fill must finish inside both band edges.

Recovery minting cannot bypass an available rebalance, an above-band state, the
ordinary cap, the proportional minimum, minimum shares, NAV cap or final band.
It uses exactly the sealed catch-up size. Shares reflect actual contribution,
capped at deposit net of protocol fees. Trading costs reduce the depositor's
shares; old holders' NAV per share cannot fall. Excess favorable execution is
not credited above the contribution cap. Failed transactions commit no economic
effects; the caller still pays network gas.

## Local evidence

Two new regressions failed against unchanged production source: a five-lot
position could not buy its safe sixth lot, and genuine lot dust incorrectly
reported an actionable rebalance. Both pass with the fix.

The completed local gate passed 704 core tests, 494 adapter tests and three
composition tests. New L3 coverage exercises long/short recovery, exact and
outside-band landings, cap drift, unavailable recovery sizes, partial/extra
fills, share floors, minimum actual contribution, protocol fees, contribution
caps, NAV caps, return to ordinary mint sizing, and 72 independently enumerated
small-position scenarios. Simulated venue sequences cover legal redemptions
into dust, recovery across several fills and subsequent normal mint/redeem on
both sides. Builds, warning-as-error lint, source boundaries (including four
new fee-routing mutations), calibration (6), keeper/IMR tests (27), ABI checker
self-tests (11), live ABI checks (5 packages/75 functions), activation self-tests
(19), Move style (200 modules/10 tests), generated references and diff checks
passed. The final gate's exit status is recorded as zero.

Evidence: `outputs/verification/2026-10-24-boosts-l3-recovery/` in the shared
workspace. The raw logs and independent review metadata are retained there.

## Independent review

Fresh Opus 5.5 reviewed the source against the audit restatement in independent
session `0e9ca93c-d016-46ae-be45-94966bfa53d0`; the CLI response confirms
`claude-opus-5-5`. It found no Critical, High or Medium issues and judged the
design to resolve L3 in source. Four Low findings and two nits prompted these
corrections:

- Explicitly document that the auditor's five-lot example now takes a successful
  one-lot rebalance; genuine one-lot dust takes the deposit recovery path.
- Pass the simulated venue's actual taker fee to both mint and readiness.
- Make the off-chain keeper helper request on-chain inspection instead of
  treating a band breach alone as permission to submit a rebalance.
- Add realistic long/short redemption-to-dust recovery sequences, multiple-fill
  recovery and incomplete-fill rejection, preparation-time minimum coverage,
  the calibrated 65-lot minimum and authenticated fee-routing mutation checks.
- Give a one-lot fill outside either band edge its own accurate diagnostic,
  remove the obsolete cost-test wrapper and update comments/ADR cross-references.

All 30 focused L3 tests and the full local gate pass after these changes.
Opus's follow-up accepted all six corrections, found no remaining actionable
issues and confirmed L3 resolved in source, conditional on the completed gate
returning success. The gate subsequently completed with exit status zero,
including current generated references and a clean diff check. Both responses
confirm `claude-opus-5-5`; raw review and follow-up metadata are retained with
the logs. This is a model review, not original-auditor acceptance.

## Remaining limits

Recovery needs a deposit and liquidity compatible with the minimum order,
ordinary order cap and NAV cap. An administrator may still need to adjust caps.
The one-cap recovery size deliberately bounds how much a deposit can repair.
Costs, absent opening margin, reserve changes, stale prices and partial fills
can reject the transaction; final safety checks are authoritative.
Mints can pay priority gas, whose venue surcharge is outside the ordinary-fee
projection; actual minimum shares and final band checks still apply.

Local venue interfaces abort instead of trading. Live Aftermath validation must
cover both sides, actual fees/partial fills, caps/margin, successful recovery and
failed-transaction rollback before deployment. Use fresh first-party packages
under ADR 0115: core helper signatures and transaction-local plan layouts change.
The historical deployed vault is unchanged. No deployment was performed.
