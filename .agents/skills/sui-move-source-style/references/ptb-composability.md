# PTB-Composable Public APIs

Apply these rules when designing or reviewing transaction-facing functions,
returned resources, delivery sinks, or APIs intended for chained calls.

## Define the composition contract

For each affected operation, name its intended caller, the source of every
input, each result's next consumer or terminal sink, and any intentional
composition restriction. The useful unit is a complete PTB data flow, not an
isolated callable function. Include a preceding producer when the operation is
intended to accept newly created assets or values.

For example, a conceptual swap-and-deposit PTB has this shape:

```text
splitCoins(input_coin, exact_input) → payment
swap(pool, payment, minimum_output) → output_coin, refund_coin
deposit(vault, output_coin) → position
position::keep(position)             // defining-module sink for key-only type
transferObjects([refund_coin], recipient)
```

If `swap` transfers `output_coin` internally, `deposit` cannot use it as a
command result. Returning only its ID does not restore that data flow. Every
additional receipt or change result also needs its own consumer or sink.

Keep capabilities, ownership, pause, version, slippage, conservation, and
settlement checks inside the owning operation. Arbitrary callers can reorder,
repeat, or bypass optional wrappers. A reusable core must enforce the same
invariants when called directly.

## Choose callable signatures

- Use `public fun` for reusable PTB and cross-package Move operations. Adding
  `entry` to a public function is unnecessary for PTB access.
- Non-public `entry` functions are also PTB-callable, but cannot be called from
  another package's Move code and can have additional argument restrictions.
  Use them for deliberate endpoints, not as the default reusable surface.
- Check the target's compiler and active protocol before relying on `entry`
  parameter or return rules. Older restrictions and newer feature flags differ;
  neither "entry cannot return resources" nor "entry cannot compose" is a
  universal rule.
- Make inputs constructible from supported pure inputs, accessible objects,
  or earlier command results. A custom non-object struct may require a public
  constructor; arbitrary BCS bytes do not make it an admissible pure input.
- Use by-value results as the portable composition boundary. A Move accessor
  returning `&T` or `&mut T` is not automatically a PTB-callable API: reference
  results require explicit support in the active protocol and transaction
  tooling. Keep internal reference accessors when useful; add a value-returning
  operation only for a concrete PTB consumer.
- Let the runtime supply `TxContext`; transaction builders omit it from their
  user arguments. Select concrete generic types at the call site.

## Keep outputs available and finish their lifecycle

- Return intermediate assets and change instead of transferring, sharing,
  freezing, or wrapping them before the next intended consumer can use them.
  A terminal settlement or delivery operation may deliberately perform those
  effects. Document the boundary rather than weakening required custody.
- Keep result arity and ordering explicit, including all refunds and receipts.
  An emitted event or returned `ID` cannot substitute for the actual resource
  needed as a later command argument.
- For an asset boundary, prefer `Coin<Asset>` for ordinary PTB coin commands.
  A deliberate `Balance<Asset>` seam is valid when the caller can produce and
  consume it, including conversion through the pinned framework.
- Preserve minimal abilities. A `key`-only object needs a public sink in its
  defining module; generic PTB transfer or public sharing requires `store`.
  Add a sink, not `store`, when unrestricted transfer or nesting would weaken
  the type's authority model.
- Account for every result without `drop`, including zero-valued coins and
  secondary outputs. Borrowing a result does not consume it. Move it into a
  legitimate consumer, transfer, storage path, or destructor before PTB end.
- For a no-ability receipt or hot potato, expose the authorized finalizer needed
  to complete the same PTB. Bind it to the correct state, asset, amounts, and
  operation. Omitting or mismatching settlement must fail atomically.
- Trace moves and borrows across commands. A moved resource is unavailable for
  later reuse; multiple uses must respect the actual signature's borrow rules.

## Preserve deliberate restrictions and published contracts

Randomness endpoints and other accepted security boundaries may deliberately
limit composition. Retain non-public `entry` and protocol-required ordering
where needed; record which chain is supported and which is rejected. Do not
expose a public bypass simply to make an example PTB work.

For flash or hot-potato workflows, check non-public `entry` argument rules in
the target execution version. Values connected to an outstanding hot potato
can be rejected even if the endpoint does not receive the receipt itself.
Use a public operation only when its security model permits that composition.

Preserve published public signatures and type abilities. If a published
endpoint transfers an output internally, add a compatible return-based API
when the accepted upgrade policy permits it; keep existing callers working.
Old bytecode remains callable, so a wrapper or new API cannot repair a missing
invariant in an old unguarded path.

## Completion gate

Every changed reusable operation has a concrete PTB showing admissible inputs,
result chaining, and a legal destination for every non-droppable output.
Verification must exercise real PTB commands under the target protocol, not
only direct Move calls or SDK serialization. Report unavailable execution as
an evidence gap. Document intentional restrictions and retain their negative
tests rather than claiming unrestricted composability.

## Pinned implementation evidence

These sources corroborate the rules; inspect the target's actual revision and
activated protocol configuration before applying version-dependent behavior:

- [Move-call visibility, reference-result feature gate, context, and private generics](https://github.com/MystenLabs/sui/blob/44c34fcc49471177dfba3dce9e40bd38a868750e/sui-execution/latest/sui-adapter/src/static_programmable_transactions/typing/verify/move_functions.rs)
- [Non-public entry argument restrictions](https://github.com/MystenLabs/sui/blob/44c34fcc49471177dfba3dce9e40bd38a868750e/sui-execution/latest/sui-adapter/src/static_programmable_transactions/typing/verify/private_entry_arguments.rs)
- [Non-droppable result checks](https://github.com/MystenLabs/sui/blob/44c34fcc49471177dfba3dce9e40bd38a868750e/sui-execution/latest/sui-adapter/src/static_programmable_transactions/typing/verify/drop_safety.rs)
- [Defining-module transfer and sharing versus public variants](https://github.com/MystenLabs/sui/blob/44c34fcc49471177dfba3dce9e40bd38a868750e/crates/sui-framework/packages/sui-framework/sources/transfer.move)
