# Partner codes

Partner codes let apps that build on Blast earn from the flow they bring. Every
Boost mint and redeem names a Blast partner, and that partner is paid a share of
the fee Blast charges on it, straight to its address, in the same transaction.
Holders never pay for it. The launchpad will use the same partner codes later.

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
their price are identical whichever partner their app names.

**Partners** are paid in the vault's collateral (USDC at launch) as each trade
they bring happens. Nothing accrues on Blast's side and there is nothing to claim.
A partner that wants to charge its users more, or give them something back, does
that in its own transaction.

**Holders** are untouched: a partner is only ever paid out of Blast's own cut.

**Blast** pays partners only from revenue earned on the flow they brought, and
never more than 80% of it.

## For integrators

- `mint` and `redeem` take the partner object right after the `Protocol` object.
- If you have a partner code, pass your `Partner` object's ID.
- If you don't, pass Blast's house partner. Its share is zero, so it prices
  exactly like no partner. Its ID is published with each deployment.
- The partner object is only read, so naming a busy partner adds no contention
  of its own.
- To charge your own fee, split it from the user's coin in your own transaction
  and send it wherever you like. The user sees and signs it like any other
  transfer, and Blast takes no cut of it.

## For partners

| Term | Set by | When it takes effect |
| --- | --- | --- |
| Share of Blast's fee, 0% to 80% | Blast | seven days after Blast sets it |
| Recipient address | you, with your `PartnerCap` | immediately |
| Which cap is live | Blast, by reissuing it | seven days after the reissue |

- Blast registers you and hands you your `PartnerCap`. Your share starts at zero
  and switches to the agreed share seven days later.
- Change where you are paid with `set_recipient`, holding your live cap. It
  applies at once. Keep the cap somewhere safe, such as a multisig: whoever holds
  it controls where your share goes.
- Blast cannot change your share or your cap without seven days' notice, which
  anyone can read on chain. The delay is a constant in a package nobody can
  upgrade.
- If you lose your cap, Blast reissues one; the new cap goes live seven days
  later, and until then the old cap still works.
- Your share arrives in your recipient's balance as each trade happens. Every
  `Minted` and `Redeemed` event records your partner ID and what you were paid,
  so you can reconcile your income from events alone.
- Your code is a public object, and any app can name it. If another app does,
  you still earn on that flow.

## For Blast's operators

- **Registering.** The partner administrator (its own role in the partner
  domain) calls `register` with the partner's recipient and share. The call
  returns the `PartnerCap`; send it to the partner in the same transaction.
- **Changing a tier.** `schedule_share` sets the new share seven days ahead.
  Scheduling again replaces a pending change and restarts the seven days;
  scheduling the share already in force cancels a pending change. Tiers are
  reviewed off chain from the Blast fee kept on each partner's flow, which wash
  volume and free-riding lower rather than raise.
- **Switching a partner off.** Schedule its share to zero. Apps that still name
  it keep working and pay the normal fee to Blast.
- **Replacing a lost or stolen cap.** `reissue_cap` returns a new cap that goes
  live in seven days. A thief holding the old cap can redirect payouts until
  then, so tell integrators to name the house partner in the meantime.
- **At launch,** publish `blast_partners` immutable, grant the partner
  administrator role, register the zero-share house partner, and record its ID in
  the release input. Also set each vault's admin share: while it is zero, as it is
  at activation, Blast earns nothing and so partners earn nothing.
- **Deny lists.** If a recipient is blocked by the collateral's deny list, trades
  naming that partner fail. The partner fixes it at once by setting a new
  recipient; until then integrators can name the house partner.

## Guarantees

These properties are enforced by the contracts and covered by tests:

1. The reserve fee, the shares minted and the redemption payout are the same for
   every partner, including the house partner.
2. A partner is paid at most 80% of Blast's admin fee, rounded down; Blast keeps
   the rest.
3. Minting and redeeming through your own code always costs more than it pays
   back: the reserve fee and at least a fifth of Blast's fee are still charged.
4. Nothing Blast schedules for a partner takes effect sooner than seven days
   after it was last scheduled, and no upgrade can change that.
5. Only the live cap can change a partner's recipient; only Blast's partner
   administrator can register partners, schedule shares and reissue caps.
6. Blast never holds partner money, and there is no claim step to miss.
