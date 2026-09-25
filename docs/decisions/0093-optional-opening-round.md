# 0093: An optional opening round replaces purchase protection and the creator's head start

- Status: accepted
- Date: 2026-09-25
- Amends: [0088](0088-reusable-launch-accounting-and-atomic-migration.md) and
  [0090](0090-minimal-launchpad-surface.md)

## Context

Purchase protection capped each purchase and each sender's running total for a
window after share. The founder ruled on 2026-09-25 that it does not stop
snipers, who split a purchase across wallets, and only limits honest buyers
with one wallet. With a fixed curve and more early demand than cheap supply,
something must ration: speed, identity, capital, or price. Per-sender caps
ration by identity, which addresses make free. A uniform-price batch rations by
capital: splitting a deposit across wallets changes nothing, and arrival order
within the window changes nothing.

The founder also ruled that the mechanism must be simple enough for traders to
understand in one sentence, and optional: the platform is generic, and some
creators want trading to start at once. The same day the founder ruled that the
creator no longer needs a purchase before anyone else can trade: that head start
was the last guaranteed snipe.

## Decision

**Creation shares.** `finalize` takes the `Clock` and shares the launch; `share`
is removed. Public time starts at creation, so there is no unshared launch for
the creator to buy from first: the creator buys, or bids, like everyone else.
With no function taking a launch by value, a shared launch cannot be re-shared
to restart its clock.

**Setting.** `set_opening_round(opening_round_ms)` replaces `set_protection`.
Zero, the default, has no opening round. Otherwise `finalize` requires one
minute to five minutes (package constants), stores the round's end, and the
launch starts in a new first lifecycle state, `OpeningRound`.

**Joining.** `join_opening_round` adds Quote to the sender's bid, recorded as a
launch-owned dynamic field, until the round's end. A zero bid aborts. No bid
can be withdrawn, so a large bid cannot fake demand and leave.

**Nothing trades.** `buy` and `sell` need `Live`, so no one can trade before
or ahead of the pot.

**Settlement.** From the round's end, anyone may `settle_opening_round`: it
moves the launch to `Live` and buys from the curve once with the whole pot,
through the same path, fees, and graduation cap as `buy`. The Meme bought and
any Quote refunded past the target are held for delivery. A pot that would buy
less than one Meme atom (an empty or dust pot, or an extreme virtual reserve)
buys nothing and is held whole for refund, so settlement can never be stuck.
A pot that reaches the target makes the launch `MigrationReady`.

**Delivery.** Anyone may `deliver_opening_round(bidder)` after settlement, in
any later lifecycle, including after migration. It retires the bid record and
sends the bidder its bid's share of the held Meme and Quote among the
undelivered bids, rounded down; the last delivery takes the remainder, so no
dust is stranded and each bidder's share moves by at most rounding across
delivery orders. Delivery transfers to the bidder, never to the caller, and one
bidder whose transfer fails cannot block the others.

**Removed.** The per-transaction and cumulative limits, their errors, and the
per-sender purchase records; `share`, the purchase before sharing, and the
shared checks in `sell` and creator claims. `buy` no longer takes the `Clock`.

**Events.** `LaunchCreated` carries `public_start_ms` and `opening_round_ms`
instead of the protection settings, and `LaunchShared` is removed.
`OpeningRoundJoined` (the bidder is the sender), `OpeningRoundSettled`, and
`OpeningRoundDelivered` (the bidder can differ from the sender) are new. The pot's purchase emits `Bought` in the same transaction
as `OpeningRoundSettled`; indexers attribute it to the round, not the settler.

## Consequences

- Everyone in a round pays the same price, whether they bid first or last and
  from one wallet or many. Speed can still pay in the first sales after
  settlement; that race is accepted.
- The round needs one settlement and one delivery per bidder; Blast's keeper
  runs both, and bidders can run them too. Deleting each record refunds its
  storage to whoever delivers.
- The launchpad ABI, lifecycle tags, event layouts, and error codes change; the
  SDK, the indexer's decoders, and the harnesses must follow.
