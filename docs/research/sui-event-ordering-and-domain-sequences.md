# Sui event ordering and application-level sequences

Date: 2026-08-23

## Question

Does the singleton `RuntimeConfig` need to store and emit its own monotonically
increasing `sequence`, or do Sui's event coordinates plus Blast's event payloads
already make configuration replay deterministic and complete?

## Verdict

Do not add an application-level `sequence` to `RuntimeConfig`,
`RuntimeConfigCreated`, or `ProtocolFeeShareChanged`.

Sui already assigns each event a ledger position and exposes ordered,
cursor-resumable event queries. Blast's creation event identifies the singleton
and records its initial value; each mutation event identifies the same object and
records the old and new values. Replaying those payloads in Sui ledger order is
therefore sufficient to reconstruct the configuration. A stored counter would
duplicate indexing metadata while adding object storage, mutation, event bytes,
and an ABI field with no protocol meaning.

This conclusion is specific to this singleton runtime configuration, whose
mutation events carry replay-complete old and new values for each setting. A
domain sequence can still be justified when it represents protocol state,
orders facts whose ledger order is intentionally insufficient, or supports an
ingestion model that deliberately does not retain Sui cursors/checkpoint
coverage.

## Primary-source findings

### 1. Sui supplies unique event identity and within-transaction order

At Blast's pinned Sui revision
`06734f6ff0af45d8632a14a4dc4b100197f6b1a2`, `EventID` is the pair
`(tx_digest, event_seq)`, and the source describes `event_seq` as the event's
sequence number within the transaction. The event envelope likewise calls its
counter consecutive and per-transaction. See pinned
[`sui-types/src/event.rs`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-types/src/event.rs#L29-L54).

The pinned legacy JSON event representation uses that `EventID` as its event
query cursor, and a page's `next_cursor` resumes after its last item. See pinned
[`sui_event.rs`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-json-rpc-types/src/sui_event.rs#L29-L55)
and [`Page`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-json-rpc-types/src/lib.rs#L40-L49).
This is legacy API evidence; new Blast integrations should use gRPC or GraphQL,
not deprecated JSON-RPC.

### 2. Current event APIs expose canonical ledger order

The current first-party gRPC schema reports an event's containing `checkpoint`,
emitting `transaction_digest`, zero-based `transaction_index` within that
checkpoint, and zero-based `event_index` within the transaction. See the
immutable first-party
[`Event` schema](https://github.com/MystenLabs/sui-apis/blob/201981c5d5fb99c8908f99b4a853fe47511cd6e3/proto/sui/rpc/v2/event.proto#L36-L63).

`LedgerService.ListEvents` returns events in ascending or descending packed
event-sequence order and supports checkpoint-bounded queries. Every response
frame carries a safe resume watermark. See the immutable first-party
[`LedgerService` schema](https://github.com/MystenLabs/sui-apis/blob/201981c5d5fb99c8908f99b4a853fe47511cd6e3/proto/sui/rpc/v2/ledger_service.proto#L41-L45)
and its
[`ListEvents` contract](https://github.com/MystenLabs/sui-apis/blob/201981c5d5fb99c8908f99b4a853fe47511cd6e3/proto/sui/rpc/v2/ledger_service.proto#L264-L310).

The pinned Sui implementation makes that ordering coordinate explicit:
`Position::Events` contains `(checkpoint, tx_seq, event_index)`, while
`EventPosition` is ordered by `(tx_seq, event_index)`. Its scan walks event
indices from `0..event_count` for ascending order and reverses them for
descending order. See pinned
[`sui-rpc-cursor`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-rpc-cursor/src/lib.rs#L13-L43),
[`EventPosition`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-rpc-api/src/ledger_history/query_options.rs#L27-L57),
and [`event_scan`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-rpc-api/src/grpc/v2/ledger_service/event_scan.rs#L180-L225).

### 3. Cursors and checkpoint watermarks provide completeness and gap-safe resume

The first-party query schema defines `after` and `before` as canonical,
exclusive ledger-position bounds. Its watermark cursor is the safe resume point,
and its checkpoint field is the inclusive checkpoint boundary fully covered by
the scan. See immutable first-party
[`QueryOptions` and `Watermark`](https://github.com/MystenLabs/sui-apis/blob/201981c5d5fb99c8908f99b4a853fe47511cd6e3/proto/sui/rpc/v2/query_options.proto#L15-L49)
and
[`Watermark` coverage semantics](https://github.com/MystenLabs/sui-apis/blob/201981c5d5fb99c8908f99b4a853fe47511cd6e3/proto/sui/rpc/v2/query_options.proto#L78-L100).

The official event guide recommends checkpoint streaming for custom indexers and
describes a subscription-first, checkpoint-watermarked backfill procedure that
avoids losing events between historical and live ingestion. See
[`Emitting Events`](https://docs.sui.io/develop/accessing-data/using-events#processing-events)
and its
[`gRPC indexing guidance`](https://docs.sui.io/develop/accessing-data/using-events#querying-events-with-grpc).

Consequently, reliable ingestion should detect/avoid gaps using the chain's
cursor and checkpoint coverage. Jumps in checkpoint, transaction, or event
indices are expected in filtered results, so numeric adjacency is not itself a
gap test. A Blast counter is not a replacement for the native mechanism: it
cannot resume a query, prove checkpoint coverage, identify the omitted
transaction, or detect a missing final domain event when no later domain event
arrives.

## Replay proof for the runtime fee share

Starting at package deployment:

1. `RuntimeConfigCreated(runtime_config_id, protocol_fee_share_bps)` establishes the
   unique entity and initial value.
2. Each `ProtocolFeeShareChanged(runtime_config_id, old, new)` applies to that entity.
3. Process mutations in Sui ledger order. Require `old` to equal the replayed
   current value, then replace it with `new`.

This reconstructs the exact live scalar after every successful mutation. The
`old` value is a domain-level continuity check; Sui's event position and
watermark are the ordering and ingestion-completeness mechanism. Adding
`sequence` would only provide a second continuity hint, not additional state
needed for replay.

## Durable rule derived from the evidence

Do not add an application-level sequence, revision, nonce, schema tag, or action
tag to a Sui event merely for ordering or generic indexing convenience. First
inspect the pinned Sui event representation and the production query API's
cursor/checkpoint guarantees. Add a domain sequence only when it has a stated
protocol invariant that native ledger position plus replay-complete payloads do
not satisfy.
