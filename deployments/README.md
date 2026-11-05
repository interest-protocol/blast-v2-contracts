# Deployment and release records

Normalized, reviewable deployment records live under
`deployments/sui/mainnet/`. Blast deploys to Sui mainnet only (ADR 0103).
Console output and `latest` pointers are not records.

Every record must contain at least:

- schema version, network/chain ID, environment, and UTC timestamp;
- repository commit, clean/dirty state, compiler and toolchain versions;
- package/contract identifiers and dependency identifiers;
- deployer, transaction digest, status, and the created shared/admin objects,
  including the `Publisher`, `UpgradeCap`/`PackageAdmin`, and
  `PackageVersion` object IDs, and, for `blast_admin`, the singleton `ACL`
  and its `SuperAdminCap`; each `AdminCap` granted with its holder and roles;
- constructor/init parameters and post-deploy verification results;
- for `blast_admin`, which is published immutably, the `sourceDigest` printed by
  `sui/admin/scripts/source_digest.sh` at the published commit, beside the
  package's `packageId`; its boundary gate refuses a `Published.toml` entry that
  no record carries or whose recorded digest differs from the current source.

Raw simulator or broadcast output stays generated and ignored. Public
normalized records must not contain secrets.

Package-specific procedures are loaded only for the operation being performed.
Blast SUI uses its [deployment](../sui/blast_sui/DEPLOYING.md) and
[upgrade](../sui/blast_sui/UPGRADING.md) runbooks. Other packages record the
same normalized evidence while following their accepted ADRs and verification
scripts.

## Records

The launch stack is greenfield: none of its packages has a live publication, and
the records of the retired launchpad, migrators, presale, timelock, admin and
partners lineages and their rehearsals and end-to-end runs were deleted on
2026-11-05 (they remain in Git history). The fresh stack receives its records
and compiler publication bindings after its own publication.

The kept records are for still-published packages the fresh stack does not
replace:

- [`2026-09-24-otc-and-vesting.json`](sui/mainnet/2026-09-24-otc-and-vesting.json):
  the immutable OTC and vesting utilities. `blast_core` links the published
  vesting package.
- `2026-09-22-nvda-alpha-boosts*.json` and `assets/`: the Boosts alpha
  deployment, its rehearsal and its metadata updates.

## Fresh launch stack

The stack is the seven packages of ADR 0137 (amended 2026-11-05) plus the
per-coin template and the vendor. `blast_admin`, `blast_partners` and
`blast_core` publish immutable; `blast_vault`, `blast_fun`, `blast_presale` and
`blast_migrators` publish compatible-upgradeable.

Before publication, set `blast_acl_root` (admin) and `blast_treasury` (core) to
their intended nonzero addresses; each `init` aborts on `0x0`.

### Publish order

A package's manifest binds the IDs of the packages it depends on, so each waits
for those: `blast_partners` needs `blast_admin`; `blast_core` needs both;
`blast_vault`, `blast_fun` and `blast_presale` need `blast_core`;
`blast_migrators` needs `blast_vault`; `launch_ticket_template` needs `blast_fun`;
the vendor `blast_aftermath_dao_presale` needs `blast_core` only. The chosen
sequence:

1. `blast_admin`
2. `blast_partners`
3. `blast_core`
4. `blast_vault`, `blast_fun` and `blast_presale`, in any order
5. `blast_migrators`
6. `launch_ticket_template` and the vendor

Each upgradeable package's deployer receives an owned `Publication<OTW>`
pinning the package's `PackageWitness`. In a follow-up transaction,
`blast_admin::package_admin::wrap` consumes it with the package's `UpgradeCap`,
sharing `PackageAdmin<OTW>` and `PackageVersion<OTW>`. The vault and both
products start fully paused; the migrators package defines no pause bits and
starts unpaused.

### Admission while paused

Admissions ignore the pause, and every publication-owned notice starts at zero,
so Blast configures the stack before any release:

1. The vault registry admits, at notice zero, the launchpad's
   `blast_fun::blast_fun::PackageWitness`, the presale's
   `blast_presale::blast_presale_package::PackageWitness`, and the venue
   witnesses `blast_migrators::cetus::Venue` and `blast_migrators::bluefin::Venue`
   (`schedule_witness`, then `apply_witness`). The vendor's venue is never listed
   here: it creates no vault.
2. Each product admits its venues at notice zero: the launchpad's
   `launch_config` lists the two migrators venues, and the presale's
   `creation_policy` lists them and the vendor's `Venue`. Then set fees, Quote
   types, partners, the launchpad claim signer and allocation.
3. Apply or cancel every outstanding zero-notice proposal, then raise every
   notice: the vault's witness notice and each product configuration notice
   (48 hours for this rollout). Raising a notice does not rewrite older
   proposals. The vault's fee-split and Blast-share notices are compiled at
   48 hours and have no setter. `blast_core`'s treasury notice and each
   package's `PackageAdmin` upgrade notice start at 48 hours and need no raise.
