# Deployment and release records

Normalized, reviewable deployment records live under
`deployments/sui/mainnet/`. Blast deploys to Sui mainnet only (ADR 0103).
Console output and `latest` pointers are not records.

Every record must contain at least:

- schema version, network/chain ID, environment, and UTC timestamp;
- repository commit, clean/dirty state, compiler and toolchain versions;
- package/contract identifiers and dependency identifiers;
- deployer, transaction digest, status, and the created shared/admin objects,
  including the `Publisher`, `UpgradeCap`/`PackageAdmin`, and
  operational-generation object IDs, and, for `blast_admin`, the singleton `ACL`
  and its `SuperAdminCap`; each `AdminCap` granted with its holder and roles;
- constructor/init parameters and post-deploy verification results;
- for `blast_admin`, which is published immutably, the `sourceDigest` printed by
  `sui/admin/scripts/source_digest.sh` at the published commit, beside the
  package's `packageId`; its boundary gate refuses a `Published.toml` entry that
  no record carries or whose recorded digest differs from the current source.

Raw simulator or broadcast output stays generated and ignored. Public
normalized records must not contain secrets.

Package-specific procedures are loaded only for the operation being performed.
Blast SUI uses its [deployment](../sui/blast_sui/DEPLOYING.md) and
[upgrade](../sui/blast_sui/UPGRADING.md) runbooks. Other packages record the
same normalized evidence while following their accepted ADRs and verification
scripts.

The launchpad and migrators pay Blast's fees to their publisher until a
`TreasuryAdmin` points them elsewhere, and anyone may trigger those payouts. In
the publication transaction's follow-up, before any launch exists, set the
launch-fee treasury with `runtime_config::set_treasury`
([ADR 0105](../docs/decisions/0105-permissionless-launch-fee-claims.md)) and
the LP-fee destination with `lp_fee_policy::set_protocol_destination`; the
post-deploy record names both addresses.

## Boosts adapter upgrades

[ADR 0123](../docs/decisions/0123-successor-activated-boosts-upgrades.md) applies
to the fresh adapter lineage, not the historical deployed package. After
publication and before the first upgrade or vault funding, seal the canonical
Publisher and raw UpgradeCap through `package_admin::wrap`. The initializer
delivers the Publisher to the publisher; wrapping uses it in a follow-up
transaction. The supported policy remains compatible.

1. Read the active operational generation from `Protocol`, the native count
   from the sealed cap, and the live UpgradeAdmin role. Compile the successor's
   `PACKAGE_VERSION` as **active generation + 1**, even after failed native
   upgrades. Review its exact digest, dependency pins and compatibility. Never
   substitute the native upgrade count for the operational generation.
2. Sign in on the immutable ACL. In one transaction, pass that witness and exact
   digest to `package_admin::authorize_upgrade`, consume the ticket with the
   native upgrade command, and consume its receipt with `package_admin::commit_upgrade`
   on the same PackageAdmin. This does not change the active generation.
3. From the newly installed package ID, in a **second transaction**, sign in
   again and call `package_admin::activate_upgrade(protocol, witness)`. It checks
   its own compiled version; no caller supplies a version number. Failure leaves
   the old generation usable. Publish a corrected successor through the same
   repair path and retry; native and operational counts can diverge.
4. Record both transaction digests, original and installed package IDs, exact
   source/toolchain/digest, dependencies, native count, operational generation,
   custody/Protocol IDs, UpgradeCommitted and OperationalVersionAdvanced events,
   and before/after checks of old rejection, new operations and required exits.
   Direct callers and dependent packages to the reviewed activated release.

Activation verifies a consecutive version, not arbitrary code health or unique
latest-package identity. Rehearse the successor and all exit/dependent routes
before activation. A retained, unactivated candidate sharing the same operational
generation remains callable; administrators must not activate an unintended
candidate. Live ACL revocation still removes repair authority, including in old
packages. Replacing governance must explicitly retire that role.
Activate only the package ID reviewed for the current cutover and record all
superseded candidate IDs: a rejected candidate compiled ahead of the active
generation can become activatable after a later cutover.

`make_immutable` is a deliberate terminal action. Keep its current-generation
check; verify intended release, dependencies and exits before burning the cap.
It checks a version match only and does not prove that no upgrade is pending or
that the latest installed code is correct. No later repair is possible once the
cap is destroyed.
