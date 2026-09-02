---
name: sui-move-source-style
description: Apply consistent Sui Move source organization, naming, visibility, abilities, signatures, `self` receiver naming, receiver and index syntax, direct UID access, pinned standard-library and framework reuse, macros, local-variable discipline, API vocabulary, documentation, and test-only conventions. Use when writing, simplifying, refactoring, or reviewing any `.move` source or test file.
---

# Sui Move Source Style

Make each file clearly communicate what it owns, who may change it, and how its state is created, updated, and retired, without requiring the reader to trace unrelated modules or call sites.

Target repository instructions, accepted design records, pinned toolchain behavior, and published compatibility commitments take precedence over this standard's examples.

## Order module sections

Use this order and omit empty sections:

1. module documentation and declaration;
2. grouped `use` declarations;
3. `// === Constants ===` or `// === Package Constants ===`;
4. `// === Public Types ===` or `// === Public Structs ===`;
5. `// === Private Initialization ===` when applicable;
6. `// === Public Functions ===`, subdivided by product operation in large modules;
7. `// === Public Aliases ===` when aliases materially improve the API;
8. `// === Package Functions ===`;
9. `// === Private Functions ===`;
10. `// === Test-Only Types ===` when needed, then `// === Test-Only Functions ===`.

Use title case. Group large public surfaces by domain operation, not only visibility.
Format function bodies as logical paragraphs, with one blank line between validation, derivation, mutation or transfer, emission, and return. Do not blank-line every statement or pad tiny helpers.

## Organize imports

- Consolidate imports from the same root address into one nested declaration per module. Do not repeat a root on separate lines; follow the repository's root ordering consistently.
- Do not import a member solely to shorten one call. Keep package error macros and one-off framework functions fully qualified; import members used repeatedly. Test modules may import ubiquitous `std::unit_test::{assert_eq, destroy}` helpers.
- Do not explicitly import Move 2024 implicit prelude modules such as `std::vector`, `std::option`, `sui::object`, `sui::transfer`, or `sui::tx_context`.
- Use aliases for clear receiver methods or real collisions, not to hide domain distinctions.

## Reuse pinned libraries before writing helpers

- Resolve the exact compiled revision from the edited package's own `Move.lock`, including the root package's dependency mapping and every deployment environment. Do not assume the unsuffixed framework entry is the root's pin; follow the root package's `deps` mapping and confirm the compiled dependency name in `BuildInfo.yaml`.
- Inspect the matching MoveStdlib, Sui framework, and dependency source before implementing an integer bound, arithmetic or conversion helper, vector or option helper, manual loop, object operation, or transfer seam. After a pinned build, check `build/<package>/sources/dependencies/<Dep>/` and `build/<package>/BuildInfo.yaml`, or use upstream source at the locked revision. A local interface stub proves linkage, not behavior.
- Search those sources for an existing function, receiver method, macro, or equivalent hand-rolled pattern before adding local code. Prefer the standard implementation when its units, rounding, borrow behavior, evaluation order, and abort semantics match the required contract.
- Prefer pinned methods and macros such as `checked_*`, `max_value!`, `div_ceil`, `mul_div`, `mul_div_ceil`, `do!`, `range_do!`, `do_ref!`, `map!`, `fold!`, `any!`, and `all!` when they make the invariant clearer. Use `saturating_*` only when saturation is the documented result, never as overflow recovery. Confirm availability for the exact integer width or collection type; do not use a macro merely to shorten code.
- Read a macro's definition before use. Because expansion occurs at the call site, confirm argument evaluation, capture and borrow behavior, short-circuiting, abort location, and lint output.
- Do not wrap a standard function only to rename it. Add a wrapper only when it owns domain validation, units, rounding, visibility, or a stable protocol boundary.
- Treat online documentation for a newer revision as discovery only; prove availability and semantics against the repository's pinned source.
- Treat bundled `sui prompt` guidance the same way: it is first-party discovery tied to the installed CLI, not proof that a feature exists in the package's pinned compiler or target network.

## Name by domain meaning

