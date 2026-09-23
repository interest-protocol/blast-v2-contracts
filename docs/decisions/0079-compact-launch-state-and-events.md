# 0079: Compact launch state and events before publication

- Status: accepted; amended by [0088](0088-reusable-launch-accounting-and-atomic-migration.md)
- Date: 2026-09-13
- Amends: [0011](0011-event-schema-and-replay.md),
  [0022](0022-dual-asset-fee-ledger-and-claims.md),
  [0040](0040-normalized-launch-state-intake.md),
  [0047](0047-coin-registry-authoritative-supply-mode.md),
  [0059](0059-production-launchpad-abi-and-sdk-parity.md), and
  [0077](0077-fixed-creator-selected-sell-burn.md)

> ADR 0088 replaces the compact launch and migration payload selections with
> its canonical replay fields for the new lineage. This ADR remains
> authoritative for avoiding derivable duplication, using native sender and
> event position metadata, emitting after mutation, and replaying ordered
> deltas; any field omission that conflicts with ADR 0088 no longer applies.

## Context

The pre-publication launch object retained two graduation rates after the
constructor had already converted them into immutable custody balances. Launch
events also repeated transaction sender, type arguments, ticket fields,
derivable trade values, and initial zero balances. The duplication lengthened
the contract and created multiple representations of the same fact.

## Decision

Store a value only while a later transition needs it. `Launch` therefore keeps
the protocol Quote migration fee rate, which migration consumes, but not the protocol
Meme graduation or liquidity-provision rates after construction. Their applied
rates and resulting balances remain in `LaunchCreated`.

Events contain the smallest replay-complete mutation facts:

- `LaunchTicketCreated` omits `launcher`; the native event sender is canonical.
- `LaunchCreated` links the ticket and records Quote, witness, nonzero custody,
  curve parameters, and applied rates. Meme identity, launcher, metadata cap,
  sell burn, and initial supply come from the ticket. Initial Quote, pending
  burn, and fee-ledger balances are defined as zero.
- `Bought` records accepted Quote rather than both supplied Quote and its
  refund. `Bought` and `Sold` record gross output/input, pending-burn custody,
  both-asset fee deltas, and final reserve snapshots. Fee totals are the sum of
  accrual deltas less claim amounts; the global protocol split is not repeated.
- Event actors and claimants use the native event sender. Launch type arguments
  come from the referenced launch. `Migrated` likewise omits repeated types,
  witness, migrator, and accumulated protocol fee totals; it retains only the
  graduation-fee deltas accrued by that transition.
- Configuration events contain the resulting values only. Native event order
  supplies their history, so old values and previous signer keys are omitted.
  `CreatorCapClaimed` contains only the Meme type because the ticket already
  records the designated recipient and the native sender identifies the
  claimant.

Reducers must process tickets before launches and launches before mutations.
They reject a `LaunchCreated` whose ticket has not been observed. A buy reaches
`MigrationReady` when its final real Quote reserve is at least the launch's
stored target.

## Consequences

- No fee is lost: all five applied launch rates are present in
  `LaunchCreated`; accrual deltas and claim amounts reconstruct every ledger
  balance, and the two removed object fields were constructor-only inputs.
- Zero-valued initial accounting is a schema rule rather than event payload.
- Event and object layouts change before first publication. SDK and indexer
  schemas must change atomically with the Move package.
- Raw event storage retains native sender and position metadata, while product
  projections join ticket and launch records for repeated identity fields.

## Verification

- Move tests decode each compact event and reconcile supply, fees, pending burn,
  reserves, and migration settlement.
- SDK replay tests reconstruct removed ticket and sender fields and derive the
  lifecycle threshold.
- The indexer projects launch creation through the referenced ticket and derives
  trade net amounts from gross amounts and fee deltas.
- The frozen pre-publication ABI artifact is regenerated with the compact object
  and payload layouts.
