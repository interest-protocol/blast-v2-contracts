# Swap reserve and fee backing

The [Z3 obligations](../scripts/dex_solvency.py) and the [Sui Prover custody
contracts](../scripts/dex_solvency_specs.py) check complementary parts of the
following induction for committed pool transitions. Repeat the argument
independently for Asset and Quote. All inequalities compare quantities in the
same token.

## Principal

At spot price `s`, let `p[i]` be `s` clamped to the tick prices `[a[i], b[i]]`
of live position `i`, and let `L[i]` be its liquidity. Its exact principal
uses integer Q96 prices as the grid.

```text
asset[i] = L[i] * 2^96 * (1/p[i] - 1/b[i])
quote[i] = L[i] * (p[i] - a[i]) / 2^96
```

The induction invariant is that each actual principal reserve is at least the
sum of the corresponding exact principal over the pool's live positions.
Both sums start at zero. A position creation or deletion with zero liquidity
adds or removes zero. On mint the position formula is linear in the added
liquidity at fixed spot. The reserve receives its upward-rounded cost. On
burn the exact principal drops by the formula for the removed liquidity and
the reserve pays at most that drop. Thus the principal split fits the reserve
before the burn.

The supporting state invariant is that `Curve.liquidity` equals the sum of
liquidity over positions satisfying `lower <= cursor < upper`, and each
initialized tick's starts and ends are the sums of position liquidity with
that lower or upper endpoint. All three sums start at zero. Mint and burn
update both endpoint sums and the active sum if the position is in range.
At a crossing, folding the per-position endpoint change gives the active
liquidity update. Moving within a range preserves active membership because
no initialized endpoint changes side.

Between successive initialized tick prices, the active positions all change
by the same price-coordinate distance per unit of liquidity. A price
increase adds quote principal and removes asset principal. A decrease reverses
those roles. Positions outside that interval have fixed clamped prices. The
per-position equation extends to a finite list by folding the sum of active
liquidity. The price is at or between the cursor's grid price and the next
grid price. A downward crossing puts the cursor one tick below the boundary.
Reversing direction at the same boundary can cross it without
moving the spot. The lookup comparison is over tick indexes, so the next
upward index can be strictly higher than the cursor while its price equals
the spot. An empty interval or a zero-distance crossing changes neither
principal claim.

For a priced interval, the upward-rounded net input covers the increase in
input-side principal. The conservative Q64 output covers at most the
decrease in output-side principal. These bounds add over the whole swap,
including a partial swap, and the final right shift only rounds output
further down. Settlement adds net input and debits output from the principal
reserves. It transfers fees to separate vaults. Donations leave principal
unchanged.

## Fee vaults

Use mathematical integers to lift global growth, each initialized tick's
outside growth, and position checkpoints. Stored values are their
representatives modulo `2^256`. A new tick initializes its outside
growth to the current global value at or below the cursor and zero
above it. The outside value flips on a crossing. A live position keeps
both endpoints initialized, so the initial value only matters when a
position establishes a fresh checkpoint. A newly initialized tick cannot be
an endpoint of another live position because positive stake already keeps
both of its endpoints initialized.

The liability of a position is its checkpointed Q128 amount plus its
liquidity times the true increase in inside growth since its checkpoint.
Empty positions have no latent growth. The invariant at a custody boundary
is that the sum of these liabilities is at most `2^128` times the
corresponding fee vault balance. Inside growth is unchanged by an endpoint
flip, including at an exact price boundary. At a credit only the active
positions accrue. Their combined increase is
`L * floor(f * 2^128 / L) <= f * 2^128`, where `L` is the active liquidity
before crossing and `f` is the actual fee or donation. An empty swap interval
issues no credit, and the donation path rejects zero active liquidity in
`credit`. During a swap, the bound includes pending credits until settlement
joins their matching payment into the correct vault. The staged swap
observation checks the sum of the arguments sent to `credit` against the fee
sent to settlement. The donation contract also checks the
growth change from the amounts joined into the vaults. Position changes occur
at custody boundaries, where all previous credits have been funded.

Checkpointing moves latent growth into the stored amount before changing the
stake, so minting more stake cannot collect earlier credits. The aggregate
bound applies to every individual liability because all are nonnegative.
At a custody boundary the bound is below `2^192` for a `u64` vault. For a
live position its true growth delta is at most its liability because its
stake is at least one. This proves that the delta fits **before** using
wrapping subtraction to recover it. The multiplication and addition used
to checkpoint also fit `u256`. Burning liquidity pays the whole-atom
quotient, which fits `u64` and is no greater than the fee vault balance.
A partial exit keeps the Q128 remainder, and a full exit relinquishes it.
Both preserve backing after subtracting the whole-atom payment.

