# Blast V2: volume fees, separate fee custody and swap burns

Design refinement, 2026-09-05. The user selected a constant-product V2 with
swap-time burns, a fee rate increasing with trading volume, and fees held
separately from trading reserves. This supersedes earlier recommendations to
start with a fixed or time-scheduled fee and to retain LP fees in reserves.
It is a concrete design for review, not implemented or deployed contracts.

Follow-up research: [dynamic-fee comparison and derivation](blast-v2-dynamic-fee-recommendation.md)
recommends exponential volume decay and progressive current-trade charging
instead of the bucketed, pre-trade-only candidate below. It also evaluates
Quote-only fee settlement explicitly, including its auto-LP tradeoff; that
denomination has not yet been selected by the user.

## Purpose and scope

The first destination is a Blast Meme/Quote pool funded by the auto-LP vault's
claimed creator fees from existing external venues. The vault deposits the
usable pair, retains excess and permanently holds the resulting LP position.
The original external migration remains untouched. Direct migration to Blast
V2 is a subsequent optional route; other venues stay available.

Use ordinary constant-product reserve pricing. Do not add ranges, bins, a
general hook engine, balancing swaps or a routing engine. The new requirements
are fee custody, LP entitlements, bounded volume measurement and burn-aware
swap settlement. They belong to the AMM's own transitions and can execute
on-chain. Aggregator quotes must reproduce these transitions exactly.

## Volume-based fee policy

The requirement is that the **percentage rate** increases with measured volume,
not merely that more transactions produce more aggregate fees at a fixed rate.
Neither elapsed time since launch nor market-cap tiers satisfy that requirement.

Recommended measurement: recent Quote-denominated swap volume in this pool,
counting the Quote leg once on each successful swap. External DEX volume,
liquidity deposits, withdrawals, fee claims, donations and burns do not count.
Using the actual Quote type avoids introducing a USD oracle. Quote precision
and thresholds are explicit atomic-unit parameters.

The user was asked whether volume should decay or accumulate for the pool's
lifetime. Pending a different answer, this proposal uses recent volume that
ages out, so a burst of trading does not permanently raise fees.

A bounded candidate is 60 one-minute buckets: include the current minute and
the preceding 59 minutes. This is a minute-granularity approximation to trailing
hour volume, not an exact timestamp-level rolling window. Bucket expiration is
deterministic and never requires iterating over individual trades; advancing
after a long idle period clears at most 60 buckets. Tiny or failing swaps must
not create unbounded work or leave committed counters behind.

One candidate fee curve is:

```text
fee_bps(V) = minimum_bps
           + floor((maximum_bps - minimum_bps)
                   * min(V, target_quote_volume) / target_quote_volume)
```

`V` is the counted prior successful volume after aging buckets at the current
Sui Clock time. The rate reaches its cap at `target_quote_volume`. Bounds and
volume sensitivity are policy parameters, not caller-selected swap inputs.
The minimum, maximum, target and recipient split are not assigned production
values in this proposal; numerical examples must not become launch defaults.

Determine the rate before executing the current trade, then record its actual
Quote volume after successful settlement. This avoids a circular fee/output
calculation. It deliberately means a first large trade can pay the low rate;
its volume raises subsequent rates. If the intended product should charge the
current large trade progressively, that is an additional amount-sensitive
pricing rule and needs a different quote specification.

Both self-trading and economically motivated trading count identically:
the chain cannot reliably identify distinct economic owners. Test the cost
of round trips, fee recovery by LP/creator/protocol beneficiaries, bucket
boundaries, liquidity changes, transaction splitting and back-to-back calls.
A cap bounds how high fees can be pushed but does not prevent artificial
volume. Do not market this schedule as proof of organic demand or bot protection.

## Separate fee balances and ownership

Trading reserves contain principal used for price formation and LP redemption.
All accrued fees are separate balances with separate claims. Fees never enter
the reserve ratio, LP-share minting base or principal withdrawal calculation.
This includes the LP allocation: the user explicitly rejected passive fee
accumulation inside V2 reserves.

