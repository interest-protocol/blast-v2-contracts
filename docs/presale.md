# How presales work

A presale sells a creator's tokens at fixed prices, in up to eight
**tranches**. Each tranche has its own price, amount, time window and, if you
want, a whitelist. There is no bonding curve: the price in each tranche is the
price the creator set. The decision record is
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
 create ── tranche windows ──┬── finalize ──── claim time ──── vesting ends
                             │   (anyone)      tokens unlock
                             └ last tranche ends
```

1. **Create.** The creator deposits exactly the tokens the tranches sell. The
   creator also picks a **claim time** no earlier than the last tranche's end,
   and optionally a **minimum raise**. Blast's fee at that moment is locked in
   for this presale.
2. **Commit.** Buyers commit Quote to open tranches. Commits to the same tranche
   add up per address.
3. **Finalize.** After every tranche has ended, anyone can finalize:
   - **Minimum reached (or none set):** the creator is paid the raise minus
     Blast's fee, and unsold tokens go back to the creator.
   - **Minimum missed:** every token goes back to the creator, and every buyer
     can take their whole commit back.
4. **Claim.** Buyers, or anyone on their behalf, claim:
   - pro-rata refunds straight after finalization;
   - tokens from the claim time, released linearly if the tranche vests.

   Claiming is always paid to the buyer, so Blast can run claims for everyone.

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
no fee.

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
