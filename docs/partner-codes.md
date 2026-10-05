# Partner codes

Partner codes let apps that build on Blast earn from the flow they bring. A
partner is paid a share of the fee Blast charges on each trade that names it,
straight to its address. Holders never pay for it. Boosts, the launchpad and
presales support it; on the launchpad and on presales a partner is chosen once,
when the coin or the sale is created.

The decisions and their alternatives are recorded in
[ADR 0095](decisions/0095-partner-codes.md), for the launchpad in
[ADR 0098](decisions/0098-launch-creation-fee-and-partners.md), and for presales
in [ADR 0106](decisions/0106-presale-partners.md). This page
explains how the program works for integrators, partners and Blast's operators.

## The idea in one example

A Boost vault charges a fee on every mint and redeem. The fee has two parts:

- the **reserve fee**, which stays in the vault as margin that protects holders;
- **Blast's admin fee**, which is Blast's revenue.

A partner code only ever divides Blast's admin fee. Say a user mints 10,000 USDC
of a Boost through a wallet whose partner share is 40%. The vault charges 30 bps,
and Blast's admin share is 50%.

| Part | Amount | Who gets it |
| --- | --- | --- |
| Fee | 30.00 USDC | charged on the 10,000 USDC mint |
| Reserve fee | 15.00 USDC | stays in the vault for holders, exactly as without a partner |
| Blast's admin fee | 15.00 USDC | split below |
| Partner's share | 6.00 USDC | 40% of Blast's admin fee, sent to the wallet's recipient address |
| Blast keeps | 9.00 USDC | the rest of the admin fee |

The partner's share rounds down, so any leftover fraction of an atom stays with
Blast. The rates above are an illustration; Blast sets each vault's live rates
within the caps fixed at issuance.

## What each side gets

**Users** pay the vault's normal fee. Their shares, their redemption amount and
their price are identical with or without a partner.

**Partners** are paid in the vault's collateral (USDC at launch) as each trade
they bring happens. Nothing accrues on Blast's side and there is nothing to claim.
A partner that wants to charge its users more, or give them something back, does
that in its own transaction.

**Holders** are untouched: a partner is only ever paid out of Blast's own cut.

**Blast** pays partners only from revenue earned on the flow they brought, and
never more than 80% of it.

## For integrators

- Without a partner code, call `mint` and `redeem` as before. Nothing about them
  changed, and they cost nothing extra.
- With a partner code, call `mint_with_partner` or `redeem_with_partner`, passing
  your `Partner` object right after the `Protocol` object. They do exactly what
  the plain calls do, then pay your share of Blast's fee on that trade.
- Boosts pays only partners it accepts; naming any other partner aborts the
  trade. Before building a partner trade, read the partner's `PartnerKey` field
  on the Boosts `Protocol`: it is accepted while the field exists and the clock is
  before its value. Otherwise call the plain entry points.
- The partner object is only read, so naming a busy partner adds no contention
  of its own.
- To charge your own fee, split it from the user's coin in your own transaction
  and send it wherever you like. The user sees and signs it like any other
  transfer, and Blast takes no cut of it.

## For partners

A company holds one `PartnerCap` for all its deals with Blast. Each deal is its
own `Partner`, with its own share and recipient, for example 50% of Blast's fee
on Boosts and 8% on another product.

| Term | Set by | When it takes effect |
| --- | --- | --- |
| Share of Blast's fee, 0% to 80%, per deal | Blast | at registration; each later change seven days after Blast sets it |
| Recipient address, per deal | you, with your cap | immediately |
| Which cap manages a deal | Blast | seven days after Blast moves it |
| Which products accept a deal | Blast, per product | added at once; removed seven days after Blast removes it |

- You can mint your own cap with `new_cap` (for example straight into your
  multisig) and give Blast its ID; Blast registers each deal under it. Each
  deal earns its agreed share from registration.
- Change where a deal pays you with `set_recipient`, holding your cap. It applies
  at once. Whoever holds the cap controls where every deal under it pays, so keep
  it somewhere safe.
- Blast cannot change your share or your cap without seven days' notice, which
  anyone can read on chain. The delay comes from `blast_fun_timelock`, an
  immutable package nobody can change.
- A deal pays only on the products that accept it: Boosts accepts a deal once
  Blast adds it there. If Blast removes it, it stays accepted, and paid, for
  seven more days.
- If you lose your cap, mint a new one and ask Blast to move your deals to it;
  each move goes live seven days later, and until then the old cap still works.
