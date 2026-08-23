# Blast V2 contract rules

These instructions apply to this repository. They are the implementation gate
for both `sui/` and `evm/`.

## Before making a change

1. Read this file, the root README, and the relevant files in `docs/`.
2. Read the chain-local README and manifest/toolchain configuration.
3. Inspect the existing implementation and tests before proposing a new
   abstraction.
4. For unstable toolchain or SDK behavior, read the installed documentation for
   the exact pinned version. Use current official documentation if it is not
   installed.
5. If the change settles a protocol, authority, upgrade, storage, dependency, or
   cross-chain parity decision, add an ADR under `docs/decisions/` first.

Reference repositories and skills are research inputs. Never copy a module,
storage layout, error number, address, dependency revision, or rule merely
because it appears there. Verify the claim against Blast's invariants and the
actual pinned toolchain.

For Sui Move implementation style, begin with
`interest-protocol/su-lending@a3552af11a531717378b6337a174f9340d1099dc`,
especially `packages/su`, its tests, `docs/error-codes.md`, and its repository
Move skills. Treat it as the primary house-style and security-pattern reference
for module organization, visibility, receiver syntax, diagnostics, capability
design, guard ordering, composability, testing, and lint gates. Use
`interest-protocol/memez-gg@00596fdac4dd11f427c7bc594e566ce36160db93`
as the historical Blast behavior/integration reference. The pinned comparison
and adopt/adapt/reject decisions live in
`docs/research/su-package-house-style.md` and `docs/reference-review.md`.

## Non-negotiable rules

- Keep one protocol specification and two idiomatic chain implementations.
- Prefer the smallest public ABI and the fewest privileged operations that meet
  the approved product scope.
- Validate all authorization, lifecycle, identity, bounds, deadlines, slippage,
  and payment conditions before mutation or external interaction.
- Never merge a production function whose intended path is `abort`, `revert`,
  `todo`, a dummy return, or a silent no-op.
- Never rely on debug-only assertions for economic safety.
- Do not add blanket lint suppressions. A narrow suppression needs an adjacent
  rationale and a regression test for the risk it permits.
- Bound every persistent collection and every loop whose input can grow onchain.
- Treat public types, function signatures, event schemas, error semantics, and
  storage layouts as release commitments.
- Keep secrets and private transaction material out of source, logs, deployment
  summaries, and fixtures.

## Protocol structure

Start with one core package/project per chain. Add a package only when it creates
a real security or dependency boundary, such as an external DEX or oracle
adapter. Do not split packages solely to mirror the historical repository.

The intended layering is:

1. types, errors, units, and pure math;
2. protocol state and lifecycle transitions;
3. fees, allocations, and vesting;
4. migration interfaces;
5. chain- or venue-specific adapters;
6. transaction/deployment tooling.

Core code must not import a venue adapter. Adapters depend inward on the narrow
core interface. See `docs/architecture.md`.

## State, authority, and upgrades

- Model lifecycle states explicitly and allow only named transitions.
- Capabilities/roles authorize actions; object possession or an address check
  must not accidentally imply broader authority.
- Keep distinct authority mechanisms in concern-owning modules. `acl.move` owns
  only root rotation and routine-admin membership; a feature configuration owns
  its own shared state and accepts only a borrowed `AdminWitness`. Public
  `acl::sign_in` must check the supplied `AdminCap` against the live singleton
  registry and return that unforgeable witness with `drop` as its only ability.
  An owned revocable admin cap must expose holder-driven destruction: remove its
  live registry id when present, delete its UID even after prior root revocation,
  and emit whether that destruction also removed active membership. Do not add a
  test-only deletion path that bypasses this production lifecycle.
  Feature setters must not also receive `ProtocolAuthority` or `AdminCap`. The
  module that owns a capability's one-time issuance also owns that capability
  type. Do not turn ACL into a registry for cryptographic keys, creator identity,
  fees, or unrelated feature state.
- Treat every backend-signed action as its own domain. Its configuration module
  owns the current authorized key and signature verification, while the domain
  module owns the exact signed message and state transition. Do not reuse a
  generic signer configuration across actions unless the shared domain and
  compromise scope are explicitly approved and tested.
- Keep a dedicated-key signed message to the fields that authorize its one
  transition. Do not duplicate a fixed Move message type with a schema-version
  or action-tag field. If one key must ever authorize multiple message types,
  add an explicit domain tag and approve the shared replay/compromise scope in
  an ADR before implementation.
- For a one-time capability claim, prefer consuming its linear authorization
  resource as the replay guard instead of retaining a persistent `claimed: bool`:
  validate first,
  consume the resource, create and return the capability, then emit the event.
  Events are index facts, never onchain replay guards. Do not add a parallel
  nonce. A repeatable signed operation needs an explicit bounded replay policy
  before it is implemented.
- Creator-cap claims must take `CreatorAuthority<Meme>` by value and return
  `CreatorCap<Meme>`. They must not directly transfer the cap, retain a claimed
  flag, or hide construction behind a separate issue function. The launch path
  must create exactly one creator authority for its unique meme type and remove
  it from launch state when claiming.
