# Blast presale

`blast_presale` is a standalone Sui package for presales that overflow pro rata or
fill first come up to a hard cap. Its
`UpgradeCap` is sealed in a shared `PackageAdmin` restricted to dependency-only
upgrades, so venue versions can be relinked but presale logic never changes.
It does not import or mutate launchpad state. Its Bluefin and Cetus adapters,
LP vault, and holder-reward rounds live in the same package.

A creator starts a sale through a venue's `new` with a zero-supply
`TreasuryCap<SaleToken>`, sets its terms on the returned `PresaleInitializer`, and
`finalize` checks them together and mints the supply with its matching
`Currency<SaleToken>` ([ADR 0110](../../docs/decisions/0110-presale-initializer-and-early-close.md)).
The terms are token supply; presale, LP, and per-recipient
allocation BPS; fixed or burn-only supply; Quote raise; commitment and migration
windows (the migration window is at least seven days); `EligibilityPolicy`;
migration venue and tier; and the LP-fee split:
up to 16 distinct fee recipients (the creator is one of them) and a holder-reward
share, whose BPS total 10,000. Allocation BPS must total 10,000. The contract mints the complete
supply once and uses largest-remainder apportionment so every atomic unit belongs
to exactly one allocation. Eligibility is either an open policy (wallet cap,
participant bound, and a minimum commitment whose product with the bound must
reach the raise) or a Merkle allowlist whose leaves carry per-wallet caps.

