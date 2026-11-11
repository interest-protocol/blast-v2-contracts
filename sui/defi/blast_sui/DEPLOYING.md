# Deploying Blast SUI

Use this runbook only for a new Blast SUI deployment. Store the normalized
result in the format required by [`deployments/README.md`](../../../deployments/README.md).

1. Publish the package. Preserve the original `UpgradeCap`; upgrading it before
   wrapping changes its package ID and makes intake fail. Publication hands the
   deployer an owned `Publication<BLAST_SUI_PACKAGE>` and shares no version.
2. Finalize Coin Registry registration for the `funSUI` and `blastSUI`
   `Currency` objects created during initialization.
3. Call `blast_admin::package_admin::wrap` with the publication and the original
   `UpgradeCap`. From its effects, verify the shared `PackageAdmin` and the shared
   `PackageVersion` with every deposit bit paused.
4. On the singleton Blast ACL, have its `SuperAdminCap` holder grant
   `blast_sui_domain::FeeAdmin`, `blast_sui_domain::CancelAdmin`, and the
   `UpgradeAdmin`, `CancelAdmin`, `PauseAdmin`, and `UnpauseAdmin` roles of
   `blast_admin::package_admin` typed by `BLAST_SUI_PACKAGE`. Record who holds each.
5. After the selected validator has a current exchange-rate entry, call
   `vault::create` with both treasury caps, both metadata caps, and the Display
   registry. Verify the pool binding, seed split, locked shares, initial redemption
   fee, zero fee delay, and that the vault holds all three sealed capabilities.
6. Raise the fee delay to 48 hours: `vault::schedule_redeem_fee` with the unchanged
   fee and the new delay, then `vault::apply_redeem_fee`. At a zero applied delay
   the change is ready at once.
7. Release deposits with `vault::unpause` and the bits to open. It refuses while the
   fee delay is zero or a pending change would make it zero.
8. Run the complete `scripts/verify.sh` gate and record publication, source
   verification, object IDs, transaction digests, and post-deploy checks.

The package behavior and exact callable signatures live in source. The rationale
lives in [ADR 0053](../../../docs/decisions/0053-single-validator-funsui-and-blastsui.md)
and [ADR 0136](../../../docs/decisions/0136-blast-sui-custody-before-activation-and-delayed-administration.md).