- Use lower snake case for packages, modules, files, functions, variables, and package macros.
- Use UpperCamelCase for structs and enums.
- Use uppercase snake case for ordinary constants.
- Use `EUpperCamelCase` for named error constants.
- End durable authority objects in `Cap`.
- End ephemeral authorization proofs in `Witness`.
- Name linear handoffs and hot potatoes for their domain fact: `Request`, `Receipt`, `Payload`, `Price`, or `FlashLoan`.
- Name phantom type parameters for their role: `Asset`, `Quote`, `CoinType`, or `Venue`, not `T` when the role matters.
- Name fixtures for what they provide: `ClaimFixture`, `UpgradeFixture`.
- Name tests as behavioral facts: `constructor_rejects_zero_allocation`.
- Name event payloads as completed past-tense facts: `AdminGranted`, `FeesClaimed`.
- Include rounding direction in math names: `apply_down`, `mul_div_up`, `to_assets_down`.

## Keep visibility narrow

- Use `public fun` only for real transaction or composition surfaces.
- Use a non-public `entry` function only when an operation must be directly callable by transactions but intentionally unavailable to other Move packages. Keep it thin, place endpoint-specific delivery there, and use a `public` function when cross-package Move composition is intended.
- Use `public(package) fun` for cross-module package internals.
- Use plain `fun` for same-module implementation details.
- Keep public ABI minimal; an upgrade cannot erase old callable bytecode.
- Treat every existing public function signature as fixed across compatible upgrades except for permitted relaxation of generic ability constraints. Treat every published struct or enum layout and ability set as fixed. Add a new function or type instead; when stored shape changes, provide an explicit authorized migration.
- Treat `init` as initial-publication-only because upgrades do not rerun it. Put post-upgrade setup in a named authorized migration or activation function.
- Keep struct fields private.
- Do not expose production getters, constructors, cleanup, or mutation solely for tests or frontend convenience.

## Assign abilities deliberately

- Give each type only the abilities its lifecycle requires.
- Use `key` only for values intended to become top-level owned or shared objects.
- Add `store` to a capability only when public transfer outside its defining module or nesting is intended.
- Remember that `store` also permits foreign modules to call public party-transfer, share, freeze, receive, and wrapping paths; audit the complete lifecycle before adding it.
- Avoid `copy` and `drop` on resources that must be consumed exactly once.
- Use `phantom` when the type parameter separates domains without a stored value.
- Move 2024 currently requires every struct type to be public. Do not confuse public type visibility with public authority: fields remain accessible only to the defining module, and constructors and operations should remain private or `public(package)` when external use is not intended.
- Do not use internal struct declarations or `extend module` merely because a newer guide shows them. Use them only after the pinned stable edition accepts them and the repository deliberately adopts them.

## Convert integers deliberately

- Move integer casts do not truncate: a narrowing `as` cast aborts when the value does not fit. Do not report truncation that the VM cannot perform.
- Still make every narrowing boundary auditable. Check the bound before expensive work or mutation when stable error ownership and precedence matter, and test the first rejected value.
- Use a pinned conversion helper when it adds domain validation or a required error contract; do not wrap a cast only to rename it.

## Order parameters

Use this order for public functions:

1. primary receiver or state object;
2. authorizing capability or witness;
3. other domain objects and values;
4. `Clock` or other framework reads;
5. `TxContext` last.

This order is Blast source style, not a PTB injection requirement. On toolchains and networks that enforce the protocol-135 `TxContext` rules, a callable signature may take it at most once as `&mut TxContext`, or multiple times as `&TxContext`; it must not take or return `TxContext` by value or return a reference to it. Verify activation against the target `ProtocolConfig` because the pinned Blast release predates that enforcement.

Use `&` for reads, `&mut` for actual mutation, and by value for resources the function consumes. Return newly created owned objects, coins, capabilities, and refunds. Transfer inside core only when delivery is the explicit endpoint contract.

Keep construction and publication separate when possible: `new` returns the owned value and `share` consumes it into shared state.

When a returned object has `key` but not `store`, provide its consuming sink in the defining module, such as `share(self)` for shared state or `keep(self, ctx)` for sender delivery. Do not strand a value that callers cannot transfer or share themselves.

## Use receiver syntax naturally

- Use dot syntax when the first parameter is the natural receiver: `market.supply(...)`, `cap.assert_market(...)`, `coin.into_balance()`.
- In the module that defines a type, name the natural-receiver first parameter `self` whenever adding or materially editing the function. Keep a role name for peer values of the same type or when `self` would obscure which value plays which role. Outside the defining module, name the parameter for its domain role. Constructors and genuinely static helpers have no `self`; the name documents intent, while dot syntax is determined by the first argument's type.
- Keep constructors and operations without a natural receiver module-qualified: `market::new(...)`, `curve::quote_buy(...)`.
- Add a module-local `use fun dependency::function as Type.method` when a pinned dependency exposes a natural receiver without receiver form. For a dependency type, keep the alias module-local. `public use fun` is legal only in the type's defining module; use it there only when it materially clarifies the external API.
- In tests, alias helpers with `use fun helper as Fixture.method`.

