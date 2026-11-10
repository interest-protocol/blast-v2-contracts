# Scratch Sui packages

Outside the production surface. Do not publish: the DEX's curve math aborts.

`dex` holds a concentrated-liquidity pool with Uniswap-v4-style lifecycle hooks.
`example_hook` is a hook that follows the calling convention below. Both
packages build and their tests pass; the tests supply curve results through
test-only seams, because the math functions abort.

This scratch checkpoint replaces the parked full-range native V2 DEX source
from [ADR 0076](../docs/decisions/0076-native-v2-and-auto-lp.md). The previous
scratch source is [retained in Git history](https://github.com/interest-protocol/blast-v2-contracts/tree/45547cf8e795878659b92a316d8ee80c9045d519/scratch-sui/dex).
Launchpad migration and native pool administration are outside this checkpoint.

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

Requests and completions have no abilities, so skipping a step aborts the
transaction. Approval and every hook mutation take the pool and check the
request belongs to it, so a hook bound to several pools cannot be handed
another pool's request. The pool stays locked from `begin_*` to `finish`, so
nothing interleaves with a hooked operation. Empty slots need no approval, and
the hook steps disappear from the transaction.

The pool owns the sequence, so routers only need the DEX's own functions plus
one hook call per bound slot.

## LP fee tiers

The shared fee tier registry starts with 0.1%, 0.3%, 1%, and 2%. The holder of
the fee-tier admin capability can append a distinct rate from 1 to 100,000 ppm.
Anyone can borrow the registry to create a pool with a registered fixed or
dynamic base rate. Pools store their selected rates at creation. Tier additions
are recorded as events and apply to future pool creation.

## Hook calling convention

Every hook exposes the same `public` function for each slot it binds; the full
list is in `example_hook/sources/fee_hook.move`. Sui forbids changing a
published `public` signature, so a router resolves any hooked pool from chain
state alone, with no registry, templates or hook-specific code:

1. Read the pool's `hooks` field: the witness type bound to each slot.
2. Call the latest version of the witness's original package, in the witness's
   module, at the slot's fixed function name.
3. Pass the `HookConfig<Witness>` at the address derived from `HookNamespace`
   and the witness's defining-ID type name, the `Clock`, and empty `hook_data`.

Hooks gate every function on `HookConfig::version`, which only increases,
because older package versions stay callable after an upgrade. `hook_data`
carries bytes from a hook's own service, such as a signed attestation; generic
routers pass it empty. Hooks needing other objects or per-user arguments add
separate typed functions for hook-aware callers.

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

For each curve step, pass the current square-root price and the nearer of the
next initialized tick and the user's limit to `lp_fee::next_step`. Use its
limit and `net_budget_down` to price the step. Round the curve's net input up
and output down. Charge `fee_up` on the net input actually consumed. Stop if
the remaining gross input cannot advance the curve. When crossing a tick,
credit the fee to the active liquidity before changing the range. Return the
sum of charged LP fees in input units for the swap event.

The reference fixes the bands for the whole path. Within a band, the rate is
the quadratic rate at its farther edge, capped by the pool maximum. This
approximates the continuous quadratic schedule with at most 512 bands on
each side and one capped region beyond each. The approximation never exceeds
the nominal cap. Each segment can round the fee up by less than one input atom.
Adding a split inside one constant-liquidity, constant-rate segment can add at
most one net-input atom and two fee atoms. Since both rounded amounts are
monotone and subadditive under merging, a split cannot reduce the fee for the
same directed price path and liquidity. The harness exercises the fee path
with a single-range fill and a fill crossing an initialized tick.

## Before publication

Implement the four curve functions at the end of `dex/sources/pool.move`
(swap stepping, liquidity amounts, donation fee growth) and the tick and fee
growth state they need, including fee checks before a position is destroyed.
Then add PTB tests that run the hooked sequence through the transaction
runtime and an SDK resolver, and an independent audit.

Verify locally from the repository root:

```sh
sui move test --path scratch-sui/dex --threads 1 --lint --warnings-are-errors
sui move test --path scratch-sui/example_hook --threads 1 --lint --warnings-are-errors
python3 scripts/check_move_style.py
```
