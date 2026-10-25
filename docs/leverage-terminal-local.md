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

Anyone can instead call `operations::begin_protected_shutdown` when the largest
accessible ordinary burn fails the minimum-order guard (ADR 0130). Bound account
facts must match, but market-wide policy/rates may change. No price or opening
margin is required. Already-settled funding must be accounted first; the planner
does not force sync because venue funding calls can fail on paused markets.
The settlement allocation mode is sealed at entry.

`operations::unwind` allows a higher gas bid during congestion. Holders pay
Aftermath's priority trading surcharge; callers pay network gas. It derives configured
direction and exact remaining
whole-lot base from the authenticated position, consumes fresh bound price
observations, isolates funding, and executes at most sixteen reduce-only orders.
Each requested and actual filled notional obeys the live bounded order cap;
each fill obeys the immutable emergency tolerance. Positive actual fills
reduce the remaining quantity. Residual raw dust, opposite-side positions,
standing orders and unexplained intra-call effects abort. A successful bounded
partial call can be retried against its new actual position. An abort rolls
back that transaction; previously committed calls remain separate transactions.

Closed markets, paused by the venue with settlement enabled, use only the
pinned `close_position_at_settlement_prices` ABI with positive venue
settlement prices; a frozen clearing house admits no call at all. This is not a market order:
its event contains no invented fill quote or isolated funding attribution.
Both routes must converge on exact flat/no-order/settled-liability state before
finalization. Unsupported or paused venue actions remain fail-closed.

## Cash, claims and replay

Finalization requires exact zero raw base and entry quote; zero ask/bid/order
count; both funding snapshots current; nonnegative allocated collateral; and an
exact returned native coin equal to free cash plus the whole-atom floor of the
allocation. Named IFixed helpers decode signed collateral before conversion.
The final checkpoint requires zero free cash and the exact allocated raw
remainder modulo `10^12`, strictly below one six-decimal collateral atom, with
all other fields unchanged. The state-derived remainder stays at the venue and
is reported explicitly; no caller tolerance, liability forgiveness, erased raw
units or synthetic recovered balance is accepted.

Actual recovered holder cash occupies a private typed native Balance field,
separate from earned admin cash. Finalization zeros the buffer book entry.
Eligible shares are always native TreasuryCap supply minus immutable locked
seed; there is no mutable numerical claim-supply ledger. No seed funder is
recorded. For administrator-approved shutdown, zero eligible supply routes the
recovered coin to Blast's admin cash, which `withdraw_admin_fees` can spend.
For protected shutdown, finalization first retains `min(recovery, reserve)`,
then gives circulating holders their floor-rounded fraction of the remaining
cash. The seed's fraction and reserve join private `protected_cash`. No holder
or admin withdrawal path exists, even after all claims; adapter upgrade
governance remains trusted. The remaining holder pool alone funds claims.

Claims burn the supplied native coin before returning its floor-rounded
remaining-cash fraction. The last claimant gets dust. A partial rounded-zero
claim fails while cash remains; holders can combine shares. A zero pool allows
positive shares to burn with explicit minimum zero and returns a composable
zero coin. Inclusive deadlines and caller minimums apply; no fee, oracle,
venue access, reactivation, cross-product payment or transfer restriction exists.

Completed events are ShutdownBegun (declared reason), ProtectedShutdownBegun
(accepted checkpoint, native supply and locked shares), UnwindProgress (the
live pre-close capture, the after checkpoint, the market-order count and the
actual market-fill quote when available). In a direct settlement, FundingSettled
already advances the reducer to the final checkpoint before UnwindProgress;
the live pre-close capture need not equal the previously stored checkpoint.
Unknown history is first reported by CheckpointDrifted, then FundingSettled
books only proven local funding from that live baseline (ADR 0132).
ShutdownFinalized records actual recovered cash, eligible supply, final checkpoint and
raw unrecoverable collateral remainder, protected reserve and seed cash; both
protected amounts are explicitly zero for admin shutdown. ShutdownRedeemed
records burn, payout, remaining cash and eligible supply. CheckpointDrifted is not deduplicated: every sync or
unwind step that finds drift emits it again, and no diagnostic state is stored
for finalization to clear. Local reducers consume same-transaction events and
compare native supply, cash and checkpoint against actual Blast objects.

## Verification boundary

Move tests exercise the production Blast lifecycle, exact checkpoint guards,
decoded dependency-port arithmetic, native TreasuryCap/coin burns, zero-eligible
admin-cash retention, and completed events. Controlled fill tests use the exact sizing/fill
guards for long/short partial budgets, failed middle fills and retries. The
composition package typechecks launch sell → local terminal claim; independent
native Quote buy/sell tests continue unchanged.

Pinned Aftermath Move interface bodies abort locally. Compilation authenticates
the selected ABI signatures, not venue runtime semantics. Direct settlement of
a closed market, deallocation availability while paused, network rollback/effects,
live object/liability evidence, capacity/gas and full production rehearsal are
not claimed. A-003 defers publication, live ABI reads, funded submissions,
whole-feature verification and release evidence until separate authorization.
The local gate is explicitly `bash scripts/verify.sh local`, never its default
`all`/proof lane.
