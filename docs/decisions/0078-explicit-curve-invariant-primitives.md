# 0078: Explicit curve invariant primitives

- Status: accepted
- Date: 2026-09-13
- Amends: [0021](0021-pure-constant-product-curve-quotes.md)

## Sources

This record introduces no external ABI fact. It names and checks the existing
Blast-owned constant-product arithmetic.

## Context

`quote_buy` and `quote_sell` previously embedded equivalent exact-input
constant-product formulas. Reserve movement trusted their returned deltas but
did not independently compare the invariant against the balances actually
mutated by `Launch`.

## Decision

`curve.move` owns two package-only invariant primitives:

- `get_amount_out` computes an exact-input output and rounds down;
- `k` multiplies two widened effective reserves.

Both exact-input quote paths call `get_amount_out`. No exact-output path exists,
so its inverse is not retained speculatively.

After every fallible quote and slippage check, `Launch` snapshots `k` from its
actual Meme reserve and effective Quote reserve before moving balances. It
recomputes `k` from the actual balances immediately after both reserve legs
move and aborts with `EConstantProductInvariantDecreased` if the product fell.
Equality remains valid when division is exact; integer rounding otherwise
leaves dust in the curve and increases the product.

## Alternatives considered

**Check only the post-trade values returned by the quote.** Rejected because it
would repeat the same arithmetic without reconciling the balances that custody
the assets.

**Require a strict increase.** Rejected because an exactly divisible
constant-product trade can preserve `k` without rounding dust.

**Keep duplicate formulas in each quote.** Rejected because the two directions
have the same invariant and rounding rule.

## Consequences

- Quote outputs and committed vectors do not change.
- The package-internal surface gains two arithmetic functions; the public ABI
  is unchanged.
- A reserve-accounting regression aborts before lifecycle mutation, fee
  accrual, event emission, or asset return.

## Verification

- Direct helper tests pin exact-input floor and widened `k` arithmetic.
- Quote tests assert non-decreasing `k` across a buy followed by a sell.
- Existing launch integration tests execute the balance-level postcondition.
- Build, warning-as-error lint, full tests, and structural source checks remain
  release gates.
