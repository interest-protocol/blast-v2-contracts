# 0142: Dynamic LP fee band count

- Status: superseded by [ADR 0143](0143-dex-continuous-lp-fees.md)
- Date: 2026-11-11
- Scope: fee approximation policy for the eventual production DEX curve.
  This records the decision before curve integration.

## Context

Dynamic fees approximate a continuous quadratic schedule using constant-rate
sqrt-price bands. Coarser bands reduce execution work and repeated atomic
rounding, but increase the difference between the sampled and continuous fees.
The user requested measurements of 64, 128 and 512 bands per side and a final
parameter selection, with independent Astra and Claude Fable input.

Reference-start examples at ordinary fee settings understate the reachable
bias near the maximum cap. A small swap near the inner edge of the last upper
band can pay substantially more than the smooth schedule, even though it
executes only one arithmetic step. Optimizing only the number of loop steps
would miss this economic tradeoff.

## Decision

Retain **512 bands per side** and deterministic outer-edge sampling. Use a
positive spatial sampling bias budget below **6 basis points of gross input**
across the admitted fee domain, before atomic amount rounding. This compares
the same directed price and liquidity path with the frozen reference against
the smooth fractional-rate schedule. It is not a bound on total slippage,
reference manipulation, rate quantization, or repeated atomic rounding.

The analytical pointwise bound is about 5.085 bps at 512 bands before a small
fixed-point allowance. Measured adverse partial-band excess is 5.07763 bps.
The corresponding 128- and 64-band measurements are 20.2234 and 40.2155 bps;
both fail the selected spatial budget. The
[comparison and domain-bound derivation](../research/dex-dynamic-fee-comparison-2026-11-11.md)
and [machine-readable measurements](../research/dex-fee-bands-2026-11-11.json)
record the decision's evidence.

## Alternatives considered

- **128 bands:** materially cheaper, but roughly four times the adverse
  spatial bias. It would require a looser economic budget or a narrower fee
  policy. Neither change is selected.
- **64 bands:** cheapest measured grid, with still larger adverse bias.
- **Continuous integration:** mathematically possible and potentially better
  on dust and long paths. The [subsequent Move comparison](../research/dex-dynamic-fee-comparison-2026-11-11.md#continuous-implementation-follow-up)
  measures a test-only implementation with bounded budget inversion. It saves
  work on wide paths and costs more across many liquidity intervals. Reconsider
  after comparing full curve settlement, split behavior and transaction costs.

## Consequences

The selected grid can introduce up to 1,024 fee-band subdivisions plus capped
regions and liquidity boundaries. Its largest measured arithmetic fixture used
331,187 Sui VM gas units above an empty test, against the pinned test meter's
5,000,000-unit allowance. The harness includes curve delta arithmetic and
consistency assertions. This is component evidence, not a complete transaction
gas bound; the pinned runner uses the Sui meter [S1, S2], and transaction
rounding is outside the harness.

More subdivisions increase atomic rounding. A thin-liquidity prescribed-path
fixture costs 112 atoms at 512 bands versus about 4.99 ideal smooth gross
atoms. The count decision therefore does not establish acceptable exact-input
fills or permit silent zero-output value loss. Changing the count later changes
fee economics even if public signatures stay the same.

## Verification

[The reproducible benchmark](../../scripts/benchmark_dex_fee_bands.py) builds
isolated copies of the production Move fee helpers for all three counts. Each
candidate passes 24 generated cases and an empty baseline under strict lint.
Integer amounts are asserted independently from the smooth numerical reference.
Gas rows reproduced exactly in repeated executions. The report records scope,
parameter coverage, numerical convergence and source/toolchain hashes.

Before publication, implement the curve and validate actual exact-input
endpoints, refunds, positive output, reserves and LP allocation, amount rounding,
split paths and full PTB gas with stored ticks and hooks. Include extreme
prices and supported amounts, adversarial partial bands and bounded work under
the intended protocol configuration. The component benchmark does not satisfy
those release gates.

## Sources

| Ref | Immutable source |
| --- | --- |
| S1 | [Pinned Sui unit-test meter and statistics adapter](https://github.com/MystenLabs/sui/blob/51d177ad7d65102fc368b582408f466d97b31548/crates/sui-move/src/unit_test.rs) |
| S2 | [Sui computation budget and gas-price conversion](https://github.com/MystenLabs/sui/blob/51d177ad7d65102fc368b582408f466d97b31548/crates/sui-types/src/gas_model/gas_v2.rs) and [meter units](https://github.com/MystenLabs/sui/blob/51d177ad7d65102fc368b582408f466d97b31548/crates/sui-types/src/gas_model/tables.rs) |
