# 0101: Presale protocol fees

- Status: proposed
- Date: 2026-10-01
- Amends: [0099](0099-standalone-overflow-presale.md), which gave Blast no fee on presales

## Context

The Blast V2 revenue sheet (2026-10-01) sets the presale model:

- on success, Blast takes a share of the Quote raised and a share of the sale's tokens;
- after migration, Blast takes a share of the venue's LP fees, in both assets;
- there is no creation, buy-in, or buy-out fee, and no fee if the sale does not succeed;
- every fee is adjustable, including to 0%.

Under ADR 0099 the raise went to the pool and to creator-chosen raise recipients, only
creator-chosen recipients received tokens, and the LP-fee split was creator-chosen recipients plus
holders. A creator could name Blast, but nothing required it or let Blast set the rate.

## Decision

**Policy.** The package shares one `fee_policy::FeePolicy` at publication. It holds four BPS
rates, zero at initialization, and the address Blast is paid at, initially the publisher:

| Rate | Applies to | Bound |
| --- | --- | --- |
| `raise_bps` | the accepted raise `R` | `< 10,000` |
| `token_bps` | the complete token supply | `<= 9,998` |
| `lp_fee_meme_bps` | each collected Meme LP fee | `<= 10,000` |
| `lp_fee_quote_bps` | each collected Quote LP fee | `<= 10,000` |

The token bound leaves one BPS each for the participant and LP allocations. Two new roles in the
shared Blast ACL (ADR 0097) govern it: `FeeAdmin` calls `set_fees`, which replaces all four rates
together and emits `FeesChanged`; `TreasuryAdmin` calls `set_destination`, which emits
`DestinationChanged`. Each setter rejects a no-op update, and the destination must be nonzero.

**Snapshot at creation.** Every presale copies the four rates when it is created and never reads
them again, so a sale's economics are fixed before commitments open, as all of ADR 0099's
per-sale terms are. Rate changes apply only to later sales. Payouts read the policy's current
destination.

**Tokens.** Blast's token share joins the supply apportionment: participant, LP, Blast, and
recipient BPS total exactly 10,000, using the same largest-remainder apportionment. The creator
therefore builds allocations against the current rate, and a rate change aborts a creation built
for the old one (`EInvalidTokenAllocation`) instead of silently shrinking the creator's shares.
Blast's tokens stay escrowed with the rest and are paid only on migration; a cancelled sale locks
them permanently.

**Raise.** Blast's Quote share joins the raise apportionment: raise recipients, then Blast, then
the LP's remainder, by largest remainder over `R`. The creator's raise allocations and Blast's
share together must leave the LP a share, and every recipient and the LP must receive a positive
amount (`EInvalidRaiseAllocation`); Blast's amount may be zero. Migration pays it, and Blast's
tokens, to the destination in the same transaction that pays the raise recipients and releases
the LP's Quote and the LP allocation to the venue adapter, and emits `ProtocolFeesPaid`.
Overflow refunds remain `C - R`; a cancelled sale pays Blast nothing.

**LP fees.** The vault takes Blast's share of each collected asset first, rounded up, and pays it
to the destination. The creator's recipients and the holder share apportion the remainder as in
ADR 0099. Every Cetus and Bluefin migration and collection entry takes `&FeePolicy`; the policy
has no constructor outside the package initializer, so a caller cannot substitute another.

**Events.** `PresaleCreated` records the snapshotted rates and Blast's Quote and token amounts.
`ProtocolFeesPaid` records the destination and both amounts migration paid. `PresaleVaultCreated`
records both LP rates, and `FeesCollected` records the destination and both amounts paid.

## Alternatives considered

- **Read the LP-fee rates live, as the launchpad's `LpFeePolicy` does.** Rejected for presales:
  ADR 0099 fixes every economic term before commitments open, and a live rate would let Blast
  raise its share of a creator's LP fees after the sale.
- **Snapshot the destination.** Rejected because LP fees accrue for the life of the pool, and a
  rotated treasury must keep receiving them.
- **Take Blast's tokens from the creator's recipient allocations.** Rejected because it would
  change the creator's configured BPS without its signature.
- **Reuse the launchpad's policy objects.** Rejected for the reason ADR 0099 gives for not using
  the launchpad migrators: it would couple the independent presale package to launchpad types.

## Consequences

- With all rates at zero, a sale behaves exactly as under ADR 0099.
- The package keeps its dependency-only upgrade policy. Rates and destination change through the
  policy object, never through new logic.
- A compromised `FeeAdmin` can set rates up to their bounds for future sales only. A compromised
  `TreasuryAdmin` can redirect Blast's future payouts, but not any participant's, recipient's,
  or holder's assets.
- Off-chain builders must read the current `FeePolicy` when building a creation transaction,
  because allocation BPS must sum to 10,000 with the current token share.

## Verification

- Policy tests cover the zero-rate, publisher-paid initial state; maximum and zero rates; every
  bound; no-op updates; and destination changes.
- Presale tests cover snapshotted Quote and token payouts at the current destination after the
  rates change, apportioned with a raise recipient; unchanged participant fills and refunds; a
  zero-rate sale paying nothing; no payout and locked tokens on cancellation; allocation sums
  that ignore Blast's share; and raise allocations that leave the LP nothing after Blast's.
- Vault tests cover Blast's rounded-up LP share of both assets before the creator's split.
- The source-boundary gate admits exactly the `FeeAdmin`, `RewardsAdmin`, `TreasuryAdmin`, and
  `UpgradeAdmin` roles.
- The presale venue fork runs both Cetus coin orders and Bluefin against mainnet bytecode with
  the published zero-rate policy, and decodes the new state and event layouts.