- Every payment emits `PartnerPaid` with your partner ID and the amount you
  received, and the product records the trade in its own event (for Boosts,
  `PartnerFeePaid`), so you can reconcile your income from events alone.
- Your code is a public object, and any app can name it on a product that
  accepts it. If another app does, you still earn on that flow.

## For Blast's operators

- **Registering a deal.** The partner administrator (the
  `blast_partners::PartnerAdmin` role in the Blast ACL) calls `register` with the company's cap ID, the recipient and the
  share. For a new company, mint a cap with `new_cap` and send it to them, or
  use a cap they minted. `register` accepts any ID, so first check on chain that
  the ID is a `PartnerCap` the company holds: a wrong ID leaves the deal without
  a working cap until `schedule_cap` fixes it seven days later.
- **Accepting a deal on Boosts.** After registering it, the Boosts risk
  administrator calls `operations::add_partner` with the `Partner`; it applies
  at once. Accept each deal only on the product it was priced for.
- **Ending a deal on Boosts.** `operations::remove_partner` takes effect seven
  days later, after which trades naming it abort. Adding it again meanwhile
  cancels the removal. To keep attributing the flow but pay nothing, schedule
  its share to zero instead.
- **Changing a tier.** `schedule_share` sets the new share seven days ahead.
  Scheduling again replaces a pending change and restarts the seven days;
  scheduling the share already in force cancels a pending change. Tiers are
  reviewed off chain from the Blast fee kept on each partner's flow, which wash
  volume and free-riding lower rather than raise.
- **Switching a deal off everywhere.** Schedule its share to zero. Apps that
  still name it keep working and pay the normal fee to Blast.
- **Replacing a lost or stolen cap.** `schedule_cap` moves a deal to a new cap in
  seven days, one call per deal. A thief holding the old cap can redirect payouts
  until then, so tell integrators to stop naming those deals meanwhile.
- **At launch,** publish `blast_partners` immutable (the timelock it builds on
  is already published immutable) and commit its `Published.toml`, so the
  adapter's mainnet build links to it. Then publish the Boosts adapter fresh,
  grant `PartnerAdmin` on the Blast ACL, and add each Boosts deal. Also set each
  vault's admin share: while it is zero, as it is at activation, Blast earns
  nothing and so partners earn nothing.
- **Deny lists.** If a recipient is blocked by the collateral's deny list, trades
  naming that deal are expected to fail; the release rehearsal confirms it. The
  partner fixes it at once by setting a new recipient; until then integrators
  can call the plain entry points.

## On the launchpad

Launching a coin costs a creation fee in SUI, which Blast sets. A launch can
name one partner, and only when it is created; nothing can change it later.
That partner is paid its share of every fee Blast takes on the launch, all at
once, whenever anyone claims Blast's fees from the launch:

- the creation fee;
- Blast's part of every curve trade fee, the opening round's included, in Meme
  and Quote;
- Blast's one-time Meme and Quote migration fee, which joins the launch's fees
  when it migrates.

The creator's part of each trade fee and the sell burn are never divided with
the partner, and neither are the venue's migration residuals.

After migration the partner also earns its cut of Blast's LP fees on the
launch's pool ([ADR 0107](decisions/0107-partner-cut-of-lp-fees.md)). The
launch's LP vault inherits its partner, and each fee collection holds Blast's
LP fees in that vault instead of paying them. Anyone may then call
`vault::claim_protocol_lp_fees_with_partner`, which pays the partner its cut of
each asset and the `LpFeePolicy` destination the rest; the SDK adds it to every
collection on a partnered vault. Vaults of launches without a partner pay
Blast at each collection, as before.

- **Integrators** that create coins call `launch::set_partner` on the
  initializer, passing the `Partner` object and the `Clock`, alongside the other
  creation settings; `finalize` is the same with or without a partner. The
  creation fee must be exactly the one set in `LaunchConfig`. Trading never
  takes the partner: `buy`, `sell` and the opening round are the same on every
  launch.
- **Partners** are paid at the claim, not when each fee is charged. Anyone may
  claim, the partner included, and no caller chooses where the money goes
  ([ADR 0105](decisions/0105-permissionless-launch-fee-claims.md)):
  `claim_protocol_fees_with_partner` pays the partner its share and Blast's
  treasury the rest, and `claim_protocol_fees` refuses a partnered launch.
  `ProtocolFeesClaimed` records both parts and the treasury paid, and
  `LaunchCreated` records the partner and the creation fee.
