# Object Custody and Storage Tests

Apply these rules when the design uses bounded inline collections, dynamic
fields, dynamic object fields, identity-bearing children, object wrapping, or
key-only returned objects.

- Exercise a bounded inline collection at maximum cardinality through every
  applicable lifecycle path. Measure serialized size and gas.
- For dynamic child storage:
  - decode every entry;
  - query each identity-bearing child by its original object ID and verify its
    current type, owner, version, and canonical state after every relevant
    committed mutation or custody transition;
  - traverse dynamic-object-field metadata back to the controlling parent and
    reconstruct promised derived values without application infrastructure;
  - for intentional wrapping, consumption, or deletion, verify the terminal
    transaction effect and approved reconstruction path;
  - prove parent destruction strands no child or value;
  - cover intentional retention on close or cancel;
  - test rebate recovery only when accepted economics require it.
- Test that every returned key-only object composes in the same transaction and
  lands through its defining module's `share` or `keep` sink.
- When historical object state is promised, verify the checkpoint,
  transaction-effects, archival, or indexer path for every relevant committed
  version. Prove failed transactions create no apparent object transition.

Coverage is complete only when every child and returned object has a tested live
lookup, custody transition, terminal path, reconstruction source, and failure
behavior matching its storage invariant.
