# Reserve-aware rebalance increases

Status: accepted. Date: 2026-10-24.

## Problem and audit alignment

L-9 shows that an increase can pass its target and hard-cap checks using the
reserve admitted at the opening notional, then have excessive leverage when
the larger final notional admits more reserve. At equity 1,000,000, stored
reserve 400,000, a 20% ceiling and opening notional 300,000, a final notional
of 1,880,000 appears to be 2x on opening NAV 940,000. Its actual NAV is
624,000 and leverage exceeds the 3x hard cap.

Follow the auditor's recommendation to use the reserve admitted at the
post-fill position. Extend it with reserve-aware order sizing and a final
completion check, so a correctly priced smaller increase can succeed instead
of repeatedly selecting an order the new guard rejects. Do not select the
alternative of permanently clamping the recorded reserve during maintenance;
that would change reserve economics. This supersedes ADR 0086's claim that
the rebalance reserve difference is harmless.

The finding source is the repository's Asymptotic October audit restatement;
model review is independent verification, not original-auditor acceptance.

## Decision

For each candidate increase, round its oracle quote and adverse execution
cost up. Price the resulting total base at the sealed oracle pair, then use:

```text
reserve_after = min(recorded_reserve, floor(notional_after * ceiling_bps / 10,000))
nav_after = equity_before - execution_cost - reserve_after
```

Search whole lots under the ordinary execution-quote cap for an increase
whose positive projected NAV supports leverage at or below target. Costs and
the admitted reserve cannot decrease as candidate base grows, so binary
search is bounded by the representable lot count. Reject candidates that
cannot fit the base or conservative notional representation bounds. A flat
opening keeps its recorded reserve for opening NAV; positive candidates use
the ceiling at their new exposure.

Preparation, keeper readiness, the mint catch-up eligibility check, and every
subsequent rebalance order use this same sizing. Reprice from the latest
accepted equity and exposure on every order. If target sizing yields no lot,
the ADR 0125 single-lot exception may still land inside the full band using
the same projected reserve and costs. The opening cap must cover that lot.

Every accepted increase fill checks actual leverage using the reserve admitted
at that fill. Completion repeats the check on final equity and exposure.
Ordinary increases remain at or below target and strictly below the hard cap;
the sealed one-lot exception must satisfy both band edges. The transaction-local
linear plan retains the last accepted increase's exception flag so completion
cannot accidentally reject a valid above-target band landing or grant the
exception to an ordinary order. No stored object, authority, public function
signature or error code changes. The plan layout changes under the fresh
first-party publication posture of ADR 0115. The existing opening-cap error
now originates in State's shared cap check rather than the fixed-NAV math
helper; its code and meaning are unchanged, and exact-abort tests follow it.

Opening NAV remains the before-progress basis. Increased base and increased
actual leverage are still required. Recorded reserve, supply and admin cash
remain unchanged by rebalance. Mint catch-up sizing keeps its separate funded
NAV basis; mint completion admits opening reserve plus its own reserve fee,
then clamps. Using the raw recorded reserve there would reassign the pending
release away from existing holders. Reduction sizing, progress and completion are governed separately by
[ADR 0129](0129-reserve-consistent-emergency-reductions.md).

## Evidence and limits

Regressions cover the audit's oversized fill, successful smaller long/short
increases, repeated capped fills, reserve-ceiling saturation and rounding,
independent whole-lot enumeration, readiness, the single-lot exception,
actual-fill and completion rejection, flat reopening, representability bounds,
and mint catch-up's distinct reserve basis. Adapter snapshot tests exercise
real capture admission with simulated venue facts.

The projection reserves ordinary slippage and venue fees; actual fills remain
authoritative and can still abort. Finite lot sizes, caps, missing liquidity,
margin requirements, venue pauses and other audit findings can still prevent
progress. Live Aftermath execution remains a release gate. No deployment or
historical package upgrade is authorized by this source change.
