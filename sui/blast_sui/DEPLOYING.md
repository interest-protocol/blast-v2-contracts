# Deploying Blast SUI

Use this runbook only for a new Blast SUI deployment. Store the normalized
result in the format required by [`deployments/README.md`](../../deployments/README.md).

1. Publish the package. Preserve the original `UpgradeCap`; upgrading it before
   package-admin intake changes its package ID and makes intake fail.
2. Finalize Coin Registry registration for the `funSUI` and `blastSUI`
   `Currency` objects created during initialization.
3. From the publication effects, verify the shared
   `blast_admin::acl::Authority<BLAST_SUI_DOMAIN>`, the owned
   `SuperAdminCap<BLAST_SUI_DOMAIN>`, and the shared `PackageVersion`. Grant and
   retain the operator's routine `AdminCap<BLAST_SUI_DOMAIN>`; grant this
   domain's package-admin role to whoever will authorize upgrades.
4. In one PTB, sign in, create the deposit-receipt Display, create
   `PackageAdmin` with the original `Publisher` and `UpgradeCap`, attach both
   metadata capabilities and the Display capability, and share
   `PackageAdmin`. Verify every attached capability from emitted facts.
5. After the selected validator has a current exchange-rate entry, create the
   vault and verify its pool binding, seed split, locked shares, and initial
   redemption fee.
6. Run the complete `scripts/verify.sh` gate and record publication, source
   verification, object IDs, transaction digests, and post-deploy checks.

The package behavior and exact callable signatures live in source. The
economic and native-staking rationale lives in
[ADR 0053](../../docs/decisions/0053-single-validator-funsui-and-blastsui.md).
