# 0016: Unified CreatorCap claim and SuiNS periphery

- Status: accepted
- Date: 2026-08-22
- Amends: [0013](0013-creator-fee-authority-and-x-claims.md), [0014](0014-typed-creator-cap-and-diagnostic-modules.md), [0015](0015-protocol-authority-and-x-signer-state.md)
- Amended by: [0017](0017-coin-type-domain-for-x-creator-claims.md), [0018](0018-authority-module-separation.md), [0019](0019-consuming-creator-authority-and-cap-return.md)

## Context

The first creator-authority slice issued `CreatorCap<Meme>` immediately for a
known address but deferred issuance for X. That makes "address assignment" and
"X claim" look like different lifecycle operations even though both decide the
same fact: whether this launch's single creator capability may now be issued to
the transaction sender.

SuiNS introduces a separate concern. Resolving a name requires a dependency on
the SuiNS package and its mutable registry state, but the Blast core should not
inherit another protocol's dependency or make future fee authority follow a
name that can expire, transfer, or retarget.

## Sources

The pinned SuiNS review, compatibility notes, and primary-source links are in
[the SuiNS creator-claim boundary research note](../research/suins-creator-claim-boundary.md).

## Decision

### Every CreatorCap is claimed once

Every launch begins with an unissued `CreatorCap<Meme>`. A caller first selects
one validated `CreatorIdentity` input:

- `Address(address)` for a literal wallet or a SuiNS-resolved address; or
- `X(vector<u8>)` for the immutable X user-id commitment.

Package code wraps that input in `CreatorAuthority<Meme>`. It stores no claimed
boolean. `CreatorAuthority<Meme>` itself is the one-time, linear authorization
resource consumed by a successful claim. The coin type remains the permanent
capability, creator-claim event, and X-signature domain. Creator authority stores
no runtime launch id.

The creator-authority module exposes one package claim seam,
`claim_creator_cap`. The future launch module exposes exactly one corresponding
public function. There is no separate direct-issue, address-claim, X-claim, or
SuiNS-claim function.

The claim accepts an optional X attestation:

- `Address`: the attestation must be `None`, and `ctx.sender()` must equal the
  stored address.
- `X`: the attestation must be `Some`, the configured backend key must verify it,
  and its claimant is `ctx.sender()`.

The contract validates the identity and optional attestation before consuming
the authority, then creates exactly one `CreatorCap<Meme>`, emits one
`CreatorCapClaimed` event, and returns the cap. A second call with the same
authority is unrepresentable because the first successful call moved it. The
future launch module must extract its single stored authority and return the cap
without adding another authority back to launch state.

The optional attestation value is `Option<vector<u8>>`, so wallets and external
Move packages can construct both branches without a public raw-attestation
constructor. `Some` contains canonical BCS `(expiry_ms: u64,
signature: vector<u8>)`; the signature must be exactly 64 bytes. The signed
message is the ADR 0017 canonical BCS sequence: original meme `TypeName`, X
identity commitment, claimant, and expiry. The claimant is no longer a
redundant function argument; it is always `ctx.sender()`.

### SuiNS is a launch periphery dependency

The core package imports no SuiNS module and stores no name or SuiNS object id.
A separate `blast_fun_suins` periphery package will depend on the pinned SuiNS
package, reject an expired or targetless record, resolve its current target while
constructing the launch, and pass only that concrete address into the core's
address-identity path.

Resolution is frozen when the launch is created. A later SuiNS expiry, transfer,
or retarget cannot redirect the unissued capability or accrued creator fees. The
periphery package will be implemented with the launch slice, when there is a
real launch interface to call; the core does not add a placeholder adapter or an
external dependency before that seam exists.

## Alternatives considered

**Issue known-address caps at launch.** Rejected: it creates two lifecycle verbs
for one authority transition and prevents the creator from explicitly claiming
the capability.

**Expose separate address and X functions.** Rejected: the stored enum already
selects the validation branch, so two public functions would make the interface
shallower without adding behavior.

**Put SuiNS in the core.** Rejected: every launch and upgrade would inherit an
external dependency used only by one input method.

**Resolve SuiNS when the cap is claimed or fees are withdrawn.** Rejected:
mutable name ownership would be able to redirect authority and value accrued
under an earlier owner.

**Add a generic creator-provider registry now.** Rejected: there is only one
onchain name provider and no second adapter proving that a generic seam is real.

## Consequences

- Address, SuiNS-resolved, and X creators all perform the same explicit one-time
  claim transition.
- Address claims need no application signature; X claims remain the only signed
  application path.
- The transaction sender is the only authorized claimant, while the returned cap
  may be delivered or composed however that claimant chooses in the same PTB.
- SuiNS affects launch construction only and never enters core state, claim
  validation, fee withdrawal, or migration.
- Address claims still supply the shared X configuration to the unified function
  even though that branch does not read its signer key; accepting that inert
  argument keeps one claim seam without weakening authorization.

## Verification

- An address creator claims with `None` and receives one returned `CreatorCap<Meme>`.
- A different address aborts.
- Supplying an X attestation for an address identity aborts.
- An X creator must supply `Some(attestation)` and pass sender, expiry, domain,
  signer-rotation, and signature checks.
- The consuming claim signature and source-boundary checks make a second call
  with the same `CreatorAuthority<Meme>` impossible.
- The core manifest and source graph contain no SuiNS dependency or import.
- Structural checks find one production creator-cap claim function and no
  creator-state getters.
