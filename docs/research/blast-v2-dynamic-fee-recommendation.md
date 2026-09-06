# Dynamic volume fees for Blast V2

Research and derivation, 2026-09-05. Recommendation for discussion, not a
deployed mechanism, empirical backtest, or approved production parameter set.
This refines the fee policy in [the earlier design](blast-v2-volume-fees-and-burn-design.md).
It preserves separate fee custody, optional Meme burns, two-asset deposits,
no balancing swaps, and Blast V2 as an optional migration destination.

User refinement, 2026-09-05: the selected default Meme-pool marginal fee
range is **0% to 2%** (`f0=0`, `f1=0.02`). The 0.30%–1.00% section below
remains a historical illustration only. The executable research model now
uses the selected bounds; its `K=100,000 Quote` and `H=30 minutes` remain
illustrative, not selected production values. Independent
[Claude Fable review](blast-v2-dynamic-fee-fable-2026-09-05.md) agrees with the
real-arithmetic mechanism; the record contains its findings and their disposition.

Further user refinement: protocol admins may change the maximum fee of an
individual pool, including raising it to 3% or 5%. The later wording
"start with 0.2" is being clarified against the earlier explicit 0%–2% range;
the current reference retains that earlier range pending clarification.

## Per-pool maximum fee administration

This is an authorized scope refinement. The proposed boundary is:

- Each canonical Meme/Quote pool has its own live maximum; pool identity and
  canonical asset ordering select the pool, not its percentage fee.
- Reuse protocol admin authorization; a creator or LP position does not
  implicitly authorize changing trading fees. This setter grants no access
  to reserves, fee pots, LP shares, creator capabilities or burn authority.
- Keep the zero floor. Recommend `0 <= maximum_bps <= 500` for this version.
  The 5% hard ceiling is a recommendation based on the requested 3%/5%
  examples, distinct from the user-selected power to adjust individual caps.
- A successful update changes the rate curve for subsequent swaps only.
  Preserve the volume score, its original time anchor, K and H. Do not
  recompute already allocated fees or LP fee-growth checkpoints using the
  new cap. Do not store the mathematical potential as an economic liability.
- Compute both ends of `P(v+q)-P(v)` under the same current policy in each
  swap. Telescoping claims require an unchanged policy; trades on opposite
  sides of an admin update intentionally pay their respective live policies.
- Swaps must bind a trader-approved maximum effective trading fee and net
  minimum output/deadline. Check the actual rounded Quote fee against its
  declared Quote-principal denominator using wide multiplication. A cap
  increase before inclusion either remains within that bound or aborts.
- Emit pool identity and old/new cap for real changes; no-op updates abort.
  Native transaction order supplies ordering; do not add a policy nonce only
  for event ordering. Swap records must preserve the applied fee facts.
- The trading-fee ceiling excludes optional Meme burn and AMM price impact.
  Display the burn separately and enforce the trader's actual net output.

The admin update itself cannot withdraw principal. The authority can change
future execution costs, market routing and LP earning opportunities; those
economic powers remain even with correct math and a hard ceiling. No new
setter or deployed policy is implemented by this research document.

The manufactured-volume cost examples assume an unchanged nonzero cap and
an attacker without admin control. If admins temporarily set the cap to zero,
trades can fill the volume score without trading fees; raising the cap then
makes that retained score affect future rates. This is a consequence of the
selected trusted administration, not proof that such score construction
remains expensive across policy changes. The same limit applies to fee
recapture and other subsidies.

With the selected 0%–2% range, score levels 0%, 25%, 50%, 75% and 100% of K
give marginal rates 0%, 0.5%, 1%, 1.5% and 2%. A finite trade starting from
empty still pays a positive progressive fee when the maximum is nonzero;
zero is the marginal floor, not a free first-trade allowance.

## What existing protocols actually do

