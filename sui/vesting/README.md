# Blast vesting

This independently deployed, framework-only Sui Move package contains two
fully funded fixed-beneficiary schedule modules:

- `blast_fun_vesting::linear` releases equal proportional tranches using a
  start, cliff, period, and period count.
- `blast_fun_vesting::checkpoints` releases exact cumulative amounts at up to
  256 irregular timestamps.

Both modules support irrevocable schedules and fair cancellable schedules.
Cancellation requires the exact schedule-bound cap, pays vested-and-unclaimed
value to the fixed beneficiary, and sends only unvested value to the fixed
refund recipient. Claims are permissionless but cannot redirect payouts.

The package has no global administrator, top-up, beneficiary rotation, schedule
editing, pause, arbitrary curves, oracle dependency, or launchpad dependency.
Production deployments are immutable.

## Checkpoint builder

Checkpoint schedules use the framework `TableVec`, which stores entries as
indexed dynamic fields. Build one linear `Schedule` value in a PTB, then consume
it in a constructor:

```move
let mut schedule = checkpoints::new_schedule(ctx);
schedule.add(first_timestamp_ms, first_cumulative_amount);
schedule.add(final_timestamp_ms, total_amount);
let vesting = checkpoints::new_irrevocable(
    funds,
    beneficiary,
    schedule,
    clock,
    ctx,
);
vesting.share();
```

Timestamps and cumulative amounts must be strictly increasing. The first
timestamp cannot precede the current `Clock`, and the final amount must equal
the funding coin. Claims use binary search, so lookup work is logarithmic in
the checkpoint count. The 256-entry cap bounds dynamic-field creation and
persistent storage.

`VestingCreated` contains the total amount and checkpoint count, not a copy of
the checkpoint data. Indexers can read the indexed dynamic fields directly or
iterate `checkpoint_page(vesting, start, limit)`, whose limit is capped at 32.

## Error registry

Errors are explicit string-literal constants in the module that raises them.
Codes are stable within that module.

| `linear` code | Constant | Meaning |
| ---: | --- | --- |
| 0 | `EInvalidBeneficiary` | The beneficiary is zero. |
| 1 | `EInvalidRefundRecipient` | The refund recipient is zero. |
| 2 | `EZeroAllocation` | Funding is zero. |
| 3 | `EZeroPeriod` | The period is zero. |
| 4 | `EZeroPeriods` | The period count is zero. |
| 5 | `EInvalidCliff` | The cliff exceeds the schedule duration. |
| 6 | `EScheduleOverflow` | Duration or end time exceeds `u64`. |
| 7 | `ENothingClaimable` | No new value is vested. |
| 8 | `EInvalidCancelCap` | The cap belongs to another schedule. |
| 9 | `EScheduleNotEnded` | Close is before the end. |
| 10 | `EScheduleNotEmpty` | Close has remaining custody. |
| 11 | `ECancelCapRequired` | A cancellable schedule must use its cap. |
| 12 | `EStartInPast` | The start precedes the current clock. |

| `checkpoints` code | Constant | Meaning |
| ---: | --- | --- |
| 0 | `EInvalidBeneficiary` | The beneficiary is zero. |
| 1 | `EInvalidRefundRecipient` | The refund recipient is zero. |
| 2 | `EZeroAllocation` | Funding is zero. |
| 3 | `ENoCheckpoints` | The schedule is empty. |
| 4 | `ETooManyCheckpoints` | The schedule exceeds 256 entries. |
| 5 | `ECheckpointInPast` | The first checkpoint precedes the current clock. |
| 6 | `ECheckpointTimesNotIncreasing` | Timestamps are not strictly increasing. |
| 7 | `ECheckpointAmountsNotIncreasing` | Cumulative amounts are not strictly increasing. |
| 8 | `EFinalAmountMismatch` | The final amount differs from funding. |
| 9 | `ENothingClaimable` | No new value is vested. |
| 10 | `EInvalidCancelCap` | The cap belongs to another schedule. |
| 11 | `EScheduleNotEnded` | Close is before the final checkpoint. |
| 12 | `EScheduleNotEmpty` | Close has remaining custody. |
| 13 | `ECancelCapRequired` | A cancellable schedule must use its cap. |
| 14 | `ECheckpointPageTooLarge` | A read requested more than 32 entries. |

## Verification

Run with the workspace-pinned Sui CLI:

```bash
sui move build
sui move lint --warnings-are-errors
sui move test --lint
bash scripts/check_coverage.sh
```

The coverage script requires 100.00% Move coverage for both production modules.
See [ADR 0052](../../docs/decisions/0052-stepped-linear-vesting.md) and
[ADR 0055](../../docs/decisions/0055-global-vesting-package-and-checkpoints.md).
