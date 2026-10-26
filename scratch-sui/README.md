# Scratch Sui interfaces

These sketches are outside the production surface and must not be published.
Core operations, validation and hook policies deliberately abort. Compilation
proves type linkage only; it does not prove execution, authorization or economics.
Production integrator references exclude these packages.

The design takes the before/after lifecycle hook idea from Uniswap v4. Operations
move actual funds. There are no signed accounting adjustments, hook debt ledgers
or payment-reconciliation phases.

## Before-hook, sealed request and execution

The before-hook receives the pool, operation parameters, payment coins and
transaction context. Liquidity hooks also inspect the owned position. It can
read its own pool-local state and public pool state, simulate
the operation, reject parameters, change the payload, or retain an explicit fee.
Keeping or transferring coins does not grant authority to burn their supply.
Core does not interpret or impose the hook's policy. Hook-specific inputs belong
in the hook's own typed arguments; core requests and completions carry no opaque
hook payload.

After its policy succeeds, the hook calls the corresponding `pool::prepare_*`
with its sealed witness, chosen parameters and the remaining payments as
`Balance<Asset>` and `Balance<Quote>`. Core authenticates the configured before
witness and wraps that entire payload in a core-owned `Request`. The request
also captures pool ID, economic nonce and caller. It has no abilities; its
private fields cannot be rewritten or its balances removed by other packages.
There is no public constructor that bypasses witness authentication.

```text
hook::before_swap(pool, params, payment coins, ctx)
  read hook's dynamic fields and public pool state
  simulate expected payments / post-swap pool state, without writes
  apply hook policy: validate, change parameters, retain coins, update own state
  pool::prepare_swap(witness, params, payment balances, fee override, ctx)
    -> sealed Request owning the chosen payload

pool::execute_swap(pool, request, ctx)
  authenticate pool / operation / caller / current nonce
  consume request and execute its wrapped parameters and balances
  recompute against live state; validate payment and preserve core invariants
    -> Completion + actual output/change coins

hook::after_swap(pool, completion, output/change coins, ctx)
  inspect immutable execution facts; validate / mutate actual coins by policy
  pool::finish_swap(witness, completion, coins)
    -> final coins
```

The request is both proof of the pre-hook's approval and the execution payload.
The caller cannot obtain approval for one payload and substitute different
parameters or balances when executing. Core enforces its own pricing, actual
funding, execution bounds, reserve conservation and position authority. It does
not duplicate hook checks or maintain original-versus-adjusted parameter copies,
gross hook budgets, hook fee accounting or automatic post-hook user bounds.
Checks spanning both hooks belong to a caller or bundled wrapper that chooses
to enforce them. Simulations do not authorize execution or reserve a pool.

The hook may simulate again after changing parameters or payments. A simulation
returns projected payments/receipts, price, tick, active liquidity, LP fee and
fee growth, with resulting position liquidity for liquidity operations. It is
read-only value data and cannot be applied as trusted state changes. Execution
must use the same economic math while recomputing from live state. Full AMM
state and per-tick economic implementation remain outside this sketch.

`example::swap` bundles these phases into one external call. It uses three core
lifecycle calls: prepare, execute and finish. Simulation and state access add
read/accessor calls. With after-swap disabled, `example::swap_without_after`
uses prepare plus execute and returns coins directly. Core must reject that
shortcut when after-swap is enabled.

The after-hook receives immutable core execution facts and the mutable actual
coin pair. Core requires after approval but does not enforce the hook's policy,
returned coin amounts or any original hook-wide budget. Both coins need a
consumer, even when zero. The completion has no abilities, requiring after
approval in the same PTB. Request and completion consumers authenticate pool,
operation and current economic nonce. Overlapping core operations stale earlier
obligations; mandatory consumption must abort instead of accepting stale state.

## Pool-local hook state

Hooks can keep state as dynamic fields owned by the existing shared pool. The
state accessors take the pool, a reference to the sealed hook witness and a
typed key. Core must require that witness to be registered on this pool, reject
`NoHook`, and namespace fields by its original defining type plus the key.
Before/after slots using the same witness share state; different witnesses are
isolated. No accessor exposes the pool UID or core storage.

The example hook shows a lazily created pool-local counter. Its policies have
`&mut Pool` so they can update their own fields; the simulation calls themselves
accept only immutable references and do not write state. State values need
`store`, not `key`. Dynamic fields cost storage/access gas, but need no second
shared object input. Pool writes retain the existing contention boundary.
Cross-pool global state requires a separate storage design.

## Creation and independent hooks

The DEX owns pools, positions and lifecycle receipts, and imports neither example
hook package. Both hooks depend inward on DEX. Initialization returns an owned,
no-ability `PoolInitializer`; only this unfinished type permits registration.

```move
let mut initializer = pool::new<Asset, Quote>(
    tick_spacing, swap_fee::new_dynamic(fee_ppm), sqrt_price_x96, ctx,
);
let liquidity_flags = liquidity::hook_flags!();
example::register_hooks(
    &mut initializer, permissions::all_hook_flags!() ^ liquidity_flags,
);
liquidity::register_hooks(&mut initializer);
let request = pool::begin_initialize(initializer, ctx);
let completion = example::before_initialize(request);
let pool = example::after_initialize(completion);
pool.share();
```

Registration binds callback slots to original defining witness types and rejects
overlap. Sealing the initializer freezes configuration; no setter accepts a ready
pool. Before and after slots may belong to different packages. Hooks must keep
witness constructors private. Core can authenticate their types, but cannot prove
a hook package keeps its own witness sealed or implements a particular policy.
`NoHook` is disabled-only, including request preparation, and cannot be registered.
There are ten lifecycle flags; accounting-return flags are unsupported bits.

Liquidity and donation operations follow the same request owning balances and
mandatory after-approval flow. Liquidity execution checks the supplied owned
position against the wrapped parameters, pool and tick range. Removing zero
liquidity collects accrued fees; donations fund LP fees without minting liquidity.

Fees use ppm. Fixed/Dynamic mode is immutable; only Dynamic permits a configured
before-swap override or authorized cached-rate update. An override does not
change the stored rate. Ticks use checked, two's-complement `I32`, with int24,
pool-range and spacing checks in core.

Before promotion, implement and test proof issuance/consumption, stale-state
rejection, disabled-hook routing, namespace isolation, simulation/execution
agreement, actual balance custody, arithmetic, pricing and LP entitlement.
Runtime PTB behavior and economic/security safety are not established here.
