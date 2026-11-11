# Dynamic LP fees: banded versus continuous integration

This records the pre-integration comparison. [ADR 0143](../decisions/0143-dex-continuous-lp-fees.md)
selects continuous fees for the implemented swap path.

Date: 2026-11-11. The user requested independent Astra and Claude Fable
input, followed by a Move benchmark of 64, 128 and 512 bands per side and a
production parameter decision. The band-count decision is recorded in
[ADR 0142](../decisions/0142-dex-dynamic-fee-band-count.md).

## Continuous implementation follow-up

The [Move integrator, originally a test-only candidate,](../../scratch-sui/dex/sources/fees/continuous_fee.move)
integrates the capped quadratic fee over each constant-liquidity interval.
It encloses the integral using directed Q96 arithmetic and a bounded series,
then ceilings the fee once per interval. The experimental affine solver brackets
the affordable net amount using `n = budget - fee(n)`. The 10% gross-rate cap
bounds the slope of fee on net by `1/9`, so the bracket contracts even when
the swap moves toward the reference and the marginal fee falls.

**Keep 512 bands as the baseline. Carry continuous forward for an integrated
curve comparison.** Continuous won 18 of 23 full-path quotes and 7 of 10
budget fills. It substantially reduces rounding dust and wide-path work.
The dense liquidity fixtures favor bands; the full curve must establish how
often those paths occur and how much they cost with stored ticks and hooks.

| Fixture | 512 bands, VM units | Continuous, VM units |
| --- | ---: | ---: |
| Quote, +1% price | 439 | 70 |
| Quote, full span down | 309,998 | 222 |
| Quote, 128 liquidity intervals up | 164,003 | 213,481 |
| Quote, 128 liquidity intervals down | 165,487 | 290,020 |
| Budget fill, −1% price limit | 327 | 340 |
| Budget fill, full-span down limit | 307,962 | 65,900 |

VM units are above the empty test on the pinned Sui runner. The full-path
tests both compute net deltas and fees and assert their totals. The partial
fills use the same prescribed constant-liquidity paths and budgets. The
continuous inverse interpolates an affine net coordinate from the supplied
integer capacity; the band inverse consumes whole steps and applies its
constant-rate budget formula on the last step. Neither models the final
rounded CLMM price/output or charges storage and PTB gas.

At liquidity 1,000, the +1% path costs **112 gross atoms with bands**
(56 net, 56 fee) and **6 with continuous** (5 net, 1 fee). With a budget of
four atoms on that path, bands allocate two atoms each to net and fee;
continuous allocates three to net and one to fee. These are arithmetic fills.
At the same endpoint, the models split the same real net delta into different
numbers of integer rounding steps.

The independent reference uses Decimal90 Gauss–Legendre quadrature, split at
the reference and cap boundaries, and integer bisection for budget fills.
Against the earlier adaptive Simpson calculation the largest fee difference
was below `2.4e-16` atoms. All 293 quoted intervals overlapped the numerical
reference windows and had bounds narrower than 0.25 fee atoms, including
maximum `u64` net input and extreme prices. All ten continuous budget fills
matched the independent integer solution. Astra checked the interval and
bracket reasoning; an upper enclosure that straddles an exact integer can
still add one fee atom. The split test exercises both directions across the
reference and caps, with at most one additional fee atom in those fixtures.
These checks do not establish a universal split or settlement guarantee.

Run the [benchmark](../../scripts/benchmark_dex_continuous_fee.py) under the
shared heavy-job guard with `--output /tmp/dex-continuous-fee-results`.
The [recorded results](dex-continuous-fee-2026-11-11.json) include the inputs,
golden amounts and meter rows. All 122 generated tests and all 122 DEX tests
passed with strict lint; every meter row repeated exactly. Before adopting
either model, implement the curve and compare actual endpoints, positive
output, refunds, fee growth, split paths and full transaction costs.

## Band-count recommendation

**Retain 512 bands per side.** Choose a positive spatial sampling bias budget
below 6 basis points of gross input across the supported fee domain, before
atomic amount rounding. The 64- and 128-band alternatives breach that budget
near the allowed 10% cap. The 512-band implementation meets the spatial bound
and the measured fee-path arithmetic fits the pinned Sui test meter.