## Verification boundary

The Z3 driver checks the arithmetic model and the induction steps. Source
hashes pin the implementation reviewed against the model. With a fresh
production build, the driver also checks the instruction sequence and
control flow of `tick_math::sqrt_price_x96` and its standard-library
helpers. It reads the factors from the compiled constant pool and
exhaustively evaluates the checked arithmetic at all 1,774,545 legal
indexes. The evaluator checks that every product fits, the reciprocal
divisor stays positive, the grid is strictly increasing, and both endpoints
equal the configured constants.

Sui Prover checks the compiled nearest-tick branch selection using the
deterministic scan summary that the Z3 bitmap proof instantiates. The
Z3 bitmap proof checks the parent/child occupancy induction and that
the selected branch leads to existing children in that model. The
compiled bitmap update contracts check the corresponding local
mutations. The nearest-tick Move contract describes successful returns. Its specification uses
a default when the result is empty, so evaluating the postcondition is
safe even when no tick is present.

Sui Prover checks that floor search and `move_inside` return without abort
and establish the local bracket when their index and price preconditions
hold. The exhaustive grid check instantiates their tick-price summary.
The harness adds identity assignments to retain the search's original
endpoints for the loop invariant. Z3 relates the bracket to the nearest
initialized endpoint, preserved active membership and the spot bounds.
The compiled swap loop preserves the cursor bracket on successful returns,
using the neighbor and tick-price summaries and the directional step bound.
Sui Prover also checks that pool creation admits `min <= spot < max`.
Public swap limits strictly exclude both extreme tick prices, so the
downward branch never crosses the tick at index zero.

The Move driver also checks compiled custody deltas, the staged fee
credit observation, and the liquidity, checkpoint, crossing and budget
contracts. The tick update and crossing contracts also preserve the
record at any other initialized tick. The crossing contract proves
arithmetic safety given a present tick, a positive index for a downward
cross, and the subtraction and addition bounds for active liquidity.
The driver runs the fee-ceiling and rejection-skip abort-freedom checks
in a separate context with their explicit preconditions.

The quote's clamp to `constant_fee` and its final ceiling imply
`fee <= net` for the admitted cap in the Z3 model. The dynamic constructor
bounds the cap directly. Fixed fees are drawn from the bounded default or
registered tiers. The Move budget proof checks the trial's net bound.
Connecting the fee bound to its two rejection-helper calls still uses
source reasoning.

The Z3 checks establish the joint invariant at creation, through each priced
step with pending transfers, after swap settlement, and across mint, burn,
donation and empty-position transitions. Z3 Spacer proves that the joint
principal and fee inequality is invariant under folding any finite set of
per-position changes with the local backing bounds, then under any finite
history of ledger transitions satisfying those bounds. The proof harness
checks that mint and burn settle the observed pre-cast pricing amounts with
the requested stake and rounding direction. The compiled curve pricing
contract checks the clamp and the asset and quote formula wiring relative to
the ordered price grid. Separate Sui Prover checks establish the principal
formulas for the rounded input and Q64 output wrappers, then prove that the
fee search returns those formulas at the selected trial endpoint. The
selection proof uses abstract deterministic pricing functions instantiated by
the wrapper checks. The bytecode checker matches both instruction paths of
`next_price`. Sui Prover checks equality with the rounded formulas and
arithmetic abort freedom under the caller bounds. Z3 proves those bounds
for a grid price, positive `u128` liquidity and a `u64` budget, including
admission to `mul_div` for the downward inverse. The raw inverse can leave
the grid. The directional clipping lemmas bound the selected price by the
spot and target before the next iteration. The compiled swap
settlement contract checks exact reserve, fee-vault and returned balance
deltas in both directions. The swap loop
observation checks that the gross input equals cumulative net input
plus cumulative fees and that the settled output is the Q64 accumulator
shifted down to atoms.

Sui Prover checks the DEX division wrapper and the checked-product fast
path. The compiled-module run matches the framework ceiling helper and
checks the fallback instruction sequence, local types, and control flow
from a fresh Sui build. The 80-bit path proves its high product and
two-limb reconstruction. The 30-bit path proves its two possible initial
prefixes, digit decomposition, quotient and remainder preservation, and
terminal rounding. The dividend, shifted quotient, and final value bounds
are needed because a Move left shift discards high bits. The Z3 caller
bounds use the checked grid range, u128 liquidity and u64 budgets. The
runner disassembles the modules from the fresh build and records their SHA-256
digests.

