# Blast stepped-linear vesting

This independently deployed Sui Move package implements the schedule accepted
in [ADR 0052](../../../docs/decisions/0052-stepped-linear-vesting.md).

Each `Vesting<CoinType>` is fully funded at creation, fixed to one beneficiary,
and published as a key-only shared object. Its schedule uses:

- `start_ms`;
- `cliff_ms`, measured from the start;
- `period_ms`; and
- `periods` equal tranches.

Use `new_irrevocable` for permanent grants. Use `new_cancelable` when a
schedule-bound `CancelCap` may settle vested value to the beneficiary and return
only unvested value to a fixed refund recipient. After either constructor, call
`share` in the same PTB.

Claims are permissionless. The contract always transfers the payout to the
fixed beneficiary. The package has no top-up, beneficiary rotation, schedule
edit, pause, global administrator, or launchpad dependency.

Production deployments are immutable. After bytecode verification, consume the
published package's `UpgradeCap` with `sui::package::make_immutable` and record
the transaction in the normalized deployment record.

## Error registry

| Code | Macro | Meaning |
| ---: | --- | --- |
| 0 | `invalid_beneficiary` | The beneficiary is the zero address. |
| 1 | `invalid_refund_recipient` | A cancellable schedule targets the zero refund address. |
| 2 | `zero_allocation` | The funding coin has zero value. |
| 3 | `zero_period` | The tranche period is zero. |
| 4 | `zero_periods` | The tranche count is zero. |
| 5 | `invalid_cliff` | The cliff exceeds the complete schedule duration. |
| 6 | `schedule_overflow` | The duration or end timestamp does not fit in `u64`. |
| 7 | `nothing_claimable` | No new value has vested. |
| 8 | `invalid_cancel_cap` | The cancellation cap belongs to another schedule. |
| 9 | `schedule_not_ended` | Close was requested before the end boundary. |
| 10 | `schedule_not_empty` | Close was requested while the schedule still holds funds. |
| 11 | `cancel_cap_required` | A cancellable schedule must finish through its matching cap. |

The next new error must use code 12.

## Verification

Run with the workspace-pinned Sui CLI:

```bash
sui move build
sui move lint --warnings-are-errors
sui move test --lint
```
