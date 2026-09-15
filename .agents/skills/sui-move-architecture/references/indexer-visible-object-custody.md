# Storage and indexer-visible object custody

Use these rules when choosing inline or dynamic child storage, or when a Sui
`key` object's stable identity, ownership, current type, or live state must
remain independently discoverable by indexers, explorers, wallets, or standard
RPC tooling while another object controls its custody.

## Choose child storage by its invariant

- Use an inline vector when the contract enforces a safe maximum and entries
  are naturally accessed by index or bounded iteration as part of the parent.
- Use dynamic fields for extensible, typed-key child storage that need not
  remain independently discoverable by an original object ID.
- Use dynamic object fields when a child has its own `UID` and must remain
  separately discoverable while attached to a controlling parent.
- Use a table for a large map-like collection only when its scale justifies
  per-entry child storage and cleanup.
- Define every dynamic child's terminal lifecycle before choosing the storage
  seam. Close and cancel paths may retain children only while the parent stays
  accessible.
- Before destroying a parent, remove every child and transfer or destroy it as
  required so no value becomes unreachable. Recover storage rebates when
  economically worthwhile.

## Preserve objecthood

- Keep the object top-level or attach it as a `dynamic_object_field` child.
- Do not embed it in a normal struct field or store it as an ordinary
  `dynamic_field` value. Those forms wrap the value, so the original object ID
  no longer resolves as an independently readable live object.
- Prefer `dynamic_object_field` custody for an authority-bearing object that
  must remain discoverable under a controlling parent. The child stays
  object-owned and can be borrowed only through the parent's `UID` and the
  defining module's callable surface; discoverability does not make the
  authority shared or generally usable as a transaction input.
- Read canonical values from the preserved object. Do not add mirrored
  counters, owner fields, status flags, or duplicate state solely for indexer
  convenience.
- Derive projections from canonical objects, transaction effects, immutable
  package data, and replay-complete events where required. Do not require
  application infrastructure to attest a value that chain data can establish.

`dynamic_object_field` records the child's ID while retaining the child as a
separate storage object. An ordinary `dynamic_field` instead stores its value
inside the field object, even when that value has `key`. The distinction is not
observable from Move code that borrows the value, but it is material to
off-chain object discovery.

Framework evidence:
[`dynamic_object_field.move`](https://github.com/MystenLabs/sui/blob/60f0e8a6abb0523d5c9c7f5edc006f40d8dead03/crates/sui-framework/packages/sui-framework/sources/dynamic_object_field.move)
and
[`dynamic_field.move`](https://github.com/MystenLabs/sui/blob/60f0e8a6abb0523d5c9c7f5edc006f40d8dead03/crates/sui-framework/packages/sui-framework/sources/dynamic_field.move).

## Permit intentional wrapping only

Wrapping remains valid when loss of direct live-object discovery is an
accepted invariant rather than an indexing accident. Examples include making
an authority permanently unusable, consuming an object into a replacement,
or hiding an implementation detail whose original identity has no external
meaning.

Before wrapping an identity-bearing object:

1. Name why independent lookup must end.
2. Define the terminal status or replacement that external tooling will
   observe.
3. Approve an on-chain reconstruction path through transaction effects,
   preserved objects, and replay-complete events.
4. Prove no supported client, exit, audit, or authority workflow still depends
   on reading the original live object.

## Verify external custody

Use the target network's supported object and dynamic-field APIs, not only Move
unit tests, to prove that external tooling can:

1. Resolve the original object ID for as long as the object is live.
2. Read its current type, owner, version, and canonical state.
3. Observe the resulting object version or terminal effect after every
   committed transition that mutates the object or changes its custody.
4. Traverse dynamic-field metadata back to the controlling parent when the
   object is a dynamic object child.
5. Reconstruct every promised derived value from chain data without trusting
   application infrastructure.

If the product promises historical state, current-object reads are
insufficient. Verify the checkpoint, transaction-effects, archival, or indexer
path that preserves every relevant committed version. Failed transactions do
not create an object transition and must not appear as one.
