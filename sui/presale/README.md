# Blast presale

`blast_presale` is a standalone, immutable Sui package for overflow presales.
It does not import the launchpad, migrators, Blast administration, or partner
packages.

A creator escrows the complete presale-token and LP-token allocations, chooses
the Quote raise, commitment window, LP window, and `EligibilityPolicy`, then
shares the `Presale`. The policy is either one open wallet cap or a Merkle
allowlist whose leaves carry per-wallet caps for equal, tiered, or custom
limits.

After the window, an underfunded sale refunds every commitment. A funded sale
uses one fill rate for every wallet. `launch` returns only the exact raise and
LP-token allocation while opening token and overflow-refund claims. The cap
holder is responsible for threading those coins into LP creation in the same
programmable transaction; the core package has no DEX dependency. If LP is not
launched by the configured deadline, anyone can cancel and preserve all Quote
for full refunds. Claims are permissionlessly relayable, so a keeper can
airdrop each wallet's tokens after launch while wallets can also claim directly.

Run `scripts/verify.sh`. Publish with
`scripts/publish_immutable.sh <sui-environment> --preview` and repeat with
`--execute` after reviewing the transaction.

The accepted design is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md).
