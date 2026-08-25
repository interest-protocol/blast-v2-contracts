# Sui Move module extensions for test-only seams

- Date: 2026-08-25
- Status: primary-source research; do not adopt on the current edition
- Sui/compiler pin: `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`
- Blast edition before this investigation: stable `2024`

## Question

Can Blast move `#[test_only]` helpers out of production source files by placing
them in test-side extensions of the modules whose private state they inspect?

## Decision

**Not on Blast's current stable `2024` edition.** The pinned compiler implements
module extensions, but gates them behind `2024.alpha`. `ModuleExtension` appears
only in `E2024_ALPHA_FEATURES`; it is absent from the stable
`E2024_FEATURES` list
([edition feature lists](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/editions/mod.rs#L148-L181)).
The parser checks that feature gate as soon as it sees `extend`
([parser gate](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/parser/syntax.rs#L4515-L4528)).

Changing Blast to `edition = "2024.alpha"` merely to relocate test helpers
would trade a small source-layout improvement for an alpha language edition.
That contradicts this repository's stable-edition rule and is not justified.
Keep narrowly scoped `#[test_only]` seams in their defining production module
until the pinned stable compiler supports extensions. Re-evaluate the migration
then.

The Move Book page that prompted this investigation states the same edition
restriction, but it is secondary guidance; the decision above comes from the
pinned compiler
([Move Book overview](https://move-book.com/testing/extend-foreign-module/)).

## Semantics available once stable support exists

### Syntax and mode filtering

The intended test form is:

```move
#[test_only]
extend module blast_fun::creator_authority {
    public fun helper_for_testing(value: &PrivateType): u64 {
        value.private_field
    }
}
```

The parser accepts extension members using the ordinary module-member grammar,
including imports, constants, structs/enums, and functions. An extension must
have at least one `#[mode(...)]` or `#[test_only]` attribute; an ungated
extension is rejected rather than compiled into every mode
([grammar and mandatory mode](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/parser/syntax.rs#L4491-L4508),
[mode check](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/parser/syntax.rs#L4625-L4638)).
For Blast, every such file should use `#[test_only]`; a more general mode does
not express the intended publication boundary.

`#[test_only]` uses the compiler's existing mode filtering: an annotated AST
item is retained only when one of its modes intersects the active compiler
modes. In a test build the extension is retained and injected; outside test
mode it is filtered away, so its declarations do not enter the production
module
([mode filter](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/parser/mode_attribute_filter.rs#L47-L84)).
The compiler's own basic
fixture places both a helper and a `#[test]` inside a test-only extension and
expects a clean non-test compilation plus a successful unit-test compilation
([basic compiler fixture](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/tests/move_2024/extensions/basic.move#L1-L14),
[unit-test filtering](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/unit_test/filter_test_members.rs#L45-L70)).
Test builds also receive the normal unit-test poison, preventing their bytecode
from linking as ordinary production code
([test poison implementation](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/unit_test/filter_test_members.rs#L142-L183)).

### Access and visibility

An extension is not a sibling module. The compiler injects its members into the
target module before alias resolution, naming, and typing. Consequently its code
has same-module authority: it can call private functions, construct or
destructure structs with private fields, and read or mutate those fields
([injection design](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/expansion/translate.rs#L1246-L1268),
[private-function fixture](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/tests/move_2024/extensions/basic.move#L1-L14),
[private-field fixture](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/tests/move_2024/extensions/struct.move#L1-L17)).
Package-visible members are therefore also accessible.

Visibility on a newly added helper still controls its callers. A private helper
is usable only by code injected into the target module. For an extension of a
Blast module, `public(package)` is sufficient for a separate Blast test module;
ordinary visibility rules still apply after injection. A `public` helper can
also be called from a separate root-package test module. Mysten's
upstream-extension fixture proves this by adding a public destructor to a
dependency's module and calling it from the root package's test
([foreign-module fixture](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-cli/tests/move_unit_tests/test_extension_upstream/sources/n.move#L1-L17),
[passing test expectation](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-cli/tests/move_unit_tests/test_extension_upstream/args.exp#L1-L7)).
Because the entire extension is test-only, public here means public only in the
test compilation; it does not enlarge the published ABI.

### Dot syntax and receiver methods

Extensions may use the target module's existing dot syntax, including aliases
for private functions. The compiler fixture invokes a private target-module
function through dot syntax from the extension
([existing method use](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/tests/move_2024/extensions/use_fun.move#L1-L17))
and another adds a `use fun` alias inside the extension before invoking it as a
method
([extension method alias](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/tests/move_2024/extensions/new_use_fun.move#L1-L16)).

The injection rule means a function declared by an extension is an ordinary
function of the target module. It can therefore be used with receiver syntax
when it satisfies the normal Move 2024 dot-call rules and is visible at the call
site. This last statement is an inference from pre-resolution injection plus the
official method fixtures, not a separate extension-specific privilege. For
cross-module tests, use the narrowest ordinary visibility that reaches the
caller and import the target module as usual.

### Root-package, target, and declaration constraints

- Only extensions declared in the build's root package are applied. Extensions
  arriving through dependencies are discarded
  ([root-package filter](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/expansion/translate.rs#L362-L396),
  [library-extension handling](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/expansion/translate.rs#L740-L755)).
- A root-package extension may target either a module in the root package or a
  dependency module, as the passing upstream fixture demonstrates.
- The target must be written as the existing `<address>::<module>` and resolve
  to a previously defined module. An unknown target is rejected
  ([target diagnostics](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/expansion/translate.rs#L362-L375),
  [unknown-module rejection](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/expansion/translate.rs#L774-L796)).
  Textual order is irrelevant: the compiler partitions extensions from ordinary
  modules before processing them, and its official fixture places an extension
  before the target declaration
  ([source partitioning](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/expansion/translate.rs#L891-L992),
  [extension-before-target fixture](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/tests/move_2024/extensions/extend_before_original.move#L1-L3)).
- The compiler imposes no special source-file basename. A repository may place
  the file under `tests/extensions/` for clarity, but the declaration's target
  address and module name—not the filename—determine what is extended.
- There may be only one extension for a given address, module, and overlapping
  mode. Multiple test-only files extending the same module are rejected, so all
  of one module's test seams must be consolidated into one extension declaration
  ([uniqueness check](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/expansion/translate.rs#L410-L444)).
- Extensions are additive. They cannot redefine an existing function, type,
  constant, import alias, or syntax method; injection feeds both original and
  extension declarations through the normal duplicate-declaration checks
  ([injection and duplicate behavior](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/expansion/translate.rs#L1248-L1268),
  [function-redefinition fixture](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/tests/move_2024/extensions/invalid_fn_redefinition.move#L1-L8)).
- An extension shares the target module's resolved package and named-address
  mapping. It cannot introduce a different dependency or address mapping merely
  because its file belongs to the root package
  ([compiler design note](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/src/expansion/translate.rs#L1248-L1258)).

## Blast migration rule for a future stable compiler

When Blast upgrades to a pinned compiler that lists `ModuleExtension` in the
stable edition, migrate only helpers that need same-module access:

1. keep one `sui/tests/extensions/<module>.move` per extended module;
2. mark the extension itself `#[test_only]`;
3. keep its helpers private when tests live inside the extension, use
   `public(package)` for cross-module Blast tests, and reserve `public` for a
   root-package test that extends a dependency module;
4. prefer production constructors and observable behavior over malformed-state
   constructors; extensions should not turn implementation details into the
   primary test API; and
5. run both the normal build and the complete test suite, then inspect generated
   production modules to confirm no helper appears in the published ABI.

Until that promotion, moving helpers out of production files is not worth an
edition downgrade. The existing `#[test_only]` declarations already stay out of
production bytecode; the remaining issue is source organization, not onchain
surface area.
