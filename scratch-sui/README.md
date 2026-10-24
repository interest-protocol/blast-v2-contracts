# Scratch Sui interfaces

These sketches are outside the production surface and must not be published.
Aborting bodies deliberately leave behavior unimplemented; compilation proves
only type linkage, not authorization, settlement, or transaction execution.

The DEX owns the pool, positions, initializer, and linear operation obligations.
The independent example hook packages depend inward on the DEX and privately
construct their approval witnesses. The DEX imports neither hook package.

The hook surface follows Uniswap v4's
[IHooks](https://github.com/Uniswap/v4-core/blob/bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6/src/interfaces/IHooks.sol)
and [permissions](https://github.com/Uniswap/v4-core/blob/bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6/src/libraries/Hooks.sol):
before/after initialization, adding liquidity, removing liquidity, swapping,
and donating. It includes the four return-delta permissions, per-swap fee
overrides and cached dynamic fee updates, original caller context, and opaque
hook data. Permissions use a `u16` bitmap with named flag macros; construction
must reject unknown bits and delta bits without their matching callback.
Fees use parts per million (1,000,000 is 100%).

The intended construction returns a `PoolInitializer` with no abilities. It owns
the unfinished pool, so trading and publication cannot receive a `Pool` yet.
Hook packages register non-overlapping callback slots on the initializer. For
example, use one package for initialization, swaps, and donations, and another
for liquidity:

```move
let mut initializer = pool::new<Asset, Quote>(
    tick_spacing, true, fee_ppm, sqrt_price_x96, ctx,
);
let liquidity_flags = liquidity::hook_flags!();
example::register_hooks(
    &mut initializer, pool::all_hook_flags!() ^ liquidity_flags,
);
liquidity::register_hooks(&mut initializer);
let request = pool::begin_initialize(initializer, ctx);
let completion = example::before_initialize(request);
let pool = example::after_initialize(completion);
pool.share();
```

`begin_initialize` consumes the initializer and freezes its bindings. Each
callback bit names its own original defining witness type, so even the before
and after callbacks of one operation can belong to different packages.
`finalize`, called by the after-initialize hook, consumes the final construction
obligation and returns the ready pool. Hook setters exist only on the initializer;
there is no `initialized` or `in_flight` flag.

For a disabled callback, callers use core's `NoHook` witness with the matching
execute/finalize/finish function. It must be rejected for enabled slots, hook
registration, hook ledgers, nonzero deltas, and fee overrides. Real hooks must
keep their witness constructors private; core checks type identity, not package
policy.

Each later operation passes its typed request and completion through the hook.
For example, a swap produces a settlement obligation rather than a free output:

```move
let request = pool.begin_swap(swap_params, hook_data, ctx);
let completion = example::before_swap(pool, request);
let mut settlement = example::after_swap(pool, completion);
let (caller_asset, caller_quote) = pool.settle_caller(
    &mut settlement, caller_asset_payment, caller_quote_payment, ctx,
);
let (hook_asset, hook_quote) = example::settle_hook(
    pool, &mut settlement, hook_asset_payment, hook_quote_payment, ctx,
);
pool.finish_settlement(settlement);
// Consume or transfer all four payout/change coins, including zero coins.
```

With the configuration above, adding and removing liquidity pass an owned
position through `liquidity`'s before/after hooks, then the same settlement flow.
Removing zero liquidity is the fee-collection path. Donations run both donation
hooks and settle a debt
credited to eligible LP fees, without minting liquidity.

Swap hooks can return specified/unspecified deltas before execution and an
unspecified delta afterward; liquidity after-hooks can return both token deltas.
Positive deltas mean the recipient is owed coins; negative deltas mean it must
pay. Settlement records a separate ledger for each delta-producing witness
type, at most two per operation; before/after deltas from the same type net into
one ledger. The caller and every recorded hook ledger settle exactly once,
including zero deltas, before the settlement can be consumed. Final user bounds
apply to combined deltas before a settlement is issued. Hook payouts and funding
require hook-owned authorization policy. Cached dynamic fee updates belong only
to the configured before-swap witness.

Runtime obligations carry a strictly increasing pool nonce that must never wrap.
Every consuming or settling function must check that it is current. Starting an overlapping
operation makes an earlier obligation stale; because it cannot be dropped,
stored, or discarded, consuming it must abort the entire transaction. This
requires every path to enforce the nonce, including final settlement; it is an
intended alternative to a mutable busy flag, not behavior proved by these stubs.

Before implementation, define witness admission, permission enforcement and
disabled-hook routing, phase ordering, pool/position/nonce binding, mandatory
obligation consumption, bounded hook data, tick/price and signed-value validation,
fee/slippage bounds, LP fee entitlement, actual-coin settlement, and reserve conservation.
All of these remain unimplemented. The sketches do not establish full
PoolManager, flash-accounting, EVM callback, or aggregator compatibility.

The old native V2 implementation and its tests were removed. Historical ADRs
and research remain historical evidence, not a specification for these sketches.
