# 0014: Coin-typed creator authority and diagnostic modules

- Status: accepted
- Date: 2026-08-22
- Amends: [0013](0013-creator-fee-authority-and-x-claims.md)
- Amended by: [0016](0016-unified-creator-cap-claim-and-suins-periphery.md), [0017](0017-coin-type-domain-for-x-creator-claims.md), [0018](0018-authority-module-separation.md), [0019](0019-consuming-creator-authority-and-cap-return.md), [0023](0023-generated-coin-supply-and-metadata-custody.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |
| `su@a3552af` | `a3552af11a531717378b6337a174f9340d1099dc` | interest-protocol/su-lending |

## Context

The first implementation of ADR 0013 stored a runtime `launch_id` inside an
unparameterized `CreatorCap`. That proves a relationship through a field check,
but the generated meme coin type is already unique to one launch and remains the
same asset after migration. Fee authority should use that permanent compile-time
identity rather than carry a second runtime identity inside the capability.

The first implementation also declared errors and event structs beside ACL and
creator-authority storage. The historical Memez Fun package keeps its error
registry in a dedicated module exposed through package macros
(`memez@00596fd:fun/sources/errors.move:4-10,96-112`) and keeps event types and
package emitters in a dedicated event module
(`memez@00596fd:fun/sources/events.move:4-11,77-108`). Its state module calls
those two diagnostic modules rather than owning their definitions
(`memez@00596fd:fun/sources/memez_fun.move:71-97`). This separation matches the
dependency layout already proposed in ADR 0001.

## Decision

### Creator authority is parameterized by the meme coin type

`blast_fun::creator_authority` owns the Sui capability `CreatorCap<phantom Meme>` and its one-time
issuance lifecycle. The capability contains only its object `UID`; it does not
store a launch id, creator address, X identity, metadata capability, lifecycle,
or migration state. As amended by ADR 0023, the native `MetadataCap<Meme>` is
returned as a separate object at creator claim.

`CreatorAuthority<phantom Meme>` carries only the launch-scoped address-or-X
identity. It is a linear, store-only resource: the unified claim consumes it by
value and returns exactly `CreatorCap<Meme>`. It does not accept or pass through
`MetadataCap<Meme>`. The future launch-level claim releases the native metadata
cap from launch custody as a separate operation. Every constructor and claim
preserves the same `Meme` type parameter.

The invariant is one generated meme coin type per launch. Future fee and LP-fee
functions must accept the launch or migrated fee store parameterized by `Meme`
and a `CreatorCap<Meme>`. A capability for another coin type is therefore
rejected by Move type checking, without a runtime launch-id comparison. Migration
does not replace the meme coin type, so the same capability remains valid for
post-migration creator and LP fees.

The X attestation uses the same `Meme` type identity as `CreatorCap<Meme>` and
the fee integrations that consume it. It does not carry a second runtime launch
id or Blast package id. See [ADR 0017](0017-coin-type-domain-for-x-creator-claims.md).

### Errors and events are diagnostic-only modules

`blast_fun::errors` owns one append-only, package-wide numeric registry. It
exposes `u64` error-code macros with package visibility, matching the current Su
package and the historical Memez Fun pattern. The macros inline the stable
number into the calling module. Named copies of those codes exist only as
`#[test_only]` constants for source tooling and the test registry.

The error module never asserts or aborts. The module that owns an invariant
performs `assert!(condition, errors::name!())` at the check site, before mutation.
This keeps the guard and its precedence visible in the state transition and
avoids a function call whose only behavior is to assert a boolean passed from
elsewhere. A reusable domain assertion may remain in the module that owns the
state or capability, but not in the diagnostic module.

The pinned linter sees the literal after macro expansion and reports
`abort_without_constant`. Each calling module therefore suppresses only that
named lint with an adjacent rationale and a pointer to the canonical numeric map
in `docs/error-codes.md`. The error module owns no storage or authority.

`blast_fun::events_wrapper` owns the public generic `Event<T>` envelope and the
single package-only function that calls `sui::event::emit`. Every Blast event is
therefore emitted as `Event<T>`, matching the current Su package
(`su@a3552af:packages/su/sources/lib/events_wrapper.move:1-17`). This gives
indexers one stable package event family across upgrades while retaining the
inner payload type `T` for exact event discrimination.

`blast_fun::events` owns the public inner payload structs and package-only
emitter functions. Creator-cap claim payloads use the meme `TypeName` with
original package ids as their durable identity; global signer payloads include
the configuration identity and complete signer transition. Test-only helpers
collect and unwrap `Event<T>` payloads and expose fields without expanding the
production ABI. Neither diagnostic module owns storage or authority.

State modules validate and mutate their state, then call an `events` payload
emitter. They do not declare event structs, call `sui::event::emit` directly, or
define local abort-code constants. `events.move` also does not emit directly; it
delegates to `events_wrapper::emit_event`.

## Alternatives considered

**Keep `launch_id` inside an untyped capability.** Rejected: it duplicates the
coin type's permanent one-launch identity and forces every fee operation to make
a runtime comparison that the type system can enforce.

**Store both `launch_id` and `Meme` identity in the capability.** Rejected: the
runtime field adds no authority fact once every consumer is parameterized by
`Meme`.

**Split errors and events into separate packages.** Rejected: these are module
boundaries, not security or dependency boundaries.

**Emit payload structs directly.** Rejected: a shared `Event<T>` envelope gives
indexers a stable package-wide family to follow through upgrades and makes the
wrapper contract testable in one place. Inner payload changes remain explicit
schema migrations; the wrapper does not make incompatible fields compatible.

## Consequences

- A `CreatorCap<MemeA>` cannot authorize fees for `MemeB`.
- Creator authority survives bonding-to-migration transitions without a new
  creator-cap claim because the meme coin type is unchanged.
- The capability no longer needs a runtime launch-id getter or binding check.
- Event and error schemas have a single package-local home and state modules are
  easier to review.
- The published event type is `blast_fun::events_wrapper::Event<T>`, not bare
  `T`; indexers unwrap and discriminate on the inner payload type.
- This is a pre-publication ABI correction. After publication, changing the type
  arity or event module would require a compatibility decision rather than an
  in-place refactor.

## Verification

- An address claim returns `CreatorCap<Meme>` and cannot return
  `CreatorCap<OtherMeme>`.
- A valid X claim returns the same `CreatorCap<Meme>` type as an address claim.
- Every creator event is emitted through `blast_fun::events` and includes the
  meme `TypeName`.
- Every payload is emitted through `blast_fun::events_wrapper::Event<T>`; no
  other production module calls `sui::event::emit`.
- Tests collect and unwrap the generic envelope and field-assert its payload.
- Every production protocol abort uses a package error-code macro from
  `blast_fun::errors`, and the owning module performs the assertion at the
  invariant check.
- `blast_fun::errors` contains no assertions or assertion-wrapper functions.
- Existing sender, expiry, domain, replay, rotation, and revocation tests retain
  their exact named error meanings after the refactor.
- Build, lint, tests, and the public-surface inventory pass with the pinned Sui
  toolchain.
