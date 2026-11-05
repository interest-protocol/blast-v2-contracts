# Deploying the launchpad

Use this procedure for a new mainnet publication. It implements the generic
package custody of
[ADR 0137](../../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md)
and the delayed policy and paused release of
[ADR 0134](../../docs/decisions/0134-delayed-administration-pause-and-table-acl.md).

**Publish → wrap → verify the PackageAdmin → configure while paused → verify notices → unpause.**
Publication creates an owned `blast_admin::package_version::Publication<BLAST_FUN>`
retaining the canonical Publisher and initial version. It creates no
`PackageVersion`, so Move cannot satisfy the required input to launch creation
or routine configuration setters. Publication authorizes no policy setters.
`blast_admin::package_admin::wrap` consumes the proof and matching native
version-1 UpgradeCap, shares `PackageAdmin<BLAST_FUN>` and creates
`PackageVersion<BLAST_FUN>` fully paused in one atomic transaction.

The deployer still receives the raw native UpgradeCap at publication. Do not
upgrade, restrict, transfer, or destroy it before wrapping. Move cannot block
the framework's native upgrade while that cap remains in the wallet; an
already-upgraded cap cannot activate this launchpad lineage. Once wrapped,
upgrades require the `UpgradeAdmin<BLAST_FUN>` witness and a
ready proposal under custody's applied notice, which starts at 172,800,000 ms
(48 hours) at wrap.

## 1. Prepare and publish

Blast's fees are paid to `blast_core::blast_treasury::Treasury`, published and
configured with `blast_core`; the launchpad has no treasury of its own.

Use a reviewed source commit and its pinned dependencies. Confirm the active
environment's chain ID is the intended Sui mainnet and the active address is
the approved deployer. Record both, the source commit and clean/dirty state,
dependency package IDs, and `sui --version`. Resolve dependency publication
before starting; do not bypass dependency verification or publish missing
dependencies as an improvised recovery step.

From the repository root, set `LAUNCHPAD_EVIDENCE_DIR` to a new local output
directory and `LAUNCHPAD_GAS_BUDGET` to the approved budget in MIST. Preserve
command output there; inspect transaction status, not just the CLI exit code.
The publish and wrap commands below broadcast transactions.

```bash
sui client active-env --json
sui client chain-identifier --json
sui client active-address --json
sui client publish sui/launchpad --build-env mainnet \
  --gas-budget "${LAUNCHPAD_GAS_BUDGET:?set the approved budget}" --json \
  > "${LAUNCHPAD_EVIDENCE_DIR:?set the evidence directory}/publish.json"
```

## 2. Identify the fresh objects

After confirmed successful publication, take these IDs from that transaction's
effects, not from an older deployment or an unfiltered wallet object list:

- `LAUNCHPAD_PACKAGE_ID`: the published package; original and current package
  IDs must be equal at this point.
- `LAUNCHPAD_PUBLICATION_ID`: the deployer-owned
  `<blast_admin>::package_version::Publication<<original-package-id>::blast_fun::BLAST_FUN>`.
  Its nested Publisher has that
  original package ID and module `blast_fun`; record the Publisher's ID too.
- `LAUNCHPAD_UPGRADE_CAP_ID`: the deployer-owned `0x2::package::UpgradeCap`
  for that package, with native `version = 1` and compatible `policy = 0`.
- No `PackageVersion` or `PackageAdmin` exists yet. `LaunchConfig` and
  `RuntimeConfig` are shared; policy configuration waits until wrap. Record
  `LAUNCHPAD_LAUNCH_CONFIG_ID` and the RuntimeConfig ID from these effects.

Read each object with `sui client object <object-id> --json`. The native cap's
version and the stored version are separate values; neither is
the Sui object storage version. Stop on a wrong owner, type, package, policy,
version, or missing object. Never try a raw upgrade to repair intake.

## 3. Seal publication custody

Submit Publication and the untouched UpgradeCap by value to
`blast_admin::package_admin::wrap` with the type argument
`<original-package-id>::blast_fun::BLAST_FUN`. It consumes
Publication forever and shares custody and the fully paused version; it needs
no ACL witness or LaunchConfig input. `TxContext` is
supplied by Sui.

```bash
sui client call --package "${BLAST_ADMIN_PACKAGE_ID:?set from the admin deployment}" \
  --module package_admin --function wrap \
  --type-args "${LAUNCHPAD_PACKAGE_ID:?set from publication}::blast_fun::BLAST_FUN" \
  --args "${LAUNCHPAD_PUBLICATION_ID:?set from publication}" \
         "${LAUNCHPAD_UPGRADE_CAP_ID:?set from publication}" \
  --gas-budget "${LAUNCHPAD_GAS_BUDGET:?set the approved budget}" --json \
  > "${LAUNCHPAD_EVIDENCE_DIR:?set the evidence directory}/wrap.json"
```

Do not continue if the transaction fails or its result is uncertain. Resolve
the submitted digest with `sui client tx-block <digest> --json` and inspect
current custody before retrying; a timeout is not evidence that wrap failed.

## 4. Verify and record custody

Require all of the following and retain the readbacks:

- The wrap transaction succeeded, deleted Publication, and created exactly
  one shared `<blast_admin>::package_admin::PackageAdmin<...::BLAST_FUN>` and one
  shared `<blast_admin>::package_version::PackageVersion<...::BLAST_FUN>`. Take their IDs
  from this transaction's effects. The consumed Publication cannot be reused.
