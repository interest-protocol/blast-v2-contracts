# Meme-launchpad feature benchmark and migration-fee design

- Date: 2026-08-24
- Scope: current launchpad mechanics relevant to Blast V2 on Sui, especially graduation revenue
- Method: first-party product documentation, official source code, and Blast's own design records
- Status: research input only; its venue-cost recommendation is superseded by accepted [ADR 0027](../decisions/0027-graduation-economics-and-migration-witnesses.md)

## Executive recommendation

Blast's accepted design models two separate terminal accounting lines:

1. a **quote-asset migration fee**, denominated in Quote and therefore SUI when Quote is SUI;
2. a **protocol Meme graduation fee**, denominated in Meme.

Migration implementation identity is separate from accounting: each launch
selects one allowlisted external migrator witness type. DEXs requiring a
pool-opening payment are not supported, so there is no venue-cost field or third
asset.

The admin may update bounded defaults for **future launches** at any time. Each launch must copy its effective terminal rates into immutable launch state before trading opens. Existing launches must not be repriced: these deductions change the assets that reach the DEX, the graduation value, and possibly whether migration can succeed.

That differs from Blast's accepted live protocol/creator share for trading fees. The live share only divides the launcher's already-fixed total trade fee on subsequent trades and never reclassifies accrued balances. A terminal rate changes net pool-seeding assets, so it must be snapshotted.

Blast's historical Memez code already used this safer pattern. A new pool copied its fee configuration, reserved the meme allocation from initial supply, and stored a concrete quote migration fee later deducted from the migration quote coin. The admin fee setter replaced the template read by later launches; it did not rewrite the copied economics of existing pools. See pinned [pool creation and migration](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/pump.move#L76-L218), [admin fee setter](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/config.move#L130-L136), and [fee/allocation construction](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/structs/fees.move#L214-L245).

## Blast V2 baseline and gap

Blast already has one permissionless virtual-liquidity constant-product curve, explicit Configured → Live → MigrationPending → Migrated states, launch-fixed quote/meme trade rates, an accepted dual-asset fee ledger, a live global protocol/creator trade-fee split, typed migration adapters, and a permanent LpVault. Local sources: [protocol scope](../protocol-scope.md), [curve](../decisions/0004-bonding-curve.md), [fees](../decisions/0006-fees-and-launch-paths.md), [migration](../decisions/0010-migration-and-venue-adapters.md), and [accepted dual-asset trade ledger](../decisions/0022-dual-asset-fee-ledger-and-claims.md).

The narrow gap is that ADR 0006 proposes only a quote-side migration fee. A protocol Meme graduation fee changes supply disposition and terminal accounting. It therefore needs a fee-policy ADR and new shared vectors; it should not be folded silently into the accepted trade-fee ledger.

