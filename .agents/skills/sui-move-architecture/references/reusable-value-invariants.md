# Reusable Value Invariants

Apply these rules when extracting, composing, simplifying, or reviewing a
sealed value type, validated unit wrapper, or field relationship reused by
multiple domain types.

## Place the invariant once

- Extract a sealed value type only when several domain values genuinely reuse
  one stable field relationship.
- Give the value type private fields and controlled construction. Let it own the
  shared invariant; each composing domain type owns only its additional
  relationships.
- Keep authorization, lifecycle, and live canonical-state checks in the owning
  transition. A reusable value type must not cache or imply them.
- Leave the checks inline when extraction has one incidental use, hides domain
  meaning, or complicates a published ABI or migration.

For example:

```text
BoundedValue(min, current, max) owns min <= current <= max
Fee(denominator, bounds: BoundedValue) adds denominator > 0 and bounds.max <= denominator
```

## Preserve meaningful wrappers

- Keep a one-field wrapper when it changes abilities, construction rights,
  type-level domain separation, atomic presence, or serialization. Data shape
  alone does not prove redundancy.
- Keep a validated unit wrapper inside the package when it prevents illegal
  stored values. At an external ABI boundary, accept or emit a primitive when
  exposing the wrapper would leak an internal representation, and validate once
  at construction.

The extraction is complete only when each shared check has one owner, each
domain-specific check remains with its domain, and callers cannot construct an
invalid value or bypass validation.
