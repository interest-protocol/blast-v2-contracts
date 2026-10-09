# 0106: Presale partners

- Status: proposed; amended by [0107](0107-partner-cut-of-lp-fees.md): the partner also earns
  its cut of Blast's LP fees on the sale's vault; amended by
  [0110](0110-presale-initializer-and-early-close.md): `set_partner` acts on the
  `PresaleInitializer`, so `finalize` fixes the partner before the sale exists
- Date: 2026-10-05
- Amends: [0095](0095-partner-codes.md), whose partners earned only on Boosts and
  the launchpad; [0101](0101-presale-protocol-fees.md), which paid Blast's fees
  at migration on every sale; and [0102](0102-presale-creation-allowlists.md),
  whose `CreationPolicy` listed only Quote types and migrators

In this record "share" is the Sui operation that makes a sale a shared object.
Blast's percentages of a sale are its raise fee, token fee, and LP-fee rates;
a partner's percentage of Blast's fee is its cut, the rate `blast_partners`
stores as `share_bps`.

## Context

On 2026-10-05 the owner asked for the partner program on presales, working like
the launchpad's: a partner is paid a percentage of what Blast takes of the
raised amount, and of nothing after it. Under ADR 0101 Blast takes a raise fee
and a token fee at migration, and LP-fee rates after it. Migration is
permissionless and runs inside each migrator: Cetus and Bluefin in
`blast_presale`, and vendor packages under ADR 0104.

## Decision

**Scope.** A sale's partner earns its cut (0% to 80%, under `blast_partners`'
seven-day timelock) of Blast's raise fee, and of nothing else. Blast's token
fee and LP fees are never divided with a partner.

**Accepted partners.** The `CreationPolicy` keeps the Blast partners new
presales may name, with the launchpad's list and notice. There is one dynamic
field per partner under `PartnerKey(ID)`, whose value is when the partner stops
being accepted: `u64::MAX` until Blast removes it. Blast's presale `FeeAdmin` calls
`add_partner`, which applies at once, cancels a pending removal, and accepts a
removed partner again, and `remove_partner`, which takes effect
`blast_partners::delay_ms()` later. They emit `PartnerAdded` and
`PartnerRemoved { partner_id, accepted_until_ms }`. Adding an accepted partner
or removing a removed one aborts with `EAllowanceUnchanged`; removing a partner
not accepted aborts with `EPartnerNotAccepted`. Removal only stops new sales
naming the partner.

**Binding at creation.** `blast_presale::set_partner` names a sale's partner
between `new` and `share`. It takes the `CreationPolicy`, the `Partner`, and the
`Clock` to check the policy accepts the partner (`EPartnerNotAccepted`), and it
records the partner's ID. An unshared `Presale` is key-only and cannot leave its
creation transaction, so only the creator can name its partner. `share` fixes
the choice: `set_partner` aborts afterward (`EInvalidLifecycle`), and nothing
else writes the field. `PresaleOpened` gains `partner_id`. `new` is unchanged,
so every migrator's sales, vendor packages' included, can name a partner when
the creator calls `set_partner` before `share`.

**Paying the partner.** `migrate` of a sale without a partner pays Blast as
before. A partnered sale's migration pays the raise recipients and releases the
LP exactly as before, but holds Blast's raise fee in the sale and leaves its
token fee in escrow. Anyone may then call `pay_protocol_fees_with_partner`
once; its name, like the launchpad's `claim_protocol_fees_with_partner`, says it
pays Blast too. It checks the partner is the sale's (`EWrongPartner`) and that
Blast's fees are still held (`ENoPartnerPayout`: before migration, after a
cancellation, or after the payout). It pays the partner its cut in force of the
held Quote, rounded down through `blast_partners::pay`, then pays Blast the rest
and all its tokens at the `FeePolicy`'s current destination. Both recipients
are fixed, so the call needs no authority; the SDK appends it to the migration
transaction.

**Events.** `ProtocolFeesPaid` gains `partner_quote`. It is emitted once per
migrated sale: at migration for a sale without a partner, with `partner_quote`
zero, and at `pay_protocol_fees_with_partner` for a partnered sale, with what
Blast kept. `blast_partners` also emits `PartnerPaid<Quote>` for any nonzero
payment.

