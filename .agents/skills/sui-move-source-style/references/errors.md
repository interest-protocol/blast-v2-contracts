# Sui Move Errors

Apply these rules when adding, changing, testing, or reviewing errors, abort
ownership, guard precedence, or diagnostic compatibility.

## Keep errors descriptive and stable

In a simple package, define an error in the module that raises it. Use an
explicit clever-error code and a descriptive byte-string message:

```move
#[error(code = 1)]
const EInvalidRecipient: vector<u8> = b"Recipient must not be the zero address.";

public fun set_recipient(recipient: address) {
    assert!(recipient != @0x0, EInvalidRecipient);
    // ...
}
```

- Require `#[error(code = N)]` on each error constant declared and raised in
  the same module.
- Give it an `EUpperCamelCase` name and a descriptive `vector<u8>` value that
  states the failed condition.
- Do not use bare module-local `u64` error constants.
- Preserve every existing numeric code and meaning. The explicit code is an
  unsigned 8-bit value; treat an out-of-range published legacy code as a
  compatibility conflict requiring an explicit decision, not permission to
  renumber silently.
- Keep the constant beside its invariant-owning code under `// === Errors ===`.

Use literal-returning package macros only when multiple modules deliberately
share one package-wide numeric namespace:

```move
// errors.move
// === Errors ===
macro public(package) fun invalid_recipient(): u64 { 1 }

// invariant-owning module
assert!(recipient != @0x0, protocol::errors::invalid_recipient!());
```

- Keep the registry append-only after publication.
- Never reuse a retired code or change a published meaning.
- Maintain one map from number to macro, raising module, and stable meaning.
- Define matching `#[test_only]` `EUpperCamelCase` constants when attributes or
  structural tooling need named codes.
- Do not introduce `errors.move` for a simple package whose invariant-owning
  modules declare and raise their own errors.
- Keep `errors.move` diagnostic-only: no state, authority, assertions, abort
  wrappers, or generic validators.

## Raise errors where invariants live

- Place fully qualified
  `assert!(condition, protocol::errors::name!())` at the invariant owner.
- Use a typed `assert_*` helper only when it inspects private representation or
  deliberately composes owned guards.
- Reject helpers that accept only a precomputed Boolean and hide error identity
  or guard position.
- Preserve the raising module as part of error semantics.
- Test exact abort code, location, and precedence when guards overlap.
- Add a narrow lint suppression only after reproducing a pinned-compiler
  warning, with the rationale adjacent.

## Preserve error compatibility

- Treat error numbers, meanings, raising modules, and guard precedence as
  published diagnostic API.
- Before publication, make compaction a deliberate one-time decision.
- After publication, append new errors. Do not renumber, reuse, relocate, or
  silently reinterpret existing diagnostics.

## Completion gate

Error work is complete only when every changed abort has one owner, stable code,
descriptive meaning, deliberate precedence, exact test oracle, and compatible
published behavior.
