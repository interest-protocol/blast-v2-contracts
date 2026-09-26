# 0096: The presale pays into the launch's address balance

- Status: accepted
- Date: 2026-09-26
- Supersedes: [0093](0093-optional-opening-round.md)

## Context

ADR 0093's opening round is a uniform-price batch: bids join one pot, the pot
buys the curve once, and each bidder receives its share. On 2026-09-26 the
founder asked for a presale that holds up against the current market, and the
design was agreed with a second reviewer (Fable) after two rounds. The research
behind it found:

- A fixed-price sale that lists straight on a DEX is priced by its creator,
  pops, and then falls; most 2025 launches ended below their launch valuation.
- First-come sales are always captured by bots or wallet farms. Pro rata at one
  price, with a refund of the excess, is neutral to wallet splitting.
- A large gap between the sale price and the listing price invites flipping.

The opening round already had the right economics. It failed at volume: every
bid wrote the shared launch (a dynamic field per bidder and the pot balance), so
a busy presale would queue on one object's congestion budget, cancel bids, and
start a gas auction. Its window was also capped at five minutes.

## Decision

**Setting.** `set_presale(presale_ms)` replaces `set_opening_round`. Zero, the
default, has no presale. Otherwise `finalize` requires one minute to 72 hours,
and the launch starts in `Presale`, which replaces `OpeningRound` as the first
lifecycle tag.

**Joining reads the launch.** `join_presale` takes `&Launch`. It sends the
bid's Quote to the launch's address balance with `balance::send_funds` and
transfers a new `BlastPresaleBid { bidder, quote }` to the launch's address.
Neither writes the launch. Joins are accepted until `presale_ms` after share;
before share only the creator's transaction reaches the launch, so the creator's
bid joins the same pot. A zero bid aborts. Bids cannot be withdrawn: that would
need `&mut Launch`.

**Settlement.** Once `presale_ms + presale_settlement_delay_ms` (10 seconds) has
passed since share, anyone may call `settle_presale` with the accumulator root.
It reads the launch's settled address balance, withdraws all of it, and buys the
curve once through the same path, fees, and graduation cap as `buy`. The Meme
bought and any Quote refunded past the target are held for delivery;
`presale_pot` records the pot. Trading opens at
`trading_opens_ms = settlement + min(presale_ms, max_delivery_window_ms)`, with
the window capped at five minutes. A pot that reaches the target makes the
launch `MigrationReady`.

**Why settlement sees every bid.** A join needs `clock < end`, and settlement
needs `clock >= end + 10 s`. The clock is fixed per consensus commit, so the
strict deadline alone puts settlement in a later commit than every join. Every
transaction in a settlement batch reads the accumulator version settled before
it, so the balance settlement reads includes every bid. The 10 seconds are
margin, not the guarantee.

**Delivery.** Anyone may `deliver_presale` one bid, passed as
`Receiving<BlastPresaleBid>`, in any lifecycle after `Presale`, migration
included. It receives and deletes the bid and sends its bidder
`held × bid / presale_pot`, rounded down, for both the Meme and the Quote. It
then subtracts the bid from `presale_pot`. The result does not depend on
delivery order beyond rounding. `presale_pot` can never fall below zero:
nothing but settlement withdraws the balance, so the pot is at least the sum of
the bids. Blast's keeper delivers in batches during the window.

**Trading window.** `buy`, `sell`, and `migrate` take the `Clock` again and
abort with `trading_not_open` before `trading_opens_ms`, which is zero without
a presale. The lifecycle is still `[Presale ->] Live -> MigrationReady -> Migrated`.
There is no `Delivery` state and no call that opens trading.

**Donations.** Quote anyone sends to the launch's address before settlement
enlarges the pot. It buys Meme that no bid claims, and that Meme stays in the
launch with the rounding dust. Quote sent in the settlement's commit or later
cannot be recovered.

**Events.** `LaunchCreated` carries `presale_ms`.
`PresaleJoined { launch_id, bid_id, quote }` names no bidder, since the bidder
is the sender. `PresaleSettled { launch_id, pot, meme, quote, trading_opens_ms }`
records the settlement. `PresaleDelivered { launch_id, bid_id, bidder, meme, quote }`
names the bidder, who can differ from the sender.

**Errors.** Codes 13, 18, 19, and 34 keep their numbers and are renamed
`invalid_presale`, `presale_ended`, `presale_not_settleable`, and
`zero_presale_bid`. Code 35, `trading_not_open`, is new.

## Alternatives considered

- **A fixed-price presale that lists on a DEX.** The creator sets the price,
  which is the main reason sales fail. There is a failure-and-refund path, and
  Blast would custody the raise.
- **Continuous clearing or uniform-price auctions.** They need an on-chain price
  book and cannot be explained in one sentence.
- **Keeping the per-bidder dynamic field.** Every bid writes the shared launch,
  which caps throughput at one object's congestion budget.
