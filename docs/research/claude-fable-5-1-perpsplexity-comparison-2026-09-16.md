# Perpsplexity on-chain review and comparison with the Blast leverage coins

- Date: 2026-09-16
- Method: Perpsplexity's four mainnet packages were fetched through Sui
  GraphQL, disassembled with the Sui 1.77 toolchain, and read as bytecode.
  Live objects were read the same day at about 16:00 UTC. Aftermath facts come
  from the pinned move-interfaces revision and Aftermath's public
  documentation. Anything not read from bytecode or a live object is marked
  *inferred*.
- Companion decision: [ADR 0084](../decisions/0084-leverage-coin-design-after-perpsplexity-review.md).

## Packages reviewed

| Package | Id | Published (UTC) | Notes |
| --- | --- | --- | --- |
| Perpsplexity core | `0xaedb8c9a905a778e831aeb4928f660210a7a645925348a7c4ec1cb4a6a3fd16e` | 2026-09-16 05:51 | pool, curve, fees, dividends, hibernation |
| Perpsplexity engine | `0x2ec50cc9740fa5cf75dd7d57e0cb3e1394f3b5cb153806b2168e8e3be681e8c1` | 2026-09-15 04:26 | perp position, shares, margin defense |
| Perpsplexity custody | `0xbf32cfba21310ac40b05d7269f789270c04aae036ab863dc340c3df3d023fd37` | 2026-09-15 04:26 | wraps one Aftermath account and admin cap |
| Perpsplexity yield adapter | `0x67e9a229946236383e6a84a01f185be9b244e4056ff398d7a39d60a19bd2d8dd` | 2026-09-14 22:24 | Suilend sleeve |
| Aftermath Perpetuals V2 | `0x3ec740df8428aa9c93aaef7f8cc1542ac3194fd014826b51bfe245346d64efc7` | — | the same package our pinned interface (`f62e74a`) publishes at |

All four Perpsplexity packages are version 1 and were made immutable in their
publish transaction; no `UpgradeCap` exists. The admin capability moved to a
wallet with ordinary DEX-swap history (*inferred*: a personal wallet, not a
multisig).

Live state: two composite pools and one spot pool, about 12,970 USDC in
total. The largest is a 3x long with about 9,730 USDC of NAV and a 75,000
USDC NAV cap. No dividend epoch had been funded.

## What their product is

A meme-coin launchpad. Each coin has a fixed 1e9 supply minted into its own
pool. The pool prices the coin on a constant-product curve between the unsold
supply and a backing basket. The basket is 80% engine shares (a leveraged
Aftermath position), 10% USDC in the pool, and 10% USDC lent on Suilend,
tunable at launch. Fees fund a treasury, a dividend ledger with lock
multipliers, the platform, and the creator. This is a different product from
ours: our coins are fungible shares minted and redeemed at NAV and intended
as launchpad quote assets.

## The engine, as decoded from bytecode

Engine parameters: `lend_bps <= 4500`, `5500 <= margin_bps <= 10000`,
`100 <= buffer_bps <= 1000`, leverage 1x to 20x, and
`floor(leverage * market_IMR) + 500 bps <= margin_bps`.

Margin placement. At activation the engine sets a per-position initial margin
ratio of `ceil(margin_bps * 10_000 / leverage_bps)` through
`set_position_initial_margin_ratio` (2,750 bps at 2x, 1,834 bps at 3x). It
never sets it again. Every trade ends its session with both auto-allocation
flags on, so Aftermath moves free collateral into the position until that
ratio holds and returns the excess to free balance on reduce-only closes
(*inferred* from the flag positions; the interface body aborts locally).
`lend` then moves `min(45% of NAV - lent, free - ceil(1% of NAV))` to
Suilend. So about 55% of NAV sits in the position, about 44% on Suilend, and
about 1% free.

NAV is `free balance + position collateral + (unrealized PnL + unsettled
funding) / collateral price + Suilend value`, valued at Aftermath's mark
price with no haircut and no freshness, confidence, or divergence check of
its own. One price snapshot serves both the pre-trade and post-trade
readings.

Mint deposits the coin, places a market order sized from
`deposit * leverage` at mark with no price limit, requires an exact fill,
lends, and credits `min(nav_after - nav_before, deposit)`. Redeem closes a
pro-rata lot-rounded size reduce-only, redeems pro-rata Suilend tokens with a
zero minimum, and pays `assets ± (nav_after - nav_before)` from free balance,
so the redeemer bears the whole close cost and receives any favorable
difference. The only protections are a 120-second deadline, the exact-fill
check, and the caller's minimum output.

Margin defense. `margin_shortfall` is the collateral needed to bring the
position back to `max(engine ratio, market IMR)`, not the maintenance level.
`restore_margin` allocates from free balance, then Suilend. `defend_margin`
takes a donor's coin. Both are permissionless. Nothing enforces the order the
whitepaper describes; a caller can spend the pool treasury before lending is
recalled. Nothing detects a liquidation; after one, `mint` keeps sizing new
orders at `deposit * leverage` and the position record is never re-levered.
If Aftermath removes an emptied position record (*inferred*), every engine
entry that reads the position aborts until a trade recreates it with the
market default IMR.

Rebalancing moves at most 5% of NAV per call, may lose at most 1% of the
step plus two units, and must strictly reduce the deviation from the target
split. Sleeve refills and hibernation steps use the same bound. The epoch
reinvestment deposit has no cost bound.

## Contradictions between their whitepaper and their bytecode

