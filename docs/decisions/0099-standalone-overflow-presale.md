# 0099: Standalone overflow presale

- Status: accepted
- Date: 2026-09-29

## Context

Projects need a fixed-window presale in which eligible wallets commit up to
per-wallet limits, oversubscription produces the same fill rate for everyone,
and unfilled Quote is refunded. Raise size, token allocations, time windows,
wallet caps, and the eligible population vary per sale. This product is not a
launchpad mode: it has separate custody, lifecycle, authority, deployment, and
upgrade risk.

The contract must also preserve participant exits if a raise is missed or the
project does not add liquidity after a successful raise.

## Decision

Create the independent `blast_presale` package. It imports only the pinned Sui
framework and is published immutable. It neither reads nor mutates launchpad
state, and no launchpad package imports it.

Each `Presale<SaleToken, Quote>` escrows two nonzero creator-funded balances:
the allocation distributed to participants and the allocation intended for
LP. Its immutable per-sale configuration contains a positive Quote raise, a
commitment duration, an LP-launch window, and an `EligibilityPolicy`:

- `Open` stores one wallet cap and a maximum participant count.
- `Allowlisted` stores a positional Blake2b-256 Merkle root and leaf count.
  Each leaf binds `(index, wallet, wallet_cap)`, so one representation covers
  equal caps, rank tiers, and custom caps.

Both policies are bounded by a technical ceiling of 65,536 dynamic commitment
records. This is not a product eligibility count or raise-size constant.

The shared-object lifecycle is:

```text
Pending -> Open -> Funded -> Launched
                   |          claims stay open
                   v
                Cancelled
```

`share` starts the commitment window. Commitments are positive, cumulative per
wallet, and cannot exceed the policy cap. Each commitment consumes a
`Coin<Quote>` and locks its full balance in that `Presale`, so recorded
commitments are backed one-for-one by on-chain Quote custody. There is no
voluntary withdrawal during `Open` or `Funded`: a cancellation returns the
full commitment, while a launched sale returns only its calculated overflow.
At the exclusive end timestamp, anyone may settle. If total commitments `C`
are below the raise `R`, the sale cancels and all Quote remains refundable.
Otherwise the sale becomes funded and fixes one common fill rate `R / C`.

Before the exclusive LP deadline, only the per-presale `PresaleCap` can call
`launch`. That transition returns exactly `R` Quote and the entire LP-token
allocation, opens claims, and leaves all overflow Quote plus the participant
token allocation in escrow. The caller must thread the returned coins into LP
creation in the same programmable transaction; a later failure rolls back the
whole transition. Core deliberately has no DEX dependency and therefore trusts
the cap holder to route those returned coins to the announced LP rather than
merely transfer them.

If a funded sale is not launched by the deadline, anyone can cancel it. A sale
first settled at or after that deadline cancels directly. Cancellation never
releases Quote to the creator; participants receive full refunds, while the cap
holder may recover only the two token allocations.

After launch, participant `i` with commitment `c_i` receives:

```text
tokens_i = floor(token_allocation * c_i / C)
refund_i = floor((C - R) * c_i / C)
```

Claims are permissionlessly relayable and always pay the committed wallet.
The final claim receives the bounded integer remainder of both balances, so
all escrowed participant assets are conserved. Claim order changes only which
wallet receives that documented sub-participant-count remainder.

## Alternatives considered

- **Add a launchpad mode.** Rejected because presales are independently
  deployed custody and do not require curve, migration, fee, or partner state.
- **Import a DEX package in core.** Rejected because LP venues are an external
  dependency boundary. Atomic PTB composition keeps the presale package
  venue-neutral.
- **Leave funded sales waiting forever.** Rejected because loss of the creator
  capability or operator availability would permanently lock participant Quote.

## Consequences

- Raise sizes, time windows, allocations, eligibility, and wallet caps are all
  per-sale values; example numbers from product material are not protocol
  constants.
- The Merkle manifest and proof construction remain off chain, while the root,
  leaf count, commitments, custody, lifecycle, and payouts are canonical on chain.
  A proof attests only the committed wallet and cap; it does not prove that the
  off-chain rank or eligibility methodology was fair.
- Immutable publication removes concurrent old-bytecode access to shared
  presale custody and eliminates a presale package-administration surface.
- A malicious cap holder can falsely attest launch by transferring the returned
  LP assets instead of adding liquidity. The contract makes that trust boundary
  explicit; venue-specific enforcement requires a separate adapter package.
- The generic package cannot remove a Quote issuer's deny, pause, or supply
  powers. Such controls can block an affected wallet's transfer, although an
  aborted claim leaves its on-chain commitment and escrow intact for retry.

## Verification

- Unit tests cover equal caps, tiered Merkle caps, cumulative cap enforcement,
  dynamic-record bounds, exact time boundaries, proportional fills, full
  refunds, creator-token recovery, and the LP timeout.
- The package gate builds both network environments, lints with warnings as
  errors, and runs Move tests.
- Publication preview must show package publication and consumption of the
  resulting `UpgradeCap` by `0x2::package::make_immutable` in the same PTB.

## Sources

| Ref | Source |
| --- | --- |
| S1 | [Sui framework at `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`](https://github.com/MystenLabs/sui/tree/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework) |
