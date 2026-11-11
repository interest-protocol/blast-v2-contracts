# Scratch Sui packages

The DEX and example hook are unpublished and outside the launch stack.
The pool implements concentrated liquidity with Uniswap-v4-style lifecycle hooks.

This scratch checkpoint replaces the parked full-range native V2 DEX source
from [ADR 0076](../docs/decisions/0076-native-v2-and-auto-lp.md). The previous
scratch source is [retained in Git history](https://github.com/interest-protocol/blast-v2-contracts/tree/45547cf8e795878659b92a316d8ee80c9045d519/scratch-sui/dex).
Launchpad migration is outside this checkpoint.

## Package lifecycle

The DEX uses the launch stack's `blast_admin` lifecycle. Publication delivers
`Publication<BLAST_FUN_DEX>` to the deployer and pins the DEX's `PackageWitness`.
In a follow-up transaction, `package_admin::wrap` consumes the publication and
native `UpgradeCap`, seals the cap and `Publisher`, and shares the package admin
and version. The version starts at 1 with all three pause bits set.

| Bit | Stops |
| --- | --- |
| 1 | Pool creation, binding hooks to new pools, finalization and sharing |
| 2 | Swaps in either direction |
| 4 | Adding liquidity and donating |

The ACL grants `PauseAdmin<BLAST_FUN_DEX>` for immediate pausing and
`UnpauseAdmin<BLAST_FUN_DEX>` for release through `blast_fun_dex::unpause`. Release
checks the current version, supplies the pinned package witness and requires a
guarded upgrade delay. The liquidity removal sequence stays open under the
current version with all bits set, including both hook calls and payout.
Fee-tier and hook configuration remain available during a pause.

`UpgradeAdmin<BLAST_FUN_DEX>` schedules an exact digest under the shared
upgrade delay, initially 48 hours. The upgrade PTB authorizes the digest,
executes the native upgrade and calls `commit_upgrade_and_advance` with its
receipt. The successor compiles the next version. Every DEX mutation that
depends on the active package takes the same shared `PackageVersion<BLAST_FUN_DEX>`
by reference. Coordinate hook upgrades that relink DEX calls with the DEX
cutover so bound hooks can still approve removals.

## Why the pool is the entry point

Sui has no dynamic dispatch, so the pool cannot call a hook. Every operation is
instead a fixed sequence of calls that the transaction makes:

```text
pool::begin_*      lock the pool; the request owns the payment
hook::before_*     may take hook fees, then approves
pool::execute_*    needs the bound before-hook's approval; runs the curve;
                   the completion owns the output and unspent payment;
                   execute_swap takes the Clock for the dynamic fee
hook::after_*      may take from or add to the output, then approves
pool::finish       needs the bound after-hook's approval and the caller's
                   minimum outputs; unlocks; returns both coins
```

Pass the shared DEX package version to each mutating call. Requests and
completions have no abilities, so skipping a step aborts the
transaction. Approval and every hook mutation take the pool and check the
request belongs to it, so a hook bound to several pools cannot be handed
another pool's request. The pool stays locked from `begin_*` to `finish`, so
nothing interleaves with a hooked operation. Empty slots need no approval, and
the hook steps disappear from the transaction.

The pool owns the sequence, so routers only need the DEX's own functions plus
one hook call per bound slot.

Within hook Move code, checked getters borrow the payment or completion
balances mutably. Hooks use the standard `Balance` operations to split fees or
join funds. Each getter checks the active DEX version, pool identity, bound
hook witness and unapproved state before returning the reference. The borrow
must end before approval; subsequent borrows fail once the step is approved.
Pool identity, swap direction, price limit and liquidity parameters stay
private to the pool module, and `finish` checks minimum outputs after all hook
adjustments.

This follows Uniswap v4's separation between fixed operation parameters and
hook-adjustable token accounting. The prototype keeps its existing permission
model: before-swap hooks may adjust both payment balances, and every bound after
hook may adjust both completion balances, including refunds. It uses funded
balances rather than v4's signed return deltas and separate return-delta
permissions; LP fees remain pool policy. These reference getters are for calls
inside hook Move code; routers call the hook's transaction functions.

## LP fee tiers

The shared fee tier registry starts with 0.1%, 0.3%, 1%, and 2%. The Blast ACL
root grants `blast_fun_dex_domain::BlastDexFeeTierAdmin` to an operator's
`AdminCap`. The operator signs in with `blast_acl::sign_in` and passes the
resulting `AdminWitness` to `lp_fee::schedule_fee_tier` with the shared Sui
`Clock`. The proposal specifies a distinct rate from 1 to 100,000 ppm and
returns its deadline. Each rate has its own 48-hour notice and rescheduling
restarts that rate's notice. The registry holds up to 32 pending rates.
`CancelAdmin<BLAST_FUN_DEX>` can discard a proposal by rate with
`lp_fee::cancel_fee_tier`, even once ready. Anyone can call
`lp_fee::apply_fee_tier` at or after the deadline to admit the rate and emit
`blast_events::BlastDexFeeTierAdded`. The shared delayed map emits the
proposal lifecycle keyed by the fee tier registry's ID and `lp_fee::FeeTierKey`.

Anyone can borrow the registry to construct validated fee settings with
`lp_fee::new_fixed` or `lp_fee::new_dynamic`, then pass them to `pool::new`.
The pool constructor checks the active DEX version, creation pause, token pair,
tick spacing and starting price. Pools store their selected rates at creation.
DEX events live in `blast_events`, and DEX abort codes live in `errors`.

## Hook calling convention

Every hook exposes the same `public` function for each slot it binds; the full
list is in `example_hook/sources/fee_hook.move`. Sui forbids changing a
published `public` signature, so a router resolves any hooked pool from chain
state alone, with no registry, templates or hook-specific code:

1. Read the pool's `hooks` field: the witness type bound to each slot.
2. Call the latest version of the witness's original package, in the witness's
   module, at the slot's fixed function name.
3. Pass the shared DEX package version, the `HookConfig<Witness>` at the address
   derived from `HookNamespace` and the witness's defining-ID type name, the
   `Clock`, and empty `hook_data`.

Hooks gate every function on `HookConfig::version`, which only increases,
because older package versions stay callable after an upgrade. `hook_data`
carries bytes from a hook's own service, such as a signed attestation; generic
routers pass it empty. Hooks needing other objects or per-user arguments add
separate typed functions for hook-aware callers.

The example hook's `FeeHookAdminCap` holder sets the starting fee at configuration
creation and uses `fee_hook::schedule_fee_bps` for later changes. Each proposal
waits 48 hours and remains cancellable by the cap holder through
`fee_hook::cancel_fee_bps`. Anyone can call `fee_hook::apply_fee_bps` once
ready. Swaps use the applied fee until that call succeeds.

## Native LP fees and the curve boundary

The swap core freezes the dynamic reference before pricing and passes a fee
path to the curve. Hooks can charge their own fee before the core prices the
remaining payment. Fixed pools use the registered rate throughout the fill and
skip reference observations. Dynamic pools set a registered base rate, a cap
from the base through 100,000 ppm, and a sensitivity from 100,000 through
100,000,000 ppm of fee per unit of squared price gap. The sensitivity is an
integer coefficient. `Ppm` stores validated rates, where 1,000,000 is 100%.

The curve interface takes one fee path per fill. The reference uses exact sums for
the current partial and previous complete 10-minute windows, aligned to Unix
time. It blends the current integral with the unexpired fraction of the
previous window's average and rounds down once. Observations within a timestamp
add zero weight. A price-changing trade affects the reference only through
the spot and the time that spot persists. The first pool price seeds the
pre-swap history. This is a bucketed estimate of a rolling average from the
pool's own spot price. A sustained price move can shift it, including in a
thin pool.

At square-root price `s` and frozen reference `r`, the fee rate is
`min(cap, base + sensitivity * ((s / r)^2 - 1)^2)`. The pool integrates
`rate / (1 - rate)` over the net input in each constant-liquidity interval.
It rounds the resulting fee up to an input atom and credits the active range
before crossing a tick. The swap event reports total gross input and the LP
fee separately. The continuous schedule supersedes the band approximation.

The exact-input solver searches rounded Q96 prices indirectly through integer
net budgets. Net input rounds up, the search checks each candidate's actual
gross charge, and the completion returns any unspent payment. Output rounds
down once after accumulating conservative Q64 amounts across ranges.
Each swap visits up to 128 ranges or empty gaps. Continue a partial fill
with a fresh swap. The explicit `execute_swap_partial` entry point allows
paid progress at the traversal cap when the output is below one atom. The
ordinary entry point requires positive curve output, and `finish` enforces
the caller's minimums after hooks in either case.

Mint funding rounds up and is checked in u256 before narrowing. Withdrawals
round principal down. Initialized ticks and position amounts determine active
liquidity. Swap fees and donations use separate balances and accrue only to
active positions. A removal pays the position's whole-atom fees in addition to
principal. Fractional accrual carries across partial removals. Full removal
relinquishes any sub-atom fraction, and residual rounding stays in the pool.

[ADR 0143](../docs/decisions/0143-dex-continuous-lp-fees.md) records the fee and
settlement policy. The [arithmetic benchmarks](../docs/research/dex-dynamic-fee-comparison-2026-11-11.md)
preserve the prior bands comparison.

## Swap arithmetic proof

With the Z3 shared library installed (`libz3-4` on Ubuntu), run the model and
compiled tick-grid, price-inverse and `mul_div` checks from the repository root.

```sh
dex_proof_build=$(mktemp -d)
CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1 sui move build --path scratch-sui/dex --install-dir "$dex_proof_build"
python3 scripts/verify_dex_swaps.py --compiled-module "$dex_proof_build/build/blast_fun_dex/bytecode_modules/sqrt_price_math.mv"
```

Pass the module from the production build directory so the verifier can
also inspect its sibling tick module and compiled standard-library
dependencies, and check the compiled pool and curve lifecycle. Omit
`--compiled-module` for a model-only run. The verifier
checks source hashes and rejects unsatisfiable premises, counterexamples,
and solver timeouts. Review the corresponding model before refreshing a
changed hash.

The [fee enclosure derivation](continuous-fee-proof.md) relates both Q96
endpoints to the exact continuous integral. The source-pinned Z3 model checks
the algebraic and rounding bounds, price inverses in both directions, output
rounding, budget search and token conservation. The search uses the runtime
quarter-atom width guard. The rational width certificate proves that every
admitted fee path passes it, with an enclosure narrower than 0.019 atom at
the largest net input. The swap model assumes ordered ticks and positive
liquidity in priced ranges. The [solvency derivation](swap-solvency-proof.md)
connects the reserve and fee-vault induction to the custody transitions and
the UID-keyed projection of all live positions, including wrapped positions.

Set `BOOGIE_EXE` and `Z3_EXE` for
[Sui Prover](https://github.com/asymptotic-code/sui-prover) and run the Move
contracts with a checkout at the Sui revision in the DEX manifest.

```sh
python3 scripts/verify_dex_swaps_move.py /path/to/sui-prover /path/to/prover-checkout /path/to/sui-checkout
```

The runner stages the DEX and its specs in a temporary package. It adds the
prover's table spec declarations to a copy of the pinned Sui framework. The
tested prover revision is `949d14419515038d341d440e9c01c0737adf2ff0`.
The liquidity proof uses the verified tick postconditions in a dedicated
solver context. Use `--functions curve::change_liquidity_spec` to rerun it
independently, or `--timeout` to set the per-check limit in seconds.

The Move contracts check directed Q96 multiplication and division, the
fee ceiling, both price inverses and the successful swap lifecycle.
They cover locked request creation in both directions, the per-step and
aggregate budget bounds, refund and fee routing, per-token conservation,
and finish-time approval, minimum outputs and unlocking.

The curve model partitions active liquidity into positions that remain active
and positions that leave at a tick. The crossing subtracts the leaving
liquidity before adding the entering liquidity. Its cursor lands on the tick
when moving up and one below it when moving down, preserving the half-open
range convention. Outside fee growth flips to global growth minus its old
value modulo `2^256`. The Z3 model proves this preserves the inside fee
growth at either boundary, even when growth wraps.

Sui Prover checks the curve's crossing, global fee credit, tick and bitmap
updates, inside fee growth, position liquidity changes, and fee withdrawal.
For a valid position range with accrual that fits in `u256`, the liquidity
contract checks active and total liquidity, accrual at the old stake, and
checkpoint initialization for new positions. The fee withdrawal contract
checks whole-atom payouts and partial-withdrawal remainders given that accrued
whole atoms fit in `u64`. The swap loop proof uses the verified crossing and
fee credit contracts.

The Move contracts abstract pricing probes for the budget proof. The
calculus proof and Z3 model cover the pricing arithmetic. The
[tick bitmap proof](tick-bitmap-proof.md) covers nearest-tick selection in
both directions for every reachable bitmap state. The
[swap progress proof](swap-progress-proof.md) bounds the loop at 128 iterations
and verifies cursor progress across zero-liquidity gaps. The formal scope
excludes Sui VM transaction semantics and hook internals. The
[runtime verification results](../docs/research/dex-dynamic-fee-comparison-2026-11-11.md#integrated-runtime-verification)
cover representative swap transactions. The
[128-step gas benchmark](swap-gas-benchmark.md) covers dense tick layouts,
zero-liquidity gaps, and large continuous-fee fills on mainnet's gas model.

## Before publication

Independently audit the curve, fee, and custody invariants and exercise the
hook lifecycle through the production SDK resolver.
