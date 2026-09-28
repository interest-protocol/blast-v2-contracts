# 0098: A launch creation fee, and one partner per launch

- Status: accepted
- Date: 2026-09-27
- Amends: [0095](0095-partner-codes.md), whose "The launchpad, later" paragraph this replaces

## Context

On 2026-09-27 the owner asked for the partner codes of
[0095](0095-partner-codes.md) on the launchpad, and set the model:

- launching a coin costs a creation fee;
- a launch's partner is set once, at creation, and can never be changed;
- the partner earns a share of every fee Blast takes on that launch.

Asked to choose, the owner ruled that:

- the partner's share of Blast's trade fees is paid when Blast claims them, so
  trades never take the `Partner` object;
- "every fee" means every Blast-owned amount for the launch: the creation fee,
  every curve trade fee (the opening round's included), Blast's Meme and Quote
  migration allocation, venue residuals, and Blast's recurring Meme and Quote
  LP-fee share. They all enter the launch's protocol ledger and therefore all
  participate in the partner split (clarified 2026-09-28);
- the creation fee and the accepted partners live in `LaunchConfig`, with the
  rest of what launch creation reads (2026-09-28, moved from `RuntimeConfig`);
- the partner is named with a setter during creation, like every other creation
  setting, and the creation fee joins Blast's fees on the launch, so the partner
  is paid its share of it at Blast's claim with the rest (2026-09-28; the first
  version paid it at creation through a `finalize_with_partner`, and sent Blast's
  part to Blast's allocation destination).

Before this change the launchpad charged nothing at creation, so a creation-time
partner had nothing to be paid from.

## Decision

**Creation fee.** `LaunchConfig` holds `creation_fee`, in MIST, zero at
initialization. The fee administrator (`FeeAdmin`) sets it with
`set_creation_fee`, next to the trade fees, and it emits `CreationFeeChanged`.
`launch::finalize` already reads `&LaunchConfig`; it now also takes a
`Coin<SUI>` that must be exactly the configured fee (`EInvalidCreationFee`), so
a creator never pays more than it signed for. The fee joins Blast's fees on the
launch: the fee ledger gains a `protocol_sui` balance beside Blast's Meme and
Quote trade fees, since the fee is SUI whatever the launch's Quote.

**Accepted partners.** `LaunchConfig` keeps the Blast partners new launches may
name, with the same list and notice as Boosts. There is one dynamic field per
partner under `PartnerKey(ID)`, whose value is when the partner stops being
accepted: `u64::MAX` until Blast removes it. `FeeAdmin` calls `add_partner`,
which applies at once and cancels a pending removal, and `remove_partner`, which
takes effect `blast_partners::delay_ms()` later. They emit `PartnerAdded` and
`PartnerRemoved { partner_id, accepted_until_ms }`. Removal only stops new
launches naming the partner.

**Binding at creation.** `launch::set_partner` names the launch's partner on the
initializer, like the other creation settings. It takes the `Partner` and the
`Clock` only to check that new launches may name it (`EPartnerNotAccepted`), and
records its ID. `finalize` copies it to the launch as `partner_id: Option<ID>`,
and no function writes that field again. Creation pays nobody, so `finalize` is
the same with or without a partner. `LaunchCreated` gains `creation_fee` and
`partner_id`.

**One Blast ledger.** The protocol balances in the launch's `FeeLedger` hold
every Blast-owned Meme and Quote amount, not only curve-trade fees. Blast's
migration allocation is an explicit part of `AllocationPlan`, separate from
the project-recipient vector. `launch::migrate` returns it in an ability-less
`ProtocolFeeAccrual<Meme, Quote, Witness>` alongside the pool balances. The
adapter adds any balances the venue did not use, then must consume that linear
value through `settle_protocol_fee_accrual`; a transaction cannot discard or
store it. Later collections begin the same kind of accrual under the launch's
stored adapter witness, `vault::split_fees` returns Blast's live Meme and Quote
shares, and the adapter settles them into the launch before continuing. The
settlement checks the launchpad package version and launch ID. Migrator vaults
hold no Blast residual or fee balance and have no independent Blast claim.
`ProtocolFeesAccrued` records each migration or post-migration addition.

**Paying the partner.** `buy`, `sell` and `settle_opening_round` are unchanged:
Blast's share of each trade fee accrues in the launch's ledger as before, next
to the creation fee, migration allocation, venue residuals, and LP fees.
Because a launch has at most one partner, every protocol fee in its ledger is
owed to that partner in part.

- `claim_protocol_fees` claims only from a launch without a partner.
- `claim_protocol_fees_with_partner` claims from a launch naming exactly that
  partner (`EPartnerMismatch` otherwise). It pays the partner its share of all
  Blast Meme, Quote, and SUI balances in the ledger, each rounded down, and
  returns the rest to the treasury administrator.

Both return a third coin, the SUI creation fee, and a ledger holding only that
fee can be claimed. `ProtocolFeesClaimed` gains `sui_amount` and the partner's
`partner_meme_amount`, `partner_quote_amount` and `partner_sui_amount`; the
other amounts are what Blast kept. Every payment also emits `blast_partners`'
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

**Keeping migration and LP fees on a separate Blast payout path.** A migrator
destination and residual vault would let those balances bypass the launch's
partner-aware claim. It would also duplicate protocol custody and claims. The
owner chose one launch ledger instead; adapters settle Blast's balances there,
so fee collection does not need the `Partner` object or a partner-specific
variant.

**A creation fee in the launch's Quote.** One fee would then need an amount per
Quote. A fixed SUI fee is one number.

**The fee and the partner list in `RuntimeConfig`.** The first version kept them
there. `RuntimeConfig` holds what trades and creator claims read live, while
only creation reads these two, and creation already reads `LaunchConfig`;
keeping them apart made `finalize` take both objects.

**Paying the partner at creation** (the first version). A
`finalize_with_partner` paid the partner its share of the creation fee at once
and sent Blast the rest to its allocation destination. It took the `Partner`
object at creation and duplicated `finalize` for a payment the claim already
makes. Holding the fee in the ledger leaves one `finalize` and one payout path.

**A destination of its own for the fee.** This would add a setter and an event;
holding the fee in the ledger needs neither.

**One claim function with an optional partner** (asked 2026-09-28). Not
expressible: Move has no `Option<&Partner>`, since references cannot be type
arguments, and the launchpad cannot take the key-only `Partner` by value, since
it can neither drop, store, delete nor re-share another module's object. A
receipt the caller settles with or without the partner, a zero-share house
partner, or a permissionless pre-claim payout each add a struct, state or a
forced object. The claim script must read the launch's `partner_id` to include
the partner anyway, so two functions only name that branch.

**Reading the partner's share at creation and storing it.** `blast_partners`
exposes no share getter, only `pay`, by design: the share in force always comes
from the timelock.

## Consequences

- A partner is paid its share of every Blast-owned amount, including the
  creation fee, migration allocation, venue residuals, and recurring LP fees,
  when Blast claims them, not when they accrue. Blast cannot claim a partnered
  launch's fees without paying the partner in the same call. Blast's creation fee
  waits in each launch until claimed, like its trade fees. The share applied is the one in force at the claim,
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
  - `finalize` gains the creation-fee coin;
  - both protocol claims return a third coin, the SUI creation fee;
  - `migrate` returns a linear protocol-fee accrual beside the pool balances;
  - adapter migration and collection settle Blast Meme and Quote balances into
    the mutable launch under the launchpad package version;
  - migrator vaults lose the protocol destination, residual balances, and
    protocol claim;
  - new functions: `set_partner`, `claim_protocol_fees_with_partner`,
    `set_creation_fee`, `add_partner`, `remove_partner`,
    `begin_protocol_fee_accrual`, `add_protocol_fees`, and
    `settle_protocol_fee_accrual`;
  - `LaunchCreated` and `ProtocolFeesClaimed` gain fields;
  - new events: `CreationFeeChanged`, `PartnerAdded`, `PartnerRemoved`, and
    `ProtocolFeesAccrued`.

  The SDK, the indexer reducers and the release PTB builder follow.

## Verification

- `LaunchConfig` tests:
  - the fee setter, its event, the unchanged guard, and the version check;
  - a partner accepted at once;
  - a removed partner accepted until one millisecond before its notice ends,
    and refused from then on;
  - re-adding cancels a removal;
  - refusals for adding twice, removing twice, and removing an unknown partner;
  - the version check before the list.
- Fee ledger tests: a ledger holding only the creation fee is claimed whole.
- Launch tests:
  - the creation fee held with Blast's fees, recorded, and claimed before any
    trade;
  - a fee one MIST short refused;
  - `set_partner` binding the partner at creation and paying nobody yet;
  - an unaccepted partner refused;
  - a partnered claim paying the partner its rounded-down share of the Meme and
    Quote trade fees and of a 1,001 MIST creation fee (400, Blast keeping 601),
    leaving the creator's fees and agreeing with `PartnerPaid`;
  - a partnered migrated launch paying the partner from the same totals after
    both the one-time Meme/Quote allocation and a later LP-fee accrual enter the
    launch ledger;
  - a zero-share partner paid nothing, with no `PartnerPaid`, while the claim
    still records it;
  - the plain claim refused on a partnered launch, and the partner claim refused
    for another partner (before the empty-ledger check) and for a launch without
    one.
- Migration tests prove both venue residuals and Blast's migration allocation
  settle into the launch ledger, and the migrators' replay reducer includes
  every recurring Blast LP-fee amount there.
- The Rust PTB harness publishes `blast_partners` before the launchpad, passes
  the new `finalize` arguments and decodes the new fields. `atomic_migration`,
  `launch_measurements` and the venue fork against mainnet Cetus and Bluefin
  bytecode all pass.
- `sui/launchpad/scripts/check_source_boundaries.sh` pins the new dependency,
  roles, the `LaunchConfig` fee and partner writers, and the partner never
  changing after creation.
