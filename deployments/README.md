# Deployment and release records

Normalized, reviewable deployment records live under
`deployments/<chain>/<network>/` (for example `deployments/sui/testnet/`).
Console output and `latest` pointers are not records.

Every record must contain at least:

- schema version, network/chain ID, environment, and UTC timestamp;
- repository commit, clean/dirty state, compiler and toolchain versions;
- package/contract identifiers and dependency identifiers;
- deployer, transaction digest, status, and the created shared/admin objects,
  including the `Publisher`, `UpgradeCap`/`PackageAdmin`, `ProtocolAuthority`,
  `SuperAdminCap`, and `PackageVersion` object IDs;
- constructor/init parameters and post-deploy verification results.

Raw simulator or broadcast output stays generated and ignored. Public
normalized records must not contain secrets. See the "Deployment and release
records" section of `AGENTS.md` for the governing rules and each package's
README runbook for the package-specific verification steps.
