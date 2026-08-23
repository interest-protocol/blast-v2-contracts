# 0008: Creator assignment, social claims, and replay-safe signatures

- Status: superseded by [0013](0013-creator-fee-authority-and-x-claims.md)
- Date: 2026-08-22

This record is retained as design history. ADR 0013 removes generic social
claims, SuiNS claims, and the second claimant-message signature.

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `suins@692a12c` | `692a12c02260fd4abecf1630d33db819e4bcadef` | MystenLabs/suins-contracts |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |

## Context

Blast Fun assigns creators, and some launches are created on behalf of a social identity — a SuiNS name
or an X/Twitter handle — whose controlling address is not yet known. The question is where that identity
belongs: in the protocol, in an attestation layer, or in an off-chain registry.

Two pieces of evidence settle it.

**SuiNS names expire and transfer.** `NameRecord` carries `expiration_timestamp_ms` with `has_expired`
and `has_expired_past_grace_period` (`suins@692a12c:packages/suins/sources/name_record.move:75-92`).
Reverse lookup is a settable pointer, and target address is mutable
(`suins@692a12c:packages/suins/sources/registry.move:263-345`). A name is a display of an address at a
moment in time; it is not a durable authority.

**The historical protected-launch signature is the threat model.** `memez_verifier` verified ed25519 over
`bcs::to_bytes(Message { pool, amount, nonce, sender })` with **no chain or package domain separation, no
expiry, and an unbounded `Table<address, u64>` of nonces**
(`memez@00596fd:fun/sources/structs/verifier.move:8-60`). The unbounded table alone violates
`../../AGENTS.md`.

Protected/private launches are not a V2 feature. The historical mechanism is
cited only as negative security evidence for social-identity claims. Creating a
canonical launch requires no platform signature, allowlist membership, launch
nonce, or attestation service.

## Decision

**Economic authority is always an address.** A social handle never receives value, never holds authority,
and never appears in economic state.

### Mechanism 1 — direct address assignment

The launch names a creator **address** at creation and mints a `CreatorCap` bound to that launch. The
address holds or claims the cap; the cap is the authority
([ADR 0007](0007-acl-pause-and-versioning.md)). No resolution, no attestation, no expiry, no signature.

**This path is complete on its own and is the default.** Mechanism 2 exists only for launches created
before the controlling address is known.

### Mechanism 2 — social claim for an unresolved alias

Used when a launch is created on behalf of a SuiNS name or an X/Twitter handle. The launch starts with
its `CreatorCap` unissued and an `identity_hash` recorded:

```text
identity_hash = H( platform_tag ‖ canonicalisation_version ‖ normalised_handle ‖ platform_user_id )
```

Resolution into an address requires **both** of the following, in the same transaction:

1. a **platform attestation** signed by a Blast attestation signer, binding `identity_hash` to a claimant
   address — Blast asserts that this platform account is controlled by that address;
2. a **claimant-address acceptance signature**, proving control of the address being bound.

Neither alone is sufficient. An attestation without acceptance would let Blast assign a creator; an
acceptance without attestation would let anyone claim any handle. Both cases are negative tests.

### Signed-message format

Both messages are domain-separated over every field the historical scheme omitted:

| Field | Purpose |
| --- | --- |
| `chain_id` | a signature for one network is invalid on another |
| `package_id` | a signature for one deployment is invalid for another |
| `action_tag` | `b"BLAST_ATTEST"` or `b"BLAST_ACCEPT"`; the two are never interchangeable |
| `launch_id` | binds the claim to one launch |
| `identity_hash` | binds the claim to one social identity |
| `claimant` | the address being bound |
| `expiry_ms` | checked against `Clock`; an expired signature is invalid |
| `nonce` | single-use within the expiry window |
| `signer_key_id` | identifies the attestation key, so rotation invalidates in-flight signatures |
| `publish_handle` | acceptance message only: the claimant's explicit consent to emit the raw handle on-chain, default `false` |

Messages are BCS-encoded from a fixed struct so field boundaries are unambiguous and no
length-extension or field-shifting variant parses.

### Bounded replay protection

A claim is **one-time**: consuming it issues the `CreatorCap` and marks the claim consumed on the launch
object itself — O(1) per launch, no growing table.

Nonce and expiry storage is bounded by construction. Signatures carry `expiry_ms` bounded by a
configured maximum window, and the consumed-claim marker lives on the launch it belongs to. **No
`Table<address, u64>` of nonces exists anywhere in this design**, which is the specific historical
construct rejected here.