| Mechanism | Actual signal and calculation | Relevant lesson |
| --- | --- | --- |
| Uniswap v4 | Hooks choose the fee policy; core does not prescribe one dynamic formula. | Dynamic fee support does not require adopting concentrated liquidity or cloning a particular hook. |
| KyberSwap Classic / DMM | Short/long EMAs of pool volume, mapped through a bounded nonlinear curve. | Direct precedent for volume-driven fees; distinguishes a surge from normal volume. |
| Algebra V1 | Volatility sigmoids, modulated by a volume-per-liquidity sigmoid. | Combines activity and price risk; volume normalization introduces its own design choices. |
| Meteora DLMM / DAMM v2 and LFJ Liquidity Book | Base fee plus a squared volatility-accumulator term, with time-dependent reference updates and limits. | Borrow bounded response and cooldown; bin movement is not gross trading volume. |
| Balancer StableSurge | Higher fees on swaps that worsen imbalance beyond a threshold. | Dynamic fees can measure inventory stress rather than time or volume. |

**Uniswap:** v4 permits periodic updates and per-swap overrides. It is a
framework, not evidence that a universal volume formula has been selected.
[Official architecture](https://developers.uniswap.org/docs/protocols/v4/concepts/architecture),
[dynamic-fee mechanics](https://developers.uniswap.org/docs/protocols/v4/concepts/dynamic-fees).

**Kyber:** the inspected source uses EMA coefficients `2/5401` and `2/10801`,
updates from completed block volume, and lazily accounts for skipped blocks.
Within one block, trades accumulate volume without changing that block's
EMA ratio. Its unscaled fee function ranges approximately from 15 to 60 bps,
equals about 25 bps at ratio one, and reaches 60 bps near ratio 1.4774;
pool amplification can scale that range downward. This is a legacy design,
not a statement about all current Kyber products. A pure short/long ratio
eventually returns to one under sustained constant activity even if absolute
volume stays high. That is a mismatch if Blast should retain a surcharge
throughout sustained high activity.
[Official explanation](https://docs.kyberswap.com/reference/legacy/kyberswap-classic/concepts/dynamic-auto-adjusting-fees),
[volume source](https://github.com/KyberNetwork/ks-classic-sc/blob/e557b57d7e4ead84caa2ec039aef280584148116/contracts/VolumeTrendRecorder.sol),
[fee source](https://github.com/KyberNetwork/ks-classic-sc/blob/e557b57d7e4ead84caa2ec039aef280584148116/contracts/libraries/FeeFomula.sol),
[pool scaling](https://github.com/KyberNetwork/ks-classic-sc/blob/e557b57d7e4ead84caa2ec039aef280584148116/contracts/DMMPool.sol).

**Algebra:** V1 evaluates two volatility sigmoids and uses their sum as the
amplitude of an outer volume-per-liquidity sigmoid, then adds the minimum
fee. Integral's documented changes remove that volume sigmoid and move
adaptive fees into plugins. Do not present the V1 formula as the current
universal Algebra implementation.
[V1 source](https://github.com/cryptoalgebra/AlgebraV1/blob/789384bc5084dd694f3d1e189250491086e44653/src/core/contracts/libraries/AdaptiveFee.sol),
[Integral changes](https://github.com/cryptoalgebra/algebra-integral-docs/blob/main/changes-after-v1.md).

**Meteora/LFJ:** Meteora's inspected SDK computes the variable numerator as
`ceil(A * (volatility_accumulator * bin_step)^2 / 10^11)` and caps the total.
LFJ updates the accumulator from distance to a reference bin and a carried
reference, using filter/decay periods. These are activity-related price
movement measurements, not a sum of traded Quote. Meteora DAMM v2 also has a
distinct buy-size rate limiter with progressive tiers, Quote-only collection,
a bounded launch duration, and a multiple-swaps-per-transaction restriction.
That is useful progressive-pricing precedent, but not a persistent rolling
volume policy for both directions.
[Meteora SDK](https://github.com/MeteoraAg/dlmm-sdk/blob/576919e3e4368e542c402f000b4264724f7f23ec/ts-client/src/dlmm/helpers/fee.ts),
[DAMM dynamic fees](https://docs.meteora.ag/core-products/damm-v2/fees/dynamic-fees),
[DAMM rate limiter](https://docs.meteora.ag/core-products/damm-v2/fees/rate-limiter),
[LFJ source](https://github.com/traderjoe-xyz/joe-v2/blob/067c6ccf5b8ff1526d03fa3e4c65ec45d01c1f73/src/libraries/PairParameterHelper.sol).

**Balancer:** the inspected StableSurge hook tests old versus estimated new
imbalance, charging a surge only when the threshold and worsening conditions
are met. Its estimate excludes fee effects. This is not a volume controller
and a stable-pair balance target should not be transplanted into a Meme/Quote
constant-product pool.
[Source](https://github.com/balancer/balancer-v3-monorepo/blob/449f7e074be4a92f9ed35ac8d201f45d4ac01f7e/pkg/pool-hooks/contracts/StableSurgeHook.sol).

These are verified documentation/source mechanics. No live pool configuration,
deployment-bytecode equivalence, or profitability claim was verified here.

## What the papers change about the recommendation

The [companion paper review](amm-dynamic-fee-papers.md) covers five primary
papers. Baggiani et al. explicitly model Quote fees outside reserves, while
their optimal controller depends on inventory and an external price.
Campbell et al. model competitive routing and find that higher fundamental
demand can lower the optimal fee at fixed volatility. Neither result endorses
an arbitrary volume-increasing curve as universally revenue-maximizing.
[Baggiani et al.](https://arxiv.org/html/2506.02869v1),
[Campbell et al.](https://arxiv.org/html/2508.08152v1).

For fee-sensitive demand `D(f)`, gross revenue is `R=f D(f)`, so
`R'=D(f)(1-elasticity)`, with `elasticity=-f D'(f)/D(f)`. A higher fee raises
revenue locally only below unit elasticity. This elementary derivation is
why routed volume must be allowed to respond in economic tests. A fixed
historical tape with larger fees applied to every unchanged trade is not a
revenue forecast. The chosen product policy can nevertheless be increasing
volume fees; optimize its parameters under that constraint.

## Proposed mechanism: decaying volume with progressive charging

The following is our derivation, not a claim of a novel optimal mechanism.
The improvements over the previous proposal are continuous time decay,
charging the current trade progressively, and explicit control of how long
a single burst can keep the surcharge high.

Use four pool parameters:

- `f0`: minimum marginal fee, as a fraction of traded Quote principal.
- `f1`: maximum marginal fee, with `0 <= f0 <= f1 < 1`.
- `K > 0`: Quote volume needed to fill the activity score from empty.
- `H > 0`: half-life of that score, in seconds.

Store a volume score `v` and its last timestamp. At the next successful swap:

```text
v_before = v_stored * 2^(-elapsed_seconds / H)
f(v) = f0 + (f1-f0) * min(v/K, 1)
fee(v,q) = integral from 0 to q of f(v+u) du
v_after = min(K, v_before + q)
```

Here `q` is actual Quote reserve movement, excluding fees, counted once in
either direction. Deposits, withdrawals, claims and external-venue trades do
not contribute. This is a **capped, decaying volume score**, not the exact sum
of all exponentially weighted historical volume: excess activity above `K`
is deliberately discarded from memory, but every unit is still charged.

That memory cap is separate from the fee cap. It prevents a giant burst from
stockpiling hours of elevated fees. With uncapped memory a burst of `16K`
could keep the marginal fee at its cap for four half-lives without another
trade. With the proposed memory cap, the surcharge halves after one idle
half-life regardless of burst size. The cost is that activity beyond the cap
does not produce a longer cooldown. If retaining burst magnitude is preferred,
the uncapped EMA is a coherent alternative; do not accidentally mix the two.

`K` should be fixed for the pool's fee policy and calibrated to the intended
launch size/Quote type. Do not divide the score by the instantaneous reserve
balance: a temporary liquidity deposit would then change the rate without
trading. A fixed `K` does not automatically adapt to a pool growing 100x;
that is its explicit tradeoff. A slow depth-adjusted threshold is possible,
but needs separate treatment of temporary liquidity and parameter transitions.

### Why integrate the rate across the current trade?

For an increasing rate, using only the pre-trade state gives a single large
trade cheaper treatment than splitting it into many trades. Using only the
post-trade rate makes splitting advantageous. Instead charge each incremental
unit at the activity level it creates.

Let `d = f1-f0`, and define a fee potential:

```text
P(x) = f0*x + d*x²/(2K)                 for 0 <= x <= K
P(x) = f0*x + d*(x-K/2)                for x >= K
fee(v,q) = P(v+q)-P(v)
```

Below the cap this is `f0*q + d*(2*v*q+q²)/(2K)`: the average of the starting
and ending marginal rates times the traded amount. Crossing the cap charges
the ramp portion and the remaining portion at `f1`.

This construction proves, in exact arithmetic at one timestamp:

```text
f0*q <= fee(v,q) <= f1*q
fee(v,q1) + fee(min(K,v+q1),q2) = fee(v,q1+q2)
```

Thus splitting the same Quote notional at the same time does not change the
total mathematical fee, even across the cap. This is a fee-schedule property,
not a promise of equal outcomes across different routes, timestamps, changing
liquidity, intervening trades, or integer/burn rounding. Same-direction V2
reserve changes also compose in exact arithmetic with fees outside reserves.
Spreading volume over time deliberately earns lower rates as activity decays.

The linear marginal ramp has constant sensitivity and a quadratic accumulated
cost. A squared-volume ramp delays more of the surcharge until high activity;
a saturating `v/(K+v)` ramp never reaches its cap and introduces a logarithm
in the exact fee integral. Neither has established economic superiority here.
Choose the linear ramp because its sensitivity and manufacturing cost are
directly interpretable, not because sophisticated functions are impossible.

### Settlement convention: explicitly recommended, not already selected

The clean exact implementation above collects **all trading fees in Quote**:

- Buy with gross Quote `A`: find the largest principal `q` such that
  `q+fee(v,q) <= A`. Add only `q` to Quote reserves, retain the fee separately,
  return any rounding excess, and compute Meme output from the V2 curve.
- Sell Meme: apply the optional incoming Meme burn, calculate gross Quote
  output `q` from the resulting principal, remove `q` from reserves, retain
  `fee(v,q)` separately, and pay `q-fee(v,q)` to the trader.
- Apply any buy-side Meme burn to outgoing Meme. Minimum received uses the
  actual post-fee, post-burn asset. Failed settlement commits no activity.

The buy equation is strictly increasing since its derivative is `1+f(v+q)`.
It has a unique real solution, a quadratic solution in the ramp region and a
linear solution above the cap. A bounded integer search is also a useful
reference oracle; its Move gas cost has not been benchmarked.

Within the ramp, write `a=(f1-f0)/(2K)` and
`b=1+f0+(f1-f0)*v/K`. The buy-budget equation is `a*q²+b*q=A`.
Its numerically stable positive root is
`q=2A/(b+sqrt(b²+4aA))`. First compare the budget with the cost to reach
`q=K-v`; any remaining budget buys principal at `1+f1` Quote per unit.
This avoids an iterative economic solver; bounded integer square-root and
rounding still need a specified production implementation.

This defines a surcharge on Quote principal. For an average surcharge `a`,
buy fee/gross payment is `a/(1+a)`, whereas sell fee/gross curve output is `a`.
The UI/SDK must disclose a common notional convention and effective net
execution; do not label the two gross-denominator percentages identical.

Quote-only collection is a proposal, not a prerequisite for dynamic fees.
Collecting in each input asset is possible, but the exact progressive
integration must then account for the changing Meme/Quote conversion; the
same simple Quote-fee telescoping argument is not sufficient.

**Auto-LP consequence:** native Quote fees cannot by themselves fund a
two-asset deposit with swaps disabled. The vault pairs them with available
Meme from source claims/retained balances, or holds them. If self-contained
native-fee compounding is essential, select two-asset fee collection and
derive its settlement separately. Do not silently add a balancing trade.

## Illustrative numbers and manufactured-volume cost

For illustration only: `f0=0.30%`, `f1=1.00%`, `H=30 minutes`, `K=100,000 Quote`.
These are not inferred optimal settings or launch defaults.

| Volume score | Marginal fee for the next tiny trade |
| --- | --- |
| Empty | 0.300% |
| 25% of K | 0.475% |
| 50% of K | 0.650% |
| 75% of K | 0.825% |
| Full | 1.000% |

A burst of `K` from empty pays average `0.65%`, or `650 Quote`, whether one
trade or 100 equal trades in exact fee arithmetic. Pre-trade-only charging
would instead charge `300` versus `646.5`. Starting full, with no new trades,
the tiny-trade rate is `0.65%` after 30 minutes and `0.475%` after 60 minutes.

In the continuous-flow approximation let `lambda=ln(2)/H`. Holding the score
at `v*` requires counted turnover `lambda*v*` per unit time. Holding it full
in this example requires about `138,629 Quote/hour`, with gross fees about
`1,386 Quote/hour`. If the trader recovers 80% of fees through LP/creator or
other rights, direct unrecovered fees are only about `277 Quote/hour`.

The burst cost from empty is `K*(f0+f1)/2`; unrecovered fee cost is that amount
times `(1-recaptured_share)`. To target a net fee-maintenance budget `B` per
hour at full activity under assumed recapture `r`, a calibration rule is
`K >= B*H / ((1-r)*f1*ln(2))`, using hours for `H`. This gives a measurable
policy lever rather than an unsupported assertion that manufacturing is
expensive. As `r` approaches one, no finite threshold assures substantial
unrecovered fee cost through this mechanism alone.

Gas, burn and outside execution effects are additional. Do not assume V2
price impact is automatically an extra permanent round-trip loss: with
burn off, no intervening trades, and fees outside reserves, buying and then
selling exactly the acquired Meme restores the curve reserves in real
arithmetic. The fee is the direct loss before any recapture. External hedging,
MEV and later routing effects require an economic model. Protocol revenue is
only its allocated part of collected fees, not the full gross fee counter.

## Numerical evidence and next calibration

[Executable reference](volume-fee-model.py) checks 2,000 deterministic random
cases using exact rational arithmetic: bounds, marginal monotonicity, split
composition with capped and uncapped memory, integer buy-budget inversion,
agreement with the independent high-precision quadratic root, V2 principal
conservation, sell-fee rounding and reversible no-burn round trips. The
current run uses the selected 0%–2% bounds; the historical 0.30%–1.00%
numbers above were checked before that change. A further 180 boundary
cases check buy inversion at caps of 0%, 0.2%, 2%, 3% and 5%, plus a worked
fee-limit rejection after an admin increase. It is not a Move implementation
or an audit.

After Fable review, select rounding each trading fee up on both buys and
sells; reject zero-principal and zero-output swaps. The actual rounded fee
must pass the trader's effective fee limit. Rounding up
individual split charges can add up to one atomic unit per extra segment;
the exact splitting statement does not extend verbatim to integers. Very
small trades can consequently face high effective percentages or fail.
Potential-difference rounding can preserve telescoping but introduces a
different dust-allocation policy. Pin that rule with SDK/contract vectors.
Production decay must also bound repeated-update rounding, use consistent
Clock timestamps, and preserve the exponential composition property within
a stated error budget. At zero elapsed time its factor must be exactly one.
Prevent caller-induced excess decay, but also prove any conservative rounding
does not keep dust activity alive forever. Fixed-point factor absolute error
and relative error are distinct, especially after long idle periods. No
fixed-point production implementation is selected by the floating-point
illustrations here. Define buy inversion by the exact integer budget
inequality and validate any approximate-root candidate against it; do not
assume a one-unit correction suffices without proving its error bound.

Recommended next experiment is a replay/synthetic-market comparison with
responsive competing routes: static baseline, Kyber-style relative surge,
the proposed integrated linear policy, and a saturating alternative. Sweep
half-life, K, floor/cap and fee recapture, keeping burn as an independently
reported cost. Measure retained volume, protocol/creator revenue, LP returns,
trader net execution and the cost of sustaining manufactured activity.
Public Sui meme-pool calibration was not performed in this research turn.

The recommendation is therefore the **mechanism**: decaying bounded volume
memory, progressive charging of the current trade, explicit fee denomination,
and separate custody. Numerical settings remain calibration hypotheses.
