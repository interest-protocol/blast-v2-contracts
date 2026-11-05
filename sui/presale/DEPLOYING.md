# Deploying Blast presale

Use this runbook for a new `blast_presale` deployment. Record the normalized result
in the format required by [`deployments/README.md`](../../deployments/README.md).
Publication alone cannot activate presales. The publisher receives an owned generic
Publication; only `blast_admin::package_admin::wrap` with the matching fresh UpgradeCap
shares PackageVersion.
Routine mutations and sale creation require the shared version (ADR 0137,
with the delayed policy of ADR 0134). Wrap starts fully paused with zero notice on publication-owned
policies and a 48-hour notice on the PackageAdmin; ordinary ACL operations configure
policy before the chosen delay and release.

1. `blast_admin`, `blast_partners` and `blast_core` must already be published, with
   their `Published.toml` entries committed, so this build links to the one Blast ACL and
   generic package administration, the partner registry (see the partners
   [README](../partners/README.md)), and the core `Treasury` every Blast fee goes to. The
   vault must also be published and wrapped, so its shared `PackageVersion` and
   `VaultRegistry` exist; it stays paused until its venues and issuers are admitted
   (step 5). Run the complete `scripts/verify.sh` gate, then `scripts/publish.sh
   --preview` and `--execute`, which publish to mainnet. The sender receives the raw
   `UpgradeCap` and the owned
   `blast_admin::package_version::Publication<BLAST_PRESALE_PACKAGE>`; the package mints no
   administrator capability. Do not upgrade the package before custody finalization:
   `blast_admin::package_admin::wrap` accepts only a never-upgraded cap, and a cap upgraded
   first can never be sealed.
2. Create the PackageAdmin with `scripts/wrap_package_admin.sh <admin-package-id> <package-id>
   <publication-id> <upgrade-cap-id> --preview` and `--execute`, which calls
   `blast_admin::package_admin::wrap<BLAST_PRESALE_PACKAGE>`. Publication carries provenance
   only and is permanently consumed. Configure policy after wrap through the ACL.

3. From the effects of step 2, verify that `PackageAdmin<BLAST_PRESALE_PACKAGE>` is shared
   and that the `UpgradeCap` is wrapped inside it, no longer address-owned, with its policy
   unchanged at compatible (`0`). Record the newly shared
   `PackageVersion<BLAST_PRESALE_PACKAGE>`; its initial pause mask must be 7. Verify zero
   notice on the presale's policies and 48 hours on the PackageAdmin. Verify that wrapping
   consumed the Publication. From the publish effects, record the shared `FeePolicy`,
   `CreationPolicy`, and `PresaleRegistry` singletons.
4. With the Blast ACL's `SuperAdminCap`, grant the roles (`blast_acl::grant_role`) to the
   operations multisig's `AdminCap`, minting one with `blast_acl::grant_admin` if needed.
   Product roles are `blast_core::blast_domain`'s, shared with the launchpad and the vault:
   `FeeAdmin` sets the rates for future sales and individual sales before they start and
   chooses which Blast partners new sales may name; `ListingAdmin` allows Quote types;
   `VenueAdmin` admits venues, each of which receives the liquidity of the sales it
   creates; `TreasuryAdmin`, with the treasury multisig, governs the core treasury's
   destination. Package roles are `blast_admin::package_admin`'s over
   `BLAST_PRESALE_PACKAGE`: `UpgradeAdmin` governs the upgrade notice and compatible upgrades
   with atomic version cutover, `PauseAdmin` and `UnpauseAdmin` set and clear pause bits,
   and `CancelAdmin` cancels upgrade actions. Grant both `CancelAdmin` roles and `PauseAdmin`
   to the independent incident-response multisig before release: revoking a role does not
   cancel its pending proposals, so cancellation must be available. Each call signs in with
   `blast_acl::sign_in` in the same PTB. The root revokes a role or an administrator at once
   if a cap is lost or compromised.
