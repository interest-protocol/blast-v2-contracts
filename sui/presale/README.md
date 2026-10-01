# Blast presale

`blast_presale` is a standalone Sui package for overflow presales. Its
`UpgradeCap` is sealed in a shared `PackageAdmin` restricted to dependency-only
upgrades, so venue versions can be relinked but presale logic never changes.
It does not import or mutate launchpad state. Its Bluefin and Cetus adapters,
LP vault, and holder-reward rounds live in the same package.

A creator supplies a zero-supply `TreasuryCap<SaleToken>` with its matching
`Currency<SaleToken>` and configures token supply; presale, LP, and per-recipient
allocation BPS; fixed or burn-only supply; Quote raise; commitment and migration
windows; `EligibilityPolicy`; migration venue and tier; and the LP-fee split:
up to 16 distinct fee recipients (the creator is one of them) and a holder-reward
share, whose BPS total 10,000. Allocation BPS must total 10,000. The contract mints the complete
supply once and uses largest-remainder apportionment so every atomic unit belongs
to exactly one allocation. Eligibility is either an open policy (wallet cap,
participant bound, and a minimum commitment whose product with the bound must
reach the raise) or a Merkle allowlist whose leaves carry per-wallet caps.

An optional uncapped phase lifts wallet caps partway through the window, either
for eligible wallets or for anyone, and either keeps overflow pro-rata or
hard-caps at the raise, returning any excess Quote immediately. Part of the
raise can also be allocated to recipients in BPS; the LP seeds with the rest.

Blast's shared `FeePolicy` sets its shares of the raise, the token supply, and
collected LP fees; each sale snapshots them at creation, every rate can be zero,
and payouts go to the policy's current destination. Blast's token share counts
toward the 10,000 allocation BPS, and its raise share is apportioned with the raise
recipients'. Nothing is charged at creation, on commitment, on refund, or if a
sale does not migrate.

Every accepted commitment is locked in the presale's Quote custody. Participants cannot
withdraw while a sale is open or funded. Underfunded sales, and funded sales
cancelled after the LP deadline, refund every commitment; successfully migrated
sales refund only overflow. One common fill rate applies to every wallet.

Anyone may call the configured Bluefin or Cetus migration at any time until the
sale is cancelled. From the LP deadline onward, anyone may instead cancel an
unmigrated funded sale; whichever transaction lands first wins. Migration
atomically pays Blast its raise and token shares, takes the rest of the raise and
the LP allocation, creates the configured
full-range pool, and seals the position or burn proof in a `PresaleVault`; a DEX
failure rolls back the presale transition. Configured recipients receive their
distinct allocations in that same transaction. Claims open only after success.

Permissionless fee collection pays Blast its snapshotted share of each asset,
then applies the immutable creation-time split to the rest: every fee recipient
is paid in the same transaction, and the holder-reward share stays
in the vault. Blast's `RewardsAdmin` in the shared Blast ACL publishes Merkle
rounds funded from that share, each with a claim deadline after which anyone can
return its unclaimed rewards to the vault. The `PresaleCap` claims migration residuals and
can be destroyed after cancellation. Anyone may relay participant or reward claims, but payment
always goes to the committed beneficiary. Eligibility and rewards share the
package's generic positional Blake2b-256 Merkle verifier.

After minting, the contract consumes the matching TreasuryCap into Coin Registry
`Fixed` or `BurnOnly` state. No mint authority remains after the presale is
created. On cancellation participant Quote is refundable, but every SaleToken
allocation remains permanently locked in the presale and the supply mode cannot
be reversed.

Run `scripts/verify.sh`. Publish with `scripts/publish.sh <sui-environment>
--preview`, repeat with `--execute`, then seal the returned `Publisher` and
`UpgradeCap` with `scripts/wrap_package_admin.sh <sui-environment> <package-id>
<publisher-id> <upgrade-cap-id> --preview` and `--execute` before creating any
presale.

The accepted design is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md);
Blast's fees are proposed in [ADR 0101](../../docs/decisions/0101-presale-protocol-fees.md).
