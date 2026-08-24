# Launchpad market landscape and differentiation

- Date: 2026-08-23
- Scope: product/discovery strategy for Blast V2, not a protocol or economics decision
- Method: current first-party product pages, official documentation, and Blast's own design records only

## Executive conclusion

Blast should not position its bonding curve, DEX graduation, creator fees, referrals, or token-creation
speed as the primary moat. Pump and Raydium already make those mechanics table stakes; Raydium also lets
third parties assemble branded launchpads from shared infrastructure, and Bags already supports social
creator identity and sophisticated fee sharing.

The stronger position is **the launchpad where a launch earns intelligibility and a durable reputation,
not merely volume**. Borrow Product Hunt's maker narrative and permanent product page, then improve on it
with an explainable on-chain ranking and a structured **Grill Me** record. Blast's replay-complete events,
creator-claim design, explicit lifecycle, and immutable post-migration metadata make that credible.

The recommended wedge is:

1. a mandatory or strongly prompted creator thesis followed by an adversarial, public Grill Me;
2. a transparent `Why this is trending` breakdown that discounts easy-to-game activity;
3. a permanent launch page spanning idea, bonding, migration, and post-graduation updates; and
4. identity-aware creator and curator reputation that compounds across launches.

## What Blast is actually building

The repository describes a permissionless Sui meme-token launchpad with one virtual-liquidity,
constant-product curve; bounded fees; explicit bonding/migration/migrated states; migration to Cetus,
Bluefin, or Turbos; creator proceeds controlled by a transferable `CreatorCap`; optional creator claims by
address, SuiNS-resolved address, or an X account; generic quote assets; and off-chain referral attribution
with bounded periodic settlement. The current web app is only a playful prototype shell with Discover,
Launch, Farms, Portfolio, Rewards, and Tools navigation plus New/Bonding/Bonded discovery filters.

Primary local references: [protocol scope](../protocol-scope.md),
[creator claims](../decisions/0013-creator-fee-authority-and-x-claims.md),
[flywheel dispositions](../decisions/0012-flywheel-features.md), and
[the current launchpad prototype](../../../web/src/components/landing/LandingExperience.tsx).

## Current benchmark set

