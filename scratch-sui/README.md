# Scratch Sui interfaces

These sketches are outside the production surface and must not be published.
Aborting bodies deliberately leave behavior unimplemented; compilation proves
only type linkage, not authorization, settlement, or transaction execution.

The DEX owns the pool and linear swap obligations. The separate example hook
depends inward on the DEX and privately constructs its approval witness. The
DEX has no hook, launchpad, or administration package dependency.

The intended transaction passes each returned value to the next call:

```move
let request = pool.begin_swap(input, minimum_output);
let completion = example::before_swap(pool, request, ctx);
let output = example::after_swap(pool, completion);
// The caller consumes or transfers output.
```

Before implementation, define the registered witness admission, pool and
operation binding, phase ordering, operation lock, fee and slippage bounds,
reserve conservation, and settlement checks. Hook-owned dynamic state,
opposite-direction swaps, liquidity operations, and quoting are outside this
interface sketch.

The old native V2 implementation and its tests were removed. Historical ADRs
and research remain historical evidence, not a specification for these sketches.