Two-asset migration accounting is not exotic infrastructure: Meteora DBC's official account schema
tracks protocol migration fees separately in base and quote, alongside pool-creation, creator, partner,
referral, vesting, and liquidity settings. [Meteora DBC accounts](https://github.com/MeteoraAg/docs/blob/main/developer-guides/dbc/program/accounts.mdx)

## Current protocol feature matrix

| Protocol | Verified first-party features | Relevant lesson for Blast |
| --- | --- | --- |
| **Memez.Fun / historical Blast** | Pump/Auction constant-product and fixed-price Stable launches; configurable virtual liquidity, target, quote type, sell burn, migration route, allocation, and vesting. Fees are separated into fixed-SUI creation, Meme swap, Quote swap, Quote/SUI migration, and Meme allocation, with configurable recipients. The current official Blast table renders 0 SUI / 0% / 1.2% / 5% / 5%; its flattened recipient table appears to assign the quote swap 80% Blast / 20% Dev and migration/allocation 100% Blast, which should be verified on-chain before being repeated as exact recipient policy. [Configuration](https://docs.interestprotocol.com/overview/sui/memez.gg/memez.fun/configuration), [fees](https://docs.interestprotocol.com/overview/sui/memez.gg/memez.fun/fees), [migrator](https://docs.interestprotocol.com/overview/sui/memez.gg/memez.fun/migrators) | Reuse its **asset separation and launch snapshot**, not its multiple curve modes or broad recipient/config complexity. The old 5% + 5% is evidence, not a V2 default. |
| **Pump.fun** | Constant-product virtual-reserve curve; automatic, atomic, irreversible graduation to a protocol-owned PumpSwap pool. Creation is 0 SOL/USDC, graduation is 0.015 SOL, and the current curve fee is 1.25% split 0.30% creator / 0.95% protocol. Canonical post-grad fees vary by market cap. Pump says fees may change. [Curve](https://pump.fun/docs/bonding-curve), [fees](https://pump.fun/docs/fees) | Automatic graduation and an explicit fee card are table stakes. A general right to change fees is not a good invariant for an already-live launch's terminal haircut. |
| **Raydium LaunchLab** | Permissionless curve launches with supply, curve allocation, raise target, optional first buy, vesting, creator fees, and CPMM graduation. Launch inputs are fixed after initialization; anyone can trigger graduation and earn a small bounty. Curve swaps layer protocol, platform, and creator fees. Platform configuration selects post-grad fee settings and splits LP between burned and locked shares. Referrals pay 0.1% of pre-grad buys/sells in quote. [Overview](https://docs.raydium.io/user-flows/launchlab-overview), [creation](https://docs.raydium.io/user-flows/creating-a-launchlab-token), [platform config](https://docs.raydium.io/products/launchlab/platform-config), [referrals](https://docs.raydium.io/user-flows/earn-referral-fees-launchlab) | Borrow preset/advanced UX, bounded parameter whitelists, explicit LP disposition, and possibly a bounded migration bounty. Do not import arbitrary curve selection or an in-trade referrer. |
| **Bags** | Seven immutable per-token fee modes vary pre/post-grad fees, graduation threshold, locked supply, and 25% or 50% post-grad compounding. Up to 100 socially identified fee earners share exactly 10,000 bps; an admin can change claimers even though the charge mode/rate cannot change after launch. [Fee modes](https://docs.bags.fm/how-to-guides/customize-token-fees), [launch sharing](https://docs.bags.fm/how-to-guides/launch-token) | Strong precedent for separating an immutable **charge schedule** from updateable **recipient administration**. Blast's transferable CreatorCap remains the smaller first-release primitive. |
| **Moonit** | Classic accelerating and creator-set flat curves, Raydium/Meteora choice, optional creator allocation vested through Jupiter Lock, and flat-curve anti-snipe via UI restriction plus per-trade cap. The detailed curve page separates route costs: 6 SOL Raydium (1 Raydium + 3 OpenBook + 2 Moonit) or 3 SOL Meteora (1 accounts + 2 Moonit). Meteora LP is locked; Raydium LP is burned. [Welcome](https://docs.moon.it/docs/welcome), [curves](https://docs.moon.it/docs/bonding-curves) | Its fee-bearing migration routes illustrate what Blast will not integrate. The LP-disposition disclosure remains useful; conflicting fee/reward pages ([terms](https://docs.moon.it/docs/terms-of-use)) reinforce choosing venues without a pool-opening charge. |
| **SunPump** | No presale/team allocation, buy/sell curve, optional creator pre-purchase in the launch transaction, and automatic SunSwap V2 graduation with LP burn. Docs list about 20 TRX creation, 1% trading, and about 3,000 TRX liquidity-addition cost deducted before roughly 100,000 TRX plus 200M tokens migrate. Referrers receive 10–20% of pre-grad trading fees in biweekly TRX airdrops with a 100 TRX threshold. [Lifecycle](https://docs.sun.io/protocols/sunpump/concepts/how-to-participate/), [launch](https://docs.sun.io/protocols/sunpump/concepts/how-to-launch/), [fees](https://docs.sun.io/protocols/sunpump/concepts/service-fees/), [referrals](https://docs.sun.io/protocols/sunpump/referral/faq/) | Borrow the disclosed same-transaction creator buy and periodic referral UX. Keep Blast's bounded epoch settlement; do not put referral identity into curve trades. |
| **Four.Meme** | Free creation, fixed 1B supply, many quote assets, same-transaction creator buy, 1% curve fee, automatic PancakeSwap seeding, and burned LP. X Mode uses block-decaying anti-bot fees; excess above 1% funds buy-and-burn. Tax Tokens apply launch-selected 1/3/5/10% post-grad tax to burn, dividends, liquidity, and/or a recipient; all tax parameters lock at creation. [How it works](https://four-meme.gitbook.io/four.meme/guide/how-it-works), [LP update](https://four-meme.gitbook.io/four.meme/product-update/3-product-update-25-03-31), [X Mode](https://four-meme.gitbook.io/four.meme/product-update/6-product-update-25-10-30), [Tax Tokens](https://four-meme.gitbook.io/four.meme/guide/introducing-tax-tokens-on-four.meme) | Future-launch-only parameter changes support snapshotting. Do not borrow high token taxes or automatic buyback into core; they obscure fills and add MEV/state complexity. |
| **Clanker** | Social/AI-assisted launch on Base and other EVM chains; optional creator buy, airdrop, vested creator vault, configurable creator rewards, and an optional social agent funded from the token's LP rewards. Its current launch UI discloses a static 1% fee and a short sniper-tax period before signing. [About](https://clanker.world/about), [launch settings](https://clanker.world/deploy), [official documentation source](https://github.com/clanker-devco/DOCS) | Borrow composable launch add-ons and precise fee disclosure. A self-funded social agent is a product-layer experiment, not a reason to put AI or mutable social behavior in Blast core. |
| **Flaunch** | A fixed-price fair-launch window with exits, creator-selected creator/community revenue sharing, fee routing to a bid wall or treasury, optional automatic buybacks, groups, and configurable revenue/staking/buyback managers. Its fee waterfall separates referrer, governance-controlled protocol share, immutable creator share, and community remainder. [Whitepaper](https://docs.flaunch.gg/community/whitepaper), [fee distribution](https://docs.flaunch.gg/developer-resources/guides/fee-distribution), [managers](https://docs.flaunch.gg/managers), [trader flow](https://docs.flaunch.gg/readme/for-traders) | Borrow the explicit revenue waterfall as UI/accounting vocabulary. Defer custom treasury managers and reject automatic buybacks/bid walls in core until they have a Sui-specific MEV and custody design. |
| **Hop.fun** | Current Sui competitor: permissionless/fair launch, no presale/team allocation, about $2 creation, 1B supply with 80% on curve and 20% for migration, migration near a documented $30k market cap, creator fee collection, and market-cap-based post-grad HopV4 fees. [Home](https://docs.hop.fun/), [contracts](https://docs.hop.fun/contracts) | Native Sui launch-to-DEX lifecycle and post-grad creator fees are table stakes. Its public docs do not disclose enough migration-fee, LP-custody, or admin detail to copy those economics. |
| **Turbos.fun** | Current first-party homepage calls it a Sui fair-launch meme platform; the live UI exposes bonding, near-graduation, graduated, featured, and leaderboard states. [Turbos](https://www.turbos.finance/), [Turbos.fun](https://app.turbos.finance/fun/) | Keep it in the competitor and migration-venue watchlist, but do not infer economics from undocumented behavior. |
| **MovePump** | Its official page says the platform shuts down on 2026-08-30 and has already distributed remaining SUI to eligible wallets. [MovePump](https://movepump.com/) | A migration/recovery design must remain operable without the launchpad frontend. Blast's event-complete state and permissionless migration are the right direction. |

## Exact terminal accounting recommendation

| Line | Asset and calculation base | Purpose | Mutability |
| --- | --- | --- | --- |
| **Quote migration fee** | Percentage of real terminal Quote; SUI only for Meme/SUI launches | Blast-owned graduation revenue | Admin updates hard-capped defaults for later launches; rate/ownership snapshots at launch |
| **Protocol Meme graduation fee** | Recommended: reserve a disclosed percentage from initial Meme supply at launch, then release only after successful migration | Blast protocol revenue | Admin updates hard-capped defaults for later launches; amount/rate/ownership snapshots at launch |
| **Migration authorization** | Original `TypeName` of one allowlisted external migrator witness | Authorizes adapter code without a DEX dependency in core | Admin updates the bounded whitelist for future launches; each launch snapshots one type |

Reserving the protocol Meme graduation fee from initial supply is safer than taking a new percentage from terminal curve inventory. A terminal-inventory haircut silently changes the net DEX reserve ratio and post-migration price. If the product insists on that design, the ADR must derive the pool price from **net** seed reserves, disclose the discontinuity, and regenerate curve/threshold/migration vectors.

Some venue interfaces require a separate fee coin; Blast's pinned Bluefin
interface is one example. Such a route is ineligible. Blast does not add a fee
coin, deduct a venue charge from Quote, or create another payer/refund lifecycle.

The Migrated settlement/event should make these conservation lines replayable:

- gross terminal Quote − Blast quote fee = Quote seeded + named Quote residual;
- initial Meme supply = curve inventory + protocol Meme graduation fee + every other approved bucket;
- terminal migration Meme = Meme seeded + terminal burn + named Meme residual; and

Emit gross balances, both Blast lines, selected migration-witness type, net seed
balances, burn/residuals, LP vault identity, and final claimable totals.

## Admin policy

| Setting | Defaults updateable anytime? | Existing launch changes? | Why |
| --- | :---: | :---: | --- |
| quote migration fee | yes, within independent ceiling and old/new event | **no** | changes net quote liquidity and graduation value |
| protocol Meme graduation fee | yes, within independent ceiling and old/new event | **no** | changes supply distribution |
| migration witness whitelist | yes for future launches | **no** | each launch commits to one adapter code identity |
| launch total quote/meme trade rates | no after launch | no | this is the trader-visible charge schedule |
| global protocol share of subsequent trade fees | yes, already accepted | **yes, prospectively** | divides a fixed total fee; prior accrual is untouched |
| accrued fee ownership | no | no | already a settled obligation |
| claim payout destination | capability holder chooses when composing the claim | no reclassification | avoids arbitrary-recipient execution in protocol paths |

Every setter needs its own ceiling, concern-specific admin witness, unchanged-value rejection, and event. LaunchCreated must carry effective snapshotted values, not only a pointer to mutable defaults. A one-way emergency power to **lower** a terminal rate for an existing launch is defensible only if explicitly desired; increases and arbitrary rewrites create a bait-and-switch surface.

## Borrow-now / later / reject

| Disposition | Features |
| --- | --- |
| **Borrow now** | Graduation economics card; immutable per-launch terminal schedule; permissionless witness-gated migration; permanent LP vault with fee-only collection; one recommended preset plus advanced disclosure; same-transaction creator buy at the public curve price and separately labeled |
| **Adapt later** | Bounded graduation bounty; bounded multi-recipient creator sharing separate from the protocol Meme graduation fee; periodic referral payout UX on Blast's already-specified bounded epochs |
| **Reject for initial core** | Retroactive fee increases; creator-defined arbitrary curves; high transfer/tax tokens; UI-only anti-bot advertised as an on-chain guarantee; dynamic launch-fee ramps without a new fee-policy ADR; automatic buybacks; DEX pool-opening charges or third-asset fee paths |

## Decisions and tests required before an ADR

1. Fix the protocol Meme graduation-fee base. Initial supply reserved at launch is recommended; terminal curve inventory is not.
2. Decide whether the fee is protocol-only or includes creator/community shares. A creator share reopens the vesting decision currently rejected for the first release by ADR 0012.
3. Choose independent ceilings and defaults only after simulating graduation price, LP depth, protocol/creator revenue, and non-graduation outcomes. Do not copy the old 5% + 5% blindly.
4. Verify each adapter has no pool-opening charge and can prove its selected sealed witness type.
5. Add shared vectors for zero/either/both fees, ceilings, one-unit rounding, insufficient net liquidity, retry, and recovery.
6. Add event-replay tests reconstructing every gross deduction, net seed, protocol Meme graduation fee, claimable balance, and default change without reading mutable state.

## Evidence limits

Moonit's official pages currently conflict on fee/reward numbers, Hop does not publicly disclose full migration economics, and Turbos publishes no detailed current launchpad fee specification. Those gaps are labeled rather than filled with secondary reports. Competitor numbers also change frequently; Blast should copy sound accounting boundaries and disclosure, never percentages without its own ADR, ceilings, simulations, and vectors.
