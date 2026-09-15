---
name: sui-move-source-style
description: Source conventions for Sui Move organization, names, visibility, abilities, signatures, errors, syntax, pinned-library reuse, locals, API vocabulary, documentation, and test-only seams. Use when writing, simplifying, refactoring, or reviewing `.move` production or test files.
---

# Sui Move Source Style

Make each file clearly communicate what it owns, who may change it, and how its state is created, updated, and retired, without requiring the reader to trace unrelated modules or call sites.

Target repository instructions, accepted design records, pinned toolchain behavior, and published compatibility commitments take precedence over this standard's examples.

## Apply the standard

1. Establish the package's edition, compiler and dependency pins, publication
   status, local instructions, and existing section vocabulary. Context is
   complete when each is known or recorded as an evidence gap.
2. Inspect every changed declaration and function in production and test code,
   including observable evaluation, abort, mutation, transfer, and emission
   order.
3. Read every matching reference below, then apply all relevant rules while
   preserving target behavior and published compatibility.
4. Finish only when every changed file has been checked for ownership,
   organization, imports, names, visibility, abilities, signatures, errors,
   syntax, locals, API vocabulary, documentation, and test-only seams.

## Order module sections

Use this order and omit empty sections:

1. module documentation and declaration;
2. grouped `use` declarations;
3. `// === Constants ===` or `// === Package Constants ===`;
4. `// === Errors ===` when the module defines error constants or macros;
5. `// === Public Types ===` or `// === Public Structs ===`;
6. `// === Private Initialization ===` when applicable;
7. `// === Public Functions ===`, subdivided by product operation in large modules;
8. `// === Public Aliases ===` when aliases materially improve the API;
9. `// === Package Functions ===`;
10. `// === Private Functions ===`;
11. `// === Test-Only Types ===` when needed, then `// === Test-Only Functions ===`.

Use title case. Group large public surfaces by domain operation, not only visibility.
Put locally declared error constants and a dedicated `errors.move` module's
macros under `// === Errors ===`. Omit the section when a module only raises
fully qualified errors defined elsewhere.
Format function bodies as logical paragraphs, with one blank line between validation, derivation, mutation or transfer, emission, and return. Do not blank-line every statement or pad tiny helpers.

## Organize imports

- Consolidate imports from the same root address into one nested declaration per module. Do not repeat a root on separate lines; follow the repository's root ordering consistently.
- Do not import a member solely to shorten one call. Keep package error macros and one-off framework functions fully qualified; import members used repeatedly. Test modules may import ubiquitous `std::unit_test::{assert_eq, destroy}` helpers.
- Do not explicitly import Move 2024 implicit prelude modules such as `std::vector`, `std::option`, `sui::object`, `sui::transfer`, or `sui::tx_context`.
- Use aliases for clear receiver methods or real collisions, not to hide domain distinctions.

## Load matching references

- **Library reuse:** Read
  [Pinned library reuse](references/pinned-library-reuse.md) completely before
  adding, replacing, or reviewing arithmetic, conversion, collection,
  iteration, object, transfer, macro, or framework-wrapper logic.
- **Move 2024 syntax:** Read
  [Move 2024 source syntax](references/move-2024-syntax.md) completely before
  changing or reviewing receiver aliases, index syntax, direct UID access, or
  partial generic inference.
- **Errors:** Read [Errors](references/errors.md) completely before changing or
  reviewing errors, assertions, abort ownership, guard precedence, or diagnostic
  compatibility.
- **Function shape:** Read
  [Function shape and locals](references/function-shape-and-locals.md)
  completely before splitting or simplifying a multi-phase function, extracting
  helpers, inlining locals, or changing pass-through parameters.

Read every matching reference; keep the loaded set to the triggered branches.
Follow the target package's pinned edition and compiler when a reference
example differs.

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
- Include rounding direction in math names: `apply_down`, `mul_div_up`, `to_assets_down`.

## Keep visibility narrow

- Use `public fun` only for real transaction or composition surfaces.
- Use a non-public `entry` function only when an operation must be directly callable by transactions but intentionally unavailable to other Move packages. Keep it thin, place endpoint-specific delivery there, and use a `public` function when cross-package Move composition is intended.
- Use `public(package) fun` for cross-module package internals.
- Use plain `fun` for same-module implementation details.
- Keep public ABI minimal; an upgrade cannot erase old callable bytecode.
- Treat every existing public function signature as fixed across compatible
  upgrades, except for permitted relaxation of generic ability constraints.
- Treat every published struct or enum layout and ability set as fixed.
- Add a new function or type instead of changing a published one. When stored
  shape changes, provide an explicit authorized migration.
- Treat `init` as initial-publication-only because upgrades do not rerun it. Put post-upgrade setup in a named authorized migration or activation function.
- Keep struct fields private.
- Do not expose production getters, constructors, cleanup, or mutation solely for tests or frontend convenience.

## Assign abilities deliberately

- Give each type only the abilities its lifecycle requires.
- Use `key` only for values intended to become top-level owned or shared objects.
- Add `store` to a capability only when public transfer outside its defining module or nesting is intended.
- Avoid `copy` and `drop` on resources that must be consumed exactly once.
- Use `phantom` when the type parameter separates domains without a stored value.
- Move 2024 currently requires every struct type to be public. Do not confuse public type visibility with public authority: fields remain accessible only to the defining module, and constructors and operations should remain private or `public(package)` when external use is not intended.

## Order parameters

Use this order for public functions:

1. primary receiver or state object;
2. authorizing capability or witness;
3. other domain objects and values;
4. `Clock` or other framework reads;
5. `TxContext` last.

Use `&` for reads, `&mut` for actual mutation, and by value for resources the function consumes. Return newly created owned objects, coins, capabilities, and refunds. Transfer inside core only when delivery is the explicit endpoint contract.

Keep construction and publication separate when possible: `new` returns the owned value and `share` consumes it into shared state.

When a returned object has `key` but not `store`, provide its consuming sink in the defining module, such as `share(self)` for shared state or `keep(self, ctx)` for sender delivery. Do not strand a value that callers cannot transfer or share themselves.

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
