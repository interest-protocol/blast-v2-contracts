# 0018: Separate protocol ACL, X signer configuration, and creator authority

- Status: accepted
- Date: 2026-08-23
- Amends: [0001](0001-sui-package-and-module-layout.md), [0014](0014-typed-creator-cap-and-diagnostic-modules.md), [0015](0015-protocol-authority-and-x-signer-state.md), [0016](0016-unified-creator-cap-claim-and-suins-periphery.md)
- Amended by: [0019](0019-consuming-creator-authority-and-cap-return.md), [0020](0020-admin-cap-self-destruction.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `su@a3552af` | `a3552af11a531717378b6337a174f9340d1099dc` | interest-protocol/su-lending |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |
| `interest-acl@91e2f4f` | `91e2f4f83626c1cb924bac246932574501c21bf8` | interest-protocol/interest-mvr |

## Context

The first implementation placed four mechanisms in `acl.move`:

1. super-admin rotation;
2. routine-admin creation, membership, and revocation;
3. X backend signer storage, rotation, revocation, and Ed25519 verification; and
4. the `CreatorCap<Meme>` type and its issuance.

That module made unrelated reviews inseparable. A reviewer checking root transfer also had to reason
about cryptographic key state and creator-fee authority. It also made the shared X configuration appear
to be part of ACL storage even though its lifecycle and events are independent.

The concerns do share one intentional dependency: changing the X signer is a routine protocol-admin
operation. That relationship needs a narrow authorization seam, not common storage or a combined module.

## Decision

### `acl` owns protocol administration only

`blast_fun::acl` owns `ProtocolAuthority`, `SuperAdminCap`, `AdminCap`, pending root transfer state,
admin creation, revocation and holder-driven destruction, and delayed recipient-accepted root rotation.
It creates and shares only the singleton `ProtocolAuthority` and transfers only the initial
`SuperAdminCap`.

The module exposes public `sign_in`, which checks the supplied `AdminCap` id against current registry
membership and returns `AdminWitness`. The witness has only the `drop` ability: callers cannot copy it,
store it, or carry it into another transaction, and only `acl` can construct it. Configuration modules
borrow that typed proof and do not receive ACL storage or cap identity. Revocation blocks all future
sign-ins. Holder-driven destruction follows the same rule while deleting the owned cap in both its
active and already-revoked states. A witness already produced earlier in the same programmable
transaction remains valid for that atomic transaction, matching the pinned Memez/SU pattern.

`acl` must not import Ed25519, store a backend public key, construct a creator capability, or verify a
creator claim.

### `x_claim_config` owns backend-signature authorization

`blast_fun::x_claim_config` owns the shared singleton `XClaimConfig` and its complete lifecycle:

- package initialization creates and shares one disabled configuration;
- an `AdminWitness` produced by signing in an active protocol `AdminCap` may set/rotate or revoke the key;
- the module validates key length and verifies Ed25519 signatures against the one current key; and
- creation, rotation, and revocation are emitted as X-configuration events.

The object is shared and mutated in place. Every X creator claim receives that shared object, so a signer
rotation or revocation changes authorization for all subsequent claims without copying configuration into
launches. The config does not issue capabilities or interpret creator identity; it answers only whether a
message was signed by the currently authorized Blast backend key.

### `creator_authority` owns creator-capability issuance

`blast_fun::creator_authority` owns `CreatorIdentity`, launch-scoped one-time `CreatorAuthority<Meme>`,
the canonical X claim message/attestation rules, and `CreatorCap<Meme>`. Its single claim function selects
the address or X branch, asks `x_claim_config` to authenticate the X signature when required, consumes
`CreatorAuthority<Meme>`, constructs and returns the capability, and emits `CreatorCapClaimed`.

The module does not decide fee amounts and does not withdraw assets. A future `fees` module owns accrued
creator-fee accounting and exposes the fee-claim operation. That function must accept the matching
`&CreatorCap<Meme>`, return the claimed coin for PTB composition, and emit the final claimed and remaining
amounts. It must not call ACL or re-check social identity: possession of the coin-typed creator capability
is the durable post-claim authority.

### Initialization and event ownership

ACL and X signer configuration initialize independently. `ProtocolAuthorityCreated` contains only ACL
identity and policy. A separate `XClaimConfigCreated` identifies the disabled shared signer object.
Splitting the creation facts is a pre-publication event-schema correction and makes each stream reducible
without implying that one object is stored inside the other.

## Alternatives considered

**Keep one large ACL module but divide it with section headings.** Rejected: headings improve navigation
but do not separate storage ownership, imports, interfaces, or review surfaces.

**Create a generic authorization package or role-bearing witness.** Rejected: there is one concrete ACL
and one protocol-wide routine-admin role. A local unit witness gives the required module boundary without
a second package, phantom protocol parameter, or permissions bitmap.

**Pass the shared ACL and admin cap into each feature setter.** Rejected: repeating the membership check
inside feature modules couples unrelated state and makes every privileged feature ABI carry two ACL
objects. A drop-only sign-in witness preserves revocability across transactions while keeping feature
concerns independent.

**Put `CreatorCap` in a separate type-only module.** Rejected: a module containing only the struct and a
package constructor would be shallow. Creator authority owns the entire capability issuance lifecycle;
future fees consume the public type without owning its creation.

**Copy the signer key into every launch.** Rejected: rotation would require touching every launch and old
copies would continue authorizing claims. The shared singleton is the intended global authorization state.

**Make fee claims check `AdminCap` or the X signer again.** Rejected: routine administration and social
attestation authorize different transitions. After the one-time claim, `CreatorCap<Meme>` alone is the
creator-fee authority.

## Consequences

- Root/admin, backend signer, creator identity, and future fee accounting can be reviewed independently.
- Admin-cap holders can renounce active membership or delete an already-inert cap without coupling that
  lifecycle to X signer or creator authority state.
- X signer rotation and revocation remain global and immediate for subsequent X claims.
- `x_claim_config` depends on ACL only through the drop-only `AdminWitness` type.
- Creator fee claims cannot accidentally inherit admin or backend-signer authority.
- `XClaimConfig` and `CreatorCap<Meme>` move to concern-owning module paths before publication.
- Indexers receive two creation payloads instead of one combined ACL/X payload.

## Verification

- Structural checks reject `XClaimConfig`, Ed25519, X signer functions, and `CreatorCap` from `acl.move`.
- `acl` tests cover admin capacity, revocation, active/already-revoked cap destruction, delayed root
  rotation, recipient acceptance, and overflow.
- ACL tests prove wrong/revoked admin caps cannot sign in; X configuration tests cover key validation,
  rotation, revocation, and old-key signature rejection through a borrowed witness.
- Creator-authority tests cover address and X claims, current shared signer state, expiry, message domain,
  and one-time coin-typed capability issuance.
- The X branch rejects a disabled shared signer before attestation parsing or Ed25519 work.
- Creation payload tests prove both ACL and X config events use the generic event wrapper.
- Build, strict lint, all tests, coverage, and the public-surface inventory pass under the pinned toolchain.