This selects the fee approximation parameter for the eventual production
curve. The present scratch pool still has aborting curve functions; this
benchmark does not approve it for publication. Actual exact-input execution,
LP allocation, rounding dust and complete transaction gas remain release gates.

Deterministic bands remain the reference implementation for curve development.
The follow-up above measures the continuous candidate at the arithmetic seam;
full curve settlement and split behavior remain open for both approaches.

## Move benchmark and reproducibility

Run [the benchmark script](../../scripts/benchmark_dex_fee_bands.py) from the
repository root under the shared heavy-job guard:

```sh
python3 scripts/benchmark_dex_fee_bands.py --output /tmp/dex-fee-band-results
```

[Recorded evidence](dex-fee-bands-2026-11-11.json) includes toolchain and source
hashes, exact integer amounts, independent smooth references, convergence
checks and raw/normalized gas statistics. Each isolated package changes only
the band-count constant. Each candidate executes 24 generated cases plus an
empty-test gas baseline, with one test worker, strict lint and warnings as
errors. Every nonempty case asserts exact agreement between production Move
helpers and the Python integer replica for steps, net input and fees. The
setup-only case asserts zero steps. Original package tests compile alongside
the generated suite but are filtered out of execution.

The cases cover both directions, flat fees, small through 10% price moves,
travel toward and across the reference, cap entry/exit, high sensitivity,
128 synthetic liquidity changes, the entire uncapped grid on both sides,
thin liquidity, and adverse final-band paths. Liquidity changes are prescribed
arithmetic intervals; they do not read stored ticks or update fee growth.
Reference sqrt-price is one. Extreme absolute prices, arbitrary tick layouts,
budget-exhausting endpoints and transaction storage are outside this harness.

| Bands per side | +1% price steps / VM gas | Full-span down steps / VM gas | Highest fixture VM gas | Adverse whole-band excess, bps | Adverse partial-band excess, bps |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64 | 7 / 88 | 130 / 1,395 | 3,235 | 20.1714 | 40.2155 |
| 128 | 14 / 118 | 258 / 7,221 | 10,200 | 10.1277 | 20.2234 |
| **512** | **56 / 462** | **1,026 / 331,187** | **331,187** | **2.53981** | **5.07763** |

Gas is the pinned CLI's Sui VM meter **above an empty test**, including harness
amount arithmetic, vectors, assertions and a per-step `net_budget_down` inverse
check. It is not a complete transaction charge. The pinned runner subtracts
remaining gas units from its monetary execution bound, producing a large
constant offset in CSV statistics. Subtracting the measured empty-test row
removes that offset. All 24 shared raw gas rows per candidate matched exactly
across the first two successful executions, despite differing elapsed times.
The pinned test configuration provides 5,000,000 computation units, so the
largest measured case consumes about 6.6% of that allowance. This is component
headroom, not a guarantee for the eventual swap plus hooks and stored ticks.
Gas growth is measured directly; it must not be extrapolated linearly from
step counts. Elapsed nanoseconds are retained as observations, not fee estimates.

The adverse comparison uses base 1 ppm, cap 100,000 ppm, sensitivity 100,000
ppm and liquidity `10^15`. For each candidate, it traverses that candidate's
last upper band, or the first millionth of that band. These are reachable
policy settings after admission of the base tier. Candidate-specific paths
expose each grid's sampling bias; they are not identical endpoints for a gas
comparison. The common-path cost columns use identical endpoints and settings.
Excess is `(band gross - smooth gross) / smooth gross`, excluding atomic amount
rounding while retaining the production rate's integer-ppm flooring.

The independent reference integrates `f/(1-f)` in net-input coordinates using
60-digit Decimal arithmetic, splitting at caps and the reference. Adaptive
Simpson tolerance is tightened 16-fold for a convergence check. Downward paths
use `1/t` as the integration coordinate, avoiding a low-price `1/t²` numerical
singularity. Convergence is checked per case; it is numerical evidence, not a
certified quadrature-error proof. Integer golden amounts do not depend on
this quadrature.

