# 0143: Continuous DEX LP fees and settlement rounding

- Status: accepted
- Date: 2026-11-11
- Supersedes: [ADR 0142](0142-dex-dynamic-fee-band-count.md)
- Scope: the unpublished concentrated-liquidity DEX

## Decision

Freeze the pool-local price reference for each exact-input swap. Integrate the
capped quadratic LP rate over actual net-input coordinates. These coordinates
are affine in square-root price for quote input and reciprocal square-root
price for asset input. With fee rate `f` on gross input, charge the integral of
`f / (1 - f)` on net input. A fixed-rate pool uses the same settlement path
with a constant rate. Fee band boundaries have no role in swap traversal.

Use directed Q96 enclosures, clamp the upper charge to the exact maximum rate,
and round the upper fee once per constant-liquidity interval. The integral's
pole denominators are positive because the cap gap divided by the pole distance
is at most the square root of 0.1. The enclosure width is below one sixteenth of
an input atom at the maximum u64 net input under the admitted parameters. The
runtime guard requires width below one quarter atom. Each change to a distinct
attained endpoint costs at least one more net atom. The integral increases
along the path, and net rounding can move the fee by less than one ninth of an
atom. Together with the enclosure bound this gives a monotone gross charge for
binary search over integer net budgets.

Round swap price toward the starting price and input up. Floor each output in
Q64, sum across intervals, then floor to whole atoms. Limit traversal to 128
steps. Refund unused input. An explicit partial-fill entry point permits paid,
zero-output progress at the traversal limit. The ordinary entry point requires
positive curve output, and both enforce the caller's minimum at finish.

Initialize ticks from funded position liquidity. Record active liquidity as the
sum of those positions, independent of reserve amounts. Mint obligations round
up and stay wide until checked against funded payment. Principal withdrawals
round down. Keep accrued swap and donation fees in separate balances, distribute
via active-range growth, and carry sub-atom claims through partial withdrawals.
A full withdrawal pays whole atoms and relinquishes the fraction.

## Consequences

The curve has a cost for each initialized tick visited and at most one exact
budget search on a final partial interval. The completed swap may span fewer
intervals than the caller's price limit. Routers can detect this from the price
and refund and submit another swap with a fresh reference observation.
Permissionless dust ranges can still raise traversal cost. Callers must opt
in to accepting zero output to make paid progress through an entirely
sub-atom prefix.

The fee benchmark remains historical evidence for the spatial sampling
tradeoff. Assess runtime gas and whole-transaction behavior separately on the
release configuration before publication.
