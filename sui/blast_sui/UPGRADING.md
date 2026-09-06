# Upgrading Blast SUI

Use this runbook only for an existing Blast SUI deployment. Record the result
as required by [`deployments/README.md`](../../deployments/README.md).

1. Build, verify, and audit the candidate bytecode against the published ABI
   and stored layouts.
2. In one PTB, sign in with a live routine `AdminCap` that holds this domain's
   package-admin role, authorize the exact 32-byte package digest, execute the
   native upgrade, and pass the matching receipt to
   `package_admin::commit_upgrade_and_advance`.
3. That finalizer commits the receipt into the same sealed cap **and** advances
   the operational generation to exactly the next compiled value, in the same
   transaction. There is no separate activation step, and no upgrade can leave
   the generation at its previous value. A failure at any step rolls back
   authorization, the native upgrade, cap state, and generation state together.
4. Verify old-generation mutations fail, new-generation mutations succeed,
   both coin redemptions remain usable, and deposit receipts still cancel
   without the shared vault.
5. Run the complete `scripts/verify.sh` gate and record the digest, policy,
   transaction, source verification, generation, and smoke-test evidence.

Administration comes from the immutable `blast_admin` package through this
package's own `BLAST_SUI_DOMAIN`. No Launchpad, DEX, or Series One capability
can authorize any step above.

Policy restriction is irreversible; this package deliberately exposes only the
compatible-to-additive narrowing, so a rescue entry point stays possible beside
a frozen path. `package_admin::make_immutable` is also irreversible: it destroys
the native `UpgradeCap` while Publisher custody and all three sealed
metadata/display children survive at the final operational generation.