## Prefer canonical index syntax

- For new packages, set the stable `edition = "2024"` in `Move.toml`. In an existing package, follow its pinned edition and migrate deliberately; do not introduce an obsolete preview edition such as `2024.beta`.
- In Move 2024, prefer `&collection[index]`, `&mut collection[index]`, `collection[index]`, and indexed assignment over explicit `borrow` and `borrow_mut` calls when the collection exposes canonical index syntax. Bare `collection[index]` dereferences and copies the element, so it requires the element type to have `copy`.
- Pass each index argument exactly as the annotated accessor declares it: use `collection[key]` for a key taken by value and `collection[&key]` for a key taken by reference.
- Add `#[syntax(index)]` to a custom type only when indexing is its canonical, unsurprising public lookup API. Annotated accessors must be public and defined in the type's module, so do not widen a package-only API merely to obtain bracket syntax or hide insertion, settlement, authorization, or other surprising work behind it.
- When defining both immutable and mutable index accessors, keep their type parameters, constraints, subject type, index parameters, and return type identical except for reference mutability.

## Read object identity directly

- Inside a type's defining module, prefer its directly accessible UID field: `self.id.to_inner()`, `value.id.to_inner()`, or `id.to_inner()` after unpacking. Take the ID before sharing, transferring, or unpacking when it is needed afterward.
- Keep `object::id(value)` for generic `key` parameters, framework or external objects, and types defined in another module whose UID field is inaccessible.
- Do not add an ID getter merely to replace `object::id`; add one only when identity is a real part of the defining module's consumer-facing interface.

## Use locals deliberately

- Inline a pure single-use temporary when its name adds no domain meaning and inlining does not change borrow lifetime, evaluation order, or abort order.
- Keep a local when it is reused, names a unit or protocol role, freezes pre-mutation state for a later event, separates validation from mutation, narrows a borrow, or makes nontrivial arithmetic auditable.
- Never inline across a mutation or external call when the later read could observe different state. Do not recompute a proposed value after mutation merely to reduce locals.
- Construct a unit witness, one-off wrapper, direct getter, or immediate return at the call site when no intermediate invariant needs a name.
- Let assertion helpers validate. Do not make them return an unchanged read solely to save the owning transition from reading and naming its own pre-state.
- Do not add a pass-through parameter solely to relay or return a value unchanged; another module should receive it only when that module validates, transforms, consumes, or stores it.
- A witness, marker, or capability used for type-level authority is not unused: keep it as `_` or a meaningful `_role` name. Remove an unread parameter from private code and from a signature already changing for another reason. Otherwise, do not churn a published or intentionally uniform forwarding signature merely to drop it; keep the parameter anonymous and document the compatibility reason only when it is not obvious.

## Use precise API vocabulary

- Use `new` for the module's primary constructor.
- Use descriptive constructors when variants matter: `new_cancelable`, `new_irrevocable`, `new_kinked`.
- Name reads exactly for the domain value returned.
- Use `is_*` and `has_*` for predicates.
- Reserve `into_*` for a real type conversion and name its destination.
- Use `destroy` when a consuming wrapper deletes itself and releases contents.
- Store `Balance` inside objects and accept or return `Coin` at public asset boundaries unless a different custody model is deliberate.
- Use the exact domain verb for a mutation: `grant_admin`, `claim_fees`, `begin_migration`.
- Reject vague production names such as `fields`, `parts`, `data`, `info`, `handle`, and `process` unless one is the precise domain term.
- Permit `<event>_fields` only as a narrow test-only payload snapshot convention.

## Document the contract

- Document public types, functions, invariants, hard bounds, rounding, and irreversible effects.
- Explain the authority and consumption semantics of capabilities, witnesses, and hot potatoes.
- Put all test constructors, malformed-value seams, field snapshots, and mutation hooks at the end with `#[test_only]`.
- Use a narrow lint suppression only after reproducing the warning under the pinned compiler. Put the rationale adjacent to it.