- Its `PackageAdminCreated<BLAST_FUN>` event, emitted by the resolved
  `blast_admin::blast_admin_events` module with the launchpad's canonical
  `<original-package-id>::blast_fun::BLAST_FUN` type argument, records the
  exact `package_admin_id`, `publisher_id`, `upgrade_cap_id`, `package_id`,
  `upgrade_cap_version = 1`, and `policy = 0` identified above.
- `sui client object <package-admin-id> --json` confirms shared ownership and
  nested custody containing that Publisher and exactly that UpgradeCap in
  its `Option`. Their package identity, UpgradeCap version, and policy agree with
  the event. Wrapped capabilities are no longer standalone wallet objects;
  their absence from a wallet listing alone does not prove custody.
- Reading the new `PackageVersion` confirms shared ownership and the compiled
  current version, initially `1`, pause mask `7` (Create,
  Trading and Migrate), and the pinned unpause witness
  `<original-package-id>::blast_fun::PackageWitness`. An aborted wrap leaves the
  Publication and cap unchanged and creates neither shared output.
- Publication-owned policies start at zero notice. The PackageAdmin starts at
  48 hours. Verify that neither has a pending proposal. This setup state is not
  the approved release policy.

Write a normalized record under `deployments/sui/mainnet/` following
[`deployments/README.md`](../../deployments/README.md). Include original and
current package IDs; Publication, Publisher, UpgradeCap, PackageAdmin, and PackageVersion
IDs; UpgradeCap version/policy and stored version; publication and
wrap digests/status; source/toolchain identity; and the matching event and
object evidence. Raw CLI output alone is not the record.

Missing or mismatched evidence blocks release. An already-upgraded cap cannot
be admitted: stop for a separately reviewed recovery or fresh-lineage plan;
do not weaken intake checks.

## 5. Configure policies while paused and release

Use the root to grant the approved role-specific AdminCaps. Sign in through the
live ACL for ordinary policy operations with the current PackageVersion. Configure
protocol fee share, trade/creation fees, allocation and claim signer;
admit each approved Quote and reviewed adapter. Protected policies use ordinary
schedule/apply calls with Clock. At zero notice both calls can share a PTB;
Quote-listing changes are immediate. Claim-signer admission waits the signer
set's notice (zero during setup) and revocation is immediate. Build validated
Bps inputs in the PTB. Zero fees and an empty signer are legal but require explicit approval.
Read back the chosen values, routes and applied-value events.

Before release, apply or cancel every outstanding zero-notice proposal, including
each independent adapter admission. Configure and read back each operation's
intended notice (172,800,000 ms = 48 hours for this rollout). The PackageAdmin
already holds 48 hours; do not propose it again (an unchanged notice aborts).
Raising a notice never rewrites an earlier proposal's deadline or proposed next
notice. Record all applied notices and pending-proposal state. The release call
below enforces the minimum: it aborts with `unguarded_delay` (32) while any
covered notice is zero, any pending proposal would set one to zero, or any
adapter or claim-signer admission is still pending. Initial setup may span transactions while fully paused.

Complete the remaining release requirements, including approved destinations,
nonempty approved Quote/adapter allowlists, consumer bindings and ACL/key custody
from the deployment-record guidance. Keep root, cancellation and unpause powers
under the approved independent multisig arrangement: grant CancelAdmin and
PauseAdmin to it before release so incident response can cancel pending proposals
and pause. Grant `UnpauseAdmin<BLAST_FUN>` through the shared Blast ACL, sign in
with its AdminCap, and call `launch_config::unpause` with the LaunchConfig, the
RuntimeConfig, the core Treasury, the witness, the shared `PackageAdmin<BLAST_FUN>`,
the mutable `PackageVersion<BLAST_FUN>` and the selected bits (all = 7). It refuses
while the treasury's notice is unguarded, as it does for the launchpad's own.
This release is immediate and needs no Clock; retain its events and readback.
A later pause cannot recreate Publication or reset a notice. Later protected
changes wait the operation's applied notice; changing that notice waits its old
notice. Persist the final configuration and release evidence in the deployment
record.

## Subsequent upgrades and local verification

Schedule the exact reviewed digest with UpgradeAdmin and wait the stored deadline
under the currently applied upgrade notice. CancelAdmin can cancel until execution.
Then use the governed transaction: authorize with an `UpgradeAdmin<BLAST_FUN>`
witness, execute the native Upgrade command, then commit the matching receipt
through `blast_admin::package_admin::commit_upgrade_and_advance` in the same
PTB. It advances the stored version by one, so the new bytecode must compile
`constants::version!()` one higher. There
is no separate activation transaction or raw-cap escape path.

The generic PackageAdmin is tested in `blast_admin`; the launchpad's publication,
wrap, and unpause guard are tested here. Use `scripts/test_admin_delay.sh`,
which substitutes fixture named addresses:

```bash
MOVE_TEST_FILTER=blast_fun bash scripts/test_admin_delay.sh launchpad
sui move test -p sui/admin package_admin_tests
bash sui/launchpad/scripts/check_source_boundaries.sh
bash sui/admin/scripts/check_source_boundaries.sh
(cd sui/launchpad/ptb_tests && cargo test --locked --test bootstrap --test atomic_migration)
```

These local fixtures validate the custody mechanism. They do not prove that
a particular mainnet deployment followed this procedure; that requires the
transaction and object evidence above.