The owned-position projection keys each ledger row by the position UID and
includes the row in the pool named by the position's immutable pool ID.
Sui Prover checks that creation sets the pool and range and starts with zero
liquidity and fees, that destruction requires zero liquidity, and that each
liquidity request binds the position and pool IDs at begin and execution.
The production bytecode check verifies the sole construction and destruction
sites, enumerates mutable access to the pool, position, curve, and position
fee fields, and checks that both liquidity executors open and settle with the
same pool and position references. It also checks the sites that construct,
consume, or mutate swap requests, completions, and approvals.

Z3 checks insertion, removal, and single-UID updates in the ledger. Spacer
checks by induction that live position multiplicity equals ledger membership
at each UID over finite traces and that a finite fold charges a local
transition once. The trace alphabet follows from Move type privacy and
linearity. The sole constructor adds a value, the sole destructor removes
it, and transfer, sharing, freezing, wrapping, and unwrapping preserve it.
As a result the fold includes positions inside other objects as well as
address-owned positions. Swaps and donations change claims through shared
price or growth even when position values remain untouched. The per-position
pricing and growth lemmas bound those changes in the same fold.

The refinement argument applies to the compiled package. It trusts Sui's
bytecode verifier, globally fresh object allocation, transaction
atomicity, and the semantics of the checked Move instructions. The proof
checks the trace projection under those runtime rules. The Sui Prover
summary for the allocation native does not model global UID history. The
projection, row fold, and backing induction are separate checked lemmas.
The transition-by-transition argument above composes them with the Move
contracts. The module digests identify a local production build of the
scratch package.

Public swap admission does not guarantee execution. The Move regression
`dynamic_swap_without_liquidity_cannot_settle` passes the begin guards and
aborts at execution with `EInsufficientOutput`. A zero-output execution can
pass only in partial mode after reaching the step cap, spending some input,
and stopping short of the price limit. Execution separately rejects an
output larger than the reserve. Hook approvals and user minimums can reject
a swap at their own boundaries. The loop's budget contract applies to
successful returns.

Sui Prover separately checks that settlement's balance arithmetic cannot
abort when the fee is covered by the spend, the spend is covered by the
payment, the reserve covers the output, and all three joins fit `u64`.
The joins are net input to principal, fees to the vault, and output to the
other request balance. The check abstracts the native event boundary.
Withdrawal principal and fees also have to fit their combined `u64` output.

Sui Prover checks that request opening returns under the current package
version, unpaused swap flag, matching pool and required approval. Completion
returns under the current version, matching pool, required approval, and
minimums checked against the post-hook balances. It proves fee credit with
positive active liquidity, a stored tick-price read with its table key
present, and reference observation from the invariant maintained by
initialization and previous observations. The compiled exact-input search
controller preserves affordability through each retry, cannot underflow
while skipping a rejected probe, and returns a charge within the budget.
That proof uses the numerical trial and output contracts as summaries. The
separate compiled trial check covers clipping, narrowing, the quarter-atom
guard, and the fee ceiling given contracts for the inverse, input delta,
and quote. Its preconditions include ordered prices and net affordability
after clipping. Z3 discharges those properties in both directions for the
modeled inverse and input delta. Relating the summary to that model across
every call in the search is a compositional argument. Separate compiled
checks prove that the input and output wrappers return their specified
rounded amounts under the wide-multiplication caller bounds. The Z3
checks include the first quotient bound needed to admit the second
multiplication for upward output.
Coin creation and event emission use external native contracts.
The [bitmap invariant](tick-bitmap-proof.md#reachability-invariant) ties
each selected tick to a live key in the tick table. That is the condition
used by the stored-price check.

Settlement headroom is an explicit arithmetic condition. In the generic
balance model, Z3 finds that a valid spend and positive backed output can
still exceed the output join's `u64` limit when the request already carries
the output token. A per-token aggregate balance bound implies all three
joins fit, but the generic proof keeps headroom as an explicit condition.
The local proofs leave open a single compiled
no-unexpected-abort theorem connecting fee construction, numerical probes,
tick lookup, and the full swap loop to settlement. The separate compiled
bitmap check proves lookup return with live selected child keys and the
Z3-checked mask and scan contracts. Hooks and Sui gas and native limits sit
outside this proof.

Run both verifiers with the [DEX proof commands](README.md#swap-arithmetic-proof).