For the same nominal 1% price increase at liquidity 1,000, prescribed endpoint
costs are 14, 28 and 112 atoms for 64, 128 and 512 bands, respectively, versus
about 4.992721 ideal smooth gross atoms. More bands improve spatial accuracy
but increase repeated atomic rounding. These target-path costs do not simulate
an exact-input partial fill. The complete engine must stop when progress is
unaffordable, reject zero-output value loss, and validate an acceptable dust
policy; adding bands does not solve that problem.

## Domain bound and independent Astra reassessment

The benign reference-start examples originally made 64–128 bands look
attractive. Astra reconsidered after bounding the whole supported fee domain,
and recommended retaining 512 if execution cost fits. Its initial provisional
recommendation is superseded by this assessment and the measurements above.

Let `h = c-b`, `d = sqrt(h/k)`, `U = sqrt(1+d)`, and let `N` be bands per side.
For the upper sqrt-price grid, the largest marginal-rate increase over one
ideal band is bounded by

```
Delta_f <= 4 h U / ((U+1) N) <= (8 - 4 sqrt(2)) h / N.
```

For the lower grid the corresponding bound is `2h/N`. Since `c <= 0.1` and
`h <= 0.099999`, a rate overestimate changes gross input by at most
`Delta_f/(1-c)` relative to smooth gross input, pointwise and consequently for
any weighted path integral. The upper-grid bound is the larger one: about
40.68, 20.34 and 5.085 bps for 64, 128 and 512 bands. Q32 cap-distance and Q96
width rounding add less than 0.001 bps. Astra checked the minimum supported
reference explicitly: with cap-extent error below `2.1e-7`, reference at least
`4,295,128,739` Q96 units and rate derivative below `17.889`, the extra relative
gross bias is bounded by `(17.889/0.9) * (2.1e-7/N + 1/reference)`. This is below
0.00070 bps at 64 bands and 0.00013 bps at 512; accumulated grid displacement
does not enter because each sampled edge is at most one actual width away.
The final forced-cap band's rounded cap extent is outward of the exact cap,
so the same local width bound applies. The selected 6 bps budget leaves margin.
Integer rate flooring can reduce or reverse positive bias, so this is
not a claim that bands always overestimate the smooth fractional schedule.
This bound covers spatial sampling, not repeated atomic rounding, reference
estimation error, or an unfinished curve's output and LP allocations.

## What the local evidence establishes

