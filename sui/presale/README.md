# Blast presale

`blast_presale` is a standalone, immutable Sui package for overflow presales.
It does not import or mutate launchpad state. Its Bluefin and Cetus adapters,
LP vault, and holder-reward rounds live in the same package.

A creator supplies a zero-supply `TreasuryCap<SaleToken>` and configures token
supply, presale-allocation BPS, LP-allocation BPS, Quote raise, commitment and
migration windows, `EligibilityPolicy`, migration venue and tier, and
creator/reward LP-fee BPS. Each token allocation is
`floor(token_supply * allocation_bps / 10_000)`. Their combined rate cannot
exceed 10,000 BPS, both results must be positive, and only those allocations
are minted. Eligibility is either one open wallet cap or a Merkle allowlist
whose leaves carry per-wallet caps.

Every commitment consumes and locks its full `Coin<Quote>`. Participants cannot
withdraw while a sale is open or funded. Underfunded and timed-out sales refund
every commitment; successfully migrated sales refund only overflow. One common
fill rate applies to every wallet.

Anyone may call the configured Bluefin or Cetus migration before the deadline.
It atomically takes the exact raise and LP allocation, creates the configured
full-range pool, and seals the position or burn proof in a `PresaleVault`; a DEX
failure rolls back the presale transition. Claims open only after success.

Permissionless fee collection applies the immutable creation-time BPS split.
The `PresaleCap` claims the creator share and migration residuals, publishes
Merkle rounds funded from the holder-reward share, and recovers the TreasuryCap
after migration. Anyone may relay participant or reward claims, but payment
always goes to the committed beneficiary. Eligibility and rewards share the
package's generic positional Blake2b-256 Merkle verifier.

Returning the TreasuryCap preserves the creator's mint authority after migration
or cancellation. The presale proves zero initial supply and prevents additional
minting while the cap is in custody; it does not promise permanently fixed supply.

Run `scripts/verify.sh`. Publish with
`scripts/publish_immutable.sh <sui-environment> --preview` and repeat with
`--execute` after reviewing the transaction.

The accepted design is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md).
