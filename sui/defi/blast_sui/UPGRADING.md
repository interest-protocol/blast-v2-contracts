# Upgrading Blast SUI

Use this runbook only for an existing Blast SUI deployment. Record the result
as required by [`deployments/README.md`](../../../deployments/README.md).

1. Build, verify, and audit the candidate bytecode against the published ABI
   and stored layouts. The candidate must raise `constants::version!()` by one:
   bytecode that keeps the deployed value closes every version-gated call once
   the upgrade commits, user exits included.
2. Sign in as `blast_admin::package_admin::UpgradeAdmin<BLAST_SUI_PACKAGE>` and
   call `blast_admin::package_admin::schedule_upgrade` with the exact 32-byte
   package digest. `CancelAdmin<BLAST_SUI_PACKAGE>` can cancel it, even once ready.
3. After the applied upgrade delay (48 hours at wrap), in one PTB: sign in as
   `UpgradeAdmin<BLAST_SUI_PACKAGE>`, call `authorize_upgrade`, execute the native
   upgrade, and pass the receipt to `commit_upgrade_and_advance`. That advances the
   stored version in the same transaction; a failure at any step rolls all of it back.
4. Verify old-version mutations fail, new-version mutations succeed, both coin
   redemptions remain usable, and deposit receipts still cancel without the shared
   vault.
5. Run the complete `scripts/verify.sh` gate and record the digest, transaction,
   source verification, version, and smoke-test evidence.

No call narrows the upgrade policy. `make_immutable` is irreversible, needs a
package wrapper that passes the package witness, and this package ships none.
