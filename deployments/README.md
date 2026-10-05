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