| Whitepaper | Bytecode |
| --- | --- |
| "No liquidity to rug" | `activate` mints an `LpPosition` (key + store) for `sqrt(reserve * value) - 1000` to the caller; trades never mint LP, so it is about 100% of `lp_supply`; `remove_liquidity` pays pro-rata reserve plus basket once the curve is retired. |
| Every buy and sell pays 1% | Sells pay only the decaying exit fee. |
| 30-hour half-life | `tau` is an e-folding time; the half-life is about 20.8 hours. |
| Treasury defends only after lending is spent | No ordering; `defend_margin` drains the whole treasury first if called first. |
| Keeper rebuilds the position after liquidation | No rebuild logic exists. |
| Creator's reinvest share every epoch | `fund_epoch_reserved` pays the entire surplus to dividends and anyone can call it first. |
| Locked receipts cannot be sold until unlock | Locks become flexible in wind-down, hibernation, and waking. |
| Parameters can never touch a pool's backing | True narrowly; admin can set the funding buffer floor without bound, which halts dividends, and reset every pool's volume EMA. |

## Comparison with the Blast design

Blast's column describes the reviewed T-001/T-002 baseline of the
`blast-leverage` workflow (commit `87357b9` on `codex/native-dex-auto-lp`),
which supersedes parts of ADR 0064 and is not yet on `main`.

| Topic | Perpsplexity | Blast (baseline `87357b9`; ADRs 0073, 0074) | Verdict |
| --- | --- | --- | --- |
| Share price | Curve between unsold supply and basket | NAV mint and redeem | Keep ours; a quote asset needs NAV. |
| Valuation source | Aftermath mark, no gates | Pyth index and collateral oracle with freshness, confidence, and mark-divergence gates | Keep ours. |
| Collateral placement | 55% allocated, 44% Suilend, 1% free | All NAV and the reserve allocated | Keep ours; see the distance table. |
| Venue orders | Market orders, no limit, exact fill | Sealed side and size, strict and emergency tolerance against the index, post-fill bounds | Keep ours. |
| Credited contribution | `min(delta NAV, deposit)` | delta NAV bounded above by a leveraged divergence allowance | Adopt theirs; it removes two policy values. |
| Liquidation handling | None | Checkpoint classification, fail-closed `sync_health`, off-chain detection, shutdown witness into `Unwinding` | Keep ours; ship the open-from-flat primitive. |
| Funding | `update_funding` when due, then settle, on every operation | `settle_position_funding` only | Adopt the `update_funding` call. |
| Upgrades | Fully immutable; parameters behind a 48-hour timelock | Series1 immutable; adapter upgradeable with a role witness and no delay | Add a delay. |
| Exit when the venue is paused | Cash-only sells with a 5% fee | Fail closed | Keep ours (I11). |
| Reserve sizing | Funding buffer projected from sampled cumulative rates | Fee-funded reserve, no target | Off-chain risk-module signal only. |

### Liquidation distance for a long

`x = (a - m * L) / (L * (1 - m))` is the adverse move that reaches
maintenance ratio `m` for allocated fraction `a` of NAV at leverage `L`.
With an illustrative `m = 5%`:

| Leverage | Fully allocated | 55% allocated |
| ---: | ---: | ---: |
| 2x | 47.4% (bankrupt at 50%) | 23.7% (bankrupt at 27.5%) |
| 3x | 29.8% (bankrupt at 33.3%) | 14.0% (bankrupt at 18.3%) |

The split halves the distance. Its benefit appears only when the position
reaches bankruptcy: the free and lent sleeves survive, and the position's bad
debt is covered by Aftermath's insurance fund, then socialized onto the
opposite side, then auto-deleveraged. With our 2.2x rebalance band and
permissionless emergency deleveraging at the hard cap, the split would only
win against a move past about 40% that no transaction could precede. In every
other regime it liquidates sooner, pays liquidation and insurance fees, and
leaves the product de-levered. It also creates contagion between a long and a
short Series through socialized loss, which ADR 0064 I4 forbids.

## Aftermath facts that change our documents

- Perpetuals V2 is the package both projects link. V1 was exploited on
  2026-04-29 for about 1.14M USDC through a negative integrator fee that
  inflated collateral. V2 was audited by OpenSec and Certora before relaunch.
  ADR 0064 lists Aftermath audit scope as a release gate; this is the input.
- Aftermath documents that socialized bad debt "is added to the funding rates
  of opposing positions and settled when those positions trigger a funding
  update." The baseline's aggregate net-funding checkpoint (workflow decision
  A-002) already treats socialized debt in the accumulator as part of the
  negative change the buffer absorbs first, so the venue's documented path
  matches the accepted rule. ADR 0064's earlier "never presented as funding"
  wording is superseded by the baseline. The controlled-network evidence for
  premises P16 to P20 must reproduce a socialized settlement to confirm the
  documented path.
- `set_position_initial_margin_ratio` is honored at open: Perpsplexity's live
  3x pool allocates exactly to its configured ratio through Aftermath's
  session auto-allocation. This is partial live evidence for premise P18
  (settable and honored). Persistence through a partial liquidation remains
  unproven.
- Free account collateral is documented as "held in the account, can be
  withdrawn anytime" and outside every position's margin, with per-market
  isolation. Perpsplexity's design relies on it. We rely on the opposite
  property, that allocated collateral is margin, which needs no such premise.

## Lessons for the lessons file

- When a permissionless call can draw on more than one source of funds, the
  contract must fix the order. A keeper convention is not enforcement.
- Setting a venue parameter once at activation is not a policy. Every
  checkpoint must recheck it; our checkpoint already carries the position IMR.
- A whitepaper claim about a keeper action ("rebuilds", "recalls first") that
  has no bytecode behind it is a liability, not a feature. Our ADRs must not
  describe keeper behavior the packages do not enforce.
