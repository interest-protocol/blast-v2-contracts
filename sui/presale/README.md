# Blast presale

`blast_presale` is a standalone, immutable Sui package for overflow presales.
It does not import or mutate launchpad state. Its Bluefin and Cetus adapters,
LP vault, and holder-reward rounds live in the same package.

A creator supplies a zero-supply `TreasuryCap<SaleToken>` with its matching
`Currency<SaleToken>` and configures token supply; presale, LP, and per-recipient
allocation BPS; fixed or burn-only supply; Quote raise; commitment and migration
windows; `EligibilityPolicy`; migration venue and tier; and the LP-fee split:
up to 16 distinct fee recipients (the creator is one of them) and a holder-reward
share, whose BPS total 10,000. Allocation BPS must total 10,000. The contract mints the complete
supply once and uses largest-remainder apportionment so every atomic unit belongs
to exactly one allocation. Eligibility is either one open wallet cap or a Merkle
allowlist whose leaves carry per-wallet caps.

Every commitment consumes and locks its full `Coin<Quote>`. Participants cannot
withdraw while a sale is open or funded. Underfunded sales, and funded sales
cancelled after the LP deadline, refund every commitment; successfully migrated
sales refund only overflow. One common fill rate applies to every wallet.

Anyone may call the configured Bluefin or Cetus migration at any time until the
sale is cancelled. From the LP deadline onward, anyone may instead cancel an
unmigrated funded sale; whichever transaction lands first wins. Migration
atomically takes the exact raise and LP allocation, creates the configured
full-range pool, and seals the position or burn proof in a `PresaleVault`; a DEX
failure rolls back the presale transition. Configured recipients receive their
distinct allocations in that same transaction. Claims open only after success.

Permissionless fee collection applies the immutable creation-time split: every
fee recipient is paid in the same transaction, and the holder-reward share stays
in the vault. Blast's `RewardsAdmin` in the shared Blast ACL publishes Merkle
rounds funded from that share. The `PresaleCap` claims migration residuals and
can be destroyed after cancellation. Anyone may relay participant or reward claims, but payment
always goes to the committed beneficiary. Eligibility and rewards share the
package's generic positional Blake2b-256 Merkle verifier.

After minting, the contract consumes the matching TreasuryCap into Coin Registry
`Fixed` or `BurnOnly` state. No mint authority remains after the presale is
created. On cancellation participant Quote is refundable, but every SaleToken
allocation remains permanently locked in the presale and the supply mode cannot
be reversed.

Run `scripts/verify.sh`. Publish with
`scripts/publish_immutable.sh <sui-environment> --preview` and repeat with
`--execute` after reviewing the transaction.

The accepted design is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md).
