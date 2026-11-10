# Scratch Sui packages

Outside the production surface. Do not publish: the DEX's curve math aborts.

`dex` holds a concentrated-liquidity pool with Uniswap-v4-style lifecycle hooks.
`example_hook` is a hook that follows the calling convention below. Both
packages build and their tests pass; the tests supply curve results through
test-only seams, because the math functions abort.

## Why the pool is the entry point

Sui has no dynamic dispatch, so the pool cannot call a hook. Every operation is
instead a fixed sequence of calls that the transaction makes:

```text
pool::begin_*      lock the pool; the request owns the payment
hook::before_*     may take hook fees, then approves
pool::execute_*    needs the bound before-hook's approval; runs the curve;
                   the completion owns the output and unspent payment
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

## Before publication

Implement the four curve functions at the end of `dex/sources/pool.move`
(swap stepping, liquidity amounts, donation fee growth) and the tick and fee
growth state they need, including fee checks before a position is destroyed.
Give dynamic-fee pools a reference price source in `reference_sqrt_price_x96`,
also in `pool.move`. Then add PTB tests that run the hooked sequence through the transaction
runtime and an SDK resolver, and an independent audit.

Verify locally from the repository root:

```sh
sui move test --path scratch-sui/dex --lint --warnings-are-errors
sui move test --path scratch-sui/example_hook --lint --warnings-are-errors
python3 scripts/check_move_style.py
```