An optional uncapped phase lifts wallet caps partway through the window, either
for eligible wallets or for anyone. An optional hard cap, from the start or from
a later point in the window, holds commitments to the raise first come, first
served, returning any excess Quote immediately; before it the sale overflows
pro rata. A sale whose hard cap closes it when filled may be settled by anyone as
soon as its raise is full, and its LP deadline then counts from that close;
otherwise every sale runs its full window. A phase open to
anyone must reach the raise at its minimum over the slots held to that minimum:
all of them under an open policy, and only those beyond the allowlist's leaves
under an allowlist, since allowlisted wallets may commit any positive amount.
Part of the raise can also be allocated to recipients in BPS; the LP seeds with
the rest. Any token or raise recipient share may vest: its cliff, step period,
and step count are fixed at creation, and migration locks it in an irrevocable
[`blast_fun_vesting`](https://github.com/interest-protocol/blast-util-contracts/tree/main/sui/vesting)
linear schedule that starts at migration instead of paying it out. Fee shares
cannot vest. Participant tokens may vest too, under terms fixed at creation:
each claim then locks the participant's tokens in its own irrevocable schedule
that starts at that claim, while its Quote refund is paid at once.

Blast's shared `FeePolicy` sets its shares of the raise, the token supply, and
collected LP fees; each sale snapshots them at creation, every rate can be zero,
and payouts go to the policy's current destination. Until a sale's window starts,
including in its creation transaction before `share`, the `AdminCap` can change
all four of its rates with `blast_presale::set_protocol_fees`; Blast's token
difference moves to or from the buyers' sale allocation and its raise difference to or from the LP's Quote. After
migration it can change one sale's LP-fee rates on its vault with
`presale_vault::set_protocol_lp_fees`. Blast's token share counts
toward the 10,000 allocation BPS, and its raise share is apportioned with the raise
recipients'. Nothing is charged at creation, on commitment, on refund, or if a
sale does not migrate.

A sale may name one Blast partner, which the creator sets with `set_partner` on
the initializer before `finalize`; it never changes afterward. The partner earns its
`blast_partners` cut of Blast's raise fee and, after migration, of Blast's LP
fees; never of Blast's token fee. A partnered sale's migration holds Blast's
fees, and anyone may then call `pay_protocol_fees_with_partner` once to pay the
partner its cut and Blast the rest
([ADR 0106](../../docs/decisions/0106-presale-partners.md)). Its vault inherits
the partner and holds Blast's LP fees at each collection, until anyone calls
`presale_vault::pay_protocol_lp_fees_with_partner`
([ADR 0107](../../docs/decisions/0107-partner-cut-of-lp-fees.md)).

Blast's shared `CreationPolicy` lists the Quote types, venue migration witnesses,
and Blast partners new presales may use; creation aborts for anything unlisted. It is checked only at
creation, so delisting a type never affects a live sale. `blast_presale::new`,
`finalize`, and `migrate` are public, so a migrator in another package, such as a partner's under
[`sui/vendors`](../vendors/README.md), creates and migrates sales with its own sealed
witness once the `AdminCap` allows it; a primitive or vector, which anyone can
construct, is never allowed
([ADR 0104](../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md)).

Sharing a sale fixes its windows from a start time, which may be ahead of the
share so a sale can be published a day early; commitments open at the start.

Every accepted commitment is locked in the presale's Quote custody. Participants cannot
withdraw while a sale is open or funded. Underfunded sales, and funded sales
cancelled after the LP deadline, refund every commitment; successfully migrated
sales refund only overflow. One common fill rate applies to every wallet.

Anyone may call the configured Bluefin or Cetus migration at any time until the
sale is cancelled. From the LP deadline onward, anyone may instead cancel an
unmigrated funded sale; whichever transaction lands first wins. The LP window is
at least seven days, so a funded sale reaches that exit only after a week in
which nobody migrated it. Migration
atomically pays Blast its raise and token fees, or holds them for
`pay_protocol_fees_with_partner` when the sale names a partner, takes the rest of
the raise and
the LP allocation, creates the configured
full-range pool, and seals the position or burn proof in a `Vault`; a DEX
failure rolls back the presale transition. Configured recipients receive their
distinct allocations in that same transaction. Claims open only after success.

Permissionless fee collection pays Blast its share of each asset at the vault's
current rates, or holds it for a partnered sale's partner payout, then applies the immutable creation-time split to the rest: every fee recipient
is paid in the same transaction, and the holder-reward share stays
in the vault. The holder of the package's `AdminCap` publishes Merkle
rounds funded from that share, each with a claim deadline after which anyone can
return its unclaimed rewards to the vault. The `PresaleCap` claims migration residuals and
can be destroyed after cancellation. Anyone may relay participant or reward claims, but payment
always goes to the committed beneficiary. Eligibility and rewards share the
package's generic positional Blake2b-256 Merkle verifier. Neither adapter
collects venue incentive rewards credited to the position, and under
dependency-only custody no later generation can add that path.

After minting, the contract consumes the matching TreasuryCap into Coin Registry
`Fixed` or `BurnOnly` state. No mint authority remains after the presale is
created. On cancellation participant Quote is refundable, but every SaleToken
allocation remains permanently locked in the presale and the supply mode cannot
be reversed.

Run `scripts/verify.sh`. Publish to mainnet with `scripts/publish.sh --preview`,
repeat with `--execute`, then seal the returned `UpgradeCap` with
`scripts/wrap_package_admin.sh <package-id> <upgrade-cap-id> --preview` and
`--execute` before creating any presale. Publication also sends
the publisher the package's single `AdminCap`, which sets Blast's fees and their
destination, allows Quote types, migrators, and partners, publishes holder-reward rounds,
and authorizes dependency-only upgrades while the shared `AdminRegistry` accepts
it, and a key-only `SuperAdminCap` whose only power is to replace or revoke that
cap. [DEPLOYING.md](DEPLOYING.md) gives the
complete order: custody is verified on chain before the `AdminCap` allows any
Quote type or migrator, so no presale can exist under an unsealed cap.

The accepted design is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md);
Blast's fees are proposed in [ADR 0101](../../docs/decisions/0101-presale-protocol-fees.md)
and its presale partners in [ADR 0106](../../docs/decisions/0106-presale-partners.md);
creation through the initializer, the sale-level hard cap, and early close are proposed in
[ADR 0110](../../docs/decisions/0110-presale-initializer-and-early-close.md).
