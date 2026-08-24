# 0029: Composable creator identity and protected linear authority

- Status: accepted
- Date: 2026-08-24
- Amends: [0014](0014-typed-creator-cap-and-diagnostic-modules.md), [0016](0016-unified-creator-cap-claim-and-suins-periphery.md), [0018](0018-authority-module-separation.md), [0019](0019-consuming-creator-authority-and-cap-return.md), [0024](0024-generated-coin-launch-ticket.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| — | No external ABI fact introduced | — |

This record simplifies Blast-owned pre-publication interfaces while preserving
creator-cap issuance security.

## Context

`launch_ticket` duplicated its complete OTW currency-creation path across
`new_address` and `new_x`; only creator-identity construction and event fields
differed. A single constructor should accept a prebuilt creator identity.

The adjacent one-field type initially looks redundant:

```move
public struct CreatorAuthority<phantom Meme> has store {
    identity: CreatorIdentity,
}
```

It is not equivalent to its field. `CreatorIdentity` is caller input and may be
dropped. `CreatorAuthority<Meme>` is coin-typed, has neither `copy` nor `drop`,
and is the one-time resource consumed to issue `CreatorCap<Meme>`. Its private
field also prevents external construction.

Making `new_address` or `new_x` return `CreatorAuthority<Meme>` publicly would
let anyone create another authority for an existing coin type, consume it
through `claim_creator_cap`, and forge a valid `CreatorCap<Meme>`.

The repository contains no committed Sui publication or deployment record, so
this is a pre-publication interface correction. A deployment outside the
repository would require an explicit migration and old-version gate first.

## Decision

The public caller input remains a freely droppable, nongeneric identity:

```move
public enum CreatorIdentity has drop, store {
    Address(address),
    X(vector<u8>),
}
```

Public `new_address` and `new_x` functions validate their inputs and return
`CreatorIdentity`. They never issue creator authority.

`CreatorAuthority<Meme>` remains the protected stored wrapper. One package-only
conversion consumes a validated identity and wraps it as linear, coin-typed
authority. The future launch stores that value until the unified claim function
consumes it.

`launch_ticket` exposes one public `new` function. It accepts
`CreatorIdentity`, consumes the generated coin's OTW, converts the identity,
creates the currency, and stores exactly one `CreatorAuthority<Meme>`.

## Package-wide wrapper audit

No current production wrapper is removed:

- UID-only admin and creator caps are Sui ownership capabilities whose object
  identity and type control authorization.
- `AdminWitness` is an unforgeable transaction-local proof of live ACL
  membership, while `ACL` is the package one-time witness required by Sui
  initialization.
- `Event<T>` is the approved stable indexing envelope, and each inner event
  payload is a distinct replay schema.
- `PendingSuperAdminTransfer` keeps recipient and deadline present or absent as
  one lifecycle value.
- `LaunchTicket`, `ProtocolAuthority`, `RuntimeConfig`, `LaunchConfig`, and
  `FeeLedger` each own multiple related values and enforce a distinct lifecycle
  or accounting interface.
- `XClaimMessage` fixes the canonical BCS signing layout rather than wrapping an
  existing value.

For each type, deletion moves a construction, ownership, ability, atomic-state,
or serialization invariant into its callers. None is a pass-through seam.

## Alternatives considered

**Expose public constructors returning `CreatorAuthority<Meme>`.** Rejected:
authority construction is capability issuance. A repeatable constructor would
allow arbitrary `CreatorCap<Meme>` creation and creator-fee claims.

**Store `CreatorIdentity` directly and remove `CreatorAuthority`.** Rejected: the
stored value would be droppable and no longer coin-typed, so launch state could
discard the pending claim and claim signatures would lose their type-level
authority domain.

**Use separate identity and authority enums.** Rejected: it duplicates the
address/X variants and conversion logic. The one-field wrapper expresses the
ability, type, and construction differences with less code.

**Keep two complete launch-ticket constructors.** Rejected: the OTW currency
creation, custody, event, and return paths are identical. A composable identity
input removes that duplication without exposing authority issuance.

**Inline creator identity fields into `LaunchTicket`.** Rejected: authority must
later move into launch state and be consumed independently. Coupling the claim
transition to ticket storage would spread the same variant and linearity rules
across lifecycle modules.

## Consequences

- The duplicated launch-ticket constructor path disappears.
- Callers compose one validated identity with one ticket constructor.
- The one-field authority wrapper remains because it changes abilities,
  construction rights, and coin typing rather than merely renaming data.
- Address and X claim behavior, errors, events, and the `CreatorCap<Meme>`
  interface do not change.

## Verification

- Structural checks require public identity constructors, package-only authority
  conversion, the protected authority wrapper, and exactly one public
  launch-ticket constructor.
- Structural checks reject public functions that return newly constructed
  `CreatorAuthority<Meme>`.
- Address and X construction, wrong-claimant, attestation, coin-domain, and
  one-time consumption tests pass through identity conversion.
- Launch-ticket tests prove both identity branches, linear custody, exact event
  fields, and release of exactly one creator authority.
- Build, warning-as-error lint, complete tests, coverage, source-boundary checks,
  and `git diff --check` remain release gates.
