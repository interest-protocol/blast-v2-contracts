# Deploying Blast presale

Use this runbook for a new `blast_presale` deployment. Record the normalized result
in the format required by [`deployments/README.md`](../../deployments/README.md).
The order matters: a presale can exist only after Blast's `ListingAdmin` and
`AdapterAdmin` allow a Quote type and a migrator, so custody is sealed and verified before any allowlisting, and no
sale is ever created under an unsealed cap.

1. Retire the previous generation's link when a release changes presale logic.
   The live package, recorded in
   `deployments/sui/mainnet/2026-10-09-blast-presale.json`, is sealed
   dependency-only and can never gain new logic, so such a release is a new
   publication, not an upgrade
   ([ADR 0104](../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md)).
   Its record stays. Delete its
   `[published.mainnet]` entry from `Published.toml` before publishing, so this
   build publishes a new package rather than resolving to the old one, and commit
   the entry the new publication writes: vendor packages link to it.
2. `blast_admin` and `blast_partners` must already be published, with their
   `Published.toml` entries committed, so this build links to the one Blast ACL
   and the partner registry (see the partners
   [README](../partners/README.md)). Run the complete `scripts/verify.sh` gate,
   then `scripts/publish.sh --preview`
   and `--execute`, which publish to mainnet. The sender receives only the raw `UpgradeCap`; the
   package mints no administrator capability. Do not upgrade the package before step 3:
   `package_admin::wrap` accepts only a never-upgraded cap, and a cap upgraded
   first can never be sealed.
3. Seal custody with `scripts/wrap_package_admin.sh <package-id> <upgrade-cap-id>
   --preview` and `--execute`.
4. From the effects of step 3, verify that `PackageAdmin` is shared and that the
   `UpgradeCap` is wrapped inside it, no longer address-owned, with its policy
   narrowed to dependency-only (`192`). From the publish effects, record the
   shared `FeePolicy`, `CreationPolicy`, and `VenueConfig` singletons.
5. With the Blast ACL's `SuperAdminCap`, grant the presale roles
   (`blast_acl::grant_role` with each `blast_presale_domain` type) to the
   operations multisig's `AdminCap`, minting one with `blast_acl::grant_admin`
   if needed. Grant each concern deliberately: `TreasuryAdmin` redirects Blast's
   fee payouts; `FeeAdmin` sets the rates of every future sale, of a sale before
   its start, and Blast's LP-fee rates on every vault, and chooses the Blast
   partners new sales may name; `ListingAdmin` allows Quote types;
   `AdapterAdmin` allows migrators, each of which receives the liquidity of the
   sales it creates; `RewardsAdmin` directs every vault's holder-reward share;
   and `UpgradeAdmin` authorizes dependency-only upgrades. Each call signs in
   with `blast_acl::sign_in` in the same PTB. The root revokes a role or an
   administrator at once if a cap is lost or compromised.
6. As `TreasuryAdmin`, call `fee_policy::set_destination`; the policy pays the
   publisher until then. As `FeeAdmin`, call `fee_policy::set_fees` if the
   launch rates are not zero.
7. Only now allow the launch Quote types as `ListingAdmin` with
   `creation_policy::set_quote_allowed`, and as `AdapterAdmin` the venues with
   `set_migration_witness_allowed<cetus::Witness>`, `<bluefin::Witness>`, and
   `<aftermath::Witness>`, plus any reviewed external migrator's witness, such as a
   vendor package's. Before allowing Aftermath, run `sui/migrators`'
   `node scripts/check_mainnet_abi.mjs`, which pins the Aftermath AMM and
   DAO-fee revisions this package links to, and prove a mainnet dev-inspect of
   `aftermath::migrate` with a fresh LP coin for both coin orders: the local
   stubs prove types, not behavior. Allow
   only Quote types whose deny-list and pause controls Blast accepts (owner,
   2026-10-02): payouts are pushed, so a denied fee recipient blocks that vault's
   collection and a denied raise recipient blocks migration until the LP deadline.
   Vet each sale coin's `Currency` regulated state the same way before listing a
   sale, since a regulated sale coin lets its creator block participants'
   post-migration claims. Accept each presale partner deal, once it is registered
   in `blast_partners`, as `FeeAdmin` with `creation_policy::add_partner`.
8. Operate a keeper that calls `settle` and the venue's `migrate` in one PTB as
   soon as a sale's `end_ms` passes, followed by
   `blast_presale::pay_protocol_fees_with_partner` for a sale that names a
   partner, which pays the partner and Blast the fees its migration held. The seven-day LP-window floor keeps a
   successful raise from being settled and cancelled in one transaction, but a
   funded sale still reaches its refund exit after a week without migration. For
   Bluefin, pass a `Coin<SUI>` equal to `config::get_pool_creation_fee_amount<SUI>`
   read at submission time; Bluefin aborts on any other amount. For Cetus, the
   Quote must be in Cetus's permission-pair allowlist at the sale's tick spacing
   when the sale is created. For Aftermath, pass the sale's shared
   `aftermath::PoolCreation` by value; its DAO fees then wait as coins at the
   vault's address until a keeper lists them in `aftermath::collect_fees`.
9. Record publication, source verification, object IDs, transaction digests, each
   presale role granted with its `AdminCap` and holder, and the checks above.

The package behavior and exact callable signatures live in source. The design
rationale is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md)
with its amendments [0101](../../docs/decisions/0101-presale-protocol-fees.md),
[0102](../../docs/decisions/0102-presale-creation-allowlists.md),
[0104](../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md),
and [0106](../../docs/decisions/0106-presale-partners.md).
