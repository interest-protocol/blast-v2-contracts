# 0052: Fully funded stepped-linear vesting

- Status: accepted
- Date: 2026-08-29

## Context

Blast needs an independently deployed vesting component without adding
time-based custody to launch pricing. Historical Memez vesting held one funded
coin balance and calculated a continuous linear release from `start` and
`duration`, with separate transferable and fixed-owner object forms
(`memez@00596fd:vesting/sources/vesting.move:18-77` and
`memez@00596fd:vesting/sources/soulbound.move:7-99`). It did not model a cliff,
release cadence, or fair cancellation.

Current launch and distribution implementations make the schedule inputs more
explicit. Raydium records a start, cliff period, unlock period, and locked
amount (`raydium-cpi@115df27:programs/launch-cpi/src/states.rs:202-218`). The
Solana Foundation rewards program defines cliff-linear time validation and a
cliff that gates accrued linear value
(`solana-rewards@20522ed:program/src/utils/vesting_utils.rs:7-63`). It also
distinguishes returning only nonvested tokens from a full clawback
(`solana-rewards@20522ed:program/src/utils/revoke_utils.rs:7-38`). OpenZeppelin's
Sui linear wallet validates period, step, cliff, multiplication, and end-time
bounds (`openzeppelin-sui@57399c7:contracts/finance/sources/vesting_wallet_linear.move:140-150`)
and supports permissionless release to a fixed beneficiary
(`openzeppelin-sui@57399c7:contracts/finance/sources/vesting_wallet.move:567-607`).

## Decision

Create the framework-only `linear` module in the independent
`sui/vesting/` Move package. It does not import `blast_fun`, and core does not
import it. ADR 0055 later adds `checkpoints` to this package before deployment.

One key-only `Vesting<CoinType>` owns one fully funded `Balance<CoinType>` and
the immutable fields `beneficiary`, `start_ms`, `cliff_ms`, `period_ms`, and
`periods`. It also records an optional fixed cancellation refund recipient and
the cumulative released amount. The creation PTB must consume the result through
`share`; the object cannot be transferred or nested.

The public constructors are:

- `new_irrevocable`, which creates no cancellation authority; and
- `new_cancelable`, which returns a schedule-bound `CancelCap<CoinType>` and
  fixes a nonzero refund recipient.

Both require a nonzero beneficiary, nonzero funding, nonzero period, nonzero
period count, `cliff_ms <= period_ms * periods`, and a representable duration and
end time. Both take the native Sui `Clock` and require
`start_ms >= clock.timestamp_ms()`. SDK and UI validation mirror this check for
early feedback, but the contract is authoritative. Retroactive migrations need
a separately reviewed path rather than weakening the standard constructor.

For total allocation `A`, time `t`, start `S`, cliff offset `C`, period `P`, and
period count `N`, cumulative vested value is:

```text
0                                      when t < S or t < S + C
A                                      when t >= S + P * N
floor(A * floor((t - S) / P) / N)      otherwise
```

The multiplication uses a widened framework operation. Intermediate releases
round down, so the beneficiary receives no value early. At the end boundary,
the beneficiary receives the complete remainder. No loop depends on `periods`.

Any caller may claim, but the contract transfers the payout only to the fixed
beneficiary. A zero claim aborts. An enabled cancellation consumes the exact
matching cap and the schedule, pays all vested-and-unclaimed value to the
beneficiary, returns only unvested value to the fixed refund recipient, and
deletes both objects. Full clawback is not supported. A drained, ended
irrevocable schedule can be closed permissionlessly. A cancellable schedule
always finishes through `cancel`, including after full vesting, so its cap is
retired with the schedule instead of becoming an orphaned authority object.

Funding is immutable after creation. Late deposits would vest retroactively and
make the original allocation ambiguous, so the package exposes no deposit or
receive path. Beneficiary rotation, schedule edits, pausing, milestone or
price-based unlocks, arbitrary curves, tradable positions, onchain batches, and
administrative recovery are outside this ABI.

Creation, claim, cancellation, and close emit their event structs directly from
the `linear` module. The same module owns its string-literal error constants.
Events contain the schedule id and canonical primitive inputs or final
accounting totals needed for replay. The SDK derives claim
previews, end times, calendars, aggregation, and transaction batches.

The EVM implementation is intentionally deferred with the rest of the currently
unimplemented EVM protocol. A shared vesting vector fixes future semantic parity;
the Sui package does not commit an EVM storage or proxy decision.

The first production Sui deployment is immutable. After publication and
verification, the operator must consume the package `UpgradeCap` through the
native `sui::package::make_immutable` operation and record that transaction in
the normalized deployment record
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:268-271`).
This package has no version field, upgrade
authority, or migration path.

## Alternatives considered

**Reuse historical continuous vesting unchanged.** Rejected because it lacks a
cliff, cadence, explicit fixed beneficiary for a shared object, and cancellation
settlement policy.

**Depend on the OpenZeppelin finance package.** Rejected for this first Blast
primitive because the generic curve, deposit, receive, and teardown surface is
larger than the fixed, fully funded requirement. The standalone package can use
only the pinned framework and avoid network dependency risk.

**Store many recipients in one distribution object.** Rejected because it adds
collection bounds, partial-funding allocation accounting, and shared contention.
Offchain tooling can batch independent creation commands in a PTB.

**Allow full clawback.** Rejected because cancellation authority must not erase
value that already vested under the published schedule.

**Make the vesting position transferable.** Rejected because selling a future
insider or contributor allocation changes its economic meaning. A separately
approved liquid-stream product can use a receipt object.

## Consequences

- Each schedule has isolated custody and shared-object contention.
- The beneficiary does not need to submit the claim transaction.
- Cancellation is opt-in, visible at creation, capability-gated, and limited to
  unvested value.
- No privileged global object, setter, collection, package dependency, or
  launchpad ABI is added.
- Immediate starts are valid; creation tooling should use a small future buffer
  when transaction latency could otherwise make a chosen start stale.
- Audit and operational fixes require a new package deployment because the
  production package is immutable.
- EVM parity remains a recorded release gap until the EVM vertical is active.

## Verification

- Exact tests cover pre-start, start, pre-cliff, cliff, intermediate tranche,
  end, repeated claims, rounding remainder, and maximum-width allocation.
- Negative tests cover every constructor bound, nothing-to-claim, mismatched
  cancellation capability, premature close, nonempty close, and an attempt to
  close a cancellable schedule without its cap, including a start before the
  current onchain clock.
- Cancellation tests reconcile prior releases, vested payout, refund, and zero
  remaining custody.
- `UnitFixture`, `ClaimFixture`, and `CancelFixture` own all test setup,
  transaction context, clock mutation, object custody, and teardown. The pinned
  Move coverage tool reports 100.00% module coverage.
- Event replay tests reconstruct creation, claims, cancellation or close.
- Build, lint with warnings as errors, and Move tests pass under the pinned Sui
  CLI and framework.
- `docs/vectors/vesting.json` fixes the chain-neutral arithmetic boundaries.
- Production verification confirms the published bytecode, then confirms that
  the package `UpgradeCap` was consumed by `sui::package::make_immutable`.

## Sources

| Short ref | Full commit |
| --- | --- |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` |
| `openzeppelin-sui@57399c7` | `57399c7c9bd51c0cf11d5ea8c5e31091198293c4` |
| `raydium-cpi@115df27` | `115df2779d53bacc7db9d0be2773a4b48a6d372b` |
| `solana-rewards@20522ed` | `20522ed0bf7a514fcd50f872de90179e0dbbefe6` |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` |