- **Operators.** The fee administrator (`FeeAdmin`) sets the creation fee with
  `launch_config::set_creation_fee`. It also accepts deals with
  `launch_config::add_partner`, which applies at once, and ends them with
  `launch_config::remove_partner`, which applies seven days later. Removing a
  deal only stops new launches from naming it. Launches that already name it
  keep paying it, unless its share is scheduled to zero. The treasury
  administrator (`TreasuryAdmin`) sets where Blast is paid with
  `runtime_config::set_treasury`; every later claim pays that address the
  creation fee with each launch's trade fees.

## On presales

A presale can name one partner, and only when it is created; nothing can change
it later. When the sale succeeds, that partner is paid its cut of Blast's fee on
the raise and, after migration, of Blast's LP fees on the sale's pool. Blast's
token fee is never divided with a partner.

Say a sale raises 100,000 USDC, Blast's raise fee is 2%, and the partner's cut is
40%. Blast's fee on the raise is 2,000 USDC; the partner receives 800 USDC and
Blast keeps 1,200. Buyers, the creator, the raise recipients and the
pool receive exactly what they would without a partner.

- **Integrators** that create sales call `blast_presale::set_partner` on the new
  sale, passing the presale `CreationPolicy`, the `Partner` object and the
  `Clock`, after `new` and before `share`. Every migrator supports it, a
  partner's own vendor package included. Commitments, claims and migration are
  the same on every sale.
- **Partners** are paid after the sale migrates. A partnered sale's migration
  holds Blast's fees in the sale, and
  `blast_presale::pay_protocol_fees_with_partner` then pays the partner its cut
  in force of Blast's raise fee and pays Blast the rest.
  Anyone can call it, once, and the SDK adds it to the migration transaction.
  Nothing is paid if the sale is refunded. `ProtocolFeesPaid` records what Blast
  kept and the partner's `partner_quote`, and `PresaleOpened` records the
  partner.
- **After migration** the sale's vault inherits its partner, and each LP-fee
  collection holds Blast's LP fees in the vault
  ([ADR 0107](decisions/0107-partner-cut-of-lp-fees.md)). Anyone may then call
  `presale_vault::pay_protocol_lp_fees_with_partner`, which pays the partner its
  cut of each asset and the fee policy's destination the rest; the SDK adds it
  to every collection on a partnered vault. `ProtocolLpFeesPaid` records both
  parts.
- **Operators.** The presale `AdminCap` accepts deals with
  `creation_policy::add_partner`, which applies at once, and ends them with
  `creation_policy::remove_partner`, which applies seven days later. Removing a
  deal only stops new sales from naming it; sales that already name it keep
  paying it, unless its share is scheduled to zero.

## Guarantees

These properties are enforced by the contracts and covered by tests; the fourth
also rests on how each package is published:

1. The reserve fee, the shares minted and the redemption payout are the same with
   or without a partner. On the launchpad, trades, the creator's fees and the
   sell burn are the same with or without a partner. On presales, what buyers,
   the creator, the recipients and the pool receive is the same with or without
   a partner.
2. A partner is paid at most 80% of Blast's fee, rounded down; Blast keeps the
   rest.
3. Minting and redeeming through your own code always costs at least as much as
   it pays back: the reserve fee and at least a fifth of Blast's fee are still
   charged.
4. Nothing Blast schedules for a partner takes effect sooner than seven days
   after it was last scheduled. For shares and caps no upgrade can change that,
   since the partner packages are immutable; the Boosts removal notice holds as
   long as the Boosts adapter, which is upgradeable, keeps it.
5. Only the cap managing a deal can change its recipient; only Blast's partner
   administrator can register deals, schedule shares and move deals between caps;
   only the Boosts risk administrator can add or remove deals on Boosts, only
   the launchpad fee administrator on the launchpad, and only the presale
   `AdminCap` on presales. A launch's or a sale's partner never changes.
6. On Boosts, Blast never holds partner money, and there is no claim step to
   miss. On the launchpad, a partner's share of Blast's fees waits in the launch
   until anyone claims, the partner included, and no claim pays Blast without
   paying the partner in the same call. On presales, a partnered sale's Blast
   fees wait in the sale until anyone pays them, and Blast cannot be paid
   without paying the partner in the same call. After migration, on both
   products, a partnered vault's Blast LP fees wait in the vault on the same
   terms.
