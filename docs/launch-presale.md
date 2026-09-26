# How the presale works

> Put SUI in for up to three days. When it ends, the whole pot buys the curve at
> once: one price for everyone, with a known ceiling. If the pot is bigger than
> the curve, the coin lists on the DEX straight away and you get the rest back.
> Blast delivers your tokens and refund before trading opens.

A presale is optional. A creator who sets none gets a launch that trades as soon
as it is shared. The decision record is
[ADR 0096](decisions/0096-presale-through-address-balances.md).

## The timeline

```text
 create ─ share ─────── presale ───────┬─ 10 s ─ settle ── delivery window ── trading
            │   (1 minute to 72 hours)   │           │    (presale length,
            │   anyone puts SUI in        │           │     at most 5 minutes)
            └ creator may bid first       └ bids close └ the pot buys the curve once
```

1. **Before share.** The creator creates the launch and may bid in the same
   transaction, into the same pot and at the same price as everyone else. There
   is no head start.
2. **The presale.** From share until `presale_ms` later, anyone can put in any
   amount, as often as they like. Each deposit is its own bid. Bids cannot be
   withdrawn, so nobody can fake demand and leave. Nothing trades yet.
3. **Settlement.** Ten seconds after the presale ends, anyone may settle. The
   whole pot buys from the bonding curve in one purchase, with the normal fees
   and the normal graduation cap.
4. **Delivery.** Each bid is then delivered its share of the tokens bought, plus
   its share of any refund. Blast's keeper delivers every bid; anyone else may
   deliver too, and the tokens always go to the bidder, never to the caller.
5. **Trading.** The curve (or the DEX pool, if the presale filled the curve)
   opens once the delivery window has passed. The window is as long as the
   presale was, but never longer than five minutes.

## What you pay and what you get

Every bid pays the same average price: the pot's single purchase divided pro
rata. Bidding first or last, from one wallet or from fifty, changes nothing.

Your share of a bid is:

```text
your tokens = tokens the pot bought × your bid / the pot
your refund = SUI the pot got back × your bid / the pot
```

Both round down by less than one atomic unit.

The price has a ceiling. A curve that starts with a virtual reserve of `V` SUI
and closes at a target of `T` SUI never sells its tokens for more, on average,
than `(V + T) / curve tokens`. That is the price when the presale fills the
whole curve.

### Worked example

This is the SDK's recommended preset for an 8,000 SUI raise, ignoring fees: a
virtual reserve of 32,000 SUI, 800 million of 1 billion tokens on the curve,
and the pool opening at the curve's final price.

| | Fully diluted value |
| --- | --- |
| Curve start | 40,000 SUI |
| Bidders' average price when the presale fills the curve | 50,000 SUI |
| DEX opening price | 62,500 SUI (1.25 × the bidders' price) |

A virtual reserve at least four times the target keeps that listing multiple at
1.25 or below. A higher multiple makes flipping pay, and the research behind
this design found it drains the new pool.

## The three outcomes

| The pot is… | What happens |
| --- | --- |
| **Smaller than the target** (the common case) | The pot buys what it can and the curve goes live after the delivery window. There is no failure state and nothing to refund. The curve now holds the pot's own SUI, which buys back the bidders' tokens on the way down. |
| **Exactly the target** | The pot buys the whole curve. The launch is ready to migrate, and the DEX pool opens after the delivery window. |
| **Larger than the target** | The pot buys the whole curve, and the rest is refunded pro rata. If the pot was 12,000 SUI against an 8,000 SUI target, every bid spends about two thirds of its SUI and gets about one third back. |

A pot too small to buy a single token atom buys nothing and is refunded whole.
An empty presale settles too, and the launch simply goes live.

## Why there are no caps or whitelists

Per-wallet caps are split across wallets for free, and first-come sales are
always taken by bots. A single price with a pro-rata fill is the one scheme
where splitting wallets and racing gain nothing, so the presale needs no caps,
whitelists, tiers, or speed rules. See
[ADR 0093](decisions/0093-optional-opening-round.md) for the earlier decision
against caps.

## Why it holds up under heavy demand

A presale that writes one shared object for every bid queues on that object's
congestion budget. Past a few hundred bids a second, bids are cancelled and
fees turn into an auction. This presale avoids that:

- A bid sends its SUI to the launch's **address balance** (`balance::send_funds`)
  and leaves a small `BlastPresaleBid` object owned by the launch. It only
  *reads* the launch, and reads use no congestion budget. Sui nets every
  deposit to an address in each commit, so ten thousand bids to one launch
  settle as one balance update.
- Settlement waits ten seconds after the end. By then every bid's deposit has
  settled, so the balance settlement reads includes every bid.
- Delivery is the only step that writes the launch once per bid. It runs during
  the delivery window, when nobody is trading. The protocol limits allow about
  500 bids per transaction; the gas of a full batch is not measured yet.

## Edge cases

- **SUI sent to the launch's address** before settlement joins the pot. It buys
  tokens no bid claims, and they stay in the launch. It makes the price slightly
  worse for every bidder and costs the sender the whole amount, so nobody gains
  by doing it. SUI sent after settlement cannot be recovered.
- **Migration before delivery.** An oversubscribed presale can make the launch
  ready to migrate at settlement. Migration waits for the delivery window like
  trading does, and delivery still works after migration.
- **Your wallet shows nothing during the presale.** The bid belongs to the
  launch, not to you. Apps list your bids from the `PresaleJoined` events and
  show the tokens once they are delivered.
- **Delivery is Blast's job, not the contract's.** The contract holds trading
  back for the delivery window. A bid still undelivered when trading opens
  gets its tokens later, at the same share, and cannot sell until then.
- **Many tiny bids** each need their own delivery. That costs whoever sends
  them gas and storage, and there is no minimum bid by design.

## For integrators and keepers

- **Creator:** `launch::set_presale` on the initializer before `finalize`. Zero
  means no presale.
- **Bidders:** `launch::join_presale`, which takes the launch read-only and a
  `Coin` of the Quote. The bidder is the sender.
- **Anyone, from the end plus 10 seconds:** `launch::settle_presale`. It also
  takes the accumulator root, the shared object `0xacc`, read-only.
- **Keeper:** `launch::deliver_presale`, once per bid, with a receiving ticket
  for one of the `BlastPresaleBid` objects the launch owns. Batch the
  deliveries, and after a congestion cancellation rebuild the batch without the
  bids already delivered.
- **Traders and migrators:** `buy`, `sell` and `migrate` take the `Clock` and
  wait for the trading time that `PresaleSettled` announces.

The events `PresaleJoined`, `PresaleSettled` and `PresaleDelivered` are enough
to rebuild every bid's outcome.
