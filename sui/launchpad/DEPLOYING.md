# Deploying the launchpad

Use this procedure for a new mainnet publication. It implements the capability
custody required by [ADR 0031](../../docs/decisions/0031-package-witness-and-publisher-custody.md)
and [ADR 0032](../../docs/decisions/0032-admin-authorized-upgrade-cap-custody.md),
as amended by [ADR 0114](../../docs/decisions/0114-launchpad-custody-before-activation.md)
for audit finding L-1.

**Publish → identify bootstrap and fresh cap → wrap → verify activation.**
Publication creates an owned `Bootstrap` retaining the canonical Publisher and
initial generation. It creates no `PackageVersion`, so Move cannot satisfy the
required input to launch creation or configuration setters. `wrap` consumes
the bootstrap and matching native version-1 UpgradeCap, shares `PackageAdmin`
and creates the usable `PackageVersion` in one atomic transaction.

The deployer still receives the raw native UpgradeCap at publication. Do not
upgrade, restrict, transfer, or destroy it before wrapping. Move cannot block
the framework's native upgrade while that cap remains in the wallet; an
already-upgraded cap cannot activate this launchpad lineage. Once wrapped,
upgrades require the launchpad's `UpgradeAdmin` witness and version checks.

## 1. Prepare and publish

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
- `LAUNCHPAD_BOOTSTRAP_ID`: the deployer-owned
  `<original-package-id>::blast_fun::Bootstrap`. Its nested Publisher has that
  original package ID and module `blast_fun`; record the Publisher's ID too.
- `LAUNCHPAD_UPGRADE_CAP_ID`: the deployer-owned `0x2::package::UpgradeCap`
  for that package, with native `version = 1` and compatible `policy = 0`.
- No `PackageVersion` or `PackageAdmin` exists yet. `LaunchConfig` and
  `RuntimeConfig` are shared, but their setters need the absent version object.

Read each object with `sui client object <object-id> --json`. The native cap's
version and the stored operational generation are separate values; neither is
the Sui object storage version. Stop on a wrong owner, type, package, policy,
generation, or missing object. Never try a raw upgrade to repair intake.

## 3. Wrap immediately

The deployer must submit the next deployment transaction with the identified
Bootstrap and untouched UpgradeCap. `wrap` takes both by value and shares
custody and the usable version; it needs no ACL witness. `TxContext` is supplied by Sui.

```bash
sui client call --package "${LAUNCHPAD_PACKAGE_ID:?set from publication}" \
  --module package_admin --function wrap \
  --args "${LAUNCHPAD_BOOTSTRAP_ID:?set from publication}" \
         "${LAUNCHPAD_UPGRADE_CAP_ID:?set from publication}" \
  --gas-budget "${LAUNCHPAD_GAS_BUDGET:?set the approved budget}" --json \
  > "${LAUNCHPAD_EVIDENCE_DIR:?set the evidence directory}/wrap.json"
```

Do not continue if the transaction fails or its result is uncertain. Resolve
the submitted digest with `sui client tx-block <digest> --json` and inspect
current custody before retrying; a timeout is not evidence that wrap failed.

## 4. Verify and record custody and activation

Require all of the following and retain the readbacks:

- The wrap transaction succeeded, deleted the bootstrap, and created exactly
  one shared `<original-package-id>::package_admin::PackageAdmin` and one
  shared `<original-package-id>::blast_fun::PackageVersion`. Take their IDs
  from this transaction's effects. The consumed bootstrap cannot be reused.
- Its `UpgradeCustodyCreated<BLAST_FUN>` event, emitted by the resolved
  `blast_admin::blast_admin_events` module with the launchpad's canonical
  `<original-package-id>::blast_fun::BLAST_FUN` type argument, records the
  exact `custodian_id`, `publisher_id`, `upgrade_cap_id`, `package_id`,
  `native_version = 1`, and `policy = 0` identified above.
- `sui client object <package-admin-id> --json` confirms shared ownership and
  nested custody containing that Publisher and exactly that UpgradeCap in
  its `Option`. Their package identity, native version, and policy agree with
  the event. Wrapped capabilities are no longer standalone wallet objects;
  their absence from a wallet listing alone does not prove custody.
- Reading the new `PackageVersion` confirms shared ownership and the compiled
  current operational generation, initially `1`. An aborted wrap leaves the
  bootstrap and cap unchanged and creates neither shared output.

Write a normalized record under `deployments/sui/mainnet/` following
[`deployments/README.md`](../../deployments/README.md). Include original and
current package IDs; Bootstrap, Publisher, UpgradeCap, PackageAdmin, and PackageVersion
IDs; native cap version/policy and operational generation; publication and
wrap digests/status; source/toolchain identity; and the matching event and
object evidence. Raw CLI output alone is not the record.

Missing or mismatched evidence blocks release. An already-upgraded cap cannot
be admitted: stop for a separately reviewed recovery or fresh-lineage plan;
do not weaken intake checks. Complete the remaining release requirements,
including treasury destinations and approved ACL/key custody from the
deployment-record guidance, before application rollout. Move enables launch
activity at successful wrap; those separate release controls remain operational.

## Subsequent upgrades and local verification

Use the governed transaction: authorize with the active generation and an
`UpgradeAdmin` witness, execute the native Upgrade command, then commit the
matching receipt through `package_admin::commit_upgrade_and_advance` in the
same PTB. Its `assert_next` requires the stored generation plus one to equal
the compiled next target before committing and advancing atomically. There
is no separate activation transaction or raw-cap escape path.

The existing focused checks exercise fresh matching custody, foreign and
already-upgraded cap rejection, and governed cutover:

```bash
sui move test -p sui/launchpad package_admin_tests
sui move test -p sui/admin upgrade_custody_tests
bash sui/launchpad/scripts/check_source_boundaries.sh
bash sui/admin/scripts/check_source_boundaries.sh
(cd sui/launchpad/ptb_tests && cargo test --locked --test bootstrap --test atomic_migration)
```

These local fixtures validate the custody mechanism. They do not prove that
a particular mainnet deployment followed this procedure; that requires the
transaction and object evidence above.
