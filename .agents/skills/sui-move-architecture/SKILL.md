---
name: sui-move-architecture
description: Architecture for Sui Move on-chain scope, invariant ownership, package and module boundaries, state and value types, authority, custody, abilities, public APIs, events and replay, and dependency seams. Use when designing, changing, simplifying, or reviewing any of those boundaries.
---

# Sui Move Architecture

Design the smallest on-chain system that preserves consensus, custody, composition, and reconstruction.

Target repository instructions, accepted design records, pinned toolchain behavior, and published compatibility commitments take precedence over this standard's examples.

## Apply the standard

1. Establish the target's publication status, accepted decisions, compatibility
   promises, and pinned dependencies. This context is complete when each source
   of authority for the design has been located or recorded as an evidence gap.
2. Map every affected invariant to its canonical state, owning module,
   authorized transitions, public consumers, and reconstruction source. The map
   is complete when every changed fact and callable seam has one owner.
3. Apply every relevant rule below and every triggered reference to that map.
   Resolve each conflict in favor of the target's accepted contract rather than
   this skill's examples.
4. Finish only when the architecture gate accounts for every changed package,
   module, state field, authority, public type or function, event, and external
   dependency.

## Load matching references

- **Object custody:** Read
  [Storage and indexer-visible object custody](references/indexer-visible-object-custody.md)
  completely when choosing inline or dynamic child storage, or when a `key`
  object is stored, nested, wrapped, indexed, or expected to remain discoverable
  by its original ID.
- **Events:** Read [Events](references/events.md) completely when adding,
  compacting, changing, indexing, or reviewing events, payload fields, emitters,
  or replay promises.
- **Value types:** Read
  [Reusable value invariants](references/reusable-value-invariants.md)
  completely when extracting, composing, simplifying, or reviewing a sealed
  value type, validated unit wrapper, or field relationship reused by multiple
  domain types.

Read every matching reference; keep the loaded set to the triggered branches.

## Decide what belongs on chain

Put logic or state on chain only when at least one of these conditions applies:

- authorize, reject, or order a consensus-critical transition;
- custody, allocate, conserve, mint, burn, or settle assets;
- provide a synchronous result for trustless contract composition;
- commit the smallest primitive fact required for independent reconstruction.

Keep deterministic projections, formatting, aggregation, previews, transaction construction, and convenience reads off chain. A transition can recompute a derived value internally when it must enforce fees, slippage, bounds, conservation, or another invariant.

## Choose package boundaries

- Start with one core package.
- Add a package only for a real security, deployment, ownership, or dependency boundary.
- Put DEX, oracle, bridge, or other volatile external dependencies in adapter packages.
- Make adapters depend inward on a narrow core interface. Never make core import an adapter.
- Keep independently deployed systems separate when core does not require their result synchronously.
- Do not split packages only to shorten files or mirror another repository.
- Do not ship placeholder integrations, dummy returns, silent no-ops, `todo`, or production functions whose intended path aborts. A dependency interface link stub that is never executed and is verified against deployed bytecode is not a production implementation.

Use this default direction:

```text
types, errors, constants, units, pure math
        ↓
state and lifecycle transitions
        ↓
fees, allocations, migration handoffs
        ↓
external adapters and independent systems
        ↓
SDK, indexing, transaction, and deployment tooling
```

## Organize modules by invariant ownership

- Make one module the owner of each coherent invariant set. A module is an
  invariant owner, not a bucket for one function, one type, or one conceptual
  subtopic.
- Keep code together when it has the same authority, lifecycle, consumers, and
  reason to change. The owning module may contain all of the related types,
  transitions, checks, and private helpers needed to preserve its invariants.
- Split a module only when the seam enforces a real security, custody,
  dependency-isolation, or visibility boundary. When the required boundary is
  independent deployment, split the package rather than pretending a module
  can deploy independently.
- A small module is justified when it enforces one of those boundaries;
  otherwise it is navigation overhead. Do not split merely to shorten a file,
  mirror a function or type taxonomy, or give every nameable subtopic a home.
- When two proposed modules share authority, lifecycle, consumers, and reason
  to change, combine them unless their seam enforces one of those boundaries.
- Put state with the lifecycle that mutates it.
- Put a capability type in the module that owns its one-time issuance and lifecycle.
- Put authorization checks beside the private authority representation they inspect.
- Extract a small authority module only for a real shared domain or to break a real module cycle.
- Separate live mutable settings from cold policy snapshotted into newly created state.
- Store and mutate each administrative resource in the module that defines its
  authority, lifecycle, and invariants.
