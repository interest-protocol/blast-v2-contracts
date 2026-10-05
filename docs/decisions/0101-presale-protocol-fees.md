# 0101: Presale protocol fees

- Status: proposed
- Date: 2026-10-01
- Amends: [0099](0099-standalone-overflow-presale.md), which gave Blast no fee on presales
- Amended: 2026-10-03 (owner decision): the `AdminCap` may change one migrated sale's LP-fee
  rates on its vault
- Amended: 2026-10-04 (owner decision): the `AdminCap` may change all four of one sale's rates
  until its window starts
- Amended by: [0106](0106-presale-partners.md): a sale naming a Blast partner holds Blast's
  fees from migration until a permissionless `pay_protocol_fees_with_partner` pays the partner
  its cut of the raise fee and Blast the rest
- Amended by: [0107](0107-partner-cut-of-lp-fees.md): a partnered sale's vault holds Blast's
  LP fees until a permissionless `pay_protocol_lp_fees_with_partner` pays the partner its cut
  and Blast the rest
- Amended: 2026-10-05 (presale audit): a per-sale update keeps Blast's raise or token amount when
  that rate is unchanged, so an LP-fee-only update no longer re-rounds creation's apportionment
- Amended: 2026-10-05 (owner decision): the `AdminCap` may also change one sale's rates in its
  creation transaction, before `share`

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

The token bound leaves one BPS each for the participant and LP allocations. The presale
`AdminCap` (ADR 0099) governs it: `set_fees` replaces all four rates together and emits
`FeesChanged`; `set_destination` emits `DestinationChanged`. Each setter rejects a no-op update, and the destination must be nonzero.

**Snapshot at creation.** Every presale copies the four rates when it is created and never reads
the policy's rates again. Policy rate changes apply only to later sales. Payouts read the
policy's current destination.

**Per-sale rates before the start.** Until a sale's window starts (ADR 0099's `start_ms`), the
presale `AdminCap` may replace all four of its rates with `blast_presale::set_protocol_fees`,
within the policy's bounds. That includes the sale's creation transaction, before `share`: a
transaction holding both the creator's inputs and the `AdminCap` can open a sale at once on rates
other than the policy's, which a shared sale could only take by starting later. The update
rejects a no-op and emits `ProtocolFeesChanged` with the new rates and amounts. Nobody can have committed yet, so a sale's economics are still fixed
before commitments open. A rate the update leaves unchanged keeps Blast's amount for it. Blast's
new token amount for a changed token rate is its rate of the supply, rounded down. The
difference moves to or from the buyers' sale allocation, which must keep at least one token
(`EInvalidTokenAllocation`). Blast's new Quote amount for a changed raise rate is its rate of the
raise, rounded down. The
difference moves to or from the LP's Quote, which must stay positive (`EInvalidRaiseAllocation`)
and still seed a poolable price (`EUnseedablePrice`). The LP's tokens, and every token and raise
recipient's amount, are unchanged. Once the window starts the rates are fixed
(`EPresaleStarted`) until migration copies them into the vault.

**Per-vault LP rates.** Migration copies the sale's rates into its `PresaleVault`. The presale
`AdminCap` may then change that vault's two LP-fee rates, within the same `<= 10,000` bound, with
`presale_vault::set_protocol_lp_fees`, which rejects a no-op update and emits
`ProtocolLpFeesChanged`. The new rates apply to every later collection, including fees that
accrued in the pool before the change; to settle those at the old rates, collect in the same
transaction first. The creator's recipients and holder share keep their creation-time split of
whatever Blast does not take. The policy's rates and every other vault are unaffected.

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

- **Let the `AdminCap` change a sale's rates until migration.** Rejected (owner, 2026-10-04):
  buyers cannot withdraw a commitment, so a raise taken after they commit would come out of
  their deal, and a compromised cap could take nearly all of every live sale's raise and tokens.
- **Move Blast's token difference to or from the LP allocation.** Rejected (owner, 2026-10-04):
  it would move the pool's opening price; the buyers' allocation instead takes a cut pro rata.
- **Read the LP-fee rates live, as the launchpad's `LpFeePolicy` does.** Rejected for presales:
  ADR 0099 fixes every economic term before commitments open, and one global live rate would move
  every sale's LP fees at once. The 2026-10-03 amendment instead lets Blast change one vault's
  rates deliberately, accepting that Blast can raise its share of that creator's later LP fees.
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
- A compromised `AdminCap` can set rates up to their bounds for future sales and for any sale
  that has not started, set any migrated sale's LP-fee rates up to 10,000 BPS, and redirect
  Blast's future payouts. Creators should check a scheduled sale's rates before its start. Together, those let
  it take every later LP fee of every migrated sale, but not any participant's commitment, any
  recipient's allocation, the vault's position, or fees already collected.
- Creators and holders cannot rely on Blast's LP-fee rates staying at the snapshot after
  migration; indexers must apply `ProtocolLpFeesChanged` to a vault's rates. Before the start,
  `PresaleCreated`'s Blast amounts and the sale allocation can also change; indexers must apply
  `ProtocolFeesChanged` to a sale.
- Off-chain builders must read the current `FeePolicy` when building a creation transaction,
  because allocation BPS must sum to 10,000 with the current token share.

## Verification

- Policy tests cover the zero-rate, publisher-paid initial state; maximum and zero rates; every
  bound; no-op updates; and destination changes.
- Presale tests cover snapshotted Quote and token payouts at the current destination after the
  rates change, apportioned with a raise recipient; unchanged participant fills and refunds; a
  zero-rate sale paying nothing; no payout and locked tokens on cancellation; allocation sums
  that ignore Blast's share; and raise allocations that leave the LP nothing after Blast's.
- Presale tests cover the `AdminCap` cutting and raising a scheduled sale's rates, with the
  difference moving to or from the sale allocation and the LP's Quote and migration and claims
  using the new amounts; the `AdminCap` repricing a sale before its share, which then opens on the
  new amounts; and rejecting a change after the start, on a funded sale, without a change, beyond
  the policy's bounds, leaving the LP no Quote or buyers no tokens, seeding an unpoolable price, or
  with a replaced `AdminCap`.
- Vault tests cover Blast's rounded-up LP share of both assets before the creator's split; the
  `AdminCap` lowering one rate to zero and raising the other, with the next collection paying at
  the new rates; no-op updates; and a replaced `AdminCap` being rejected.
- The presale venue fork runs both Cetus coin orders and Bluefin against mainnet bytecode with
  the published zero-rate policy, and decodes the new state and event layouts.
