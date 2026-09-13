# 0017: Coin-type domain for X creator claims

- Status: accepted
- Date: 2026-08-23
- Amends: [0013](0013-creator-fee-authority-and-x-claims.md), [0014](0014-typed-creator-cap-and-diagnostic-modules.md), [0015](0015-protocol-authority-and-x-signer-state.md), [0016](0016-unified-creator-cap-claim-and-suins-periphery.md)
- Amended by: [0019](0019-consuming-creator-authority-and-cap-return.md), [0028](0028-hot-cold-runtime-configuration.md), [0080](0080-provider-independent-creator-recipient.md)

> ADR 0080 preserves this coin-type claim domain while replacing the X
> commitment with an opaque Blast account commitment.

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |

## Context

Every Blast launch creates a unique meme coin type. That type already defines
`CreatorCap<Meme>`, survives migration, and is the identity consumed by creator
fee and feature integrations. A separate Blast package id and runtime launch id
in the X attestation create parallel domains for the same authority.

The signer key is dedicated to one Blast deployment and retired keys are never
reused. A separate Blast package field would therefore protect mainly against a
forbidden operational key-reuse mistake. A runtime launch id is useful for
events and indexers, but it is not the durable economic identity of creator
authority.

Sui's `type_name::with_original_ids<T>()` produces a fully qualified `TypeName`
whose package components use the first package version, including when a type
was introduced by a later upgrade
(`sui@06734f6:crates/sui-framework/packages/move-stdlib/sources/type_name.move:47-57`).

## Decision

The X creator-claim signer signs this canonical BCS sequence:

| Field | Purpose |
| --- | --- |
| `meme: TypeName` | `type_name::with_original_ids<Meme>()`; binds the claim to one generated coin type |
| `x_identity_hash: vector<u8>` | binds the authenticated stable X account commitment |
| `claimant: address` | must equal `ctx.sender()` and authorizes the PTB that receives `CreatorCap<Meme>` |
| `expiry_ms: u64` | bounds attestation lifetime |

The message contains no schema version, action tag, chain id, Blast package id,
runtime launch id, signer generation, or nonce. `XClaimMessage` is the fixed
Move type for this transition and `XClaimConfig` owns a key dedicated to that
type, so duplicating either fact inside the signed bytes adds no distinct
authorization. If a future design shares one key across message types, it must
first add an explicit domain tag and replay tests.

The backend receives the canonical original meme type tag from the launch being
claimed and signs it only after verifying that launch's X identity commitment
and claimant session. On chain, the claim derives the meme type from its generic
`Meme` parameter rather than accepting it as call data.

One signature cannot claim another generated coin, even for the same X identity
and claimant, because the derived `TypeName` changes. A successful claim consumes
the coin-typed `CreatorAuthority<Meme>`, so no later transaction can reuse that
authority or signature for the coin.

Launch objects may retain UIDs for their own lifecycle and trading operations,
but creator authority stores no runtime launch id and `CreatorCapClaimed` is
keyed by the original meme `TypeName`. Launch ids are not creator authority.

## Alternatives considered

**Keep the Blast package id.** Rejected: a dedicated never-reused signer key
already scopes official issuance, while another package accepting the public key
can affect only its own typed objects. The extra field does not distinguish an
exact chain fork that retains the same package id.

**Keep the runtime launch id.** Rejected: it duplicates the one-coin-per-launch
identity and does not follow `CreatorCap<Meme>` into downstream integrations.

**Sign no per-coin identity.** Rejected: one attestation could then claim every
unclaimed coin carrying the same X identity and claimant before its expiry.

**Keep a schema version or action tag.** Rejected for this dedicated-key design:
the fixed Move message type defines the layout and the signer configuration is
not shared with another action. A changed payload must use a newly reviewed
message type and signer domain rather than making old and new layouts ambiguous.

**Add a nonce.** Rejected: consuming `CreatorAuthority<Meme>` makes the only
transition the signature can authorize unavailable afterward. Memez's per-sender
nonce is appropriate for repeatable signed buys, but would duplicate state for
this one-time issuance.

## Consequences

- Creator authority, signatures, fees, migration, and feature integrations use
  the same permanent `Meme` identity.
- `CreatorCapClaimed` is a one-time meme-scoped fact and carries no launch id.
- The backend and any signing SDK must BCS-encode Sui's original `TypeName`
  exactly; display aliases and package-latest ids are invalid.
- Independent Blast deployments must continue using dedicated signer keys.
- The X-claim key must not be reused for a second signed action without a new
  ADR, explicit domain separation, and cross-action replay tests.
- The outer claim argument remains `Option<vector<u8>>` containing BCS
  `(expiry_ms, signature)` and does not change.

## Verification

- The canonical vector contains an original meme `TypeName` and no schema,
  action, package, launch, or nonce field.
- A valid fixture signature claims `CreatorCap<Meme>` once.
- The same signature submitted for `CreatorCap<OtherMeme>` aborts with invalid
  signature.
- Wrong X identity, claimant, expiry, current signer, or encoding still aborts
  with its existing error semantics.
