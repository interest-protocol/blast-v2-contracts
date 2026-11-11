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
   `blast_sui_domain::FeeAdmin`, `blast_sui_domain::ValidatorAdmin`,
   `blast_sui_domain::CancelAdmin`, and the
   `UpgradeAdmin`, `CancelAdmin`, `PauseAdmin`, and `UnpauseAdmin` roles of
   `blast_admin::package_admin` typed by `BLAST_SUI_PACKAGE`. Record who holds each.
5. After the first validator has a current exchange-rate entry, call
   `vault::create` with both treasury caps, both metadata caps, the Display
   registry, the pool ID, and the `Clock`. Verify the listed pool, seed split, locked
   shares, initial redemption fee, 48-hour fee delay, zero validator delay, and that
   the vault holds all three sealed capabilities.
6. List the remaining validators while the validator delay is still zero:
   `vault::schedule_validator`, then `vault::apply_validator`, once each. Each pool
   must be active with a current exchange-rate entry.
7. Raise the validator delay to 48 hours: `vault::schedule_validator_delay`, then
   `vault::apply_validator_delay`. Apply or cancel every scheduled admission first.
8. Release deposits with `vault::unpause` and the bits to open. It refuses while
   either delay is zero, a pending change would make one zero, or an admission
   scheduled at the zero delay is still pending.
9. Run the complete `scripts/verify.sh` gate and record publication, source
   verification, object IDs, transaction digests, and post-deploy checks.

The package behavior and exact callable signatures live in source. The rationale
lives in [ADR 0053](../../../docs/decisions/0053-single-validator-funsui-and-blastsui.md)
[ADR 0136](../../../docs/decisions/0136-blast-sui-custody-before-activation-and-delayed-administration.md),
and [ADR 0141](../../../docs/decisions/0141-blast-sui-validator-list.md).
