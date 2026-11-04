# Deploying Blast SUI

Use this runbook only for a new Blast SUI deployment. Store the normalized
result in the format required by [`deployments/README.md`](../../deployments/README.md).
Custody follows [ADR 0136](../../docs/decisions/0136-blast-sui-custody-before-activation-and-delayed-administration.md).

**Publish → wrap → verify custody → grant roles → create the vault → verify notices → unpause.**

1. Publish the package. Publication sends an owned `Publication`, both treasury
   caps and both metadata caps to the deployer, and shares no `PackageVersion`, so
   no vault call can run yet. The raw `UpgradeCap` is also in the deployer's
   wallet: do not upgrade, restrict, transfer or destroy it before wrap. An
   already-upgraded cap cannot be admitted; stop and plan a fresh lineage instead
   of weakening intake.
2. Finalize Coin Registry registration for the `funSUI` and `blastSUI`
   `Currency` objects created during initialization.
3. Immediately call `package_admin::wrap` with the `Publication`, the untouched
   `UpgradeCap`, `MetadataCap<FUN_SUI>`, `MetadataCap<BLAST_SUI>` and the shared
   `DisplayRegistry`. It needs no ACL witness. Verify from its effects and events
   that it deleted `Publication`; created exactly one shared `PackageAdmin`, one
   shared `PackageVersion` and one shared receipt `Display`; that
   `UpgradeCustodyCreated<BLAST_SUI_PACKAGE>` records the Publisher, the cap at
   native version 1 and compatible policy; that `PackageAdmin` holds both metadata
   caps and the display cap as children; that the upgrade notice is 172,800,000 ms
   (48 hours) with nothing pending; and that `PackageVersion` is at generation 1
   with pause mask 7.
4. On the singleton Blast ACL, have the root grant `blast_sui_domain::UpgradeAdmin`,
   `FeeAdmin`, `CancelAdmin`, `PauseAdmin` and `UnpauseAdmin` to the approved
   `AdminCap`s. Keep the root, `CancelAdmin`, `PauseAdmin` and `UnpauseAdmin`
   under the approved independent multisig, and `UpgradeAdmin` behind it as
   well: an upgrade can rewrite every custody path once its notice elapses.
5. After the selected validator has a current exchange-rate entry, create the
   vault with both treasury caps and the owner seed. Verify its pool binding, seed
   split, locked shares, initial redemption fee (2 BPS) and fee notice (48 hours,
   from `DelayedCreated<RedeemFeeKey, u64>`).
6. Confirm both notices are nonzero with no pending change, then sign in as
   `UnpauseAdmin` and call `package_admin::unpause` with the vault and the
   approved flags (all = 7). Retain the `Unpaused` event.
7. Run the complete `scripts/verify.sh` gate and record publication, source
   verification, object IDs, transaction digests and post-deploy checks. The
   record must name the holder of the root and of every Blast SUI role, whether
   each is a multisig, and its signers and threshold.

The package behavior and exact callable signatures live in source. The
economic and native-staking rationale lives in
[ADR 0053](../../docs/decisions/0053-single-validator-funsui-and-blastsui.md).
