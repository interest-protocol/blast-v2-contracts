# 0013: Creator fee authority and X account claims

- Status: accepted
- Date: 2026-08-22
- Supersedes: [0008](0008-creator-identity-and-claims.md)
- Amended by: [0014](0014-typed-creator-cap-and-diagnostic-modules.md), [0015](0015-protocol-authority-and-x-signer-state.md), [0016](0016-unified-creator-cap-claim-and-suins-periphery.md), [0017](0017-coin-type-domain-for-x-creator-claims.md), [0019](0019-consuming-creator-authority-and-cap-return.md), [0023](0023-generated-coin-supply-and-metadata-custody.md), [0080](0080-provider-independent-creator-recipient.md)

> ADR 0080 replaces the provider-specific X identity with an opaque Blast
> account recipient whose securely linked login methods remain off chain.

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `suins@692a12c` | `692a12c02260fd4abecf1630d33db819e4bcadef` | MystenLabs/suins-contracts |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |

## Context

A launch may assign creator proceeds to the launcher, another wallet, the current
target of a SuiNS name, or the owner of an X account. These cases do not need one
generic identity protocol.

SuiNS already resolves a name to an address. The resolved address can receive
authority immediately, so adding a Blast signer or later name claim would add
friction and make a mutable name part of an economic path.

An X account does not resolve to a Sui address. Blast's backend can verify the
person logged in with X through a private user-context API and attest the wallet
address that person selected. This is the only case that needs an application
signature.

Protected/private launches are not a V2 feature. Launch creation, trading,
address-identity selection, and ordinary fee withdrawal are permissionless and do not
require a platform signature.

The X claim attestation defined here is the protocol's only custom
application-signed payload. Ordinary chain transaction signatures, multisig
transactions, and capability checks remain part of normal authorization and are
not additional application-message schemes.

## Decision

### The authority is `CreatorCap<Meme>`

`CreatorCap<Meme>` is the canonical Sui name for creator authority. The unique
generated meme coin type binds it to its launch and remains unchanged after
migration. Possessing it, not a social name or a recorded address, authorizes
creator proceeds and the other creator operations explicitly listed in
[ADR 0007](0007-acl-pause-and-versioning.md). It contains no metadata capability;
the native `MetadataCap<Meme>` is returned separately at claim, as specified by
ADR 0023. See
[ADR 0014](0014-typed-creator-cap-and-diagnostic-modules.md).

The X signature assigns this capability once. It is not required again whenever
the holder withdraws accrued fees.

### Path 1 — address creator claim

Every launch accepts a concrete creator address and leaves its `CreatorCap`
unissued. That address later calls the unified `claim_creator_cap` function with
no X attestation. The contract compares the stored address with
`TxContext::sender`, consumes the one-time claim marker, and returns the creator
cap and native metadata cap separately to the calling PTB. The future launch
function removes the metadata cap from launch custody; it does not pass that cap
through the creator-authority helper. ADR 0019 defines the claim marker as the linear
`CreatorAuthority<Meme>` resource itself and requires the claim to return the
cap rather than transfer it.

If the launcher enters a SuiNS name, the SuiNS periphery resolves the name to its
current target address while constructing the launch and passes only that address
to core. It must reject a missing, expired, or targetless resolution.

The contract stores no SuiNS name and performs no later name lookup. A subsequent
expiry, transfer, or retargeting of the name cannot redirect the unissued
capability or fee stream. This path has no Blast signature, claim nonce, or
attestation key.

### Path 2 — X creator claim

When a launch is created for an X account whose wallet is not yet known, the
launch records an immutable X identity commitment and leaves its `CreatorCap`
unissued. The commitment binds the stable X user id rather than the mutable
username:

```text
x_identity_hash = H("BLAST_X_ID" || x_user_id)
```

The human-readable handle remains frontend/indexer metadata and never controls
value.

The claim flow is:

1. the claimant connects a wallet and completes X user-context authentication in
   the Blast frontend;
2. Blast's backend validates the private authenticated session and obtains the X
   user id;
3. the backend verifies that its commitment matches the launch, then signs an X
   claim attestation bound to the connected wallet;
4. the claimant's wallet submits `launch::claim_creator_cap` with
   `Some(x_attestation)`;
5. the contract verifies the backend signature, currently configured signer
   key, expiry, meme coin type, identity commitment, and that
   `TxContext::sender` equals the
   attested claimant;
6. the creator-authority helper consumes `CreatorAuthority<Meme>`, emits the
   claim fact, and returns `CreatorCap<Meme>`;
7. the launch function independently removes `MetadataCap<Meme>` from launch
   custody and returns both separate objects to the claimant's PTB.

The wallet's transaction signature already proves control of the claimant
address. There is no second custom claimant-acceptance signature.

### Backend boundary

The attestation private key exists only in backend signing infrastructure. It is
never present in browser code, frontend environment variables, source, logs, or
fixtures. The frontend orchestrates login and claim submission; it does not sign
the attestation.

