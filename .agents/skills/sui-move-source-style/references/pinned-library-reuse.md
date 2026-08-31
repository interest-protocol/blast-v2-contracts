# Pinned Library Reuse

Use this procedure before adding, replacing, or reviewing arithmetic, conversion, collection, iteration, object, transfer, macro, or framework-wrapper logic.

## Resolve the compiled source

- Resolve the exact revision from the edited package's own `Move.lock`, including the root package's dependency mapping and every deployment environment.
- Do not assume the unsuffixed framework entry is the root package's pin. Follow the root package's `deps` mapping and confirm the compiled dependency name in `BuildInfo.yaml`.
- After a pinned build, inspect `build/<package>/sources/dependencies/<Dep>/` and `build/<package>/BuildInfo.yaml`, or use upstream source at the locked revision.
- Treat a local interface stub as proof of linkage only, not behavior. Treat online documentation for a newer revision as discovery only.

## Search before implementing

- Inspect the matching MoveStdlib, Sui framework, and dependency source before writing an integer bound, arithmetic or conversion helper, vector or option helper, manual loop, object operation, or transfer seam.
- Search for an existing function, receiver method, macro, or equivalent hand-written pattern.
- Prefer the standard implementation only when its units, rounding, borrow behavior, evaluation order, and abort semantics match the required contract.
- Do not wrap a standard function only to rename it. Add a wrapper only when it owns domain validation, units, rounding, visibility, or a stable protocol boundary.

## Audit methods and macros

- Prefer pinned methods and macros such as `checked_*`, `max_value!`, `div_ceil`, `mul_div`, `mul_div_ceil`, `do!`, `range_do!`, `do_ref!`, `map!`, `fold!`, `any!`, and `all!` when they make the invariant clearer.
- Confirm availability for the exact integer width or collection type. Use `saturating_*` only when saturation is the documented result, never as overflow recovery.
- Read a macro's definition before use. Because expansion occurs at the call site, confirm argument evaluation, capture and borrow behavior, short-circuiting, abort location, and lint output.
- Do not use a macro merely to shorten code.
