# 0055: Global vesting package and checkpoint schedules

- Status: accepted
- Date: 2026-08-29
- Amends: [0052](0052-stepped-linear-vesting.md)

## Context

ADR 0052 placed stepped-linear vesting in a package named for that one schedule
shape. Blast now also needs unequal and irregular unlocks. Calendar presets do
not justify more modules, but a bounded checkpoint schedule has different
canonical state and release logic from equal-period linear vesting.

The current protocol comparison is recorded in
[`../research/vesting-contract-patterns-2026.md`](../research/vesting-contract-patterns-2026.md).
It supports keeping linear cadence in one module and using checkpoints only for
unequal tranches. Oracle curves, mutable streams, governance locks, milestone
attestation, and bulk distribution have different trust or custody models.

## Decision

Consolidate the pre-deployment package at `sui/vesting/` under the named address
`blast_fun_vesting`. The package contains independent `linear` and
`checkpoints` modules. Each module owns its types, string-literal errors,
events, custody, cancellation capability, and tests. There is no shared wrapper
or speculative schedule abstraction.

`checkpoints::Vesting<CoinType>` owns one fully funded balance, one fixed
beneficiary, an optional fixed cancellation refund recipient, cumulative
released value, and an immutable `TableVec<Checkpoint>`. A checkpoint contains:

- `timestamp_ms`, an absolute Sui clock timestamp; and
- `cumulative_amount`, the total atomic units vested at that timestamp.

Callers create a linear `Schedule` value with `new_schedule(ctx)`, append
entries with `schedule.add(timestamp_ms, cumulative_amount)`, and consume the
completed value in `new_irrevocable` or `new_cancelable`. `Schedule` cannot be
dropped or stored, so a PTB cannot abandon the `TableVec` handle.

The builder contains 1–256 checkpoints. Timestamps and cumulative amounts are
strictly increasing. The first timestamp must be greater than or equal to the
current Sui `Clock`, and the last cumulative amount must equal the complete
funding coin value. These checks prevent past schedules, ambiguous zero-value
steps, surplus custody, and an unvested terminal remainder.

At time `t`, vested value is zero before the first checkpoint and otherwise the
cumulative amount of the last checkpoint whose timestamp is at most `t`.
Claim uses binary search over the immutable `TableVec` and transfers only newly
vested value to the fixed beneficiary. The 256-entry bound is a module constant
and caps construction work and persistent dynamic fields.

The module mirrors ADR 0052 cancellation semantics. `new_irrevocable` creates
no authority. `new_cancelable` fixes a nonzero refund recipient and returns one
schedule-bound `CancelCap<CoinType>`. Cancellation consumes both objects, pays
vested-and-unclaimed value to the beneficiary, and sends only unvested custody
to the fixed refund recipient. Possession of the cap does not select either
recipient.

Creation, claim, cancellation, and close emit direct module events. Creation
records the schedule id, total amount, and checkpoint count, but does not copy
the checkpoint data into a bounded event vector. An indexer reads the created
shared object, obtains the nested `TableVec` table id from object content, and
enumerates its indexed dynamic fields. The module also exposes
`checkpoint_page(vesting, start, limit)` for direct or simulated reads; the
limit is capped at 32. The SDK owns iteration, plus previews, labels, calendars,
and batched transaction construction.

## Rejected alternatives

**Separate package per schedule shape.** Rejected because both modules have the
same framework-only dependency and immutable deployment policy. Separate
packages would add deployment and SDK surface without a security boundary.

**Raw vector storage.** Rejected because it enlarges the parent shared object and
unnecessarily limits practical schedules to a small serialized value. The
constructor builder writes each entry into a framework `TableVec`.

**Custom dynamic fields.** Rejected because `TableVec` already supplies the
required indexed dynamic-field storage, length tracking, borrowing, and safe
drop lifecycle.

**Relative offsets and basis points.** Rejected because absolute timestamps and
atomic cumulative amounts are the canonical settlement facts and require no
rounding policy.

**Unbounded checkpoints.** Rejected because each checkpoint is persistent state
created onchain. The 256-entry limit supports more than 21 years of monthly
irregular unlocks while fixing creation work and storage growth. Binary search
keeps each release lookup logarithmic in the checkpoint count.

**Arbitrary nonlinear or price-gated curves.** Rejected until a concrete Blast
transition requires oracle trust or curve arithmetic that neither schedule can
express.

## Consequences

- Single unlock, cliff, periodic, continuous-like, and TGE-plus-linear remain
  linear presets or PTB composition, not modules.
- Unequal schedules store exact cumulative amounts and have no proportional
  rounding.
- A schedule with more than 256 irregular steps must be simplified or reviewed
  as a different product.
- Renaming the package and linear module changes the pre-deployment ABI. No
  published immutable deployment is migrated.
- Both modules retain fixture-based tests and the package-level 100% Move
  coverage gate.

## Sources

| Short ref | Full commit |
| --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` |
