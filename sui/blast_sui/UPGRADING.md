# Upgrading Blast SUI

Use this runbook only for an existing Blast SUI deployment. Record the result
as required by [`deployments/README.md`](../../deployments/README.md).

1. Build, verify and audit the candidate bytecode against the published ABI and
   stored layouts. Its `PACKAGE_VERSION` must be exactly the deployed generation
   plus one. The finalizer runs the outgoing bytecode, which advances the shared
   generation to its own compiled next value; candidate bytecode that keeps the
   old `PACKAGE_VERSION` would reject every gated call, both redemptions included,
   and could never be upgraded again. `NEXT_PACKAGE_VERSION` is derived from it.
2. Sign in as `blast_sui_domain::UpgradeAdmin` and call
   `package_admin::schedule_upgrade` with the exact 32-byte digest and `Clock`.
   Publish the digest and the action's `ready_at_ms`; holders may exit during the
   notice. `CancelAdmin` can cancel until execution.
3. After `ready_at_ms`, in one PTB, sign in as `UpgradeAdmin`, call
   `package_admin::authorize_upgrade` with the scheduled digest and `Clock`,
   execute the native upgrade, and pass the matching receipt to
   `package_admin::commit_upgrade_and_advance`. It commits the receipt into the
   sealed cap **and** advances the operational generation in the same
   transaction. A failure at any step rolls back authorization, the native
   upgrade, cap state and generation state together.
4. Verify old-generation mutations fail, new-generation mutations succeed, both
   coin redemptions remain usable, and deposit receipts still cancel without the
   shared vault.
5. Run the complete `scripts/verify.sh` gate and record the digest, policy,
   transaction, source verification, generation and smoke-test evidence.

Administration comes from the singleton Blast ACL in the immutable `blast_admin`
package through this package's own roles. No other package's role can authorize
any step above.

## Repairing a release that kept the old generation

If a committed upgrade's bytecode kept `PACKAGE_VERSION` at the old value, every gated
call (both redemptions included) aborts. Receipt `cancel` still works. Recover with a
repair, which reads no package version and never advances the generation:

1. Build bytecode whose `PACKAGE_VERSION` equals the stored generation (the value
   `commit_upgrade_and_advance` advanced to), and audit it.
2. Sign in as `UpgradeAdmin` and call `package_admin::schedule_repair` with its exact
   digest and `Clock`. Announce it; it waits the applied upgrade notice, and
   `CancelAdmin` can cancel it with `package_admin::cancel_upgrade_action`.
3. After `ready_at_ms`, in one PTB, call `package_admin::authorize_repair` with the
   digest and `Clock`, execute the native upgrade, and pass the receipt to
   `package_admin::commit_repair`. The generation stays as it is and the repaired
   bytecode becomes the only one that matches it.
4. Verify gated calls succeed on the repaired bytecode, then continue with ordinary
   upgrades from it.

No call narrows the upgrade policy: under a narrowed policy the generation could
never advance again. `package_admin::make_immutable` is the only irreversible
step; it waits its own scheduled notice, destroys the native `UpgradeCap`, and
leaves Publisher custody, all three sealed children and the final operational
generation in place, so every vault call keeps working.