### Signer rotation and revocation

`AdminCap` rotates and revokes attestation signers, each with an event
([ADR 0007](0007-acl-pause-and-versioning.md)). Verification resolves `signer_key_id` against the current
active set; a signature from a rotated-out or revoked key fails even if unexpired. Rotation is therefore
an immediate, complete invalidation of in-flight attestations from that key.

### Handles never enter economic state

Only `identity_hash` is stored on-chain. A renamed, sold, or expired handle can never redirect a fee
stream, because the fee stream follows the `CreatorCap` and the cap follows an address. A SuiNS name may
be shown next to a creator in a UI; it is never consulted to decide who gets paid.

### Canonicalisation

- **`platform_user_id` is the primary key.** Handles are renameable and resellable; the platform's
  immutable account id is not. Including both means a rename does not invalidate an existing claim, and a
  handle takeover by a different account does not produce a matching hash.
- **`normalised_handle`** is NFKC-normalised, lower-cased, and stripped of a leading `@` and any
  platform-specific decoration before hashing. Without a fixed rule, two encodings of one handle hash
  differently and a claim silently fails to match.
- **`canonicalisation_version`** is part of the pre-image, so a future change to the normalisation rules
  is a visible, versioned event rather than a class of claims that quietly stop matching.
- **Homoglyph and confusable handling** is an attestation-layer responsibility, not a hash property: the
  signer must refuse to attest a handle confusable with one it has already attested.

### Privacy, consent, and linkability

**A hash of a public handle is not a privacy control.** The handle space is small and enumerable, so
`identity_hash` is brute-forceable by anyone who can guess candidates. It is a **binding** primitive, not
a confidentiality one, and this ADR makes no concealment claim.

**Publishing the raw handle on-chain is consent-gated and off by default.** The claimant's acceptance
message carries an explicit `publish_handle: bool`. Only when it is `true` does `SocialClaimOpened` carry
the raw handle and platform user id; otherwise the on-chain discovery payload is limited to
`platform_tag`, `canonicalisation_version`, and `identity_hash`, and human-readable metadata lives in
off-chain records keyed by address ([ADR 0011](0011-event-schema-and-replay.md)). The claimant decides,
and the decision is inside the signed, domain-separated bytes rather than in a client setting.

**On-chain publication is permanent and linkable.** Once emitted, a handle-to-address link cannot be
retracted: it stays in the event stream, it links every future transaction of that address to a social
identity, and it links every other launch by the same creator. Consent must therefore be informed — the
signed message names this consequence — and no default, migration, or admin action may set
`publish_handle` on a claimant's behalf.

**No other personal data is accepted.** No email, display name, avatar URL, or profile text enters state
or events. Discovery beyond the handle is off-chain, consistent with `../../AGENTS.md` keeping private
material out of source, logs, and fixtures.

### Threat model

| # | Attacker | Capability | Attack | Mitigation | Test |
| --- | --- | --- | --- | --- | --- |
| T1 | anyone | can call any public function | claim a `CreatorCap` for a handle they do not control | attestation required, binding `identity_hash` to a named claimant | `attestation without acceptance`, `wrong claimant` |
| T2 | anyone | holds a valid attestation for another launch | replay it onto a richer launch | `launch_id` in the domain | `wrong launch_id` |
| T3 | anyone | observes a testnet or staging signature | replay it on mainnet | `chain_id`, `package_id` in the domain | `wrong chain_id`, `wrong package_id` |
| T4 | anyone | holds an attestation message | replay its bytes as an acceptance | distinct `action_tag` per message kind | `wrong action_tag` |
| T5 | anyone | holds an old unconsumed attestation | use it long after issuance | `expiry_ms` against `Clock` | `expired` |
| T6 | anyone | holds a consumed attestation | claim twice | one-time claim marker on the launch | `second claim on an already-claimed launch` |
| T7 | compromised attestation signer | signs arbitrary attestations | bind handles to attacker addresses | blast radius is unclaimed `CreatorCap`s only — cannot mint, move reserves, or alter the curve; rotation invalidates in flight | `rotated-out signer`, `revoked signer` |
| T8 | Blast operator | controls the attestation signer | unilaterally assign a creator | claimant acceptance also required | `attestation without acceptance` |
| T9 | claimant | controls an address | bind a handle they do not own | platform attestation also required | `acceptance without attestation` |
| T10 | handle squatter | acquires the handle after a claim resolves | redirect the fee stream | authority is the `CreatorCap`, which follows an address and is never re-derived from the handle | `no payout path reads identity_hash` |
| T11 | anyone | can craft encodings | collide pre-images or shift field boundaries | fixed BCS struct encoding plus versioned canonicalisation | `malleable or re-ordered encoding` |
| T12 | anyone | can enumerate handles | de-anonymise `identity_hash` | **not mitigated, and not claimed to be**; publication of the raw link is separately consent-gated | `publish_handle` consent tests |
| T13 | client or operator | builds the transaction | publish a handle without consent | `publish_handle` is inside the claimant's signed message | `publish_handle` flipped after signing |

