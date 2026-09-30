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
Its only first-party dependency is the immutable `blast_admin` ACL, used solely
to authorize holder-reward rounds.

Each `Presale<SaleToken, Quote>` consumes a `TreasuryCap<SaleToken>` whose total
supply is zero and verifies it belongs to the supplied `Currency<SaleToken>`.
The creator configures a token supply, positive participant and LP allocation
BPS, and zero or more distinct recipient allocations. These BPS total exactly
10,000. The contract mints the complete supply, uses largest-remainder
apportionment so every atomic unit is assigned exactly once, and escrows every
allocation. It then irreversibly consumes the TreasuryCap into the selected Coin
Registry `Fixed` or `BurnOnly` supply state before commitments open. The remaining
immutable per-sale configuration contains a positive Quote raise, a commitment
duration, an LP-migration window, a sealed migration witness, venue tier, an
LP-fee split, and an `EligibilityPolicy`. The fee split is up to 16 distinct
`(recipient, bps)` fee recipients, the creator configured as one of them, and a
holder-reward BPS; together they total exactly 10,000. The eligibility policy is:

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

While the sale is `Funded`, anyone may call the configured venue adapter; the LP
deadline does not close migration.
The adapter alone holds the sealed witness needed to take exactly `R` Quote and
the entire LP-token allocation from core. In the same call it creates the
configured full-range pool and seals its position or burn proof in a
`PresaleVault`. Claims open only after this call succeeds; a venue failure rolls
back the complete transaction. That transaction also pays each configured
recipient its distinct immutable token allocation. The migration witness, tier,
allocations, and fee split were fixed before commitments opened and cannot be
supplied by the migration caller.

If a funded sale is not migrated by the deadline, anyone can cancel it from
then on. Until someone does, migration stays open, so after the deadline the
first of a migration or a cancellation wins. Settlement cancels only an
underfunded sale; a sale that met its raise and is first settled after the
deadline becomes funded and may still migrate or be cancelled. Cancellation never
releases Quote to the creator; participants receive full refunds, while the cap
holder may destroy the now-useless `PresaleCap`. Every minted SaleToken
allocation remains permanently locked in the cancelled presale, and the consumed
TreasuryCap is never recreated.

After migration, participant `i` with commitment `c_i` receives:

```text
tokens_i = floor(token_allocation * c_i / C)
refund_i = floor((C - R) * c_i / C)
```

Claims are permissionlessly relayable and always pay the committed wallet.
The final claim receives the bounded integer remainder of both balances, so
all escrowed participant assets are conserved. Claim order changes only which
wallet receives that documented sub-participant-count remainder.

LP fee collection is permissionless. The vault apportions each asset across
the fee recipients and the holder-reward share with largest-remainder
apportionment, pays every recipient in the same call, and keeps the holder
share. Blast's `blast_presale_domain::RewardsAdmin` role in the shared Blast ACL
(ADR 0097) commits each reward round's beneficiaries and amounts with a Merkle
root and funds it from that share, so holder distribution runs on Blast's
automated reward pipeline rather than the creator's availability. Anyone may
relay a valid proof, but assets go only to its committed beneficiary. The same
generic positional Blake2b-256 module verifies eligibility and rewards. The
`PresaleCap` claims migration residuals.

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
- Token supply; participant, LP, and recipient allocation BPS; recipient
  addresses; and fixed-versus-burn-only mode are per-sale values. The contract
  proves the matching TreasuryCap starts at zero, mints and apportions the
  complete configured supply, and permanently removes mint authority.
- The Merkle manifest and proof construction remain off chain, while the root,
  leaf count, commitments, custody, lifecycle, and payouts are canonical on chain.
  A proof attests only the committed wallet and cap; it does not prove that the
  off-chain rank or eligibility methodology was fair.
- Immutable publication removes concurrent old-bytecode access to shared
  presale custody and eliminates a presale package-administration surface.
- Blast's rewards administrator chooses the reward Merkle roots. Proofs enforce
  the published allocation but cannot prove that its off-chain holder
  methodology was fair. The creator cannot redirect the holder share.
- Fee recipients are fixed addresses, not transferable claims: a recipient that
  loses its key loses its future fee share. Pushing at collection keeps the
  vault free of per-recipient balances and claim paths.
- Cancellation refunds participant Quote but permanently locks every SaleToken
  allocation. It cannot restore mint authority or change the selected Coin
  Registry supply mode; a creator who retries must deploy a new coin type.
- The generic package cannot remove a Quote issuer's deny, pause, or supply
  powers. Such controls can block an affected wallet's transfer, although an
  aborted claim leaves its on-chain commitment and escrow intact for retry.

## Verification

- Unit tests cover equal caps, tiered Merkle caps, cumulative cap enforcement,
  dynamic-record bounds, exact time boundaries, proportional fills, full
  refunds, exact full-supply apportionment, distinct recipient payouts, fixed and
  burn-only supply modes, cancelled-supply locking, migration witness enforcement,
  LP-fee splitting with direct recipient payouts, fee-split validation,
  administrator-published holder rounds, generic Merkle proofs, and relayed
  holder rewards.
- The package gate builds both network environments, lints with warnings as
  errors, and runs Move tests.
- Publication preview must show package publication and consumption of the
  resulting `UpgradeCap` by `0x2::package::make_immutable` in the same PTB.

## Sources

| Ref | Source |
| --- | --- |
| S1 | [Sui framework at `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`](https://github.com/MystenLabs/sui/tree/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework) |
