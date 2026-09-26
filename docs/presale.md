# How presales work

A presale sells a creator's tokens at fixed prices, in up to eight
**tranches**. Each tranche has its own price, amount, time window and, if you
want, a whitelist. There is no bonding curve: the price in each tranche is the
price the creator set. When the presale succeeds, the money raised is split
between recipients the creator chose and, if they want, a DEX pool that opens
at their listing price. The decision record is
[ADR 0096](decisions/0096-presale-package.md).

## A tranche in one line

> *"1,000,000 tokens for 30,000 SUI, from Monday 14:00 to Tuesday 14:00,
> whitelist only, first come, vesting over 30 days."*

Each tranche is:

| Setting | What it means |
| --- | --- |
| **Tokens and Quote** | The tranche sells `tokens` for `quote` in total, so the price is `quote / tokens`. |
| **Window** | Commits are accepted from the start until the end. |
| **First come or pro rata** | See below. |
| **Access** | Either **public**, with an optional wallet cap on what one address may commit, or **whitelisted**, where only listed addresses may commit, each up to its own allowance. |
| **Vesting** (optional) | Tokens unlock linearly from the claim time over this period. Without it, they all unlock at the claim time. |

A presale might run a cheaper whitelisted tranche first and a pricier public one
after it, each in its own window.

## First come or pro rata

**First come.** Commits fill in arrival order until the tranche's Quote is
reached. The part of a commit that doesn't fit comes straight back in the same
transaction. Once the tranche is full it is sold out. This is simple and exact,
but when demand is high, the fastest buyers win.

**Pro rata.** Every commit is accepted while the tranche is open. If more Quote
comes in than the tranche raises, everyone is filled in the same proportion,
and the rest is refunded:

```text
your tokens = your commit × tokens ÷ everything committed
your refund = your commit × (everything committed − quote) ÷ everything committed
```

Example: a tranche sells 2,000 tokens for 400 SUI, and 600 SUI is committed. A
buyer who committed 300 SUI gets 1,000 tokens, paying 200 SUI, and 100 SUI back.
Arriving early doesn't help, and splitting across wallets doesn't either.

## The timeline

```text
 create ── tranche windows ──┬── finalize ──────── claim time ──────── vesting ends
                             │   (anyone)          tokens unlock
                             │   recipients paid   DEX pool opens
                             └ last tranche ends
```

1. **Create.** The creator deposits the tokens the tranches sell, plus the
   tokens for the pool if there is one (see below). The creator also picks:
   - a **claim time**, no earlier than the last tranche's end;
   - optionally, a **minimum raise**;
   - **where the raise goes**.

   Blast's fee at that moment is locked in for this presale.
2. **Commit.** Buyers commit Quote to open tranches. Commits to the same tranche
   add up per address.
3. **Finalize.** After every tranche has ended, anyone can finalize:
   - **Minimum reached (or none set):** Blast takes its fee, the recipients are
     paid their shares, and the pool's share waits for the claim time. Unsold
     tokens and any unused pool tokens go back to the creator.
   - **Minimum missed:** every token goes back to the creator, and every buyer
     can take their whole commit back.
4. **Claim.** Buyers, or anyone on their behalf, claim:
   - pro-rata refunds straight after finalization;
   - tokens from the claim time, released linearly if the tranche vests.

   Claiming is always paid to the buyer, so Blast can run claims for everyone.
5. **Pool.** From the claim time, anyone can open the DEX pool. It opens when
   buyers can first claim, so nobody gets to sell into it ahead of them.

## Where the raise goes

After Blast's fee, the raise is split by percentage, set at creation:

- up to 16 **recipients** (team, treasury, marketing, the creator…), each with
  a share;
- optionally a **liquidity** share that goes into a new DEX pool.

The shares must add up to exactly 100%. Each share is rounded down, and the
first recipient gets the few leftover atoms. Recipients are paid at
finalization.

## The DEX pool

If the creator chooses liquidity, they also pick:

- **the venue:** Cetus or Bluefin, with its fee tier;
- **the listing price:** how many tokens one unit of Quote buys in the new pool.

The pool gets its share of the raise plus the tokens that Quote buys at the
listing price. The creator deposits those tokens up front, sized for the most
the tranches could raise. If less is raised, the pool needs fewer tokens, and
the rest go back to the creator at finalization.

> Example: after Blast's fee the presale raised 10,000 SUI. The payout is 30% to
> the team, 20% to the creator and 50% to liquidity, listing at 50 tokens per
> SUI. The team gets 3,000 SUI, the creator 2,000 SUI, and the pool opens with
> 5,000 SUI and 250,000 tokens. If the tranches could have raised 12,000 SUI,
> the creator deposited 300,000 pool tokens and gets 50,000 back.

The pool is full-range and its position is **locked forever** in a Blast vault,
so the liquidity can't be pulled. Anyone can collect the pool's trading fees.
Blast's LP share goes to Blast and the rest to the creator.

- **Cetus:** creating the presale reserves the Cetus pool, which needs the
  token's `TreasuryCap`, so no one else can create it afterwards at another
  price. Cetus must support the Quote and fee tier. If the token **already has
  a Cetus pool** at that tier, the new pool can't be created. Check first, or
  use another tier or Bluefin; otherwise the pool share stays stuck until a
  contract upgrade. Coins whose supply was fixed have no cap and can use
  Bluefin.
- **Bluefin:** whoever opens the pool pays Bluefin's pool creation fee in SUI.

The listing price must be within the venue's price range, and a pool share of
only a few atoms may be too small to open. If the presale fails, or raises
nothing for the pool, no pool is opened and every token goes back to the
creator.

## Whitelists

A whitelist is a Merkle tree the creator publishes off-chain. Each leaf is
`(position, address, allowance)`, and an allowance of zero means no limit. To
commit, a listed buyer sends their leaf's position, their allowance and the
proof, and can commit up to that allowance in total. The tree doesn't depend on
the presale, so you can build it before creating the presale. The exact hashing
and padding rules are in ADR 0096. A standard sorted-pair Merkle library won't
produce trees this contract accepts.

## Fees

Blast's fee is a share of the raise, at most 10%, rounded up in Blast's favour.
The fee admin sets it for presales created afterwards. It is paid at
finalization to the destination the treasury admin set. A failed presale pays
no fee. A presale's DEX pool also pays Blast its usual LP-fee share on trading
fees.

## Edge cases

- **Nothing committed and no minimum:** the presale succeeds with a zero raise,
  and all tokens go back to the creator.
- **Rounding:** tokens and refunds round down, so a few atoms of dust can stay
  in the presale.
- **Too small to buy anything:** a commit must buy at least one token atom at the
  tranche's price. In an oversubscribed pro-rata tranche, a very small commit
  can still end up with zero tokens; it gets its refund.
- **No cancellation:** once created, a presale's settings can't change, and the
  creator can't pull the tokens before finalization.
