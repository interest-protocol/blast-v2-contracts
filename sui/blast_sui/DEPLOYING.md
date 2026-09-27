# Deploying Blast SUI

Use this runbook only for a new Blast SUI deployment. Store the normalized
result in the format required by [`deployments/README.md`](../../deployments/README.md).

1. Publish the package. Preserve the original `UpgradeCap`; upgrading it before
   package-admin intake changes its package ID and makes intake fail.
2. Finalize Coin Registry registration for the `funSUI` and `blastSUI`
   `Currency` objects created during initialization.
3. From the publication effects, verify the shared `PackageVersion`. On the
   singleton Blast ACL, have its `SuperAdminCap` holder grant
   `AdminCap<blast_sui_domain::UpgradeAdmin>` to whoever attaches capabilities
   and authorizes upgrades, and `AdminCap<blast_sui_domain::FeeAdmin>` to whoever
   sets the redemption fee.
4. In one PTB, sign in as `UpgradeAdmin`, create the deposit-receipt Display, create
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