- After `CreatorCap<Meme>` is claimed, creator economic operations authorize with
  that typed capability. They must not re-check ACL membership, X identity, or
  the backend signer; those facts authorize issuance, not later fee ownership.
- Give every privileged setter a documented bound and corresponding event.
- Define pause scope precisely. Emergency pause must not strand user exits unless
  that behavior is explicitly approved and tested.
- Decide upgradeability before deployment. Version mutable shared state and gate
  old Sui package versions; define EVM proxy/storage policy explicitly if a proxy
  is approved.
- Minimize public structs and functions. Sui upgrades cannot erase old callable
  bytecode, and EVM upgrades cannot repair an incompatible storage commitment.

## Errors and events

- Use stable, named errors. Preserve already-published error meaning.
- Allocate codes from a documented append-only registry if numeric codes are
  used. Do not reuse a retired code.
- For Sui package-wide protocol errors, keep `errors.move` diagnostic-only:
  `#[test_only]` named constants document the source/test registry and
  `macro public(package) fun name(): u64` returns the production code. The
  module must never contain `assert!`, abort wrappers, storage, or authority.
- Perform `assert!(condition, errors::name!())` where the owning module checks
  the invariant. A reusable domain assertion may live only in the module that
  owns that state or capability; never move the assertion into `errors.move`.
- The error macro deliberately inlines the number into the caller. If the
  pinned linter reports `abort_without_constant`, suppress only that named lint
  on the affected module, with an adjacent rationale pointing to
  `docs/error-codes.md`; do not broaden the suppression.
- Keep `docs/error-codes.md` synchronized so frontends, SDKs, indexers, and
  tests can map every stable number to its macro, raising module, and meaning.
- Test the exact error and, when multiple guards can fail, the intended guard
  precedence.
- Name events as completed facts and emit them after the final successful state
  is known.
- On Sui, emit every protocol payload `T` through the single
  `events_wrapper::Event<T>` envelope and its package-only `emit_event` helper.
  State and diagnostic modules must not call `sui::event::emit` directly. Treat
  both the outer wrapper and inner payload type as published indexing ABI; an
  upgrade may add payload types but must not bypass or silently replace the
  envelope.
- A consumer starting at deployment and replaying events in order must be able to
  reconstruct lifecycle, balances/accounting, configuration, fee state,
  allocation state, and migrations without reading mutable state.
- Mutation events must include stable entity identity, old/new or delta values,
  final totals needed for reconciliation, and a revision/sequence when order is
  otherwise ambiguous.
- Treat event field changes as schema migrations with replay tests.
- Keep event collection, wrapper unwrapping, and payload field inspection under
  `#[test_only]`; do not publish view functions solely for event tests.

## Economic math

Every economic formula must document:

- input/output units and scale;
- valid input bounds and intermediate-width proof;
- monotonicity or conservation property;
- rounding direction and who receives the rounding remainder;
- behavior at zero, one unit, maximum supported value, and transition boundary.

Use wide intermediates and checked conversions. Never use a narrowing cast as a
substitute for a proved bound. Name helpers by rounding direction (`*_up` and
`*_down`) where direction moves value. In general, amounts owed to the protocol
or debt round up and user payouts round down, unless the product specification
explicitly chooses otherwise.

Do not replace multiplication/division with shifts or unchecked arithmetic
without an adversarial proof and boundary tests. Equivalent Sui and EVM formulas
must be differential-tested from shared vectors.

## Sui Move

- Use stable Move edition `2024`, not alpha/beta editions.
- Use a Blast-prefixed named address.
- Rely on the Move 2024 implicit prelude instead of importing it again. Do not
  write explicit `use` declarations for `std::vector`, `std::option`, `Option`,
  `std::internal`, `sui::object`, `ID`, `UID`, `sui::tx_context`, `TxContext`,
  or `sui::transfer`.
- Consolidate imports from the same root address into one nested declaration per
  module, such as `use blast_fun::{acl, events};` or
  `use sui::{clock::Clock, vec_set::{Self, VecSet}};`. Do not repeat separate
  `use blast_fun::...`, `use sui::...`, or `use std::...` lines.
- Do not import a module member solely to shorten one function or macro call.
  Keep those calls fully qualified, especially package error macros
  (`blast_fun::errors::name!()`), test assertion macros
  (`std::unit_test::assert_eq!()`), and one-off framework functions such as
  `sui::event::emit(...)`.
- Name capabilities with the `Cap` suffix and events in past tense.
- Keep package-wide production values in `sources/constants.move` as
  lower-snake-case `macro public(package)` accessors. Do not declare protocol
  limits, delays, byte lengths, schema tags, or layout offsets in state modules;
  derive related layout values from the primitive constants in that registry.
- Before defining an integer bound, arithmetic helper, vector helper, or manual
  loop, inspect the exact MoveStdlib and Sui framework revision pinned by
  `Move.lock`, then the pinned `su` house-style reference. Prefer the standard
  integer methods/macros (`min`, `max`, `diff`, `checked_*`, `saturating_*`,
  `max_value!`, `div_ceil`, `mul_div`, `range_do!`, `do!`) and vector macros
  (`do!`, `do_ref!`, `map!`, `filter!`, `find_index!`, `fold!`, `any!`, `all!`)
  when they preserve clarity and abort precedence.
