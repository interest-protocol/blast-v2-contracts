# Terminal leverage: deterministic local record

Status: pre-publication source implementation, not a production release or live
venue result. The current contract has exactly Uninitialized, Active,
Unwinding and Settled. The risk-admin ReduceOnly surface is removed; no
compatibility path or migration is introduced. Immutable-publication and
separately authorized release requirements remain unchanged.

## Operation and authority

An observer reports authenticated unexpected checkpoint changes, including
possible full/partial liquidation or ADL, for shutdown-role review. Its label
is not an on-chain verdict. The pure `emergencyDecision` and
`buildTerminalPlan` functions in the adapter's offline planner test this
boundary. An administrator explicitly chooses Emergency or ObservedVenueChange,
signs in through the existing ACL, and supplies that witness to
`vault::begin_shutdown`. This call needs no venue or oracle availability.
The planner emits inert call descriptions or unsigned-serialization arguments;
it never reads RPC, signs, serializes live objects or submits.

Normal `operations::unwind` derives configured direction and exact remaining
whole-lot base from the authenticated position, consumes fresh bound price
observations, isolates funding, and executes at most sixteen reduce-only orders.
Each requested and actual filled notional obeys the live bounded order cap;
each fill obeys the immutable emergency tolerance. Positive actual fills
reduce the remaining quantity. Residual raw dust, opposite-side positions,
standing orders and unexplained intra-call effects abort. A successful bounded
partial call can be retried against its new actual position. An abort rolls
back that transaction; previously committed calls remain separate transactions.

Frozen markets use only the pinned `close_position_at_settlement_prices` ABI
with enabled, positive venue settlement prices. This is not a market order:
its event contains no invented fill quote or isolated funding attribution.
Both routes must converge on exact flat/no-order/settled-liability state before
finalization. Unsupported or paused venue actions remain fail-closed.

## Cash, claims and replay

Finalization requires exact zero raw base and entry quote; zero ask/bid/order
count; both funding snapshots current; nonnegative integral recoverable
collateral; an exact returned native coin; and a post-withdrawal checkpoint
with both collateral locations zero and all other fields unchanged. Named
IFixed helpers decode signed collateral before atom conversion. There is no
write-off of fractional units and no synthetic recovered balance.

Actual recovered holder cash occupies a private typed native Balance field,
separate from earned admin cash. Finalization zeros the buffer book entry.
Eligible shares are always native TreasuryCap supply minus immutable locked
seed; there is no mutable numerical claim-supply ledger. With zero eligible
supply, the recovered coin transfers once to the recorded nonzero seed funder.

Claims burn the supplied native coin before returning its floor-rounded
remaining-cash fraction. The last claimant gets dust. A partial rounded-zero
claim fails while cash remains; holders can combine shares. A zero pool allows
positive shares to burn with explicit minimum zero and returns a composable
zero coin. Inclusive deadlines and caller minimums apply; no fee, oracle,
venue access, reactivation, cross-product payment or transfer restriction exists.

Completed events are ShutdownBegun (declared reason), UnwindProgress (actual
before/funding/after checkpoints and actual market-fill quote when available),
ShutdownFinalized (actual recovered cash, eligible supply, optional seed-funder
payment and final checkpoint), and ShutdownRedeemed (burn, payout, remaining
cash and eligible supply). Existing unresolved/reconciled diagnostics remain
deduplicated; successful finalization reconciles a pending diagnostic. Local
reducers consume same-transaction events and compare native supply, cash,
checkpoint and diagnostic identity against actual Blast objects.

## Verification boundary

Move tests exercise the production Blast lifecycle, exact checkpoint guards,
decoded dependency-port arithmetic, native TreasuryCap/coin burns, seed-funder
custody, and completed events. Controlled fill tests use the exact sizing/fill
guards for long/short partial budgets, failed middle fills and retries. The
composition package typechecks launch sell → local terminal claim; independent
native Quote buy/sell tests continue unchanged.

Pinned Aftermath Move interface bodies abort locally. Compilation authenticates
the selected ABI signatures, not venue runtime semantics. Direct frozen
settlement, deallocation availability while frozen, network rollback/effects,
live object/liability evidence, capacity/gas and full production rehearsal are
not claimed. A-003 defers publication, live ABI reads, funded submissions,
whole-feature verification and release evidence until separate authorization.
The local gate is explicitly `bash scripts/verify.sh local`, never its default
`all`/proof lane.