4. Unpause the vault (`blast_vault_package::unpause`), then the products
   (`launch_config::unpause`, `creation_policy::unpause`). Each takes the core
   `Treasury` and refuses while one of its notices, or the treasury's, is
   unguarded.

Record the chosen fees, destinations, allowlists and applied-value events,
Publication consumption, sealed custody, every applied notice, proposal state,
pause masks and unpause evidence. Verify approved key custody before the
multisig `UnpauseAdmin` releases selected operations. Later protected changes
wait their operation's applied notice, including while paused; notice
reductions wait the old notice.

### Releases

- A vault upgrade forces a migrators relink in the same window. The venues call
  version-gated vault functions, so after `commit_upgrade_and_advance` on the
  vault, migration and fee collection abort until the relink lands. The relink
  is a normal migrators release: a compatible upgrade that rebinds the vault
  address and bumps `constants::version`. Prepare, review and schedule both
  upgrades together, then execute the vault upgrade and the migrators upgrade
  back to back.
- A migrators (DEX bump), product or vendor release forces no other package to
  relink: products and venues meet only through the `Migration` passed in the
  PTB.
- Every release bumps the package's `constants::version`;
  `commit_upgrade_and_advance` advances the stored version in the same call.
- `make_immutable` ends upgrades for good. It needs the package's own witness
  and live `PackageVersion`, so only a package with its own wrapper can take
  it: today the vault (see [Vault immutability](#vault-immutability)). Another
  package gains one only through an upgrade.

## Boosts adapter upgrades

[ADR 0123](../docs/decisions/0123-successor-activated-boosts-upgrades.md) applies
to the fresh adapter lineage, not the historical deployed package. After
publication and before the first upgrade or vault funding, seal the canonical
Publisher and raw UpgradeCap through `package_admin::wrap`. The initializer
delivers the Publisher to the publisher; wrapping uses it in a follow-up
transaction. The supported policy remains compatible.

1. Read the active version from `Protocol`, the native count
   from the sealed cap, and the live UpgradeAdmin role. Compile the successor's
   `PACKAGE_VERSION` as **active version + 1**, even after failed native
   upgrades. Review its exact digest, dependency pins and compatibility. Never
   substitute the native upgrade count for the version.
2. Sign in on the immutable ACL. In one transaction, pass that witness and exact
   digest to `package_admin::authorize_upgrade`, consume the ticket with the
   native upgrade command, and consume its receipt with `package_admin::commit_upgrade`
   on the same PackageAdmin. This does not change the active version.
3. From the newly installed package ID, in a **second transaction**, sign in
   again and call `package_admin::activate_upgrade(protocol, witness)`. It checks
   its own compiled version; no caller supplies a version number. Failure leaves
   the old version usable. Publish a corrected successor through the same
   repair path and retry; native and operational counts can diverge.
4. Record both transaction digests, original and installed package IDs, exact
   source/toolchain/digest, dependencies, native count, version,
   custody/Protocol IDs, UpgradeCommitted and VersionAdvanced events,
   and before/after checks of old rejection, new operations and required exits.
   Direct callers and dependent packages to the reviewed activated release.

Activation verifies a consecutive version, not arbitrary code health or unique
latest-package identity. Rehearse the successor and all exit/dependent routes
before activation. A retained, unactivated candidate sharing the same operational
version remains callable; administrators must not activate an unintended
candidate. Live ACL revocation still removes repair authority, including in old
packages. Replacing governance must explicitly retire that role.
Activate only the package ID reviewed for the current cutover and record all
superseded candidate IDs: a rejected candidate compiled ahead of the active
version can become activatable after a later cutover.

`make_immutable` is a deliberate terminal action. Keep its current-version
check; verify intended release, dependencies and exits before burning the cap.
It checks a version match only and does not prove that no upgrade is pending or
that the latest installed code is correct. No later repair is possible once the
cap is destroyed.

## Vault immutability

The vault ships upgradeable and is made immutable after its audit and a quiet
period (#195). Schedule it with `package_admin::schedule_make_immutable` under
`UpgradeAdmin<BLAST_VAULT_PACKAGE>`, wait the applied upgrade notice, then call
`blast_vault_package::make_immutable` from the current vault package. It checks
the live version before the generic administration checks the vault's package
witness, consumes the action and destroys the cap. Before you execute it, record
the installed package ID and digest, and verify the migrators' relink against
that exact vault. Nothing can be repaired afterwards.

## Imported utility records

The September 2026 OTC and vesting record retains its original repository URL
and commit IDs as provenance. Their full Git history is imported here; see
[utility verification](../docs/utilities.md). Consolidation does not publish,
upgrade, or replace an on-chain package.