The fee path uses a frozen reference and constant rates on deterministic
sqrt-price bands. The rate comes from the edge farther from the reference,
including when the swap moves toward the reference. Thus splitting a band
does not resample its rate at a cheaper endpoint. These properties are owned
by [lp_fee.move](../../scratch-sui/dex/sources/fees/lp_fee.move#L222).

Gross input and net input are different units: the implemented fee on net is
`ceil(net * f / (1-f))`, and the affordable net budget is
`floor(gross * (1-f))`. Integrating `f` directly against net input would change
the economics. See [the settlement helpers](../../scratch-sui/dex/sources/fees/lp_fee.move#L279).

The reference is a time-weighted **sqrt-price**, whose square becomes the
reference price in the fee equation. Same-Clock observations preserve the
reference, but different-time trades can legitimately obtain different
references. See [price_reference.move](../../scratch-sui/dex/sources/fees/price_reference.move)
and [pool reference freezing](../../scratch-sui/dex/sources/pool.move#L865).

The [fee-path tests](../../scratch-sui/dex/tests/fees/fee_path_tests.move)
cover selected split paths, a liquidity boundary, capped regions, and dust.
They are a rational-delta harness, not an executable production CLMM. The
[production curve seam](../../scratch-sui/dex/sources/pool.move#L1045) still
aborts. These tests do not prove full swap conservation, exact-input partial
fills, general split resistance, or production gas bounds.

## Continuous mathematics

Let `s = sqrt(price)`, `r = sqrt(reference_price)`, `t = s/r`, liquidity `L`,
and express base `b`, sensitivity `k`, and cap `c` as fractions rather than ppm.
Inside an uncapped region:

```
f(t) = b + k(t² - 1)²
D(t) = 1 - f(t) = 1 - b - k + 2kt² - kt⁴
```

For increasing sqrt-price from `t0` to `t1`, net input is `L r dt`, so gross
input is:

```
G_up = L r ∫[t0,t1] dt / D(t)
```

For decreasing sqrt-price, with `t1 < t0`, the other input asset has net
increment `-(L/r) dt/t²`:

```
G_down = (L/r) ∫[t1,t0] dt / (t² D(t))
```

These identities follow directly from the CLMM deltas used in the
[local harness](../../scratch-sui/dex/tests/fees/fee_path_tests.move#L75)
and the gross/net fee identity above. Both integrands are rational functions.
Partial fractions therefore give elementary antiderivatives involving logs,
and depending on parameters arctangents, plus reciprocal terms for the down
direction. This is an exact real-valued expression, not exact finite-integer
evaluation. The generic inverse for an exact gross budget is not an
algebraic CLMM endpoint formula; a bounded numerical solve is needed.

At the cap, ordinary constant-fee math applies. At initialized ticks,
liquidity changes and fees must be credited to the correct active positions:
integration remains piecewise in liquidity. Continuous fees remove fee-grid
boundaries, not liquidity boundaries. A full segment can be priced directly;
only the final budget-exhausting segment needs inversion. An implementation
need not run an inverse solve at every tick.

The real gross integral is strictly increasing along a nonempty positive-
liquidity path because `1-f >= 0.9`. Bracketing is consequently available.
Newton iteration alone does not establish termination or conservative
settlement; a bounded bracketed method and explicit integer postconditions
are preferable.

## A useful alternative to generic quadrature

The fee cap provides a strong mathematical simplification:

```
1/(1-f) = Σ[n=0..N] fⁿ + f^(N+1)/(1-f)
0 <= remainder <= 0.1^(N+1)/0.9
```

For a net-input amount `A`, truncating through `N=20` has exact-real gross
error at most `A * 0.1^21 / 0.9`. Even at `A = 2^64-1`, that bound is below
0.021 atomic input units. This bounds truncation only, not arithmetic error.

Each term is polynomial in `t` for the up direction and Laurent-polynomial
after division by `t²` for the down direction. Its antiderivative is
elementary without logs: only even powers occur before integration. This
offers a bounded candidate for investigation, rather than requiring adaptive
quadrature or a transcendental library. It is not a finished algorithm:
naive expansion around `t=0` can cause cancellation, particularly at high
sensitivity near `t=1`; fixed-point widths, stable evaluation, operation
count, and inversion still need proofs and measurements.

## Precision, splitting, and dust

Continuous pricing is exactly additive over a fixed path in real arithmetic.
That does not automatically make a numerical implementation split resistant.
Independently rounded quadrature errors can change when the caller splits a
trade. A consistently evaluated monotone antiderivative, endpoint
differences, conservative settlement, and a documented cumulative error bound
are promising ingredients; they still require proof across tick crossings.

The banded model gives a much simpler argument for unchanged rates on a
fixed path. Its cost is an upward spatial sampling bias and repeated integer
rounding. The sampled formula itself floors to ppm and can undershoot the
ideal integer rate by one ppm, so “always an exact upper bound on the smooth
fee” is too strong; see [fee evaluation](../../scratch-sui/dex/sources/fees/lp_fee.move#L179).
Every extra fee boundary can also create additional net-input and fee dust.
That matters for small amounts and thin liquidity, independently of gas.

Neither model prevents a different fee caused by a different time-weighted
reference or liquidity path. Split comparisons must freeze those economic
inputs. A smooth fractional rate also differs from integrating a rate floored
to integer ppm; that precision policy must be chosen explicitly.

## Illustrative numerical comparison

The coordinating agent evaluated a Python integer replica of the band path
against Decimal arithmetic with 50-digit precision and composite Simpson
integration of the smooth gross/net formula. I checked the replica against
the source for these cases. Parameters are base 1,000 ppm, cap 10,000 ppm,
sensitivity 1,000,000 ppm, reference price 1, and one constant-liquidity range.
Price moves below are changes in price, not sqrt-price. Excess gross is
`(band gross - smooth gross) / smooth gross`, excluding atomic amount
rounding; band rates retain production integer-ppm flooring.

| Price increase | Steps, 512 per side | Excess gross, bps | Steps, 64 per side | Excess gross, bps |
| --- | ---: | ---: | ---: | ---: |
| 1% | 56 | 0.004134 | 7 | 0.072649 |
| 5% | 273 | 0.041110 | 35 | 0.368581 |
| 10% | 513 | 0.079298 | 65 | 0.671223 |

The final row includes a capped segment beyond the last band. At liquidity
`10^9`, changing Simpson resolution from 2,048 to 4,096 panels per smooth
region changed the computed fee by less than `10^-10` input atoms for these
three cases. This is numerical convergence evidence, not a certified error
bound. Endpoint conversion to Q96 also introduces a negligible endpoint
difference here. The integrator splits at the cap; this experiment covers
one-sided paths starting at the reference, not arbitrary cross-reference
paths or changing liquidity.

The same 1% price-increase target with liquidity 1,000 illustrates a separate
problem: rounding each of 56 band deltas and their fees upward costs 112 input
atoms, versus about 4.992721 ideal smooth gross atoms. Each sub-atom net
segment becomes one atom of net plus one atom of fee. This compares costs of
reaching a prescribed endpoint; it is not evidence of a production
budget-exhaustion bug, because the production swap remains a stub. Actual
affordable endpoints and zero-output handling need tests in the full engine.

These earlier examples motivated the completed benchmark above. They do
not establish that 64 meets a global error budget, nor that either band
count beats continuous evaluation in gas. Small movements can even have
negative pre-atomic-rounding excess against the smooth fractional curve
because ppm flooring outweighs outer-edge sampling: the supplied 0.1% upward
case at 512 bands was approximately -0.002392 bps. This reinforces the need to
separate rate quantization from spatial and atomic rounding errors.

Temporary experiment artifacts were
`/tmp/codex-dex-fee-comparison-2026-11-11.py` and
`/tmp/codex-dex-fee-comparison-numerics-2026-11-11.json`. They are session-local,
not committed reproducibility or release evidence. The subsequent Move band-count
benchmark above supplies reproducibility and metered arithmetic evidence.

## Evidence that would change the recommendation

Prefer continuous integration if a Move implementation proves conservative
gross-budget settlement and bounded error across the supported domain, then
beats the banded baseline materially on realistic and adverse swaps without
making common short swaps disproportionately expensive. Prefer a coarser
banded model if it meets an explicitly chosen economic-error budget at much
lower cost and complexity. The follow-up comparison measures continuous at the
component seam; the remaining work concerns the complete curve and transaction.

The comparison should hold the CLMM, reference, tick layout, and fee policy
constant and measure:

- Actual Sui computation gas and worst-case execution limits for both
  directions: inside one band, many bands without ticks, many ticks, crossing
  the reference, and entering/exiting cap regions.
- Error against an independent high-precision real-valued reference, reporting
  gross input, output, endpoint price, and LP fee allocation separately.
- Dust from each source: curve delta rounding, fee rounding, band sampling,
  integration approximation, and inverse termination.
- Exact-input fills and refunds at zero, one, and maximum supported amounts;
  extreme supported prices, liquidity, sensitivity, and fees; cap and tick
  boundaries approached from both sides.
- Split-versus-whole sequences with unchanged reference/liquidity, randomized
  cut points and adversarial boundary cuts, including repeated tiny fills.
- A hard bound on steps or evaluations, plus behavior when no further
  positive-output progress is affordable.

The follow-up covers component arithmetic, bounded inversion and selected
rounding cases. The complete swap and transaction criteria remain open.

## Independent Claude Fable assessment

The user requested Claude Fable through the CLI. A fresh, tool-disabled
`claude --print --model fable --effort high` run received the local fee,
reference, constants, harness, and curve-seam source plus applicable guidance.
It did not receive Astra's conclusion or the coordinating agent's numerical
results. The invocation succeeded and its reported canonical model was
`claude-fable-5-1`. It made no workspace changes.

Fable favored the banded baseline for the first implemented curve, primarily
because conservative continuous settlement requires proofs for integration
error, cancellation, integer monotonicity, inverse termination, and rounding
in both directions. It acknowledged that continuous integration is possible,
that the final exact-input interval needs inversion, and that artificial band
crossings could cost more than a bounded solver. It requested actual Move
measurements before treating that as a gas advantage.

Fable also highlighted repeated fee-rounding dust, especially for small
amounts. Its strongest counterargument to bands was that high-sensitivity
settings can create many arithmetic subdivisions even without liquidity ticks,
and the unimplemented curve makes this an inexpensive time to compare designs.

The coordinator does not adopt every detail of that answer:

- Its normalized variable was labelled `P/Pref` while the supplied quadratic
  expression uses `sqrt(P/Pref)`. The derivation above uses `t = s/r` throughout.
- A universal convexity claim for gross cost versus travel distance is too
  strong. Moving toward the reference can lower the marginal fee. Numerical
  inversion needs a valid bracket and proved integer monotonicity; plain Newton
  convergence from the net-only endpoint is not a sufficient global argument.
- The selected split tests do not prove universal implementation-level split
  resistance, and ideal continuous additivity does not prove numerical split
  resistance either.
- A short geometric-series truncation is an approximation, not an exact
  continuous primitive. Adding its full worst-case remainder as a fee creates
  economic bias; the slack and split dependence require separate bounds.
- Production bands are not always a strict upper-bound oracle for the smooth
  curve because integer-ppm flooring can outweigh spatial sampling bias.
- Continuous settlement does not automatically reduce all dust to one unit per
  tick: curve rounding, integration slack, inversion, and fee growth still count.
- Its claimed globally immaterial pricing improvement is not established by
  a complete parameter-domain bound. The numerical examples here are expressly
  examples, and per-boundary dust is a separate issue.
- Speculative integration concerns and deliberately unchecked test constructors
  are not confirmed production vulnerabilities. No separate bug finding is
  asserted from those comments.

## Primary external references

The recommendation is an engineering assessment of the local code, not a
statement that an external protocol mandates this model. Relevant primary
references provide the comparison baseline:

- [Uniswap SwapMath](https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/SwapMath.sol)
  uses a constant fee in each supplied swap step and separates gross budget
  from affordable net input.
- [Uniswap SqrtPriceMath](https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/SqrtPriceMath.sol)
  supplies the two directional CLMM amount and endpoint formulas and explicit
  rounding directions.
- [Sui gas documentation](https://docs.sui.io/develop/transaction-payment/gas-in-sui)
  describes computation gas buckets. Actual transaction measurements are needed;
  counting Python iterations does not establish Sui gas cost.

## Integrated runtime verification

On isolated Sui 1.77.2 localnet (protocol 133), published the packages, wrapped
the DEX publication, released pauses through the real ACL, and exercised the
hooked mint, both swap directions, donation and full removal in signed PTBs.
Replaying the liquidity, swap and donation events reproduced both principal
reserves and fee balances. The full exit left two asset atoms and one quote atom
of principal dust, with both LP fee balances exhausted. A failing minimum-output
check rolled back the swap and its events.

| Successful local PTB | Computation charge, MIST |
| --- | ---: |
| Hooked quote-input swap with a price limit | 1,000,000 |
| Hooked asset-input swap that exhausted its budget | 2,540,000 |
| Dynamic swap crossing the 128 initialized-tick cap | 354,800,000 |
| Dynamic swap with a 10^16-atom budget across the capped-fee boundary | 158,300,000 |

The dense case refunded 84,227,515,742,621 of 200,000,000,000,000 input atoms.
The table shows local computation charges, excluding storage charges and
rebates. The wide fill's elapsed Clock time influences its frozen reference
and can change the number of inverse probes.
