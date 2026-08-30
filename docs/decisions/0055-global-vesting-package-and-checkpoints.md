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
released value, and an immutable `vector<Checkpoint>`. A checkpoint contains:

- `timestamp_ms`, an absolute Sui clock timestamp; and
- `cumulative_amount`, the total atomic units vested at that timestamp.

Callers create a linear `Schedule` value with `new_schedule()`, append
entries with `schedule.add(timestamp_ms, cumulative_amount)`, and consume the
completed value in `new_irrevocable` or `new_cancelable`. `Schedule` cannot be
dropped or stored, so a PTB cannot abandon an incomplete builder.

The builder contains 1–256 checkpoints. Timestamps and cumulative amounts are
strictly increasing. The first timestamp must be greater than or equal to the
current Sui `Clock`, and the last cumulative amount must equal the complete
funding coin value. These checks prevent past schedules, ambiguous zero-value
steps, surplus custody, and an unvested terminal remainder.

At time `t`, vested value is zero before the first checkpoint and otherwise the
cumulative amount of the last checkpoint whose timestamp is at most `t`.
Claim uses binary search over the immutable vector and transfers only newly
vested value to the fixed beneficiary. The 256-entry bound is a module constant
and caps construction work and serialized shared-object size.

The module mirrors ADR 0052 cancellation semantics. `new_irrevocable` creates
no authority. `new_cancelable` fixes a nonzero refund recipient and returns one
schedule-bound `CancelCap<CoinType>`. Cancellation consumes both objects, pays
vested-and-unclaimed value to the beneficiary, and sends only unvested custody
to the fixed refund recipient. Possession of the cap does not select either
recipient.

Creation, claim, cancellation, and close emit direct module events. Creation
records the schedule id, total amount, and checkpoint count, but does not copy
the checkpoint data into an event. An indexer or SDK reads the bounded vector
from the created shared object's canonical content. The SDK owns local paging,
previews, labels, calendars, and batched transaction construction.

## Rejected alternatives

**Separate package per schedule shape.** Rejected because both modules have the
same framework-only dependency and immutable deployment policy. Separate
packages would add deployment and SDK surface without a security boundary.

**Dynamic checkpoint storage.** Rejected because a non-empty `TableVec::drop`
deletes its table UID without removing the dynamic-field children, stranding
their storage rebates when a vesting object is canceled or closed. The maximum
inline vector is about 4 KiB, well below the object-size limit, and avoids child
reads and writes on every lifecycle operation.

**Custom dynamic fields.** Rejected because the entries have no independent
identity or lifecycle, the vector is bounded, and a custom index would recreate
length, ordering, iteration, and complete-deletion logic.

**Relative offsets and basis points.** Rejected because absolute timestamps and
atomic cumulative amounts are the canonical settlement facts and require no
rounding policy.

**Unbounded checkpoints.** Rejected because every checkpoint enlarges canonical
state. The 256-entry limit supports more than 21 years of monthly irregular
unlocks while fixing construction work and object size. Binary search keeps
each release lookup logarithmic in the checkpoint count.

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
- The immutable mainnet release is blocked until a full 256-entry irrevocable
  and cancellable vector is created and exercised on mainnet, with transaction
  digests, gas, serialized object size, SDK decoding, and first/middle/final
  boundary evidence recorded under `deployments/sui/mainnet/`.

## Sources

| Short ref | Full commit |
| --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` |