- Do not combine capability custody, ACL membership, cryptographic keys,
  identity, fees, upgrades, or product configuration in a generic `config`,
  `manager`, or `admin` module.
- Avoid generic `config`, `utils`, `manager`, `helper`, or `registry` dumping grounds. Name the domain concern.

Use these module roles only when needed:

- package marker module: one-time witness and publisher claim; private `init`;
- `constants`: package-wide protocol constants as package macros;
- `errors`: package error registry with no state or assertions;
- `events`: payload schemas and package-only emitters;
- `events_wrapper`: the package's one envelope and raw emission seam;
- authority or `acl`: root rotation, routine membership, and ephemeral sign-in witness;
- runtime configuration: the smallest live settings;
- cold configuration: bounded policy copied into new domain objects;
- package administration: validated custody of `Publisher` and `UpgradeCap`;
- domain modules: lifecycle transitions and owned invariants;
- pure math modules: deterministic arithmetic without storage or transfer effects;
- adapter packages: sealed venue witness, external dependency, and venue settlement.

Give an initializer an OTW parameter only when it validates, transforms,
consumes, or stores that witness for its own concern. Other initializers take
`TxContext` only.

Treat initialization as publication-only. Package upgrades do not rerun module
initializers, so post-upgrade setup belongs in an explicit authorized migration
or activation transition.

## Make invalid states hard to express

- Model lifecycle states with an enum and permit only named transitions.
- Use typed capabilities for durable authority and drop-only witnesses for ephemeral authorization.
- Use a non-copyable, non-droppable resource for one-time handoffs and replay prevention.
- Wrap a stored linear resource in `Option<T>` only when a transition must remove it from a borrowed parent; do not pair that option with a redundant claimed flag.
- Use phantom type parameters for domain separation when no value of the type is stored.
- Keep reserves, fees, pending burns, allocations, refunds, and claims in separate balances when their ownership or terminal treatment differs.
- Use the defining module's exclusive construction and field access to enforce the type's invariants. Expose only constructors and mutation operations that create valid state and preserve those invariants.
- Give shared top-level state `key` only unless transfer or nesting is an explicit requirement.
- Add `store`, `copy`, or `drop` only when the intended lifecycle requires it.
- Treat every published struct or enum layout and ability set as fixed across
  compatible upgrades.
- To change stored shape, introduce a new type and an authorized migration, or
  use a dynamic-extension seam designed before publication.
- For every stored field, name its canonical authority and the transition that needs a local copy. Reject a mirror when construction makes disagreement unreachable or no operation can change the copy independently.
- Do not duplicate state already owned by a native registry or canonical object merely to revalidate it later. Read the authority at the transition that needs it, unless a sealed construction proof already establishes the invariant.
- Prefer consuming a unique authorization resource over storing a parallel `claimed` flag or nonce.
- Decide upgrade seams before publication. A compatible upgrade cannot add
  fields to an existing struct, so include version or migration fields only
  when an accepted upgrade plan requires them.
- Otherwise use a new type or a predesigned dynamic-extension seam instead of
  speculative flags, modes, roles, or governance hooks.

## Design authority by scope

- A protocol-global admin cap normally carries only its identity. Revocation comes from live shared registry state.
- A per-instance cap carries target IDs only when those IDs define its exact authority domain.
- The module that issues a capability owns its destruction, rotation, or consumption rules.
- Separate root authority from routine administration.
- Do not make object possession or an address check imply broader authority than the type promises.
- Do not pass overlapping capabilities to one operation.

## Protect dependency integrity

- Pin Git dependencies to immutable full commit SHAs and commit lockfiles.
- Keep core buildable without mutable external heads.
- Treat external interfaces as hostile versioned boundaries.
- Never rely on an external dependency to enforce core invariants. Validate adapter inputs and outputs, limit delegated authority and custody, and re-check asset, state, and economic invariants before committing settlement.
- Verify the deployed package, original type origin, ABI, and economic assumptions consumed by each adapter.

## Architecture gate

Architecture is complete only when every changed fact has a canonical owner,
every public seam has a concrete caller and invariant, every stored value has a
required lifecycle, and every promised off-chain fact has a durable
reconstruction source.

Reject on-chain logic whose removal would not weaken a consensus transition,
asset invariant, trustless composition seam, or independent reconstruction.
Reject speculative roles, modes, governance hooks, and public APIs without a
concrete caller and invariant.
