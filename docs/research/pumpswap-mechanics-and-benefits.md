# PumpSwap mechanics and benefits for a Blast-owned V2

Research captured 2026-09-05. This is a design comparison, not a decision to
implement or a verification of deployed Solana configuration. Primary sources
only. Pump's public documentation repository was read at commit
[`9c82f61cb711b044a17f770ab8ce9f9bdf78f333`](https://github.com/pump-fun/pump-public-docs/commit/9c82f61cb711b044a17f770ab8ce9f9bdf78f333),
dated 2026-07-15; official production fee pages were checked separately today.

## What PumpSwap actually does

Pump identifies PumpSwap as a constant-product AMM. It supports creating pools,
swaps, LP deposits, and withdrawals. Its deposit interface requests an exact
LP output subject to maximum token inputs. The initial two deposited amounts
set the starting price. Its internal LP supply preserves the share represented
by directly burned LP tokens; redeeming LP through withdrawal is treated
differently. These are useful patterns for Blast's proportional deposits and
permanent liquidity commitment.
[PumpSwap program documentation](https://github.com/pump-fun/pump-public-docs/blob/9c82f61cb711b044a17f770ab8ce9f9bdf78f333/docs/PUMP_SWAP_README.md)

Modern PumpSwap has more features than a bare Uniswap-V2-style design:
quotes must use actual quote reserves plus `virtual_quote_reserves`.
The pinned documentation says this added field was zero in all pools at the
time of writing. That statement is not a current live-pool audit. Blast need
not reproduce this extension to build an ordinary constant-product AMM.
[Effective reserve instructions](https://github.com/pump-fun/pump-public-docs/blob/9c82f61cb711b044a17f770ab8ce9f9bdf78f333/README.md#pumpswap-update-virtual-quote-reserves)

For graduated launches, Pump's `migrate` transfers the completed curve's
liquidity to PumpSwap and burns the received LP tokens. Migration is
permissionless and idempotent. That replaces the older privileged withdrawal
and off-chain Raydium migration path. LP burning commits the liquidity; it
does not burn the underlying meme tokens sitting in the pool.
[Pump program and migration](https://github.com/pump-fun/pump-public-docs/blob/9c82f61cb711b044a17f770ab8ce9f9bdf78f333/docs/PUMP_PROGRAM_README.md)

## Current fees versus historical examples

The current official fee page lists **0.015 SOL on graduation**, not zero.
Its SOL canonical-pool schedule begins at 1.25% for market caps below
420 SOL, becomes 1.20% in the next band, and steps down to 0.30% at
98,240 SOL and above. Most bands allocate 0.20% to LPs and 0.05% to
the protocol, with a changing creator component. The lowest band differs:
0.02% LP, 0.93% protocol, 0.30% creator. USDC pools have their own
threshold table. Noncanonical pools currently list 0.30% total: 0.25%
LP, 0.05% protocol, zero creator fee. These are published rates, not an RPC
inspection; the page says smart contracts determine actual charges.
[Official fee schedule](https://pump.fun/docs/fees)

The pinned migration documentation describes a `pool_migration_fee` intended
to cover account-creation costs, with an example of 15,000,001 lamports.
Its prose contains an arithmetic inconsistency when comparing that value
with 15,000,000; treat it as explanatory documentation, not precise live
accounting. Waiving a commercial migration charge does not make network and
account-creation costs disappear. The older 0.25% swap example in the
PumpSwap README also predates the current published fee schedule above.
[Migration configuration example](https://github.com/pump-fun/pump-public-docs/blob/9c82f61cb711b044a17f770ab8ce9f9bdf78f333/docs/PUMP_PROGRAM_README.md#global),
[older AMM fee example](https://github.com/pump-fun/pump-public-docs/blob/9c82f61cb711b044a17f770ab8ce9f9bdf78f333/docs/PUMP_SWAP_README.md#globalconfig)

The historical zero-migration-fee launch claim was located as a quoted
announcement, but the original X page could not be fetched. This report does
not use that inaccessible announcement to override today's official page.

## Dynamic fees and fee destinations

Pump's fee-program reference selects a fee tier from the pool's reserve-based
market capitalization for canonical pools. It uses flat fees for other
pools. Canonical status is determined from the Pump pool authority, not
from any creator-supplied label. The published reference is a market-cap
schedule, not a volatility-sensitive DLMM algorithm. Its example accepts a
trade-size parameter but does not use it in the shown tier-selection logic.
[Fee-program reference](https://github.com/pump-fun/pump-public-docs/blob/9c82f61cb711b044a17f770ab8ce9f9bdf78f333/docs/FEE_PROGRAM_README.md)

Creator fees are separately routed to a creator vault in the pool's quote
asset. They are separate from both retained LP fees and protocol fees;
claiming a creator fee does not require redeeming migrated LP principal.
The announcement file describes historical activation defaults, so its
zero-fee examples must not be treated as current rates.
[Creator-fee integration](https://github.com/pump-fun/pump-public-docs/blob/9c82f61cb711b044a17f770ab8ce9f9bdf78f333/docs/PUMP_SWAP_CREATOR_FEE_README.md)

Pump also has a separate protocol-token buyback program. Its current official
page says 50% of defined net revenue buys and burns **PUMP**, with a one-year
programmatic commitment starting 2026-04-28. Its revenue definition includes
bonding curves, PumpSwap and Terminal, net of stated deductions and excluding
Mayhem. This is neither burning graduated LP receipts nor automatically
burning every launched coin's supply. The percentages and commitment are
Pump's published policy, not a transaction-by-transaction verification here.
[Official PUMP buyback-and-burn page](https://pump.fun/pump-token)

## Implications for Blast — design judgments

A small Blast V2 has a clear role in the user's proposed two-stage rollout:

1. Keep selected external migration destinations. Route the auto-LP vault's
   claimed entitlement into one Blast Meme/Quote pool, using available paired
   amounts and retaining unmatched balances.
2. Offer direct migration to that same AMM design as an explicit launch choice.
   A waived Blast migration charge can leave more quote liquidity in that
   destination, if the accounting sends the saving into pool reserves.

The benefit of owning the AMM is control over reserve/LP behavior and fees on
trades executed there. It removes the need for separate external deposit
implementations in the auto-LP flow. It does not remove external fee-collection
adapters, create paired assets from one-sided fees, or capture trades executed
entirely in another venue. Pump's documents establish mechanics; they do not
prove Blast will receive comparable routed volume.

Waiving migration revenue should be compared with **incremental net** trading
revenue. If a waived fee is `F` quote units and the additional retained fee
rate is `r`, the simplified gross break-even volume is `F / r`. For example,
waiving 100 SUI and adding five basis points of net retained revenue requires
200,000 SUI of cumulative volume. This is an illustration, not Blast's
configured fee or a volume forecast; include ongoing costs and revenue already
earned through the external migration position in a real comparison.

Keep three independent choices explicit:

- **LP compounding:** leave LP swap fees in reserves. No claim-and-redeposit
  loop is needed for that fee component.
- **Locked liquidity:** hold nonwithdrawable LP shares, or implement a correct
  permanent-share accounting mechanism. Destroying LP receipts while reducing
  the denominator can donate the share to remaining LPs instead of preserving
  the intended locked allocation.
- **Token burning:** allocate an explicit creator/protocol fee entitlement to
  token burns. A quote-denominated entitlement needs a separate conversion to
  buy and burn Meme; this is outside the approved no-balancing-swap auto-LP
  flow. Direct Meme-fee burns and auto-LP also compete for the same available
  asset, so their budgets must be separate.

Dynamic fee selection can be layered onto a constant-product pool without
implementing V3 or DLMM liquidity math. A fixed fee is the smallest launch
surface. If dynamic fees are included, a bounded, fully specified schedule
with precise rounding and quote parity is manageable; a price-sensitive
schedule additionally needs manipulation analysis. Pumpswap's existence is
evidence that concentrated liquidity is unnecessary for this product shape,
not evidence that an arbitrary copied fee schedule is safe or optimal.

For Blast's current purpose, V3/DLMM adds range or bin management and more
accounting without being required for fee-funded permanent liquidity. The
tradeoff of full-range V2 is lower capital concentration near the current
price. Actual swap quality depends on funded depth and fees. The recommended
scope is one simple constant-product destination, correct proportional LP
accounting, distinct fee entitlements, and external quote/router support;
defer range/bin mechanics until measured execution quality demands them.
