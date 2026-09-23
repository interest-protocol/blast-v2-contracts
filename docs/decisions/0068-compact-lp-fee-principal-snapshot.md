# 0068: Compact the LP-fee principal snapshot before release

- Status: **superseded by [0088](0088-reusable-launch-accounting-and-atomic-migration.md)**
- Date: 2026-09-02
- Amends: [0011](0011-event-schema-and-replay.md),
  [0012](0012-flywheel-features.md),
  [0054](0054-v3-dex-migrators-and-locked-lp-fees.md),
  [0059](0059-production-launchpad-abi-and-sdk-parity.md), and
  [0066](0066-aftermath-dao-fee-pool.md)

## Context

Every fee-collection transition reads position principal immediately before and
after the venue interaction and aborts unless the values are equal. The
pre-release `LpFeesCollected` event nevertheless records both values. A
successful transaction therefore emits the same `u128` fact twice.

The SDK reducer already treats only the final value as the authoritative
principal snapshot. The aggregate migrators package has no recorded production
publication, so its event layout can still be compacted without preserving an
obsolete compatibility field.

## Decision

Keep both local reads and the equality assertion in each venue transition. The
assertion remains adjacent to the external interaction that could change
principal.

Change `LpFeesCollected` to contain one `principal_liquidity: u128` field. Pass
only the verified post-collection value into the common vault accrual helper and
event emitter. The field is the canonical final principal snapshot for replay.

Aftermath also reads its locked LP balance before and after receiving DAO fee
coins, asserts equality, and emits only the verified final amount.

Update the SDK schema and reducer to consume `principal_liquidity`, then
regenerate the frozen production ABI artifact as an approved pre-release
amendment.

## Alternatives considered

**Keep both event fields as audit evidence.** Rejected because the on-chain
equality assertion already prevents a successful collection from committing a
changed principal value. Repeating the same value does not add a reconstructible
fact.

**Emit only the pre-collection value.** Rejected because completed-fact events
record final state. The post-collection value is the canonical replay snapshot.

**Move the equality assertion into the common vault helper.** Rejected because
the venue module owns the external interaction and its principal invariant. The
check must occur there before fee-ledger mutation.

## Consequences

- Each `LpFeesCollected` payload is one `u128` smaller.
- Indexers retain the same authoritative final principal state.
- Venue adapters still abort before accrual when collection changes principal.
- The Move event, SDK schema, reducer, tests, and frozen ABI change together
  before the first recorded migrators-package publication.

## Verification

- Source gates require one `principal_liquidity` event field and reject the old
  before/after field names.
- Every venue collection keeps its before/after equality assertion.
- Move build, warning-as-error lint, tests, and source boundaries pass.
- SDK ABI parity, type checking, event decoding, reducer tests, and the complete
  SDK test suite pass.