Keep protocol, creator and LP entitlement distinct. The split of each fee
must conserve its input asset under a specified rounding rule. The allocation
sum cannot exceed the fee collected. Claiming fees does not redeem principal.

LP positions need per-asset fee-growth checkpoints and accrued entitlement.
Settle a position's earnings before adding or removing its shares; newly minted
shares must not inherit past earnings. Preserve accrued fees through partial
withdrawals, position transfers and final closure. Round claims down and keep
rounding custody explicit; never let claim totals exceed the funded LP pot.
No loop over all LP holders belongs in a swap.

The auto-LP vault can collect its own position's separately accrued fees and
reinvest the available pair in a later transaction. That is explicit
compounding and still needs a caller. Every unmatched unit remains in vault
custody. Permanently held LP shares retain their fee entitlement without a
principal-extraction path.

The existing `CreatorCap<Meme>` remains privately held by the auto-LP vault
for its source claims. New-pool creator authority must not duplicate or expose
that cap. Before implementation, bind each creator claim and protocol claim
to the intended beneficiary, and specify how the pool's native fee split
relates to Blast's existing runtime share. Do not silently assume an additional
fee layer or a new unrestricted administrator.

## Burn on swap

An optional, bounded Meme burn executes as part of the successful swap.
For a sell, deduct the burn from the incoming Meme before determining the
amount entering reserves. For a buy, deduct the burn from the outgoing Meme
amount; the user receives the remainder. Minimum-output protection applies to
the user's actual net receipt after every fee and burn.

The exact trade-fee asset convention and order of fee/burn deductions must
be specified once for both contract math and SDK quotes. In particular, burning
Meme obtained as output is different from reducing input used by the curve.
Do not destroy reserves belonging to existing LPs without the corresponding
swap accounting, and do not also allocate burned units as claimable fees.

Enable true native burning only for `BurnOnly` Meme currencies. Call the
framework's burn operation in the same transaction and verify the supply
delta. A failed burn aborts the swap. Fixed-supply currencies need burn
disabled; sending coins to an inaccessible address must not be described as
the same supply reduction. Ordinary transfers and swaps on other DEXes remain
outside this pool's burn rule.

Burning Meme already present in a swap does not require an extra conversion.
Buying Meme with Quote fees to burn is outside the no-balancing-swap scope.
Burn percentages and fee allocations must be disclosed together because both
affect the trader's net execution and the amount available for reinvestment.

## Invariants and verification

For each asset separately, opening custody plus receipts must equal closing
reserves, closing fee pots, retained excess, payouts and native burns. A change
in one asset cannot conceal a deficit in the other. Initial LP issuance,
subsequent deposits and redemptions use actual reserves and explicit rounding;
fees are excluded even when physically held by the same pool object.

Required evidence before handling funds includes:

- Quote/execution parity for both directions and every fee/burn combination.
- Reserve invariant, per-asset conservation and native supply reconciliation.
- Minimum output, deadlines, zero/dust inputs and maximum integer boundaries.
- Fee growth across deposit, withdrawal, transfer, claim and permanent custody.
- No new LP acquiring historical fees and no old LP losing accrued entitlement.
- Volume bucket rollover, idle resets, cap behavior and adversarial round trips.
- One PTB composing claims, swaps and deposits without leaking assets;
  a failed operation aborts the transaction, with retries in a new transaction.
- Source fee collection into the bound Blast pool, retained leftovers and
  no principal extraction through the auto-LP vault.

V2 has a smaller accounting surface than V3/DLMM, but the requested extensions
are custom financial logic. Passing local tests is not an audit or proof of
mainnet readiness. The recommendation remains independent review before public
funds. Deployment, immutability and any decision to operate without an external
audit are separate from agreement on this design; no deployment is performed
by recording the scope.

## Remaining implementation inputs

The scope is selected. The exact volume window/curve, production fee bounds,
fee beneficiaries and split, fee-asset convention, and burn-rate policy still
need concrete values or rules before the complete contract is specified.
These gaps must not be replaced with undocumented assumptions in code.
