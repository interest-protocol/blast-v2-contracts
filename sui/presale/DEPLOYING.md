# Deploying Blast presale

Use this runbook for a new `blast_presale` deployment. Record the normalized result
in the format required by [`deployments/README.md`](../../deployments/README.md).
The order matters: a presale can exist only after `FeeAdmin` allows a Quote type
and a migrator, so custody is sealed and verified before any allowlisting, and no
sale is ever created under an unsealed cap.

1. Run the complete `scripts/verify.sh` gate, then `scripts/publish.sh <env>
   --preview` and `--execute`. The sender receives the `Publisher` and the raw
   `UpgradeCap`. Do not upgrade the package before step 2: `upgrade_custody::new`
   accepts only a never-upgraded cap, and a cap upgraded first can never be sealed.
2. Seal custody with `scripts/wrap_package_admin.sh <env> <package-id>
   <publisher-id> <upgrade-cap-id> --preview` and `--execute`.
3. From the effects of step 2, verify that `PackageAdmin` is shared, that the
   `UpgradeCap` is wrapped inside it and no longer address-owned, and that
   `UpgradeCustodyCreated` and `UpgradePolicyRestricted` show the policy narrowed
   to dependency-only (`192`). From the publish effects, record the shared
   `FeePolicy`, `CreationPolicy`, and `VenueConfig` singletons.
4. On the singleton Blast ACL, have the `SuperAdminCap` holder grant
   `blast_presale_domain::FeeAdmin`, `TreasuryAdmin`, `RewardsAdmin`, and
   `UpgradeAdmin` to the intended `AdminCap`s. Hold the root and these caps in
   multisigs: `RewardsAdmin` directs every vault's holder-reward share and
   `FeeAdmin` sets the terms of every future sale.
5. As `TreasuryAdmin`, call `fee_policy::set_destination`; the policy pays the
   publisher until then. As `FeeAdmin`, call `fee_policy::set_fees` if the launch
   rates are not zero.
6. Only now, as `FeeAdmin`, allow the launch Quote types with
   `creation_policy::set_quote_allowed` and the venues with
   `set_migration_witness_allowed<cetus::Witness>` and `<bluefin::Witness>`. Allow
   only Quote types whose deny-list and pause controls Blast accepts (owner,
   2026-10-02): payouts are pushed, so a denied fee recipient blocks that vault's
   collection and a denied raise recipient blocks migration until the LP deadline.
   Vet each sale coin's `Currency` regulated state the same way before listing a
   sale, since a regulated sale coin lets its creator block participants'
   post-migration claims.
7. Operate a keeper that calls `settle` and the venue's `migrate` in one PTB as
   soon as a sale's `end_ms` passes. The seven-day LP-window floor keeps a
   successful raise from being settled and cancelled in one transaction, but a
   funded sale still reaches its refund exit after a week without migration. For
   Bluefin, pass a `Coin<SUI>` equal to `config::get_pool_creation_fee_amount<SUI>`
   read at submission time; Bluefin aborts on any other amount. For Cetus, the
   Quote must be in Cetus's permission-pair allowlist at the sale's tick spacing
   when the sale is created.
8. Record publication, source verification, object IDs, transaction digests, role
   grants, and the checks above.

The package behavior and exact callable signatures live in source. The design
rationale is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md)
with its amendments [0101](../../docs/decisions/0101-presale-protocol-fees.md)
and [0102](../../docs/decisions/0102-presale-creation-allowlists.md).
