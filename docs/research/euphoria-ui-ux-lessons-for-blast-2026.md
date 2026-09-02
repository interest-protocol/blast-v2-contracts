# Euphoria UI/UX lessons for Blast meme discovery

- Date: 2026-08-31
- Status: product-design spike; no implementation decision
- Scope: Euphoria's current first-party product, documentation, and deployed web
  assets, compared with Blast's current prototype source
- Evidence: first-party Euphoria sources and this repository only

## Recommendation

**Add a full-screen `Reel` discovery mode for Blast, but do not turn meme buys
into Euphoria's wagering grid.** One meme should own the viewport. Its identity,
thesis, live market motion, bonding progress, reason for appearing, and fixed
buy amount should stay visible while the user swipes between memes.

This should be a third mode beside `Arena` and `Rows`, not a replacement. Blast
already has most of the foundation in the unused
[`DiscoveryFeed`](../../../web/src/components/launchpad/DiscoveryFeed.tsx) and
[`CoinEpisode`](../../../web/src/components/launchpad/CoinEpisode.tsx). The
current application routes discovery to `ApeBoard`, and its toggle exposes only
`Arena` and `Rows`
([`BlastScrollApp`](../../../web/src/components/launchpad/BlastScrollApp.tsx),
[`DiscoveryModeToggle`](../../../web/src/components/launchpad/DiscoveryModeToggle.tsx)).

The core product distinction is important:

- Euphoria's unit is a disposable, five-second binary position.
- Blast's unit is a meme with identity, a creator, a thesis, a bonding lifecycle,
  a persistent asset position, and a post-graduation history.

Borrow Euphoria's focus and feedback. Preserve Blast's context and explicit
risk information.

## What Euphoria's experience gets right

### 1. The market is the entire surface