- **Sharding the pot across several objects.** Address balances already net
  every deposit per commit, so shards add storage and settlement work for
  nothing.
- **A presale cap below the graduation target.** It creates a cheaper cohort
  than the public.
- **Insider vesting at migration.** It was deferred by founder decision; the
  launch page discloses the creator's allocation instead.

## Consequences

- Joining uses no congestion budget on the launch. Read-only shared inputs are
  not charged, and a deposit to an address balance takes no object input.
- Settlement needs the accumulator root (`0xacc`) as an immutable input. The
  SDK needs its initial shared version.
- Bidders' wallets show nothing until delivery, because the bid object belongs
  to the launch. The SDK lists bids from `PresaleJoined`.
- The keeper must deliver every bid. Each delivery creates up to two coins, and
  the deleted bid's storage rebate goes to whoever delivers. The protocol limits
  allow about 500 deliveries per transaction; the gas of such a batch is not
  yet measured.
- Tokens reach a bidder when its bid is delivered, not at settlement. The
  contract delays trading by the delivery window; delivering every bid inside
  it is the keeper's job.
- There is no minimum bid. Many one-atom bids each need a delivery. That costs
  the attacker gas and storage, and the deliverer collects the rebates. It is
  accepted, since caps and minimums were ruled out as dials.
- **Publication precondition.** Settlement needs the accumulator root and the
  `enable_accumulators` and `enable_object_funds_withdraw` protocol features.
  Without the latter, `withdraw_funds_from_object` aborts: the launch stays in
  `Presale`, and its bids' Quote stays in its address balance with no way out.
  Move code cannot read the flag to fail closed at `finalize`. Before any
  presale launch is created on a network, the deployment checks those features
  and dry-runs a funded `settle_presale` there. The design research read both
  as enabled on live mainnet at protocol version 137 on 2026-09-26; that
  reading is a premise the deployment check must confirm.
- **Accepted residual.** If settlement ever read less than the sum of the bids,
  for example after a protocol change to accumulator visibility, deliveries
  would abort on the division or the pot subtraction. The remaining Quote would
  stay in the launch's address balance, which only settlement can withdraw.
  There is no recovery path; adding one would need an administrator who can
  move bidders' funds.
- The launchpad ABI, lifecycle tag names, event layouts, and error names change.
  The SDK, the indexer, and the migrators' call to `migrate` (which now passes
  the `Clock`) follow.
- The graduation economics are the ones ADR 0092 left to the creator. The SDK's
  presale preset should keep the virtual Quote at least four times the target,
  so an oversubscribed presale lists at most 1.25 times the bidders' price.

## Verification

- Move unit tests cover every presale guard and its precedence, including the
  stale package version, lifecycle before the trading window, the window before
  the migration witness, and a bid delivered through another launch. The
  settlement guards run on the production `settle_presale`; the Move test VM
  cannot settle accumulators, so it reads an empty pot. Funded settlements use
  a test-only seam that supplies the pot. The tests also cover pro-rata
  delivery and order independence, donations, the delivery window and its
  bounds, migration before the window opens, and delivery after migration.
- The migrators' replay test reduces `PresaleJoined`, `PresaleSettled`, and
  `PresaleDelivered` into a model that must equal every getter and each bid
  object the launch owns.
- Release gate: the PTB harness's
  `presale_bids_pay_the_launch_address_and_settle_from_its_settled_balance`
  runs the address-balance path in simulacrum. It covers join, the checkpoint
  that settles deposits, settlement from the settled balance, and delivery by
  `Receiving`. It has not been compiled yet (the harness needs a Sui rebuild),
  so it must pass before publication. Simulacrum runs no validator-side
  post-execution funds check, so the harness proves the read and the amounts,
  not that check.
- Release gate: a localnet or testnet load test with 10,000 joins, and a
  `send_funds` check with a regulated Quote such as USDC.

## Sources

| Ref | Revision | Path |
| --- | --- | --- |
| FW | MystenLabs/sui `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` (launchpad `Move.lock`) | `crates/sui-framework/packages/sui-framework/sources/balance.move:102-126` (`send_funds`, `redeem_funds`, `withdraw_funds_from_object`, `settled_funds_value`); `transfer.move:139` (`receive`) |
| DM | MystenLabs/sui `51d177ad7d65102fc368b582408f466d97b31548` (PTB harness pin) | `crates/sui-core/src/accumulators/design_docs/data_model.md:104` (one accumulator version per settlement batch); `object_funds_checking.md` (object withdrawals checked after execution) |
| TC | MystenLabs/sui `51d177ad7d65102fc368b582408f466d97b31548` | `crates/sui-transaction-checks/src/lib.rs:645` (the accumulator root is taken immutably); `crates/sui-core/src/authority/shared_object_congestion_tracker.rs:223` (only exclusive access is charged) |
