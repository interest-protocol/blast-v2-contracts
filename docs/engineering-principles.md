# Engineering principles

## 1. Make invalid states hard to express

Use explicit lifecycle variants, typed authorities, and single-use transition
rights. Keep curve state, accrued fees, allocations, and migration claims
separate enough that one role cannot silently reinterpret another balance.

## 2. Guard, compute, mutate, emit

Protocol operations follow this order:

1. global version/pause/reentrancy guard;
2. cheap input, identity, lifecycle, deadline, and authorization checks;
3. bounds, slippage, balance, and economic checks;
4. external reads or calls that are actually required;
5. state mutation and transfers;
6. final-state event emission.

Guard ordering is observable through abort/revert precedence and therefore part
of the tested API. Never emit a state event before the state it describes is
final.

## 3. Treat rounding as value transfer

For every division, fixed-point conversion, share calculation, fee, and curve
quote, state which party receives the remainder. Use wide intermediates and
prove the narrowing boundary. Test one-unit trades, values on each side of every
step, maximum supported reserves, and the migration threshold.

The default safety posture is:

- user payout and collateral value round down;
- user obligation, protocol fee, and debt round up;
- no zero-output trade or zero-share deposit is silently accepted;
- inverse operations are tested for bounded, documented dust rather than assumed
  to be exact.

## 4. Preserve conservation

At every successful transition, tests must reconcile:

```text
assets in = assets out + reserves + accrued fees + explicitly burned amount
```

The exact equation varies by operation, but no value may disappear into an
adapter, rounding path, unclaimable remainder, or event-only counter.

## 5. Design composable APIs

Core functions produce values or state transitions; thin transaction entrypoints
may choose a recipient. On Sui, return owned objects/capabilities rather than
self-transferring them. Make the safe path useful in programmable transactions.

## 6. Separate dependency risk

Core builds should remain reproducible without fetching mutable heads. Pin Git
dependencies to full SHAs and package-manager dependencies to lockfiles. Put DEX,
oracle, or bridge dependencies behind adapters so their upgrade and failure
surface cannot leak into core.

## 7. Events are an accounting interface

Events are not UI notifications. They are the append-only record from which an
indexer can rebuild all economically relevant state. Every mutable setter,
claim, fee accrual/distribution, curve trade, lifecycle transition, allocation,
and migration must emit sufficient identity and final accounting data.

A replay test must reduce the event stream and compare it with contract state.
When a state field cannot be reconstructed, either improve the event or document
why the field is deliberately non-indexable.

## 8. Make operational facts reproducible

Build, test, simulate, deploy, wait for finality, and verify. Record normalized
deployment facts separately from raw tool output. A deployment summary must say
which source commit, toolchain, dependencies, parameters, administrator, and
transaction produced each onchain identifier.

For new Sui clients, use gRPC for standard current-state operations and execution;
use GraphQL for custom indexed or historical queries. Do not introduce JSON-RPC
into new code.

## 9. Prefer evidence over inherited claims

Compiler, cast, overflow, RPC, upgrade, and lint behavior must be verified using
the pinned toolchain and current official documentation. A reference TODO,
skill, test, or comment can be wrong or stale. Turn important assumptions into a
minimal executable test.

## 10. Complexity needs a budget

Do not add a mode, role, setter, adapter, package, proxy, or generic abstraction
without identifying the invariant or product requirement it serves. Delete dead
paths instead of suppressing warnings. Ship one complete adapter rather than
several placeholder integrations.

## 11. Remove redundant single-use temporaries

A local is a redundant single-use temporary when it only renames a pure
expression before passing or returning that value once:

```move
let value = pure_expression();
consume(value);
```

Prefer `consume(pure_expression())` when the name adds no domain meaning and
inlining preserves borrow lifetime, evaluation order, abort order, and mutation
order.

This rule is not based on use count alone. Keep a one-use local when it narrows
an overlapping borrow, holds a resource across checks, snapshots pre-mutation
state for an event, separates a mutation from an external call, names auditable
arithmetic, or preserves required evaluation order. In particular, copying one
field before mutably borrowing another field of the same Move value can be
required by the borrow checker.

## 12. Keep multi-phase transitions as readable orchestrators

A transition becomes a monolithic implementation when one body mixes several
independent phases, such as liveness recovery, rate-cache updates, custody
revaluation, receipt activation, buffer policy, and event emission. The problem
is not a fixed line count. The anti-pattern exists when a reviewer must hold
several invariants and nested branches in mind to verify one state transition.

Keep the owning function as a short, ordered description of the transition.
Extract cohesive phases into domain-named private helpers. Use a private
`macro fun` when the helper is only a source-organization boundary and its
instructions must remain expanded at the call site. A macro removes Move
function-call overhead; it does not make the expanded operations gas-free.

Before extracting a macro, verify argument evaluation, capture, borrow lifetime,
abort location, mutation order, and event order. Prefer a normal private
function when the helper is a reusable semantic boundary or when inlining would
duplicate substantial bytecode across call sites.

## 13. Use attributed strings for module-local errors

A bare numeric error constant in the module that raises it is an opaque-error
anti-pattern:

```move
const EInvalidInput: u64 = 0;
```

Define a stable numeric code and a descriptive message together instead:

```move
#[error(code = 0)]
const EInvalidInput: vector<u8> = b"Input must be greater than zero.";
```

Use this form for every error that is declared and raised in the same module.
It preserves the abort code while making compiler and client diagnostics useful.
The message must describe the violated invariant and must not merely restate the
constant name.

Package-wide error registries are the exception. When several modules share a
stable error namespace, keep the zero-cost package error macros and the canonical
registry documentation so the invariant is still asserted by its owning module.
