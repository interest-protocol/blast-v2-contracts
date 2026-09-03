# 0070: Series1 operational version and role administration

- Status: **accepted**
- Date: 2026-09-03
- Amends: [0064](0064-aftermath-backed-leverage-coins.md)

## Context

Series1 will own long-lived shared Vault state. The old-bytecode posture already
accepted in [ADR 0045](0045-single-package-version.md) requires each future
shared-state mutation to use one package-wide operational-version gate.
Series1 also needs a small authority model before Vault issuance, risk-module
rotation, adapter rotation, and shutdown administration can be added without
giving every administrator every power.

The accepted product model is one cold super administrator that grants and
revokes routine administrators and their roles. One `AdminCap` may hold several
roles. A routine administrator snapshots its complete assigned-role bitmap in
an ephemeral `AdminWitness(u8)`, and each consumer checks the bit it requires.

## Decision

Create one shared `PackageVersion` initialized to version 1. Its module keeps
the compiled `PACKAGE_VERSION` private. Package code can assert that shared
state matches the compiled version, and future package administration can
activate only the exact next version with checked arithmetic. Initialization is
eventless; a successful activation emits the previous and new versions.

Create one shared `ProtocolAuthority` and transfer one `SuperAdminCap` to the
publisher. The authority stores a bounded `VecMap<ID, u8>` from each live
`AdminCap` id to its role bit set. The registry contains at most 16 live caps.
The five initial single-bit roles are:

| Value | Role | Future authority |
| ---: | --- | --- |
| 1 | `VAULT_ISSUER` | Issues a new Series1 Vault and its share currency. |
| 2 | `RISK_ADMIN` | Replace a Vault's accepted risk-module witness. |
| 4 | `ADAPTER_ADMIN` | Replace a Vault's accepted adapter witness. |
| 8 | `SHUTDOWN_ADMIN` | Start the Series1 shutdown path. |
| 16 | `PACKAGE_ADMIN` | Authorize upgrades, restrict upgrade policy, and activate the next package version. |

`grant_admin` accepts any nonzero subset of these bits. The super administrator
may later add or remove one exact role bit, or revoke the complete cap.
Removing the last role leaves a registered but inert cap that the root may
reconfigure or revoke. A cap holder may destroy its cap and thereby remove any
live registry entry.

`sign_in` takes no caller-selected role. It returns `AdminWitness(roles)` only
when the supplied cap is live, copying the complete authoritative bitmap from
the shared registry. Future concern-owning modules must check their required
single role bit before their transition. Root authority does not itself satisfy
an operational role and cannot mint an `AdminWitness` without a separately
granted `AdminCap`.

All shared ACL mutations and role sign-ins check the operational package
version before any other validation. Grant, revoke, role-change, cap
destruction, version activation, and root-transfer events contain the primitive
facts required to replay the current registry and active root.

The root capability follows the existing cold-authority model: a proposed
recipient must accept after seven days. A new proposal replaces the old one,
and the current root may cancel. Acceptance immediately invalidates the prior
root id; the retired cap can then be deleted. This delay applies only to root
custody. Risk-module, adapter-witness, and package-upgrade operations remain
immediate for their role-bearing modules. A future governance custodian can
enforce its own delay while holding the only role-bearing cap.

Package initialization shares the version and authority objects, transfers the
root cap, and emits no user events.

## Alternatives considered

**One cap type per role.** Rejected because one operator may need several
roles, and independent cap objects make atomic role removal and registry replay
larger.

**One unrestricted routine-admin witness.** Rejected because Vault issuance,
risk rotation, adapter rotation, and shutdown do not need identical authority.

**Store one role per cap.** Rejected because it contradicts the accepted
multi-role administration model and creates unnecessary cap proliferation.

**Let the root call every operational transition.** Rejected because root
custody should administer authority, not silently bypass the role registry.

**Version every future Vault independently.** Rejected because Series1 is one
upgrade lineage and one package-wide cutover prevents mixed old/new mutators.

## Consequences

- A compromised routine admin is limited to the roles on its live cap.
- Root compromise can immediately change routine roles, but root custody itself
  cannot move to a new controller until the acceptance delay passes.
- Governance can later become the sole root custodian and revoke every other
  administrator without changing the ACL storage model.
- Role values and event payloads become stable public protocol facts.
- Future shared-state modules must take `&PackageVersion` and reject stale
  bytecode before validating operation-specific inputs.
- At acceptance, the package had no Vault, share currency, custody, adapter,
  oracle, or venue transition. ADR 0071 subsequently added inert Vault and
  share-currency issuance, and
  [ADR 0072](0072-series-one-package-capability-custody.md) added permanent
  package-capability custody and operational activation authority without
  adding financial or venue transitions.

## Verification

- Pin every role and abort code with exact tests.
- Prove sign-in copies the complete authoritative bitmap, each assigned role is
  accepted, and unassigned or invalid required roles are rejected.
- Test grant, per-role mutation, complete revocation, voluntary cap destruction,
  registry capacity, cross-registry rejection, and replay-complete events.
- Test delayed recipient-accepted root transfer, cancellation, replacement,
  stale-root rejection, and retired-cap destruction.
- Test current, stale, skipped, repeated, and overflowed package versions.
- Assert that package initialization is eventless and creates only the intended
  shared objects and root capability.
- Run Series1 source boundaries, testnet and mainnet builds, warning-as-error
  lint, and the full Move test suite.
