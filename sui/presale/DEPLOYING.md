# Deploying Blast presale

Use this runbook for a new `blast_presale` deployment. Record the normalized result
in the format required by [`deployments/README.md`](../../deployments/README.md).
The order matters: a presale can exist only after the `AdminCap` allows a Quote
type and a migrator, so custody is sealed and verified before any allowlisting, and no
sale is ever created under an unsealed cap.

1. Retire the previous generation's link. The live package at
   `0x76cb0508fc94234fddd910b5616248f8a42998048a28e55f5fe1cc89e7b98400` is
   sealed dependency-only and can never gain the logic this source adds, so this
   is a new publication, not an upgrade
   ([ADR 0104](../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md)).
   Its record stays in
   `deployments/sui/mainnet/2026-10-04-blast-presale.json`. Delete its
   `[published.mainnet]` entry from `Published.toml` before publishing, so this
   build publishes a new package rather than resolving to the old one, and commit
   the entry the new publication writes: vendor packages link to it.
2. `blast_partners` must already be published, with its `Published.toml`
   committed, so this build links to it (see its
   [README](../partners/README.md)). Run the complete `scripts/verify.sh` gate,
   then `scripts/publish.sh --preview`
   and `--execute`, which publish to mainnet. The sender receives the `SuperAdminCap`, the
   `AdminCap` the shared `AdminRegistry` accepts, and the raw `UpgradeCap`. Do not upgrade the package before step 3:
   `package_admin::wrap` accepts only a never-upgraded cap, and a cap upgraded
   first can never be sealed.
3. Seal custody with `scripts/wrap_package_admin.sh <package-id> <upgrade-cap-id>
   --preview` and `--execute`.
4. From the effects of step 3, verify that `PackageAdmin` is shared and that the
   `UpgradeCap` is wrapped inside it, no longer address-owned, with its policy
   narrowed to dependency-only (`192`). From the publish effects, record the
   shared `AdminRegistry`, `FeePolicy`, `CreationPolicy`, and `VenueConfig`
   singletons, the `SuperAdminCap`, and the `AdminCap`, and check that the
   registry records that `AdminCap`'s ID.
5. Move the `SuperAdminCap` to Blast's cold multisig with
   `blast_presale_admin::transfer_super_admin`, and the `AdminCap` to the
   operations multisig. The `AdminCap` is the package's only administrator: it
   directs every vault's holder-reward share, sets the terms of every future
   sale and Blast's LP-fee rates on every vault, redirects Blast's fee payouts, chooses the
   Blast partners new sales may name, and authorizes dependency-only upgrades.
   Every one of those calls also takes the `AdminRegistry`. The `SuperAdminCap`
   can only `replace_admin_cap`, which mints a new cap and stops the old one at
   once, or `revoke_admin_cap`, which stops all administration until the next
   replacement. Use it only if the `AdminCap` is lost or compromised.
6. With the `AdminCap`, call `fee_policy::set_destination`; the policy pays the
   publisher until then. Call `fee_policy::set_fees` if the launch rates are not
   zero.
7. Only now, with the `AdminCap`, allow the launch Quote types with
   `creation_policy::set_quote_allowed` and the venues with
   `set_migration_witness_allowed<cetus::Witness>` and `<bluefin::Witness>`, plus
   any reviewed external migrator's witness, such as a vendor package's. Allow
   only Quote types whose deny-list and pause controls Blast accepts (owner,
   2026-10-02): payouts are pushed, so a denied fee recipient blocks that vault's
   collection and a denied raise recipient blocks migration until the LP deadline.
   Vet each sale coin's `Currency` regulated state the same way before listing a
   sale, since a regulated sale coin lets its creator block participants'
   post-migration claims. Accept each presale partner deal, once it is registered
   in `blast_partners`, with `creation_policy::add_partner`.
8. Operate a keeper that calls `settle` and the venue's `migrate` in one PTB as
   soon as a sale's `end_ms` passes, followed by
   `blast_presale::pay_protocol_fees_with_partner` for a sale that names a
   partner, which pays the partner and Blast the fees its migration held. The seven-day LP-window floor keeps a
   successful raise from being settled and cancelled in one transaction, but a
   funded sale still reaches its refund exit after a week without migration. For
   Bluefin, pass a `Coin<SUI>` equal to `config::get_pool_creation_fee_amount<SUI>`
   read at submission time; Bluefin aborts on any other amount. For Cetus, the
   Quote must be in Cetus's permission-pair allowlist at the sale's tick spacing
   when the sale is created.
9. Record publication, source verification, object IDs, transaction digests, the
   `SuperAdminCap` and `AdminCap` transfers, and the checks above.

The package behavior and exact callable signatures live in source. The design
rationale is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md)
with its amendments [0101](../../docs/decisions/0101-presale-protocol-fees.md),
[0102](../../docs/decisions/0102-presale-creation-allowlists.md),
[0104](../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md),
and [0106](../../docs/decisions/0106-presale-partners.md).
