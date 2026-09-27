# Partner codes

Partner codes let apps that build on Blast earn from the flow they bring. A
partner is paid a share of the fee Blast charges on each trade that names it,
straight to its address, in the same transaction. Holders never pay for it.
Boosts supports it today; the launchpad will use the same partner codes later.

The decision and its alternatives are recorded in
[ADR 0095](decisions/0095-partner-codes.md). This page explains how the program
works for integrators, partners and Blast's operators.

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

## Guarantees

These properties are enforced by the contracts and covered by tests; the fourth
also rests on how each package is published:

1. The reserve fee, the shares minted and the redemption payout are the same with
   or without a partner.
2. A partner is paid at most 80% of Blast's admin fee on the trade, rounded down;
   Blast keeps the rest.
3. Minting and redeeming through your own code always costs at least as much as
   it pays back: the reserve fee and at least a fifth of Blast's fee are still
   charged.
4. Nothing Blast schedules for a partner takes effect sooner than seven days
   after it was last scheduled. For shares and caps no upgrade can change that,
   since the partner packages are immutable; the Boosts removal notice holds as
   long as the Boosts adapter, which is upgradeable, keeps it.
5. Only the cap managing a deal can change its recipient; only Blast's partner
   administrator can register deals, schedule shares and move deals between caps;
   only the Boosts risk administrator can add or remove deals on Boosts.
6. Blast never holds partner money, and there is no claim step to miss.