Euphoria does not put a chart inside a dashboard card. Its trading surface is a
full-screen coordinate system: price is the vertical axis, time is the
horizontal axis, the price line advances into future squares, and each square
contains its current multiplier. The user acts directly on the market graphic
instead of moving from chart to order form
([official trading guide and screenshots](https://docs.euphoria.finance/euphoria/how-to-tap-trade)).

The result is unusually legible causality: `tap this place`, then watch the live
line either touch or miss it. Continuous motion is useful because it changes the
meaning of the action, not because the page needs decoration.

### 2. Persistent controls remove repeated form work

The official screenshots keep four important controls at the edges of the
surface:

- the current asset and price at the upper left;
- sound and settings at the upper right;
- wallet balance at the lower left; and
- the fixed per-tap amount at the lower right.

The user sets the stake once; every square then becomes a valid action target.
Euphoria documents a `$0.10` default and a bottom-right size selector
([trading guide](https://docs.euphoria.finance/euphoria/how-to-tap-trade),
[FAQ](https://docs.euphoria.finance/euphoria/faq)). Funding is a separate wallet
sheet with crypto and fiat routes instead of a prerequisite form embedded in
the trading surface
([trading guide](https://docs.euphoria.finance/euphoria/how-to-tap-trade)).

This is progressive disclosure done well: the frequent decision stays on the
surface; account, funding, history, and settings move to secondary sheets.

### 3. Feedback happens at the point of consequence

The official win screenshot layers feedback without navigating away:

- the selected square remains visible;
- a burst appears where the price line reaches the result;
- a `+$...` label appears beside that point;
- a profit toast appears at the top; and
- the wallet balance receives a secondary delta.

The spatial event, numerical result, and account effect all agree
([official trading guide screenshots](https://docs.euphoria.finance/euphoria/how-to-tap-trade)).
This is stronger than a generic success toast because it explains what just
happened and where.

### 4. Sound and haptics are product states, not one global click

The current deployed app includes separate sounds for chart taps, profiles,
leaderboards, settings, asset selection, panels, and bets. It exposes separate
music and sound-effect mute and volume controls
([deployed audio module](https://euphoria.finance/assets/audio-context-D4whTKYu.js)).
Its haptic module supports light/medium impact, success, error, and selection
feedback through Telegram APIs or device vibration, and the Telegram app asks
for full-screen mode
([deployed haptic module](https://euphoria.finance/assets/use-haptic-feedback-IjaN_iLk.js)).

The transferable lesson is semantic feedback: selection, submission, success,
and failure should not sound or feel identical. These effects must remain
optional and respect reduced-motion and mute preferences.

### 5. Social proof stays close to the action

Euphoria's deployed trade screen includes tracked active traders and transient
win amounts on the market surface; the official product then turns performance
into a weekly/all-time leaderboard, shareable profit card, profile history, and
referral link
([deployed trade module](https://euphoria.finance/assets/trade-DvsKRun9.js),
[trading-guide screenshots](https://docs.euphoria.finance/euphoria/how-to-tap-trade)).
Its Tapathon made the loop explicit: equal starting balances, real-time PnL
rankings, prizes, and later referral credit
([Tapathon](https://docs.euphoria.finance/euphoria/tapathon)).

The share card is especially transferable. It creates a branded artifact from
the exact market moment instead of sharing a generic product URL.

### 6. Errors use recovery language

Euphoria maps protocol-style failures to short next actions: try another square,
reduce size, wait, or add funds. Slippage protection rejects execution rather
than silently accepting a materially worse multiplier
([FAQ](https://docs.euphoria.finance/euphoria/faq),
[platform description](https://docs.euphoria.finance/euphoria/about-the-platform)).

## What Blast should not copy

1. **Do not copy the five-second urgency loop.** Euphoria's own terms require
   more than 100 taps on three separate days for a weekly reward. That optimizes
   frequency, not understanding
   ([Euphoric Mondays terms](https://docs.euphoria.finance/euphoria/euphoric-mondays)).
   Blast should not add expiring buy prompts, artificial countdowns, or streaks
   for raw trade count.
2. **Do not make loss or cost secondary.** Euphoria's grid foregrounds payout
   multipliers; the complete-loss condition is explained in documentation.
   Blast should keep spend, estimated receive, fees, slippage, and price impact
   beside the action, especially for a real transaction
   ([trading guide](https://docs.euphoria.finance/euphoria/how-to-tap-trade)).
3. **Do not use raw PnL as the primary social rank.** It rewards risk-taking and
   is easy to distort. Blast's product direction already rejects raw activity
   points and unexplained rankings in favor of explainable discovery and durable
   judgment
   ([product direction](../../../web/docs/product/grill-me-and-explainable-discovery.md)).
4. **Do not hide meme-specific facts to obtain visual simplicity.** Creator,
   quote asset, supply mode, bonding progress, migration venue, and the reason a
   meme appears are part of the product, not advanced settings.
5. **Do not auto-buy on swipe or scroll.** Navigation and financial intent must
   remain separate. Continuous market motion must pause on interaction and for
   reduced-motion users, as Blast's Arena already does
   ([`ApeBoard`](../../../web/src/components/launchpad/ApeBoard.tsx)).

## Blast's current foundation

The current prototype already contains two different directions:

- The active `Arena` is a full-height, continuously moving spatial field of up
  to 32 meme tiles. It pauses for pointer, focus, touch, wheel, reduced motion,
  or an open inspector. Selecting a tile opens an inspector with market facts,
  bonding progress, social signals, buy/sell, and details
  ([`ApeBoard`](../../../web/src/components/launchpad/ApeBoard.tsx)).
- `Rows` is a dense comparison table with identity, market cap, volume,
  holders, stage, change, signal, and a quick-buy action
  ([`ApeBoard`](../../../web/src/components/launchpad/ApeBoard.tsx)).
- The dormant `DiscoveryFeed` already implements snap-like full-height episodes,
  arrow/Page key navigation, active-item observation, `For You`, `Following`,
  `Graduating`, and `New` feeds, and restoration by coin identity
  ([`DiscoveryFeed`](../../../web/src/components/launchpad/DiscoveryFeed.tsx)).
- Each existing `CoinEpisode` already has full-bleed art, lifecycle and trending
  marks, creator/follow, thesis, market facts, bonding progress, `Why this is
  moving`, social actions, and a persistent fixed-size quick buy with a separate
  amount control
  ([`CoinEpisode`](../../../web/src/components/launchpad/CoinEpisode.tsx)).
- The shared quick-buy path already quotes the trade, checks the demo balance,
  commits the simulated fill, announces the result, and plays distinct success
  or error sounds. Arena then animates the bought coin into the persistent bag
  ([`BlastScrollApp`](../../../web/src/components/launchpad/BlastScrollApp.tsx),
  [`ApeBoard`](../../../web/src/components/launchpad/ApeBoard.tsx)).

The product gap is therefore routing and hierarchy, not a new design system.

## Proposed `Reel` experience

Each swipe or wheel step moves exactly one meme into the active viewport:

```text
feed tabs + search                         top edge

full-bleed meme art
live price/curve trace and bonding motion  main stage

$TICKER · creator · thesis
market cap · 1h · bonding progress
Why this is moving                         lower context

watch · discuss · share                    side rail
[ Review buy · 1 SUI ] [ amount ]          anchored action
bag value / position delta                 bottom edge
```

For the prototype, the current simulated quick buy can remain a direct action.
For real execution, the first tap should stage a compact quote sheet with the
spend, estimated receive, fees, slippage, and price impact; the explicit confirm
submits the transaction. A future consciously enabled session mode could remove
that second step, but it should not be the default assumption.

On a successful buy, keep the user in the episode. Animate the meme into the
bag, update the position/bonding state in place, announce the exact fill, and use
one short semantic sound/haptic. On failure, keep the same context and name the
recovery action. This copies Euphoria's causal feedback without copying its
binary-bet cadence.

Social output should be a branded lifecycle card: `I backed $MEME at X% bonded`,
with the creator, thesis, current/then state, and direct launch URL. Avoid a
profit-only card or a taps leaderboard. If Blast ranks users later, rank durable
judgment after an observation window, consistent with the existing product
direction.

## Smallest validation path

1. Expose the existing episode feed as `Reel` beside `Arena` and `Rows`.
2. Reuse the existing `CoinEpisode`, quick-buy amount, bag animation, sounds,
   explainable signal, and feed state. Add no protocol work.
3. Test five representative launches on phone and desktop with motion on and
   reduced motion enabled.
4. Measure whether users can name the creator, spend, bonding state, and reason
   for appearance before buying. Also measure qualified coin opens, staged-buy
   completion, accidental cancellation, and return-to-feed rate.
5. Keep the mode only if it improves qualified discovery or buy completion
   without reducing comprehension of spend and launch context.

The decisive idea is **one meme, one viewport, one visible next action**. The
moving UI should make Blast's live launch lifecycle understandable, not make a
memecoin purchase feel like a five-second wager.
