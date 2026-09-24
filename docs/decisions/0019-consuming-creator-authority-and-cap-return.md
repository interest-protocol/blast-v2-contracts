# 0019: Consuming creator authority and returning CreatorCap

- Status: accepted
- Date: 2026-08-23
- Amends: [0011](0011-event-schema-and-replay.md), [0013](0013-creator-fee-authority-and-x-claims.md), [0014](0014-typed-creator-cap-and-diagnostic-modules.md), [0016](0016-unified-creator-cap-claim-and-suins-periphery.md), [0017](0017-coin-type-domain-for-x-creator-claims.md), [0018](0018-authority-module-separation.md)
- Amended by: [0023](0023-generated-coin-supply-and-metadata-custody.md)

## Context

The first claim implementation retained `CreatorAuthority<Meme>` after a successful claim and stored a
`creator_cap_claimed: bool` inside it. The claim then called a private `issue_creator_cap` helper that
created `CreatorCap<Meme>` and transferred it directly to `TxContext::sender`.

The creator authority is already a linear Move resource with `store` but without `copy` or `drop`. A
successful claim does not need any of its pre-claim identity state afterward. Retaining the resource and
adding a boolean duplicates the lifecycle state that Move can express by consuming the resource itself.
Direct transfer also prevents the claimant from composing the returned capability in the same PTB or
delivering it immediately to another chosen address.

An emitted event cannot be the onchain replay guard. Move execution does not consult historical events
when deciding whether a call is authorized; the live resource transition must make a second claim
unrepresentable.

## Decision

`CreatorAuthority<phantom Meme>` stores only its validated `CreatorIdentity`. It
retains `store` and has neither `copy` nor `drop`, so launch state must preserve
it until it is either claimed or handled by a future explicit recovery decision.

`creator_authority::claim_creator_cap` takes `CreatorAuthority<Meme>` by value. It performs all address or
X-identity, attestation, signer, expiry, and signature checks before destructuring the authority. On
success it:

1. consumes the `CreatorAuthority<Meme>` and its identity;
2. creates exactly one `CreatorCap<Meme>`;
3. emits `CreatorCapClaimed`; and
4. returns `CreatorCap<Meme>` to the calling PTB.

This helper does not accept or return `MetadataCap<Meme>`. The future public
launch-level claim removes the native metadata cap from launch custody and
returns it separately alongside the creator cap. It must not pass the metadata
cap through this helper merely to return it unchanged.

The claim does not transfer the capability. The authenticated creator is still `ctx.sender()`, but after
the claim returns, that caller may transfer, store, or immediately use the
returned creator capability in a later command. The future launch-level function
provides the independent metadata-cap return.

There is no `creator_cap_claimed` field and no separate `issue_creator_cap` function. A repeat claim is
rejected structurally because the authority value no
longer exists, not by a runtime boolean assertion.

Consumption proves at most one cap per creator-authority resource. The stronger one-cap-per-launch
invariant also requires the launch path to construct exactly one
`CreatorAuthority<Meme>` from the unique launch ticket and never expose a
recreation path. Public `new_address` and `new_x` constructors create only a
droppable `CreatorIdentity`; package-only conversion creates linear authority
during unique OTW ticket initialization. The future launch implementation and
its tests must enforce this construction invariant.

## Alternatives considered

**Retain the authority with a claimed boolean.** Rejected: it leaves inert persistent state, pays for a
redundant field, and turns a linear transition into a runtime convention.

**Use `CreatorCapClaimed` as the uniqueness check.** Rejected: events are replayable indexing facts, not
state that Move can read to authorize a later transaction.

**Transfer the cap directly to `ctx.sender()`.** Rejected: authentication should identify who may claim;
it should not prevent that authenticated caller from choosing custody or composing the capability in the
same PTB.

**Keep a private issue helper.** Rejected: construction is one line in the sole consuming claim path. A
separate verb suggests another issuance lifecycle and makes uniqueness harder to inspect.

## Consequences

- A creator may claim days or months after launch as long as the launch still holds its authority.
- Successful claim removes the creator identity and leaves no inert claimed-state object or boolean.
- `CreatorCap<Meme>` remains `key, store`, contains only its `UID`, and can be
  delivered or composed independently from the native metadata capability.
- A second claim from the same authority is impossible to express because the first call consumes it.
- Indexers continue treating `CreatorCapClaimed` as the one-time fact, while contracts rely on resource
  consumption rather than event history.
- Launch construction becomes the explicit enforcement point for exactly one authority per unique meme
  type.

## Verification

- Structural checks reject a claimed boolean, an `issue_creator_cap` helper, or a transfer call from
  `creator_authority.move`.
- Structural checks require the helper to take `CreatorAuthority<Meme>`, return
  only `CreatorCap<Meme>`, and contain no metadata-cap dependency.
- Address and X happy-path tests capture the returned typed capability.
- The address test transfers the returned creator cap to an address different
  from the authenticated claimant, proving PTB composability and caller-selected
  delivery.
- Existing wrong-sender, wrong-attestation, signer, expiry, type-domain, and signature failures preserve
  their abort precedence before capability creation.
- Build, strict lint, tests, coverage, and source-boundary checks pass with the pinned Sui toolchain.
