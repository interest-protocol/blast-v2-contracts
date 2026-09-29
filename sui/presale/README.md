# Blast presale

`blast_presale` is a standalone, immutable Sui package for overflow presales.
It does not import the launchpad, migrators, Blast administration, or partner
packages.

A creator supplies a zero-supply `TreasuryCap<SaleToken>` and chooses the total
supply, presale allocation, LP allocation, Quote raise, commitment window, LP
window, and `EligibilityPolicy`. The contract mints the total supply, escrows
the cap and all three token balances, and shares the `Presale`. The unallocated
remainder is the creator allocation. The policy is either one open wallet cap
or a Merkle allowlist whose leaves carry per-wallet caps for equal, tiered, or
custom limits.

Every commitment consumes a `Coin<Quote>` and joins its full balance into the
shared `Presale`; recording an amount without locking the matching Quote is not
an available contract path. A participant cannot withdraw during the open or
funded states. Cancellation returns the full commitment; after launch, only the
calculated overflow is refundable.

After the window, an underfunded sale refunds every commitment. A funded sale
uses one fill rate for every wallet. `launch` returns only the exact raise and
LP-token allocation, plus the creator allocation and original TreasuryCap,
while opening token and overflow-refund claims. The cap holder is responsible
for threading the LP assets into pool creation in the same programmable
transaction; the core package has no DEX dependency. If LP is not launched by
the configured deadline, anyone can cancel and preserve all Quote for full
refunds. The creator may then recover the TreasuryCap and every minted token.
Claims are permissionlessly relayable, so a keeper can airdrop each wallet's
tokens after launch while wallets can also claim directly.

Returning the TreasuryCap preserves the creator's mint authority after launch
or cancellation. The presale guarantees a zero initial supply and prevents
additional minting while the cap is in custody; it does not promise permanently
fixed supply after the cap is returned.

Run `scripts/verify.sh`. Publish with
`scripts/publish_immutable.sh <sui-environment> --preview` and repeat with
`--execute` after reviewing the transaction.

The accepted design is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md).
