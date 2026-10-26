# Scratch Sui interfaces

These sketches are outside the production surface and must not be published.
Core operations, validation and hook policies deliberately abort. Compilation
proves type linkage only; it does not prove execution, authorization or economics.
Production integrator references exclude these packages.

The design takes the before/after hook idea from Uniswap v4. Each operation
accepts actual coins and returns actual output/change coins. Hooks never return
signed accounting adjustments, and callers never open debts against a shared
manager. There is no separate payment-reconciliation phase.

## Pool-local hook state

Hooks can keep state as dynamic fields owned by the existing shared pool. The
state accessors take the pool plus a reference to the sealed hook witness and
a typed key. Core must require that witness to be registered on this pool,
reject `NoHook`, and namespace fields by its original defining type plus the key.
The same witness can share state across before/after callbacks; different hook
witnesses remain isolated. No accessor exposes the pool UID or core storage.

`example::record_call` shows a hook lazily creating and updating a pool-local
counter; policies receive `&mut Pool` so they can use this access. Its public
`call_count` reader constructs the witness internally and returns only the count.
State values need `store`, not `key`. Dynamic fields are child storage and still
cost storage/access gas, but need no additional shared object input. Pool writes
retain the existing pool contention boundary. Cross-pool global state needs a
separate storage design. These accessors are aborting interface stubs too.

## Swap and hook boundary

The complete before payload is the pool, swap parameters, opaque hook data,
actual payment coin pair and transaction context. The before-hook may validate
and replace parameters/data, split off an explicit fee, transfer coins it is
entrusted with, or consume coins under the required coin authority. Merely
holding a coin does not authorize burning its supply. Hook-supplied funding
must come from actual coins and remain within the approved execution limits.

The wrapper snapshots original parameters and gross coin budgets before policy
mutation and passes both original and adjusted inputs to core. These snapshots
are attested by its sealed witness; core cannot infer what a hook already spent.
The hook module is trusted to snapshot honestly and validate gross caller
funding before its first coin effect. Core still owns reserve conservation,
actual-payment checks, original execution limits and final coin bounds. A hook
that publicly issues its witness defeats its own policy and must not be admitted.

A bundled swap composes the phases in the hook package:

```move
let (asset_coin, quote_coin) = example::swap(
    pool, swap_params, hook_data, asset_payment, quote_payment, ctx,
);
// Transfer or consume both returned coins, including zero coins.
```

Its flow is:

```text
complete swap payload
  before policy: validate / mutate params, data and payment coins
  core execute_swap: consume actual payment, update reserves
    -> Completion + actual output/change coins
  after policy: inspect all core results, mutate / validate returned coins
  core finish_swap: authenticate after approval, check original final bounds
    -> final actual coins
```

The after-hook receives the whole result tuple. Its core-owned `Completion`
is read-only proof of execution; its coin pair is mutable and can be split,
consumed or augmented. It does not receive permission to rewrite core facts.
Core keeps the original caller, limits, gross budgets, actual core payments,
adjusted parameters, hook data and resulting tick in the receipt. Final checks
apply to the coins returned after the after-hook, including output deductions
and input-change consumption. Parameters cannot change the caller's swap
direction or exact-input/output mode, loosen the price limit or exceed the
original gross spend bound. Exact-input amount is the gross budget before hook
fees, with the approved remainder traded; exact-output amount is the final user
output target. Swaps require a zero coin on the output side; existing output
funding cannot count toward the minimum receipt. Insufficient payment or a final
bound failure aborts everything.

This is two core transition calls, `execute_swap` and `finish_swap`; policy
reads may add calls. Individual before/after wrappers remain available for PTB
composition and independently configured callback packages. With after-swap
disabled, `example::swap_without_after` uses a single
`pool::execute_swap_without_after` transition and returns coins directly. Core
must reject that shortcut when after-swap is enabled. A disabled before callback
uses `NoHook` directly, with unchanged parameters, matching gross budgets and no
fee override; `NoHook` never authorizes an enabled callback.

The completion has no abilities. Its mandatory final consumption enforces
after approval in the same PTB even though coins are passed separately. Every
consumer checks pool identity, operation and a strictly increasing current pool
nonce. An overlapping operation stales an earlier receipt; its mandatory
consumption must abort rather than silently discard it. These checks remain
implementation requirements, not guarantees supplied by the current stubs.

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

Registration binds each callback slot to its original defining witness type and
rejects overlap. Sealing the initializer freezes the configuration; no setter
accepts a ready pool. Before and after slots may belong to different packages.
`NoHook` is for disabled callbacks only and cannot be registered. There are ten
callback flags; accounting-return flags are unsupported bits and must be
rejected. Hooks must keep their witness constructors private.

Adding/removing liquidity and donations follow the same actual-coin execution
and after-approval flow. Liquidity callers supply an owned position and validated
parameters; core checks its ID, pool and tick range. Removing zero liquidity
collects accrued fees as actual coins. Donations credit actual funded amounts
to eligible LP fees and never mint liquidity. Both returned coins always need a
consumer, even when one or both are zero.

Fees remain in ppm. `SwapFee` combines the immutable Fixed/Dynamic mode and its
current rate. Only Dynamic permits a before-swap override or an authorized
cached-rate update; an override does not change the stored rate. Ticks retain
the checked, two's-complement `I32` type, with int24/range/spacing checks in core.

Before promotion, implement and test witness checks, disabled-hook routing,
immutable caller bounds, nonce binding, hook-state namespace/authority checks,
fee/slippage checks, actual coin custody, reserve conservation and LP fee entitlement.
Real PTB execution, economic and
security behavior are not established by interface compilation. No PoolManager,
flash-accounting or aggregator compatibility is claimed.
