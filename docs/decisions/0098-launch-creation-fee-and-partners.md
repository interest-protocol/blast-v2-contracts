# 0098: A launch creation fee, and one partner per launch

- Status: proposed
- Date: 2026-09-27
- Amends: [0095](0095-partner-codes.md), whose "The launchpad, later" paragraph this replaces

## Context

On 2026-09-27 the owner asked for the partner codes of
[0095](0095-partner-codes.md) on the launchpad, and set the model:

- launching a coin costs a creation fee, kept in `RuntimeConfig`;
- a launch's partner is set once, at creation, and can never be changed;
- the partner earns a share of every fee Blast takes on that launch.

Asked to choose, the owner ruled that:

- the partner's share of Blast's trade fees is paid when Blast claims them, so
  trades never take the `Partner` object;
- "every fee" means the launchpad's fees: the creation fee and every curve trade
  fee, the opening round's included. Blast's migration allocation is not a fee,
  and Blast's LP-fee share after migration stays Blast's;
- the creation fee goes to Blast's allocation destination.

Before this change the launchpad charged nothing at creation, so a creation-time
partner had nothing to be paid from.

## Decision

**Creation fee.** `RuntimeConfig` holds `creation_fee`, in MIST, zero at
initialization. The fee administrator (`FeeAdmin`) sets it with
`set_creation_fee`, which emits `CreationFeeChanged`. `launch::finalize` takes
`&RuntimeConfig` and a `Coin<SUI>` that must be exactly the configured fee
(`EInvalidCreationFee`), so a creator never pays more than it signed for. Blast's
part goes to its allocation destination, the first recipient of the plan. The fee
is SUI whatever the launch's Quote, and a zero fee transfers nothing.

**Accepted partners.** `RuntimeConfig` keeps the Blast partners new launches may
name, with the same list and notice as Boosts. There is one dynamic field per
partner under `PartnerKey(ID)`, whose value is when the partner stops being
accepted: `u64::MAX` until Blast removes it. `FeeAdmin` calls `add_partner`,
which applies at once and cancels a pending removal, and `remove_partner`, which
takes effect `blast_partners::delay_ms()` later. They emit `PartnerAdded` and
`PartnerRemoved { partner_id, accepted_until_ms }`. Removal only stops new
launches naming the partner.

**Binding at creation.** `launch::finalize_with_partner` is `finalize` naming a
`Partner` that new launches may name (`EPartnerNotAccepted`). It pays the partner
its share of the creation fee at once through `blast_partners::pay`, rounded down,
and sends Blast the rest. It records the partner's ID on the launch as
`partner_id: Option<ID>`. No function writes that field again. `LaunchCreated`
gains `creation_fee`, `partner_id` and `partner_fee`, the partner's part of the
fee.

**Trade fees.** `buy`, `sell` and `settle_opening_round` are unchanged: Blast's
share of each trade fee accrues in the launch's ledger as before. Because a
launch has at most one partner, every protocol fee in its ledger is owed to that
partner in part.

- `claim_protocol_fees` claims only from a launch without a partner.
- `claim_protocol_fees_with_partner` claims from a launch naming exactly that
  partner (`EPartnerMismatch` otherwise). It pays the partner its share of
  Blast's Meme and Quote fees and returns the rest to the treasury administrator.

`ProtocolFeesClaimed` gains `partner_meme_amount` and `partner_quote_amount`;
its existing amounts are what Blast kept. Every payment also emits `blast_partners`'
own `PartnerPaid<T>`.

## Alternatives considered

**Paying on every trade, as Boosts does.** `buy_with_partner`, `sell_with_partner`
and a partnered opening-round settlement would pay in the trade itself. But with
the partner fixed per launch, the plain versions would have to abort on
partnered launches. Every trader, bot and aggregator would then need the launch's
`Partner` object, and the opening round would need its own settlement variant.
Paying at Blast's claim keeps the trade ABI unchanged and never forces the
object on a trader.

**A partner per trade as well as per launch.** Two partners dividing the same
fee compound: at 80% each, Blast would keep 4% of its cut, and a creator who is
also the partner could fake volume almost for free. The owner chose one partner
per launch.

**Sharing only Blast's graduation allocation.** It pays only on coins that
graduate. The owner chose every fee.

**Sharing Blast's LP-fee share after migration.** That needs the partner on the
migrators' vaults and a partner variant of every fee collection. It was
deferred.

**A creation fee in the launch's Quote.** One fee would then need an amount per
Quote. A fixed SUI fee is one number.

**A destination of its own on `RuntimeConfig`.** This would add a setter and an
event. The owner chose Blast's allocation destination, which is already set.

**Reading the partner's share at creation and storing it.** `blast_partners`
exposes no share getter, only `pay`, by design: the share in force always comes
from the timelock.

## Consequences

- A partner is paid its share of trade fees when Blast claims them, not when the
  trade happens. Blast cannot claim a partnered launch's fees without paying the
  partner in the same call. The share applied is the one in force at the claim,
  and any change Blast makes to it waits seven days.
- The binding is permanent. To stop paying a bound partner, Blast schedules its
  share to zero in `blast_partners`, which affects that deal on every product.
- A Quote deny list blocking the partner's recipient makes that launch's partner
  claim abort until the partner sets a new recipient, as in Boosts. SUI, the
  creation fee's coin, has no deny list.
- A creator's transaction aborts if the fee changes between signing and
  execution. The fee is the only price at creation, and it cannot be raised
  under a signed transaction.
- The launchpad now depends on `blast_partners`, so `blast_partners` is published
  before the launchpad's mainnet build.
- ABI:
  - `finalize` gains two parameters;
  - new functions: `finalize_with_partner`, `claim_protocol_fees_with_partner`,
    `set_creation_fee`, `add_partner` and `remove_partner`;
  - `LaunchCreated` and `ProtocolFeesClaimed` gain fields;
  - new events: `CreationFeeChanged`, `PartnerAdded` and `PartnerRemoved`.

  The SDK, the indexer reducers and the release PTB builder follow.

## Verification

- `RuntimeConfig` tests:
  - the fee setter, its event, the unchanged guard, and the version check;
  - a partner accepted at once;
  - a removed partner accepted until one millisecond before its notice ends,
    and refused from then on;
  - re-adding cancels a removal;
  - refusals for adding twice, removing twice, and removing an unknown partner;
  - the version check before the list.
- Launch tests:
  - the creation fee paid to Blast and recorded;
  - a fee one MIST short refused;
  - a partnered creation splitting a 1,001 MIST fee 400/601 (rounded down),
    binding the partner, and emitting `LaunchCreated` and `PartnerPaid<SUI>`;
  - an unaccepted partner refused;
  - a partnered claim paying the partner its rounded-down share of both assets,
    leaving the creator's fees and agreeing with `PartnerPaid`;
  - the plain claim refused on a partnered launch, and the partner claim refused
    for another partner and for a launch without one.
- The migrators' replay reducer decodes the new `LaunchCreated` fields.
- The Rust PTB harness publishes `blast_partners` before the launchpad, passes
  the new `finalize` arguments and decodes the new fields. `atomic_migration`,
  `launch_measurements` and the venue fork against mainnet Cetus and Bluefin
  bytecode all pass.
- `sui/launchpad/scripts/check_source_boundaries.sh` pins the new dependency,
  roles, `RuntimeConfig` layout and transitions, and the partner never changing
  after creation.
