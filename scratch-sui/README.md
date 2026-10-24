# Scratch Sui interfaces

These sketches are outside the production surface and must not be published.
Aborting bodies deliberately leave behavior unimplemented; compilation proves
only type linkage, not authorization, settlement, or transaction execution.

The DEX owns the pool, positions, and linear operation obligations. The separate
example hook depends inward on the DEX and privately constructs its approval
witness. The DEX has no hook, launchpad, or administration package dependency.

The hook surface follows Uniswap v4's
[IHooks](https://github.com/Uniswap/v4-core/blob/bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6/src/interfaces/IHooks.sol)
and [permissions](https://github.com/Uniswap/v4-core/blob/bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6/src/libraries/Hooks.sol):
before/after initialization, adding liquidity, removing liquidity, swapping,
and donating. It includes the four return-delta permissions, per-swap fee
overrides and cached dynamic fee updates, original caller context, and opaque
hook data. Permissions use a `u16` bitmap with named flag macros; construction
must reject unknown bits and delta bits without their matching callback.
Fees use parts per million (1,000,000 is 100%).

The intended initialization returns an owned pool, then runs both hook phases
before publication. Creation alone must not permit trading:

```move
let mut pool = example::new_pool<Asset, Quote>(tick_spacing, true, fee_ppm, ctx);
let request = pool.begin_initialize(sqrt_price_x96, ctx);
let completion = example::before_initialize(&mut pool, request);
example::after_initialize(&mut pool, completion);
pool.share();
```

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

Adding and removing liquidity use an owned position and their respective
before/after hooks, then the same settlement flow. Removing zero liquidity is
the fee-collection path. Donations run both donation hooks and settle a debt
credited to eligible LP fees, without minting liquidity.

Swap hooks can return specified/unspecified deltas before execution and an
unspecified delta afterward; liquidity after-hooks can return both token deltas.
Positive deltas mean the recipient is owed coins; negative deltas mean it must
pay. The caller and hook settle separately, including zero deltas, before the
pool unlocks. Final user bounds apply to combined deltas before a settlement
is issued. Hook payouts and funding require hook-owned authorization policy.

Before implementation, define witness admission, permission enforcement and
disabled-hook routing, phase ordering, pool/position/nonce binding, operation
locks, bounded hook data, tick/price and signed-value validation, fee/slippage
bounds, LP fee entitlement, actual-coin settlement, and reserve conservation.
All of these remain unimplemented. The sketches do not establish full
PoolManager, flash-accounting, EVM callback, or aggregator compatibility.

The old native V2 implementation and its tests were removed. Historical ADRs
and research remain historical evidence, not a specification for these sketches.