5. With the ordinary role witnesses and Clock, schedule/apply fee rates and reviewed venue
   admission: `creation_policy::schedule_venue` and `apply_venue` for each admitted venue
   witness (`blast_migrators::cetus::Venue`, `blast_migrators::bluefin::Venue`, vendor
   venues). Quote admission uses ListingAdmin. At zero delay scheduling and application can
   share a PTB. Zero fees are valid; verify rates and venue admission. Apply or cancel every
   outstanding zero-delay proposal. Use each operation's role to schedule/apply its intended
   next notice (172,800,000 ms = 48 hours) and read each notice back. The PackageAdmin
   already holds 48 hours; do not propose it again (an unchanged notice aborts). Then grant
   `UnpauseAdmin<BLAST_PRESALE_PACKAGE>` and clear the selected bits (all = 7) with
   `creation_policy::unpause`, passing the shared CreationPolicy, PackageVersion, PackageAdmin,
   FeePolicy and the core Treasury. It aborts with `EUnguardedDelay` while either policy's or the
   treasury's notice is zero, a pending proposal would set one to zero, or a venue admission is
   pending, and the generic administration aborts while the upgrade notice is unguarded. Unpause
   is immediate and needs no Clock. Pausing never resets a notice.

   Each admitted venue that creates vaults must also be admitted in the vault's
   `VaultRegistry`, or its migrations abort, so admit it there first. Removing a venue from
   the registry strands every funded sale that names it until it is admitted again; reserve
   that for a venue found unsafe. The vault must also list the presale's
   `blast_presale::blast_presale_package::PackageWitness`, the issuer of every presale's
   vault terms. To list each: with the core `blast_domain::VenueAdmin`,
   `blast_vault_package::schedule_witness<Witness>` then `apply_witness`. The vault
   publishes fully paused with a zero admission notice, so admit the presale and launchpad
   issuers and venues together, then raise the vault's notice to 48 hours and unpause it, as
   [migrators DEPLOYING](../migrators/DEPLOYING.md) describes. A venue admitted later waits
   that notice.
6. Creation tooling should dev-inspect the venue's `migrate` with each new sale's own
   venue terms before listing it: a sale the venue rejects refunds only at its liquidity
   deadline. Allow only Quote types whose deny-list and pause controls Blast accepts
   (owner, 2026-10-02): payouts are pushed, so a denied fee recipient blocks that vault's
   collection and a denied raise recipient blocks migration until the LP deadline (ADR 0134,
   accepted trust boundaries). Create sale coins through Coin Registry without regulation.
   Finalization enforces confirmed `Unregulated` status and rejects legacy `Unknown` status,
   which can conceal an existing deny cap. Accept each presale partner deal, once it is
   registered in `blast_partners`, as `FeeAdmin` with `creation_policy::add_partner`.
7. Operate a keeper that calls `settle`, `blast_presale::migrate` and the venue's `migrate`
   in one PTB as soon as a sale's `end_ms` passes, followed by
   `blast_presale::pay_protocol_fees_with_partner` for a sale that names a partner, which
   pays the partner and Blast the fees its migration held. After each LP-fee collection on a
   partnered sale's vault, call `blast_vault::vault::pay_protocol_fees_with_partner`. The
   seven-day LP-window floor keeps a successful raise from being settled and cancelled in
   one transaction, but a funded sale still reaches its refund exit after a week without
   migration. Each venue's own arguments (Bluefin's creation fee, Cetus's coin order) are in
   [migrators DEPLOYING](../migrators/DEPLOYING.md).
8. Record publication, source verification, object IDs, transaction digests, each
   presale role granted with its `AdminCap` and holder, and the checks above.

The package behavior and exact callable signatures live in source. The design
rationale is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md)
with its amendments [0102](../../docs/decisions/0102-presale-creation-allowlists.md),
[0104](../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md),
[0106](../../docs/decisions/0106-presale-partners.md), and
[0137](../../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md).

For later governed upgrades, increment `constants::version`. Schedule the digest with
`blast_admin::package_admin::schedule_upgrade` under `UpgradeAdmin<BLAST_PRESALE_PACKAGE>`,
wait its snapshotted deadline, authorize it, execute the native upgrade, and call
`blast_admin::package_admin::commit_upgrade_and_advance` with the receipt and mutable
PackageVersion in the same PTB. Refresh SDK package IDs while retaining the original type identity and
shared objects. Never advance a version separately from the native commit.