- Never duplicate primitive maximum literals such as `MAX_U64`; use
  `std::uN::max_value!()` or checked arithmetic. The `#[test_only]` named error
  aliases in `errors.move` and constants local to test fixtures are deliberate
  non-production exceptions to the package constants registry.
- Prefer `public` composable functions that return newly created owned values.
  Direct transfer is reserved for deliberately non-composable entry wrappers.
- Order function parameters as primary object, capability or witness, domain values,
  system objects such as `Clock`, then `TxContext` last.
- Format function bodies as logical paragraphs. Use one blank line when the code
  moves between authorization/input validation, derived values, state mutation,
  object transfer or return, and event emission. Keep tightly coupled statements
  in the same paragraph; do not separate every statement or add blank lines to
  tiny single-purpose helpers without a real phase change.
- Cache an object or container read when the same derived value is used more than
  once and no intervening mutation can change it. Re-read after mutation when the
  live value is semantically required; never cache across a state transition just
  to satisfy this optimization rule.
- Use receiver-style dot syntax whenever the first argument is the natural
  receiver; this is mandatory for Blast-owned objects and same-package methods
  (`authority.assert_super_admin(cap)`, `config.set_signer(...)`,
  `creator_state.claim_creator_cap(...)`) as well as framework receivers
  (`ctx.sender()`, `clock.timestamp_ms()`, `uid.to_inner()`, `option.is_some()`).
  Add a local `use fun` receiver alias when the pinned dependency requires one.
  Module syntax is reserved for constructors, static helpers, macros, and
  operations that genuinely have no natural receiver; generic framework helpers
  such as `object::id<T>(&T)` remain static when the compiler cannot specialize
  them as receiver aliases without wrapper functions.
- Prefer package visibility for cross-module internals; expose public API only
  when external composability requires it.
- Default functions to private. Promote a function to `public(package)` only
  for a concrete production caller in another module, and to `public` only for
  a concrete external package or transaction caller. Keep test inspection under
  `#[test_only]`; tests alone never justify production ABI.
- Before adding a getter or view function, identify its production caller.
  Offchain consumers should use object reads and replayable events, while tests
  should exercise behavior or use test-only helpers.
- Organize every Move module with explicit `// === ... ===` section titles in
  this order, omitting empty sections: `Constants`, `Public Structs` or `Public
  Types`, `Private Initialization`, `Public Functions` (split by domain when a
  large module benefits), `Public Aliases`, `Package Functions`, `Private
  Functions`, `Test-Only Functions`. Move 2024 requires struct declarations to
  be public; minimize their fields and abilities when the type is only an
  implementation detail.
- Pin Git dependencies to immutable full commit SHAs. Keep the core package free
  of network-only dependencies; isolate external dependencies in adapters.
- Run lints as a hard gate. Use `assert_eq!`, bare `assert!` in tests, exact
  expected aborts, builder fixtures, randomized/property tests, and boundary
  enumeration where coverage tooling is insufficient.
- New TypeScript uses `SuiGrpcClient` for standard reads/writes/simulation and
  `SuiGraphQLClient` for custom indexed or historical queries. SDK libraries
  should accept `ClientWithCoreApi`. JSON-RPC is legacy-only.

## Solidity / EVM

- Use custom errors and explicit events for protocol failures and mutations.
- Apply checks-effects-interactions and guard reentrancy at the smallest correct
  boundary. Treat callbacks and non-standard tokens as hostile.
- Use safe token-transfer semantics and balance-delta checks where fee-on-transfer
  or rebasing assets are intentionally supported; otherwise reject them.
- Avoid arbitrary external calls and unconstrained delegate calls.
- If upgradeable, lock initializers, reserve storage deliberately, validate the
  upgrade authorization path, and regression-test storage layout.
- Pin compiler and dependency revisions before the first production contract.
- Use unit, fuzz, invariant, fork/integration, gas-bound, and differential tests
  as required by `docs/testing.md`.

## Deployment and release records

Do not treat console output or a `latest` pointer as the deployment record. Store
normalized, reviewable records under `deployments/<chain>/<network>/` containing
at least:

- schema version, network/chain ID, environment, and UTC timestamp;
- repository commit, clean/dirty state, compiler and toolchain versions;
- package/contract identifiers and dependency identifiers;
- deployer, transaction digest/hash, status, and created/admin/upgrade objects;
- constructor/init parameters and post-deploy verification results.

Raw simulator or broadcast output can remain generated and ignored. Public
normalized records must not contain secrets.

## Definition of done

A contract change is complete only when:

- the implementation is simpler than or justified against the current design;
- positive, negative, boundary, property/invariant, and replay tests pass;
- both chain implementations or the parity matrix explain any intentional gap;
- lint, format, build, and test commands pass with the pinned toolchains;
- affected errors, events, deployments, architecture, and ADRs are updated;
- no placeholder path, mutable dependency branch, broad suppression, or
  undocumented privileged action remains.