### Where a claim can and cannot happen

A social claim can be resolved at any lifecycle state, including after migration, because it changes only
who holds the `CreatorCap` and never touches curve state or accounting. Accrued creator fees remain
accrued and are claimable by whoever holds the cap once it is issued.

## Alternatives considered

**Put the handle in economic state.** Rejected: mutable and transferable identity would redirect value.

**Resolve SuiNS on-chain at payout time.** Rejected on `suins@692a12c:packages/suins/sources/name_record.move:75-92`:
the record may have expired or been retargeted between assignment and payout.

**Attestation only, no acceptance signature.** Rejected: it makes Blast able to assign creators unilaterally.

**Acceptance only, no attestation.** Rejected: no binding to the social identity at all.

**Reuse the historical nonce table.** Rejected: unbounded persistent collection.

**Store PII to support recovery.** Rejected: `../../AGENTS.md` keeps private material out of source and
state, and a hash plus off-chain records serves discovery without it.

**Emit the raw handle unconditionally for indexer convenience.** Rejected: it publishes a permanent,
irretractable link between a social identity and every transaction of an address, without the person
whose identity it is having agreed. The consent flag costs one bool in an already-signed message.

**Hash the handle and call it private.** Rejected as false: an enumerable pre-image space makes the hash
reversible, so hashing must be described as binding, not concealment.

## Consequences

- Direct assignment covers the common case with zero cryptography.
- Social claims require an operating attestation signer; if that service is unavailable, launches can
  still be created with direct assignment.
- A compromised attestation key can bind handles to attacker addresses until rotation, but cannot mint,
  cannot move reserves, and cannot alter the curve — the blast radius is unclaimed creator caps.
- Handle changes are a display concern only.

## Verification

Signed-message vectors, shared with `../../evm/` for cross-chain parity:

| Case | Expected |
| --- | --- |
| valid attestation plus valid acceptance | claim succeeds, `CreatorCap` issued |
| wrong `chain_id` | abort |
| wrong `package_id` | abort |
| wrong `action_tag` (attestation bytes replayed as acceptance) | abort |
| wrong `launch_id` | abort |
| wrong `identity_hash` | abort |
| wrong `claimant` | abort |
| expired `expiry_ms` | abort |
| replayed nonce within the window | abort |
| signature from a rotated-out `signer_key_id` | abort |
| signature from a revoked signer | abort |
| malleable or re-ordered encoding | abort |
| attestation without acceptance | abort |
| acceptance without attestation | abort |
| second claim on an already-claimed launch | abort |

Consent and canonicalisation tests:

| Case | Expected |
| --- | --- |
| `publish_handle = false` | `SocialClaimOpened` carries no raw handle and no platform user id |
| `publish_handle = true` | raw handle and platform user id are emitted, and the signed message covered the flag |
| `publish_handle` flipped after signing | signature verification fails, because the flag is inside the signed bytes |
| admin attempts to set `publish_handle` | no such path exists; asserted by public-surface inventory |
| handle differing only by NFKC form, case, or leading `@` | produces the identical `identity_hash` |
| same handle, different `platform_user_id` | produces a **different** `identity_hash` |
| same account, renamed handle | prior resolved claim remains valid and the `CreatorCap` is unaffected |
| `canonicalisation_version` mismatch | claim aborts rather than silently failing to match |

Plus:

- the threat-model table above executed row by row, each row naming the test that closes it;
- a state test asserting no `identity_hash` is ever read by a payout path;
- a bounded-state test asserting no per-address nonce collection exists;
- an event-schema test asserting no field of any event carries personal data beyond the consented handle
  and platform user id.
