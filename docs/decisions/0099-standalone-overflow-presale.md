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

The contract must also preserve participant exits if a raise is missed or
liquidity migration does not complete after a successful raise. Migration must
not depend on the creator remaining online.

## Decision

Create the independent `blast_presale` package and publish it immutable. It
neither reads nor mutates launchpad state, and no launchpad package imports it.
Bluefin and Cetus adapters stay inside this package so core escrow release and
venue creation are one atomic call without a second presale-adapter package.

Each `Presale<SaleToken, Quote>` consumes a `TreasuryCap<SaleToken>` whose total
supply is zero. The creator configures a token supply and two positive BPS
allocations: one distributed to participants and one intended for LP. Their
combined rate cannot exceed 10,000 BPS. Each atomic allocation is
`floor(token_supply * allocation_bps / 10_000)` and must be positive. The
contract mints exactly those allocations and holds them with the TreasuryCap,
stored as a discoverable dynamic object child, while the sale is active. All
other supply remains unminted. The remaining immutable per-sale configuration
contains a positive Quote raise, a commitment duration, an LP-migration window,
a sealed migration witness, venue tier, creator/reward LP-fee BPS totaling
10,000, and an `EligibilityPolicy`:

- `Open` stores one wallet cap and a maximum participant count.
- `Allowlisted` stores a positional Blake2b-256 Merkle root and leaf count.
  Each leaf binds `(index, wallet, wallet_cap)`, so one representation covers
  equal caps, rank tiers, and custom caps.

Both policies are bounded by a technical ceiling of 65,536 dynamic commitment
records. This is not a product eligibility count or raise-size constant.

The shared-object lifecycle is:

```text
Pending -> Open -> Funded -> Migrated
                   |          claims stay open
                   v
                Cancelled
```

`share` starts the commitment window. Commitments are positive, cumulative per
wallet, and cannot exceed the policy cap. Each commitment consumes a
`Coin<Quote>` and locks its full balance in that `Presale`, so recorded
commitments are backed one-for-one by on-chain Quote custody. There is no
voluntary withdrawal during `Open` or `Funded`: a cancellation returns the
full commitment, while a migrated sale returns only its calculated overflow.
At the exclusive end timestamp, anyone may settle. If total commitments `C`
are below the raise `R`, the sale cancels and all Quote remains refundable.
Otherwise the sale becomes funded and fixes one common fill rate `R / C`.

Before the exclusive LP deadline, anyone may call the configured venue adapter.
The adapter alone holds the sealed witness needed to take exactly `R` Quote and
the entire LP-token allocation from core. In the same call it creates the
configured full-range pool and seals its position or burn proof in a
`PresaleVault`. Claims open only after this call succeeds; a venue failure rolls
back the complete transaction. The migration witness, tier, allocations, and
fee split were fixed before commitments opened and cannot be supplied by the
migration caller.

If a funded sale is not migrated by the deadline, anyone can cancel it. A sale
first settled at or after that deadline cancels directly. Cancellation never
releases Quote to the creator; participants receive full refunds, while the cap
holder may recover the original TreasuryCap and both minted token allocations.

After migration, participant `i` with commitment `c_i` receives:

```text
tokens_i = floor(token_allocation * c_i / C)
refund_i = floor((C - R) * c_i / C)
```

Claims are permissionlessly relayable and always pay the committed wallet.
The final claim receives the bounded integer remainder of both balances, so
all escrowed participant assets are conserved. Claim order changes only which
wallet receives that documented sub-participant-count remainder.

LP fee collection is permissionless. The vault applies the immutable BPS split
to each asset: the creator share remains claimable with the transferable
`PresaleCap`, while the remainder funds holder-reward rounds. The cap holder
commits each reward round's beneficiaries and amounts with a Merkle root;
anyone may relay a valid proof, but assets go only to its committed beneficiary.
The same generic positional Blake2b-256 module verifies eligibility and rewards.
The cap also claims migration residuals and recovers the TreasuryCap after
successful migration.

## Alternatives considered

- **Add a launchpad mode.** Rejected because presales are independently
  deployed custody and do not require curve, trade-fee, or partner state.
- **Use the launchpad migrators package.** Rejected because it imports launchpad
  types and would couple the independent presale product to that lifecycle.
- **Let the cap holder release migration assets.** Rejected because the caller
  could falsely attest migration or disappear; sealed adapters make completion
  permissionless and atomic.
- **Leave funded sales waiting forever.** Rejected because loss of the creator
  capability or operator availability would permanently lock participant Quote.

## Consequences

- Raise sizes, time windows, allocations, eligibility, and wallet caps are all
  per-sale values; example numbers from product material are not protocol
  constants.
- Token supply and the presale and LP allocation BPS are per-sale values. The
  contract proves the supplied TreasuryCap starts at zero, derives both atomic
  allocations with floor rounding, mints exactly those allocations, and
  prevents further minting while the cap remains in presale custody.
- The Merkle manifest and proof construction remain off chain, while the root,
  leaf count, commitments, custody, lifecycle, and payouts are canonical on chain.
  A proof attests only the committed wallet and cap; it does not prove that the
  off-chain rank or eligibility methodology was fair.
- Immutable publication removes concurrent old-bytecode access to shared
  presale custody and eliminates a presale package-administration surface.
- The creator chooses the reward Merkle roots. Proofs enforce the published
  allocation but cannot prove that its off-chain holder methodology was fair.
- The TreasuryCap is returned after migration or cancellation, so the creator can
  mint additional supply afterward. Permanently fixed or burn-only supply
  requires an explicit Coin Registry transition outside this package.
- The generic package cannot remove a Quote issuer's deny, pause, or supply
  powers. Such controls can block an affected wallet's transfer, although an
  aborted claim leaves its on-chain commitment and escrow intact for retry.

## Verification

- Unit tests cover equal caps, tiered Merkle caps, cumulative cap enforcement,
  dynamic-record bounds, exact time boundaries, proportional fills, full
  refunds, allocation recovery, migration witness enforcement, LP-fee splitting,
  creator claims, generic Merkle proofs, and relayed holder rewards.
- The package gate builds both network environments, lints with warnings as
  errors, and runs Move tests.
- Publication preview must show package publication and consumption of the
  resulting `UpgradeCap` by `0x2::package::make_immutable` in the same PTB.

## Sources

| Ref | Source |
| --- | --- |
| S1 | [Sui framework at `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`](https://github.com/MystenLabs/sui/tree/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework) |
