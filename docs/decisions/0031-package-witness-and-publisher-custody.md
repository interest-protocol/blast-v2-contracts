# 0031: Package witness and Publisher custody

- Status: accepted
- Date: 2026-08-25
- Amends: [0001](0001-sui-package-and-module-layout.md), [0015](0015-protocol-authority-and-x-signer-state.md), [0018](0018-authority-module-separation.md), [0029](0029-composable-creator-identity.md)
- Amended by: [0032](0032-admin-authorized-upgrade-cap-custody.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui |
| `su@a3552af` | `a3552af11a531717378b6337a174f9340d1099dc` | interest-protocol/su-lending |

## Context

`acl.move` defines the package one-time witness as `ACL` and accepts it in
`acl::init`, but the initializer does not validate, transform, consume into
state, or otherwise use that value. `runtime_config` and `launch_config`
correctly use context-only initializers because their singleton construction
does not require an OTW. Leaving the witness on ACL falsely suggests that the
witness authenticates protocol administration.

The witness is nevertheless valuable at package publication. The pinned Sui
framework's `package::claim` validates an OTW and returns a `Publisher`, and
`package::claim_and_keep` transfers that object to the publishing transaction's
sender (`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:132-154`).
The framework records both package and module provenance in that object, and
permits multiple module publishers for one package
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:79-88,132-148`).
The primary Sui house-style reference isolates this exact concern in its small
package module: the OTW and publisher claim only
(`su@a3552af:packages/su/sources/su.move:1-18`).

An OTW can be consumed only during package initialization. If Blast merely
drops it now, a package `Publisher` cannot be recovered later when a concrete
framework integration requires package provenance. ADR 0001 already anticipates
using a retained `Publisher` for non-generic protocol displays.

## Decision

Add `blast_fun::blast` as the package-level module. It owns:

- the canonical `BLAST` one-time witness; and
- a private initializer that consumes `BLAST` through
  `sui::package::claim_and_keep`.

The resulting owned `Publisher` is delivered to the package publisher as a
deployment-time bridge. ADR 0032 then requires the publisher to move it, beside
the validated `UpgradeCap`, into the shared `PackageAdmin`. Possession of the
Publisher does not grant ACL membership, configuration authority, or package-
upgrade authority; those responsibilities remain distinct even though the two
framework package capabilities share a custody object.

`acl::init`, `runtime_config::init`, and `launch_config::init` accept only
`&mut TxContext`. An initializer accepts an OTW only when it passes that witness
to an API that validates or consumes it for the module's concern. The ACL
initializer continues to create exactly one `ProtocolAuthority` and initial
`SuperAdminCap` as an independent package-publication action.

The claim itself emits no Blast event. The later package-administration wrap
emits the Publisher object ID as part of the complete custody fact, and the
normalized deployment record must identify that final shared custodian.

## Alternatives considered

**Keep `ACL` as the witness and claim the Publisher in `acl::init`.** Rejected:
it keeps package provenance coupled to protocol administration and makes the
ACL module own an authority it never consumes after publication.

**Drop the package OTW and claim no Publisher.** Rejected: this saves one owned
object but permanently removes the ability to use publisher-gated framework
features without republishing a new package lineage.

**Store the Publisher inside `ProtocolAuthority`.** Rejected: ACL operations do
not need publisher provenance. Embedding it would enlarge shared state, couple
future framework features to ACL mutations, and blur separate authority domains.

**Create a generic feature module and claim its witness.** Rejected for now:
the provenance need is package-level and no concrete feature owns it yet. A
small `blast` module states that responsibility directly without precommitting a
feature abstraction.

## Consequences

- Every state/feature initializer follows one rule: omit an OTW unless that
  initializer actually consumes it for its own concern.
- Package publication creates one framework `Publisher` under the publisher's
  address only until the required package-administration wrap.
- ACL's public types and authority semantics are no longer conflated with
  package provenance.
- Future publisher-gated features may use the retained object after their own
  ABI, authority, and event decisions are approved.
- The `Publisher` is not a substitute for the `UpgradeCap`; both IDs and their
  final shared custodian must be recorded during deployment.

## Verification

- A Move test runs `blast` initialization, retrieves the delivered `Publisher`
  from the publishing sender, and proves it recognizes both the `blast` module
  and another type in the `blast_fun` package.
- Structural checks require the `BLAST` OTW and its sole production use in
  `sui::package::claim_and_keep`, reject an OTW parameter or declaration in
  `acl.move`, and require the ACL initializer to remain context-only.
- Build, lint, and full Move tests pass with the pinned Sui CLI and framework.
- Deployment verification records the `Publisher` object id and final custodian
  independently from ACL and upgrade capabilities.
