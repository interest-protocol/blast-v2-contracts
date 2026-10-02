# Deployment and release records

Normalized, reviewable deployment records live under
`deployments/<chain>/<network>/` (for example `deployments/sui/testnet/`).
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
