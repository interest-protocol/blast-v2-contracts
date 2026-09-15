# Event Replay Tests

Apply these rules when events, payloads, emitters, indexers, or replay promises
are in scope.

- Collect payloads and assert every field, not only event count or type.
- For each event and field, identify its authoritative recovery source and
  prove the payload adds a required fact. Include native effects, transaction
  metadata, compiled constants, durable immutable object content, and the prior
  stream.
- Assert eventless initialization when publication effects and bytecode recover
  every initial fact. Add a source-boundary gate that fails if an initializer
  emits again.
- Before publication, gate fields equal to `ctx.sender()` when native metadata
  already supplies the fact. Preserve attested actors, beneficiaries, and
  recipients that can differ from the sender.
- Reduce native-ordered events and compare every promised replayable field with
  final object state.
- Cover configuration changes between economic operations.
- Cover failed transitions and retries without inventing rolled-back events.
- Cover multiple entities and multiple events in one transaction.
- Treat a new event payload type or changed emission semantics as an event ABI
  migration.
- Assert every Move payload field and emission condition.
- When an indexer is in scope, require its reducer tests to support a migration
  before release.
- Keep explicit tests for deliberate redundancy such as delta plus total,
  old/new pairs, reconciliation snapshots, and values removed or delivered.

Coverage is complete only when every payload field and emission condition is
asserted, the reducer reconstructs every promised fact, and failed or migrated
paths preserve the declared event ABI.
