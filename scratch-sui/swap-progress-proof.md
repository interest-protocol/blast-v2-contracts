# Swap loop progress and termination

The production `swap_amounts` loop enters its body at most 128 times per
call. Every iteration that reaches the loop header again has crossed an
initialized tick and advanced the cursor strictly in the swap direction.
This includes crossings with zero active liquidity and crossings where the
spot already equals the tick price.

## Ranking functions

The first rank is `128 - steps`. It starts at 128 and is nonnegative.
Entering the body requires `steps < 128`, and the first statement increments
`steps` by one. Each back edge decreases the rank by exactly one. The guard
also ends the loop when the budget is exhausted or the spot equals the
price limit. The increment fits in `u64`.

The second rank is the cursor's distance to the end of the index grid in
the swap direction. Write `i` for the cursor, `t` for the initialized tick
and `M = 1,774,544` for the largest index.

| Direction | Eligible tick | Cursor after crossing | Rank |
|---|---|---|---|
| Up | `t > i` | `t` | `M - i` |
| Down | `t <= i` | `t - 1` | `i` |

The [nearest-tick proof](tick-bitmap-proof.md) supplies eligibility and
bounds from reachable bitmap states. Crossing changes the selected tick's
outside fee growth and the cursor. Fee credit preserves the cursor, and
neither operation changes bitmap membership. Every back edge goes through
a successful crossing, so both ranks decrease and the same tick cannot
be crossed again during that call. The legal downward price limit lies
strictly above the price at index zero. Both gap jumps and priced steps
respect that limit, so the downward crossing cannot subtract from index
zero. A priced step that returns its starting spot exits immediately.
A priced step that ends inside the range updates the cursor and exits.

## Zero-liquidity gaps

With zero active liquidity, the loop skips pricing and fee credit. If the
nearest initialized tick lies at or before the price limit in the swap
direction, the loop sets the spot to that tick's price and crosses it.
The iteration preserves the remaining input, accumulated output and fees.
The cursor still advances, including at an exact tick-price boundary.
A successful crossing from zero active liquidity enters positive active
liquidity because an initialized tick has a nonzero start or end count and
the crossing cannot subtract liquidity from an empty range.

If there is no initialized tick at or before the limit, the loop exits without
moving the spot. If the tick is exactly at the limit, the loop crosses it
and the next header ends the loop. A gap crossing counts toward the same
128-iteration cap. The cap can produce a partial fill. Final output and
reserve checks can still abort, and a gap jump alone cannot satisfy the
paid-partial condition.

## Verification scope

Sui Prover checks the compiled loop with read-only snapshots in a temporary
package. An invariant checks cursor bounds and the observations at each
back edge. An extra proof result carries the observations through early
breaks. The staging changes add no branch exits, pool writes, or assertions
to the swap. The contract uses the checked crossing and credit
contracts, the source-pinned nearest-tick theorem, and the step budget
contract. Sui Prover treats production aborts as terminal. Z3 checks the
ranks, loop guards, gap and limit branches, and zero-liquidity transition.

The proof composes with bounded callees. The prior Z3 budget-search lemmas
show that the exact-input search at least halves a nonnegative interval of
width at most `2^64 - 1` each iteration, giving at most 64 search
iterations per priced step. The price, fee, and bitmap helpers use fixed
iteration counts, fixed-size vectors, or shrinking integer intervals.
The loop bound describes program control flow. Transaction gas and
successful settlement depend on execution conditions.

## Reproduce

Run from the repository root with the [pinned prover setup](README.md#swap-arithmetic-proof).

```bash
python3 scripts/verify_dex_swaps.py
python3 scripts/verify_dex_swaps_move.py /path/to/sui-prover /path/to/prover-checkout /path/to/sui-checkout \
  --functions pool::swap_progress_spec
```
