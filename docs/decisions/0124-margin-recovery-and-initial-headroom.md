# Margin recovery and initial headroom

Status: proposed. Date: 2026-10-24.

## Problem and audit alignment

M-5 blocks a reducing rebalance when margin is below the opening requirement,
both before planning and after every fill. Donations encounter the same gate.
L-4 leaves donated cash unallocated, so it cannot improve position margin.
L-5 accepts arbitrary nonnegative position IMR and seals it at activation.

We follow the audit restatement's M-5 recommendation: separate opening admission
from reducing admission, permit donations, and validate initial settings with
headroom. We also follow L-4's deposit-and-allocate recommendation. We refine
L-5's inverse-hard-cap equality/tight-band suggestion: equality leaves no room
in a simple zero-reserve model and does not account for the venue haircut or
costs. Use the live market floor and the conservative policy-derived upper
bound below. Core still enforces the vault's actual leverage limits. This
supersedes ADR 0084 D6's inverse choice for the current fresh-lineage source.
The audit document is a project restatement, not original-auditor sign-off.

## Reductions and donations

The authenticated capture prepares a core rebalance plan before checking
opening margin. Only a plan core proves is increasing requires that margin.
Each later fill uses the direction sealed in that same plan. All ordinary
above-band reductions qualify, including those below the emergency threshold.
The caller cannot choose the exemption. The keeper readiness hint also admits
reductions below opening margin and filters unsafe increases. It creates no
linear execution plan and does not promise funding, fee, gas, size or fill success. Increasing mint/seed/rebalance paths,
redemption admission and profit realization's close/reopen remain strict.

Keep exact checkpoint reconciliation, fresh bound prices, correct side,
representable economics, positive shareholder NAV, no resting orders,
operational market, fill proof, capped sizing and completion progress. The
existing emergency/ordinary gas and price policies and private-entry boundary
are unchanged. A bounded reduction may commit before opening margin is fully
restored; it still must satisfy the existing progress requirement. This is not
a new inside-band rescue path and does not remove L-8's mark-divergence gate.

Donations deposit and allocate exactly the supplied amount to the bound
position. Completion verifies allocated collateral rose by that amount and
free cash did not change, with the existing checkpoint proof. The reserve
receives the donation up to its cap; excess increases NAV. Supply, admin cash
and fees do not change. Partial recovery below opening margin is allowed;
other active-operation checks remain. Existing Donated checkpoints still
describe the actual custody state, so no new event or persistent state is needed.

## Initial-margin budget

Before account creation or seed movement, adapter requires raw IFixed
`0 < position_imr <= 1`, `position_imr >= market_imr`, and `0 <= haircut < 1`.
Unsigned unit-interval checks also reject negative signed carriers. Ignore
negative fee rebates. Budget the positive ordinary fee plus the positive
optional priority surcharge; an absent surcharge contributes zero to this
configuration budget and promises no priority execution. Reject total fees
above one. Round IMR, haircut and total fee upward to basis points.

Core's issuance seam reads the immutable policy and checks, with bounded u128
cross-products and before any subtraction:

```text
B = 10,000
M = max_leverage_bps
S = emergency_max_slippage_bps
D = max_mark_divergence_bps
R = position IMR rounded up to bps (at least live market IMR)
H = live collateral haircut rounded up to bps
F = live total fee rounded up to bps
C = S + ceil((B + S) * F / B)

M*C < B²
(B² - M*C)*(B - H) > M*D*B + M*(B + D)*R
```

This conditional model starts with fully realized, fully allocated equity at
the hard cap, without reserve credit. Reserve a full-position emergency
execution cost, discount remaining cash by the haircut, allow adverse mark
PnL and still require margin for the original notional at the highest accepted
mark. Combining both adverse mark effects and charging the full position is
conservative for either direction and more severe than the actual partial
cap-restoring sale. Strict inequality leaves positive model headroom. There is
no new arbitrary buffer setting. Raw sub-bps values cannot evade the ceiling.

This is configuration admission, not a universal economic guarantee. Existing
unrealized losses/cost basis, accumulated costs, reserve movements, price
changes and future venue policy can exhaust margin. No activation-only ratio
can prevent those cases. Reductions and donations never recheck this budget.
The actual seed and opening paths still check current venue margin.

The activation builder requires a venue-rate preview and mirrors this check.
The preview supplies no on-chain authority; Move rereads live rates. A stale
preview can fail a transaction, never bypass on-chain admission.

## Verification and release limits

Test both directions, ordinary and emergency reductions, partial recovery,
post-fill admission, strict increases, bad venue states, exact donation custody,
event replay, ratio signs/ranges, raw market floor, rounding boundaries,
haircut/fee/mark budgets and exhausted headroom. Independently value stressed
cash and position requirements in the numerical sweep. Validate the new
priority-fee getter against the pinned live ABI.

Local venue interfaces do not execute trades. Captured-state tests replace
external reads/fills while exercising production admission and core rules;
ABI checks and simulations do not establish real execution. Before deployment,
controlled venue evidence must cover below-opening-margin reductions in both
directions, repeated partial recovery, allocated donations, priority fees,
and seed rejection/acceptance under actual rates. Liquidity, venue pauses,
insolvency, accepted prices and existing progress limits still constrain
recovery. Fresh publication under ADR 0115 is required; no deployed historical
bytecode or existing vault IMR is changed by this source fix.
