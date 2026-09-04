# Upgrading Blast SUI

Use this runbook only for an existing Blast SUI deployment. Record the result
as required by [`deployments/README.md`](../../deployments/README.md).

1. Build, verify, and audit the candidate bytecode against the published ABI
   and stored layouts.
2. In one PTB, sign in with a live routine `AdminCap`, authorize the exact
   32-byte package digest, execute the native upgrade, and commit the matching
   receipt into `PackageAdmin`.
3. If the candidate changes the compiled operational generation, activate the
   exact next generation in the same PTB only when integrations are ready.
   Additive or dependency-only changes can leave the operational generation
   unchanged.
4. Verify old-generation mutations fail, new-generation mutations succeed,
   both coin redemptions remain usable, and deposit receipts still cancel
   without the shared vault.
5. Run the complete `scripts/verify.sh` gate and record the digest, policy,
   transaction, source verification, generation, and smoke-test evidence.

Policy restriction is irreversible. Re-evaluate rescue requirements before
narrowing beyond additive compatibility.
