# Deployment and release records

Normalized, reviewable deployment records live under
`deployments/<chain>/<network>/` (for example `deployments/sui/testnet/`).
Console output and `latest` pointers are not records.

Every record must contain at least:

- schema version, network/chain ID, environment, and UTC timestamp;
- repository commit, clean/dirty state, compiler and toolchain versions;
- package/contract identifiers and dependency identifiers;
- deployer, transaction digest, status, and the created shared/admin objects,
  including the `Publisher`, `UpgradeCap`/`PackageAdmin`, `Authority<Domain>`,
  `SuperAdminCap<Domain>`, and operational-generation object IDs;
- constructor/init parameters and post-deploy verification results.

Raw simulator or broadcast output stays generated and ignored. Public
normalized records must not contain secrets.

Before the first launch with a presale on a network, confirm that its protocol
enables `enable_accumulators` and `enable_object_funds_withdraw` and that the
accumulator root `0xacc` exists, then dry-run a funded `settle_presale` there
([ADR 0096](../docs/decisions/0096-presale-through-address-balances.md)).

Package-specific procedures are loaded only for the operation being performed.
Blast SUI uses its [deployment](../sui/blast_sui/DEPLOYING.md) and
[upgrade](../sui/blast_sui/UPGRADING.md) runbooks. Other packages record the
same normalized evidence while following their accepted ADRs and verification
scripts.
