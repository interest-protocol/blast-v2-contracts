# Sui Move Events

Apply these rules when adding, compacting, changing, testing, indexing, or
reviewing events, payload fields, emitters, or replay promises.

## Make events replay complete

From package publication onward, make every economically relevant mutable fact
promised to index reconstructible from these durable sources, alone or in
combination:

- native transaction effects and metadata;
- immutable published bytecode;
- historical contents of object versions referenced by creation effects, but
  only when durable archival access is guaranteed;
- the protocol event stream.

If those sources do not durably provide a required fact, emit the smallest
primitive needed to reconstruct it. Check transaction metadata, effects, and
object content before adding a field; absence from the inner Move struct does
not prove an event field is needed.

- Emit each mutable setter, claim, accrual, distribution, trade, lifecycle
  transition, allocation, and migration settlement.
- Name payloads as completed facts in past tense.
- Emit only after final state and asset movement are known.
- Carry stable entity identity plus the primitive delta, old/new pair, or final
  snapshot required for replay.
- Include post-transition totals when replay must detect gaps or resynchronize
  a promised aggregate.
- Record exact economic inputs when later configuration can change historical
  interpretation.
- Reject no-op setters so every emitted old/new pair records a real transition.
- Do not emit exactly reproducible display values.
- Do not add an application sequence, revision, nonce, schema tag, or action
  tag merely to order, paginate, classify, or detect gaps.
- Add a domain counter only when it is protocol state or native order plus
  payload type cannot sequence transitions. Record that decision.
- Emit one authoritative event for one accounting mutation.

## Audit necessity event by event

- Name the new protocol fact each event commits. The payload type's occurrence
  is itself a fact.
- Remove an event only when both its occurrence and every field already come
  from durable native effects, metadata, bytecode, object history, or the prior
  replay stream.
- Default publication initialization to eventless when it only shares or
  delivers objects recorded by publication effects and initializes compiled
  constants. Keep a creation event when an ordinary function commits values
  that can vary.
- Before publication, do not restate `ctx.sender()` as `buyer`, `seller`,
  `claimant`, `caller`, or another actor field; native event metadata supplies
  the sender.
- Keep an actor, attested identity, beneficiary, recipient, or refund address
  only when it can differ from the sender. Name and justify that role.
- On a non-mutating fact, emit only what it newly commits.
- Keep a destroyed object's ID when it distinguishes a multi-instance entity or
  closes a keyed replay fact. Omit it only when payload type and native metadata
  identify the entity uniquely.
- Store bounded immutable inputs only in canonical created-object content when
  the declared data-availability model makes that content durable.
- Preserve deliberate verification or resynchronization redundancy: delta plus
  final total, an old/new pair, a required snapshot, or the identity and final
  value removed or delivered.

## Design identity deliberately

- Carry identity for every multi-instance entity.
- Do not use the executing package version ID as an event-domain key.
  Compatible upgrades preserve existing Move type identity; partition a
  continuing stream by stable payload type and entity identity.
- Let a typed singleton mutation omit its unchanging owner ID only when
  production creates exactly one instance, replay begins at publication, and
  payload type partitions the stream.
- Keep old/new identity for root replacement or a transition that changes
  recognized singleton identity.
- Restore explicit identity when a later design permits replacement or multiple
  instances.
- Partition reducers by stable payload identity and process native Sui event
  order.

## Describe accounting precisely

- Distinguish pending custody, native burn, transfer to an irrecoverable
  address, refund, and returned residual.
- Include asset deltas and post-accrual totals when reconciliation needs both.
- Include the applied fee or policy input when configuration can change later.
- Document deliberately non-indexable facts, such as current ownership of a
  freely transferable capability, and direct consumers to native data.
- Before publication, keep reducers and field tests synchronized with payload
  changes.

## Centralize event construction

Use an envelope only when the package standard needs one stable outer namespace
for the package lineage. Indexers can subscribe to its defining module and use
the type argument to discover payloads added by later versions. A separate
package has a different envelope identity.

```move
public struct Event<T: copy + drop>(T) has copy, drop;

public(package) fun emit_event<T: copy + drop>(payload: T) {
    sui::event::emit(Event(payload));
}
```

- Keep payloads and package-only named emitters in `events.move`.
- Let only `events_wrapper` call `sui::event::emit` directly.
- Let transition modules mutate first and call descriptive emitters afterward.
- Do not pack the same payload ad hoc at several call sites.
- Keep collection, unwrap, and `<event>_fields` helpers test-only.
- Preserve schema, emitter, and replay discipline when a package intentionally
  uses direct native events. Do not add a wrapper for uniform appearance.

## Preserve event compatibility

- Treat payload types, fields, wrappers, identity, meaning, and emission
  semantics as published indexing API.
- Before publication, make compaction a deliberate one-time decision.
- After publication, do not add, remove, rename, reorder, or retype fields of an
  existing payload or change its abilities. Add a new payload type instead.
- Treat the replacement and any meaning or emission change as an indexing ABI
  migration.
- Adding emission only to upgraded bytecode does not make replay complete while
  callers can use an old version. Gate old mutators through an accepted
  operational transition before promising complete replay.

## Completion gate

Event design is complete only when every promised mutable fact can be replayed
from durable sources, every payload field has a necessary recovery role, and
every changed schema or emission condition has a compatible migration and test.
