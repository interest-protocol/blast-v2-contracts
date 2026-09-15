# Move 2024 Source Syntax

Apply these rules when adding, changing, simplifying, or reviewing receiver
syntax, method aliases, index expressions, direct object identity access, or
partial generic inference. Follow the target package's pinned edition and
compiler when it differs.

## Use receiver syntax naturally

- Use dot syntax when the first parameter is the natural receiver:
  `market.supply(...)`, `cap.assert_market(...)`, `coin.into_balance()`.
- In the defining module, name a natural-receiver first parameter `self` when
  adding or materially editing the function.
- Keep a role name for peer values of the same type or when `self` would obscure
  which value plays which role.
- Outside the defining module, name the parameter for its domain role.
- Give constructors and genuinely static helpers no receiver. Parameter names
  document intent; the first argument's type determines dot syntax.
- Keep operations without a natural receiver module-qualified:
  `market::new(...)`, `curve::quote_buy(...)`.
- Add a module-local `use fun dependency::function as Type.method` when a pinned
  dependency exposes a natural receiver without receiver form.
- Keep dependency-type aliases module-local. `public use fun` is legal only in
  the type's defining module; use it there only when it clarifies the external
  API materially.
- In tests, alias helpers with `use fun helper as Fixture.method`.

## Prefer canonical index syntax

- For new packages, set stable `edition = "2024"` in `Move.toml`. Follow an
  existing package's pinned edition and migrate deliberately; do not introduce
  an obsolete preview such as `2024.beta`.
- In Move 2024, prefer `&collection[index]`, `&mut collection[index]`,
  `collection[index]`, and indexed assignment over explicit `borrow` and
  `borrow_mut` calls when canonical index syntax exists.
- Remember that bare `collection[index]` dereferences and copies the element,
  requiring the element type to have `copy`.
- Pass an index exactly as its annotated accessor declares: use
  `collection[key]` for a key by value and `collection[&key]` for a key by
  reference.
- Add `#[syntax(index)]` only when indexing is the custom type's canonical,
  unsurprising public lookup API.
- Keep annotated accessors public and in the type's module. Do not widen a
  package-only API for bracket syntax or hide insertion, settlement,
  authorization, or other surprising work behind it.
- When defining immutable and mutable accessors, keep type parameters,
  constraints, subject type, index parameters, and result type identical except
  for reference mutability.

## Read object identity directly

- Inside a type's defining module, prefer its accessible UID field:
  `self.id.to_inner()`, `value.id.to_inner()`, or `id.to_inner()` after
  unpacking. Read the ID before sharing, transferring, or unpacking when needed
  afterward.
- Keep `object::id(value)` for generic `key` parameters, framework or external
  objects, and types whose UID field belongs to another module.
- Do not add an ID getter merely to replace `object::id`; add one only when
  identity belongs in the defining module's consumer-facing interface.

## Infer generic arguments when clear

- Omit generic arguments the compiler can infer.
- When only some arguments must remain explicit, use `_` for those fixed by a
  value argument, receiver, or expected result:
  `dynamic_object_field::exists_with_type<_, Capability>(&self.id, CapabilityKey<Capability>())`.
- When a generic return type must be specified, put it in the call's type
  arguments and infer the local variable type. Prefer
  `let policy_override = venue_config.policy<_, AftermathPolicy>(PolicyKey());`
  over
  `let policy_override: &AftermathPolicy = venue_config.policy(PolicyKey());`.
- Keep a type argument explicit when inference fails or its spelling
  communicates domain meaning absent from the expression.
- Verify partial inference with the pinned compiler. `_` is an expression-level
  type placeholder, not a type permitted in signatures, constants, or datatype
  fields.

## Completion gate

Syntax work is complete only when every edited receiver, index, identity read,
and inferred type preserves its domain meaning and compiles under the package's
pinned edition and compiler.
