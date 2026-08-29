# Vesting contract patterns, 2026

Reviewed on 2026-08-29. This review selects a small Blast vesting primitive. It
does not copy another protocol's product surface.

## References

| Reference | Relevant behavior | Blast disposition |
| --- | --- | --- |
| [Squads V4](https://github.com/Squads-Protocol/v4) | Multisig execution, transaction timelocks, spending limits, roles, and treasury subaccounts. It is an administration primitive, not a token vesting schedule. | A Squads-controlled address can hold a cap. Vesting math must not depend on Squads. |
| [Historical Memez vesting](https://github.com/interest-protocol/memez-gg/tree/00596fdac4dd11f427c7bc594e566ce36160db93/vesting) | One fully funded linear schedule with `start` and `duration`; separate transferable and fixed-owner object forms. | Keep full funding, balance custody, released accounting, and integer linear math. Replace duplicate forms, transferable-beneficiary semantics, and missing cliff, cadence, and cancellation policy. |
| [Raydium LaunchLab CPI state](https://github.com/raydium-io/raydium-cpi/blob/115df2779d53bacc7db9d0be2773a4b48a6d372b/programs/launch-cpi/src/states.rs#L202-L218) | Launch vesting records total locked amount, cliff period, unlock period, start time, and allocated amount. | Adopt explicit start, cliff, and release cadence. Derive total from custody instead of storing it twice. |
| [Solana Foundation rewards](https://github.com/solana-foundation/rewards/blob/20522ed0bf7a514fcd50f872de90179e0dbbefe6/program/src/utils/vesting_utils.rs#L7-L63) | Immediate, linear, cliff, and cliff-linear schedules. Optional revocation distinguishes return of nonvested tokens from a full clawback. | Ship one cliff-plus-stepped-linear shape. Cancellation preserves vested beneficiary value and returns only unvested value. Reject full clawback. |
| [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui/1.x/vesting-wallet) | Shared, permissionless release to a fixed beneficiary; start, cliff, period, and steps; capability-gated teardown. The July 2026 audit index includes its vesting wallet review. | Adopt the schedule parameters, fixed payout target, permissionless claim, overflow checks, and final remainder release. Keep Blast's implementation focused and dependency-free. |
| [Streamflow vesting](https://streamflow.finance/vesting) | Product support for cliffs, graded or linear schedules, cancellation rules, batch creation, and contract transfer. | Use its schedule and cancellation concepts as product evidence. Keep batching, tradable contracts, price conditions, and platform fees off chain or out of scope. |

## Proposed Blast surface

Each schedule is fully funded at creation and contains one coin type. The fixed
parameters are:

- `beneficiary`: the only payout address;
- `start_ms`: the schedule origin;
- `cliff_ms`: the no-release interval measured from `start_ms`;
- `period_ms`: the release cadence;
- `periods`: the number of equal tranches; and
- optional cancellation with a fixed `refund_recipient` and a schedule-bound
  `CancelCap`.

The cliff gates the accrued schedule; it does not move the end. At the cliff,
all complete periods since `start_ms` become claimable. Intermediate tranche
calculations round down. The final boundary releases every remaining atomic
unit.

The default is irrevocable. Cancellable schedules support contributor and
service-provider grants. Cancellation pays all vested-and-unclaimed value to
the beneficiary and returns only unvested value. A transferable beneficiary,
full clawback, administrator pause, arbitrary curve, oracle or milestone
trigger, late deposit, and onchain recipient batch are separate products.

## Consensus boundary

Custody, schedule authorization, time-gated release, cancellation settlement,
and released-balance conservation require consensus. Claim previews, end-time
display, calendar formatting, schedule aggregation, and batch transaction
construction are deterministic SDK work.