Before signing, the backend must verify all of the following in one authenticated
session:

- the X API response represents the currently authenticated user;
- the returned stable X user id matches the launch commitment;
- the claimant wallet address is the address in the payload;
- the launch is still unclaimed;
- the requested expiry is within the configured maximum window.

### Attestation format

The backend signs one fixed, BCS-encoded structure:

| Field | Purpose |
| --- | --- |
| `meme` | canonical `TypeName` with original package ids; binds the statement to one generated coin type and its `CreatorCap<Meme>` domain |
| `x_identity_hash` | binds the authenticated X account |
| `claimant` | address that must equal `TxContext::sender` and receive the cap |
| `expiry_ms` | bounds the lifetime of a leaked attestation |

There is no schema version, action tag, chain id, Blast package id, launch id,
or per-user nonce. The dedicated X-claim key authorizes only this fixed Move
message and transition, so a second in-message domain marker adds no distinct
authorization fact. Each launch creates a unique meme coin type, and the
authority's one-time consumed marker makes the attestation unusable after a
successful claim without creating a growing nonce table. See
[ADR 0017](0017-coin-type-domain-for-x-creator-claims.md).

### Fee behavior before and after claim

Creator fees accrue to the launch whether or not the X claim has resolved. Before
the capability is claimed, no address can withdraw them. After claim, the `CreatorCap`
holder claims the entire accrued amount through the ordinary capability-gated fee
path; the X backend is not consulted again.

The X claim may resolve during bonding or after migration because it changes
authority only and does not alter curve reserves, pricing, or accrued accounting.

### Failure and recovery policy

An admin cannot assign or redirect an unclaimed X `CreatorCap`. If the X account
cannot authenticate, the creator fees remain accrued and unclaimable rather than
being redirected by governance. Any recovery or expiry/sweep policy requires a
separate approved decision.

### Signer rotation

An active protocol-wide `AdminCap` can sign in for a drop-only `AdminWitness`,
which can rotate or revoke the X claim attestation signer with replay-complete
events. Rotation replaces the current public key;
revocation clears it. A rotated or revoked key is invalid immediately, including
for an otherwise unexpired attestation. Signer keys are dedicated per deployment
and retired keys are never reused, as specified by
[ADR 0015](0015-protocol-authority-and-x-signer-state.md).

## Alternatives considered

**Require signatures for every launch.** Rejected: it recreates the protected
launch bottleneck and makes backend uptime a launch dependency.

**Require a signature for SuiNS resolution.** Rejected: the periphery can resolve a
concrete address directly, and authority must not follow a mutable name.

**Resolve SuiNS again when fees are withdrawn.** Rejected: expiry, transfer, or
retargeting would redirect already-earned value.

**Require a second claimant message signature.** Rejected: the claim transaction
already proves control of `TxContext::sender`; the extra message adds signing UX
without adding an independent security fact.

**Require a fresh backend signature for every fee withdrawal.** Rejected: the
`CreatorCap` is the durable authority after claim, so repeated application
approval would introduce custody-like control and an availability dependency.

**Let the frontend hold the attestation key.** Rejected: browser-delivered secrets
are public to users and attackers.

**Store or authorize by mutable X username.** Rejected: the stable account id is
the identity key; the handle is display metadata.

**Use a global or per-address nonce table.** Rejected: one-time launch state
already closes replay, while a nonce table creates unnecessary persistent growth.

## Consequences

- The common wallet and SuiNS paths have no backend dependency or signature UX.
- Only an unassigned X creator authority depends on Blast's X authentication and
  attestation backend.
- A backend-key compromise can steal still-unclaimed X creator authorities until
  the key is revoked, but cannot affect address-identity launches, mint supply,
  trade reserves, or already-issued `CreatorCap`s.
- X username changes do not affect an existing commitment or issued capability.
- An X account that cannot authenticate has no admin recovery path; its fees stay
  accrued pending a separately approved recovery policy.

## Verification

Address-claim tests:

- literal address claims `CreatorCap` once with no X attestation;
- periphery-resolved SuiNS address follows the identical address-claim path;
- no public launch function accepts a platform signature, nonce, name, or handle;
- no payout path reads or resolves SuiNS.

X-claim tests:

| Case | Expected |
| --- | --- |
| valid backend attestation submitted by its claimant | `CreatorCap` returned to claimant PTB |
| transaction sender differs from `claimant` | abort |
| wrong meme coin type or identity commitment | abort |
| expired attestation | abort |
| rotated or revoked signer | abort |
| malformed or reordered encoding | abort |
| second claim for the same launch | impossible after the launch removes its consumed authority |
| ordinary fee withdrawal after claim | succeeds without an X signature |
| fee withdrawal before claim | impossible because no `CreatorCap` exists |

Backend integration gate **P15**: before release, an integration test must prove
that the configured X user-context authentication flow returns the stable id of
the currently authenticated user and that app-only credentials cannot satisfy
the claim-verification path. Failure blocks X claims, not direct launches.
