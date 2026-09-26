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
| Share of Blast's fee, 0% to 80%, per deal | Blast | seven days after Blast sets it |
| Recipient address, per deal | you, with your cap | immediately |
| Which cap manages a deal | Blast | seven days after Blast moves it |

- You can mint your own cap with `new_cap` (for example straight into your
  multisig) and give Blast its ID; Blast registers each deal under it. Each
  deal's share starts at zero and switches to the agreed share seven days later.
- Change where a deal pays you with `set_recipient`, holding your cap. It applies
  at once. Whoever holds the cap controls where every deal under it pays, so keep
  it somewhere safe.
- Blast cannot change your share or your cap without seven days' notice, which
  anyone can read on chain. The delay comes from `blast_fun_timelock`, an
  immutable package nobody can change.
- If you lose your cap, mint a new one and ask Blast to move your deals to it;
  each move goes live seven days later, and until then the old cap still works.
- Every payment emits `PartnerPaid` with your partner ID and the amount you
  received, and the product records the trade in its own event (for Boosts,
  `PartnerFeePaid`), so you can reconcile your income from events alone.
- Your code is a public object, and any app can name it. If another app does,
  you still earn on that flow.

## For Blast's operators

- **Registering a deal.** The partner administrator (its own role in the partner
  domain) calls `register` with the company's cap ID, the recipient and the
  share. For a new company, mint a cap with `new_cap` and send it to them, or
  use a cap they minted.
- **Changing a tier.** `schedule_share` sets the new share seven days ahead.
  Scheduling again replaces a pending change and restarts the seven days;
  scheduling the share already in force cancels a pending change. Tiers are
  reviewed off chain from the Blast fee kept on each partner's flow, which wash
  volume and free-riding lower rather than raise.
- **Switching a deal off.** Schedule its share to zero. Apps that still name it
  keep working and pay the normal fee to Blast.
- **Replacing a lost or stolen cap.** `schedule_cap` moves a deal to a new cap in
  seven days, one call per deal. A thief holding the old cap can redirect payouts
  until then, so tell integrators to stop naming those deals meanwhile.
- **At launch,** publish `blast_fun_timelock` and then `blast_partners`, each
  immutable, and grant the partner administrator role. Also set each vault's
  admin share: while it is zero, as it is at activation, Blast earns nothing and
  so partners earn nothing.
- **Deny lists.** If a recipient is blocked by the collateral's deny list, trades
  naming that deal are expected to fail; the release rehearsal confirms it. The
  partner fixes it at once by setting a new recipient; until then integrators
  can call the plain entry points.

## Guarantees

These properties are enforced by the contracts and covered by tests, except the
fourth, which rests on the packages being published immutable:

1. The reserve fee, the shares minted and the redemption payout are the same with
   or without a partner.
2. A partner is paid at most 80% of Blast's admin fee on the trade, rounded down;
   Blast keeps the rest.
3. Minting and redeeming through your own code always costs at least as much as
   it pays back: the reserve fee and at least a fifth of Blast's fee are still
   charged.
4. Nothing Blast schedules for a partner takes effect sooner than seven days
   after it was last scheduled, and, since the packages are immutable, no
   upgrade can change that.
5. Only the cap managing a deal can change its recipient; only Blast's partner
   administrator can register deals, schedule shares and move deals between caps.
6. Blast never holds partner money, and there is no claim step to miss.