## Alternatives considered

- **Pay the partner inside `migrate`.** `migrate` would need the `Partner`, and
  Move has no `Option<&Partner>`. Two variants would double every migrator's
  entry point, Cetus, Bluefin, and every vendor, and the plain ones would abort
  on partnered sales. Holding Blast's fees for a separate payout leaves
  `migrate` and every migrator unchanged.
- **Pay before migration.** A funded sale can still be cancelled and refunded
  in full, so Blast's raise fee is not earned until migration.
- **Hold every sale's fees for a claim, as on the launchpad.** Launch fees
  accrue over many trades, so the launchpad holds them for a permissionless
  claim ([ADR 0105](0105-permissionless-launch-fee-claims.md)). A presale's raise
  fee is one amount at migration, so a sale without a partner still pays it
  then, and only a partnered sale waits for its one payout.
- **Pay Blast's tokens at migration and hold only the Quote.** Blast's payout
  would span two transactions and two events. Holding both keeps one
  `ProtocolFeesPaid` per sale; the tokens wait only until a payout anyone can
  make at once.
- **Give the partner a cut of Blast's token fee or LP fees.** The owner limited
  the program to what Blast takes of the raise.
- **Name the partner in `new`.** `new` has no clock to check the removal notice,
  and every migrator's `new` would have to forward it. `set_partner` between
  `new` and `share` mirrors the launchpad's initializer.
- **Keep the list in `FeePolicy`.** The `CreationPolicy` already holds what a
  sale may name at creation and is checked only then.

## Consequences

- Participants, the creator, the recipients, and the LP receive exactly what
  they would without a partner. Only Blast's raise fee is divided.
- A partnered sale's Blast fees stay in the sale until someone calls
  `pay_protocol_fees_with_partner`, and nothing else can move them. The
  partner's cut is the one in force at the payout, and any change Blast makes
  to it waits seven days.
- The binding is permanent. To stop paying a bound partner, Blast schedules its
  cut to zero in `blast_partners`, which affects that deal on every product.
- A Quote deny list blocking the partner's recipient makes
  `pay_protocol_fees_with_partner` abort until the partner sets a new
  recipient, as on the launchpad; Blast's fees stay held meanwhile.
- `blast_presale` depends on `blast_partners` and on `blast_admin`, whose ACL
  administers it (ADR 0099). `blast_partners` is published before the presale
  generation ADR 0104 already requires.
- ABI:
  - new functions: `blast_presale::set_partner` and
    `pay_protocol_fees_with_partner`, and `creation_policy::add_partner` and
    `remove_partner`;
  - `PresaleOpened` gains `partner_id` and `ProtocolFeesPaid` gains
    `partner_quote`;
  - new events: `PartnerAdded` and `PartnerRemoved`.

  The SDK follows.

## Verification

- `CreationPolicy` tests:
  - a partner accepted at once, with its event;
  - an unlisted partner refused;
  - a removed partner accepted until one millisecond before its notice ends,
    and refused from then on;
  - re-adding cancels a pending removal, and accepts a removed partner again;
  - refusals for adding twice, removing twice, and removing an unknown partner.
- Presale tests:
  - a partnered sale releasing the same raise and LP while holding Blast's
    fees, then paying the partner 13 of Blast's 33 Quote at a 40% cut (13.2
    rounded down) and Blast 20 Quote and every token, agreeing with
    `PartnerPaid`, with no token payment to the partner and claims unchanged;
  - the cut in force at the payout applied, not the one at creation;
  - a zero-cut partner paid nothing, with no `PartnerPaid`;
  - an unaccepted partner refused at creation, and a shared sale's partner
    fixed;
  - the payout refused before migration, after a cancellation, a second time,
    for another partner (checked first), and on a sale without a partner;
  - a zero raise rate paying the partner nothing and Blast its held tokens;
  - a rate set before the start being the one a partnered migration holds;
  - a vendor sale naming a partner before its `share`;
  - a sale without a partner paying Blast at migration with `partner_quote`
    zero and its `PresaleOpened` naming none.
- `sui/presale/scripts/check_source_boundaries.sh` pins that only
  `set_partner`, on an unshared sale, writes a sale's partner.