| Product | What it proves | Core mechanics and current first-party evidence | Gap or implication for Blast |
| --- | --- | --- | --- |
| **Pump.fun** | The scale and feature baseline for permissionless token launch | Pump says it facilitated **more than 14 million token launches and over $1B revenue in its first two years**. Its current official token page calls it the world's leading launchpad and reports a live 90-day annualized revenue figure; treat that live number as volatile, but the direction establishes the category leader. Creation is free, curve trades charge creator and protocol fees, graduation moves to PumpSwap, and SOL or USDC can be the paired asset. Discovery currently exposes Movers, Mayhem, New, Charities, Live, market cap, Agents, Oldest, and Last trade. [Launch guide and scale](https://hackathon.pump.fun/launch), [current revenue page](https://pump.fun/pump-token), [fee schedule](https://pump.fun/docs/fees), [Explore](https://pump.fun/explore) | Competing on speed, free creation, creator revenue, graduation, or an activity feed is not differentiation. Pump's own notice also documents the cost of social spectacle: livestream volume grew more than 100x in under a week, hundreds of streams were removed daily, and streaming was paused until moderation could catch up. [Pump community notice](https://pump.fun/docs/moderation-message) |
| **Product Hunt** | The discovery and launch-ritual benchmark outside crypto | Products launch into a daily community leaderboard through submissions, upvotes, comments, and sharing. Each launch has a page; the broader product page becomes a source of truth for launches, reviews, and the product journey. Maker context matters: Product Hunt says 70% of Product-of-the-Day launches had a first maker comment. Product forums can notify a product's followers, extending the relationship beyond launch day. Product Hunt's own product page currently displays 144K followers, but that is an internal follower count, not a disclosed MAU figure. [Launch guide](https://www.producthunt.com/launch), [definitions and ranking](https://www.producthunt.com/launch/definitions), [product forums](https://help.producthunt.com/en/articles/11432379-maker-s-guide-to-product-forums), [Product Hunt's product page](https://www.producthunt.com/products/producthunt) | Product Hunt proves that story, maker access, discussion, and status can create distribution. Its ranking algorithm is explicitly confidential and uses upvotes, time, and undisclosed factors. Blast can make the ranking legible because its economic inputs are replayable. |
| **Raydium LaunchLab** | Launch mechanics are becoming infrastructure, not a unique app | Anyone can create a token, configure a bonding curve and graduation target, then migrate to Raydium. Third-party `Platform` configurations provide branded launch surfaces with custom fees, launch grouping, LP disposition, and creator-fee support. Creators can earn during bonding and after migration; Raydium's default gives the creator a Fee Key NFT representing 10% of ongoing LP-fee rights. Referral links pay 0.1% of trades during the session. [LaunchLab overview](https://docs.raydium.io/user-flows/launchlab-overview), [platform configuration](https://docs.raydium.io/user-flows/launchlab-platforms), [creator fees](https://docs.raydium.io/user-flows/how-creator-fees-work), [referrals](https://docs.raydium.io/user-flows/earn-referral-fees-launchlab) | A launchpad can be cloned at the infrastructure layer. Raydium's own trader checklist says users must inspect the mint, platform, fee settings, migration pool, and LP handling; Blast can turn that configuration burden into a human-readable, immutable launch card and Grill Me questions. |
| **Bags** | Social identity and creator fee sharing are already competitive features | Bags Token Launch v2 supports up to 100 fee earners, identified by X/Twitter, Kick, GitHub, or wallet, with allocations totaling 10,000 bps. It exposes creator profiles, royalties, claim history, custom fee/compounding modes, and partner configurations. [launch and fee-sharing guide](https://docs.bags.fm/how-to-guides/launch-token), [creator records](https://docs.bags.fm/how-to-guides/get-token-creators), [fee modes](https://docs.bags.fm/how-to-guides/customize-token-fees) | Blast's single `CreatorCap` is safer and simpler but is not, by itself, a market differentiator. Bags' docs say an external API wallet displays only an address, while a Bags Login wallet displays social profiles and the API flow may involve exporting the Bags private key. Blast can differentiate with an external wallet plus a one-time social attestation, never an exported platform-wallet key. [Bags identity behavior](https://docs.bags.fm/faq/linking-wallets) |
| **Memez.fun** | The closest Sui precursor and the source of historical Blast behavior | Memez offers virtual-liquidity launches, Bonding/Migrating/Migrated states, Pump/Auction/Stable modes, configurable supply and quote type, mutable metadata, and DEX migration. Its official fee docs already name a Blast.fun configuration and Blast migration path. [Memez overview](https://docs.interestprotocol.com/overview/sui/memez.gg/memez.fun), [configuration](https://docs.interestprotocol.com/overview/sui/memez.gg/memez.fun/configuration), [fees](https://docs.interestprotocol.com/overview/sui/memez.gg/memez.fun/fees) | Blast V2's reduction to one curve and tighter authority model is a reliability advantage, but users will experience it only if the UI makes invariants and lifecycle clearer than the predecessor did. |
| **Turbos.fun / Four.Meme** | Direct chain-specific competition remains active | Turbos calls Turbos.fun Sui's largest meme launch platform and describes each token as a fair launch, but its public page did not expose usable activity totals during this review. Four.Meme's official site describes itself as a public, decentralized, permissionless BNB platform and announced Tax Mode in February 2026; no comparable first-party usage total was located. [Turbos](https://www.turbos.finance/), [Four.Meme announcements](https://four.meme/en/announcement) | Treat both as live competitors, but do not repeat their unverified scale claims in marketing. Their presence reinforces that “fair and permissionless on chain X” is a category descriptor, not a moat. |

## Differentiation opportunities

### 1. Grill Me: turn due diligence into the launch ritual

Every launch gets a short creator thesis and an AI-generated adversarial interview. The questions should
be grounded in launch facts rather than generic banter:

- Who is the intended community, and what evidence exists before the token?
- What do the launcher and visibly linked wallets own after the first buy?
- Why this quote asset and graduation venue; what extra risk do they introduce?
- Who controls creator fees, and what happens if an X-named creator never claims?
- What remains for the community after bonding ends?
- Which claims are verifiable on-chain, which are social assertions, and which remain unknown?

Publish answers, edits, skipped questions, and community challenges on the permanent launch page. A
claimed creator can answer with a verified badge; an unclaimed X launch can visibly show `awaiting
creator`. The AI must be presented as a question generator and summarizer, not as a safety rating or
endorsement.

This combines Product Hunt's high-value maker comment with facts that generic product directories cannot
observe. It also avoids Pump's moderation-heavy livestream trap while still making creators present and
accountable.

### 2. Explainable discovery instead of another hot feed

Add `Why this is trending` to every ranked card. Show the score components and the time window, for
example:

- unique funded buyers and repeat participation, with obvious self-trade/funder clusters discounted;
- sustained activity across 15-minute, 1-hour, and 24-hour windows rather than a single volume spike;
- holder-concentration movement, curve progress, and liquidity depth;
- creator identity/response state and unresolved Grill Me challenges; and
- post-graduation survival and update cadence.

Keep this in the indexer, as the existing ADR already requires; do not add an on-chain leaderboard or
holder collection. Never collapse these signals into an unexplained “safe” score. Product Hunt's
confidential algorithm and Pump's activity-first filters leave room for a ranking users can interrogate.

### 3. Make the launch page a permanent lifecycle record

The page should evolve from `New` to `Bonding` to `Bonded`, preserving:

- the initial thesis and parameter/risk snapshot;
- creator identity and claim history;
- Grill Me answers and community challenges;
- curve and fee history with plain-language explanations;
- the exact migration venue, pool, LP lock/disposition, and immutable metadata point; and
- post-graduation updates, milestones, and creator fee claims.

This imports Product Hunt's durable product page and forum idea into a crypto setting where most feeds
discard attention as soon as trading slows.

### 4. Build reputation around judgment, not raw activity

Give creators a cross-launch record: prior launches, graduation rate, 7/30-day survival, response rate,
unresolved claims, and repeat community participation. Give curators a non-financial forecast card:
`backed before graduation`, thesis, disclosed position, and later outcome. Reward useful questions and
accurate early judgment only after an observation window; do not pay immediately for clicks, posts, or
raw volume, which invites wash activity.

### 5. Productize Blast's identity boundary

Blast can let a community launch for an X creator who has not connected a wallet, accrue that creator's
fees without redirecting them, and later issue one typed on-chain capability after authenticated claim.
Make the states legible: `wallet creator`, `SuiNS resolved at launch`, `X creator unclaimed`, or `X creator
claimed`. This is more defensible than a generic social badge, but Bags means the message must emphasize
external-wallet ownership, one-time claim semantics, and the absence of repeated platform approval.

### 6. Turn quote-asset choice into community distribution—with warnings

Generic quote assets let ecosystem communities launch in a stablecoin, LST, regulated coin, or partner
asset. Present these as curated lanes or campaigns, but display quote liquidity, issuer/control context,
and the fact that an illiquid creator-controlled quote can make graduation value meaningless. This is a
distribution feature only when paired with strong risk disclosure.

## What not to prioritize

- **Livestreaming at launch:** Pump's direct moderation account shows the operational and safety burden.
- **Raw points for trading, launching, or posting:** they buy activity that is easy to sybil or wash.
- **A secret AI quality score:** it recreates ranking opacity and can be mistaken for investment advice.
- **More launch curves or fully creator-configurable economics:** Raydium already owns the configurable
  infrastructure position; Blast's simpler invariant set is an advantage.
- **On-chain leaderboards/holder sets:** expensive, unbounded, and gameable; the current ADR correctly
  assigns discovery to the indexer.
- **“Verified” badges that imply safety:** verification should name the exact fact—wallet, SuiNS
  resolution, X claim, metadata immutability, or LP lock.

## Smallest useful validation plan

1. Prototype Grill Me as a structured section on five sample launch pages; measure completion, question
   expansion, and whether users can correctly identify creator/fee/migration risks afterwards.
2. A/B-test a normal Trending list against cards with `Why this is trending`; measure qualified token-page
   opens and unique-wallet conversion, not clicks alone.
3. Track `claimed creator`, Grill Me completion, and creator response rate against graduation and 7/30-day
   active-wallet retention. Correlation is not causation, but it will identify the next product bet.
4. Only after the read-only ritual works, add curator forecasts or rewards with delayed outcome scoring.

## Evidence limits

First-party public usage metrics were easy to locate for Pump and not for most competitors. Product Hunt's
144K figure is an on-platform follower count; Turbos and Four.Meme provided no comparable verified total
on the reviewed official pages. No third-party traffic estimates, Dune dashboards, press rankings, or
secondary market-share reports were used. Product gaps above are either direct statements in official
documentation/notices or clearly labeled product inferences from documented mechanics; they are not
presented as user-survey findings.
