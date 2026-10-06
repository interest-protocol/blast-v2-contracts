# 0004: Constant-product bonding curve

- Status: proposed
- Date: 2026-08-22
- Amended by: [0041](0041-launch-config-owned-trade-fees.md)

> ADR 0026 clarifies that the sell formula's `burned` amount is a pending-burn
> allocation during bonding, not an immediate supply decrease. It remains
> excluded from curve inventory and is destroyed once at migration.

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |

## Context

Decision D1 fixes one curve: constant product with virtual quote liquidity. Auction and Stable are out of
the initial Sui core (D2). `../protocol-scope.md` requires the formula, scales, virtual reserves,
terminal threshold, and dust policy to be settled before an ABI exists.

The historical implementation is evidence. It computed the quote reserve as
`virtual_liquidity + quote_balance` against the real meme balance
(`memez@00596fd:fun/sources/structs/constant_product.move:90-94, 156-160`) and signalled the terminal
condition as `total_quote_balance >= target_quote_liquidity` (`memez@00596fd:fun/sources/structs/constant_product.move:122`). Two
specific hazards in that code are closed below.

## Decision

### State and units

| Symbol | Meaning | Unit |
| --- | --- | --- |
| `V` | virtual quote liquidity, fixed at launch, never withdrawable | quote atomic units |
| `Q` | real quote held by the curve | quote atomic units |
| `M` | meme inventory held by the curve | meme atomic units |
| `T` | terminal threshold on real quote | quote atomic units |

All arithmetic is in **atomic units on both sides**. No human-readable price appears anywhere in the
on-chain path. The effective quote reserve is `V + Q`; the effective meme reserve is `M`.

### Fee placement

Admins independently configure `QUOTE_FEE_BPS` and `MEME_FEE_BPS` in cold
`LaunchConfig` policy. Each launch snapshots the active pair. A zero rate
disables that asset's fee; either or both rates may be positive. The rates are
fixed for that launch.

On a buy, the quote fee is taken from input before curve math and the meme fee is taken from gross meme
output after curve math. On a sell, the meme fee is taken from input before the progress burn and curve
math, while the quote fee is taken from gross quote output after curve math. Each fee is therefore
denominated and retained in its own asset.

### Buy

```text
quote_fee      = ceil(quote_in_gross * QUOTE_FEE_BPS / 10_000)
quote_net      = quote_in_gross - quote_fee
meme_gross     = floor(M * quote_net / (V + Q + quote_net))
meme_fee       = ceil(meme_gross * MEME_FEE_BPS / 10_000)
meme_net       = meme_gross - meme_fee
M'             = M - meme_gross
Q'             = Q + quote_net
crossed        = Q' >= T
```

`meme_gross` rounds **down** because it bounds the curve payout. Both fees round **up** for the protocol;
the launcher/user receives `meme_net` for slippage purposes.

A buy producing `quote_net == 0`, `meme_gross == 0`, or `meme_net == 0` is **rejected with a named
error**. The vector
`buy_one_atomic_unit` shows the case: one atomic quote unit is entirely consumed by the ceiling fee,
leaving a zero net and a zero output.

### Sell

```text
meme_fee       = ceil(meme_in_gross * MEME_FEE_BPS / 10_000)
meme_after_fee = meme_in_gross - meme_fee
progress_bps   = min(Q * 10_000 / T, 10_000)                 // floor
burn_bps       = MAX_BURN_BPS * progress_bps / 10_000        // floor
burned         = ceil(meme_after_fee * burn_bps / 10_000)    // ceil, seller obligation
meme_eff       = meme_after_fee - burned
quote_gross    = floor((V + Q) * meme_eff / (M + meme_eff))
quote_fee      = ceil(quote_gross * QUOTE_FEE_BPS / 10_000)
quote_net      = quote_gross - quote_fee
M'             = M + meme_eff
Q'             = Q - quote_gross
```

The burn is specified in [ADR 0003](0003-treasury-cap-lifetime-and-burn.md); it appears here because it
changes the curve inputs. Applying the burn to `meme_after_fee` makes both percentage obligations
well-defined without requiring their sum to stay below 10,000 basis points. A sell producing
`meme_after_fee == 0`, `meme_eff == 0`, `quote_gross == 0`, or `quote_net == 0` is rejected with a named
error.

Because a sell requires the `Live` state and crossing `T` leaves it, `progress_bps` on any executable
sell is at most `9_999` and `burn_bps` at most `MAX_BURN_BPS - 1`. The top of the ramp is an asymptote,
not an attained value.

### The clamp hazard, closed

The historical code clamped the payout with `quote_value_out.min(quote_balance_value)`
(`memez@00596fd:fun/sources/structs/constant_product.move:164`) after having already joined the full
meme amount into the reserve. A clamp that binds silently strands value.

Blast does not clamp. Instead it relies on a stated invariant:

> **Sell-back invariant.** For any `meme_in` not exceeding the meme that exists outside the curve
> (`M0 - M`), `quote_gross <= Q`.

The precondition is enforced structurally: a seller can only pass `Coin<Meme>` that exists, and meme only
leaves the curve through a buy that added quote. Burns and fees only increase the reserve relative to
outstanding meme, so they strengthen the invariant.

This invariant is now backed by the deterministic property suite accepted in
[ADR 0021](0021-pure-constant-product-curve-quotes.md). The repository commits:

- the generator, fixed seed `314159`, operation count `256`, and parameter set alongside
  the test, so any reviewer can re-run it and obtain the identical sequence;
- the algebraically equivalent pre-call invariant, so an impossible generated state is identified before
  the production no-clamp guard aborts; and
- an `assert_eq!` trace containing the operation index and all six generated/state inputs on failure;
- the parameters are those in [`../vectors/curve.json`](../vectors/curve.json).

If a parameter set can violate the invariant, the correct response is a named abort, not a silent
clamp.

### The fee-ordering hazard, closed

The historical buy path checked slippage against a net figure while splitting a gross amount from the
reserve and taking fees from the resulting coin afterwards
(`memez@00596fd:fun/sources/structs/constant_product.move:96-112`). Blast applies each asset fee at its
explicit side of the curve calculation and checks the slippage bound against exactly the net asset the
user receives: `meme_net` on buys and `quote_net` on sells. Each enabled fee is deducted exactly once.

### Terminal threshold

`crossed` becomes true when `Q >= T` after a buy. Crossing closes trading and moves the launch to
`MigrationPending`; it never happens on a sell. The launch state at the moment of crossing — `M`, `Q`,
and both decimals — is the sole input to the migration price
([ADR 0005](0005-quote-asset-generalisation.md), [ADR 0010](0010-migration-and-venue-adapters.md)).

### Intermediate width

The proposed parameter set would fit in `u128`, but those ceilings are not accepted function
preconditions. ADR 0021 therefore widens all products and effective-reserve sums to `u256`. A buy result
is bounded by `M`; a sell result is checked against `Q` before narrowing. Post-trade reserve additions
use checked `u64` arithmetic. Helpers are named by rounding direction.

### Proposed parameters

| Parameter | Proposed value | Unit |
| --- | --- | --- |
| meme total supply | `1_000_000_000_000_000_000` | meme atomic (10^9 tokens at 9 decimals) |
| `M0` curve inventory | `800_000_000_000_000_000` | meme atomic |
| `V` virtual quote | `1_000_000_000_000` | quote atomic |
| `T` terminal threshold | `3_000_000_000_000` | quote atomic |
| `QUOTE_FEE_BPS` | `100` | basis points |
| `MEME_FEE_BPS` | `0` | basis points |
| `MAX_BURN_BPS` | `100` | basis points |

**Every value above is proposed, not accepted.** They exist so the vectors are concrete and reviewable.

At these parameters the terminal state is `M_T = 200_000_000_000_000_001` meme atomic and
`Q_T = 3_000_000_000_000` quote atomic for the vectored buy sequence: its final buy is capped at `T`
and refunds the excess Quote ([ADR 0039](0039-deterministic-quote-valuations.md)).

## Alternatives considered

**A fee-asset enum.** Rejected: the two rates already encode none, quote-only, meme-only, and both. An
enum would duplicate that state and add combination branches.

**Apply meme burn and meme fee independently to gross sell input.** Rejected: two individually valid
rates could sum above 100% and underflow. Taking the fee first and burning the remainder composes safely.

**Clamping the sell payout.** Rejected: a binding clamp destroys value with no accounting entry. An
invariant plus a named abort is strictly more honest.

**Rounding `meme_gross` up.** Rejected: it pays more than the curve earned and breaks the
sell-back invariant.

**No virtual liquidity.** Rejected: without it the opening price is zero-divided and the first buy takes
the entire inventory.

## Consequences

- Each launch independently snapshots the admin-owned Quote and Meme fee rates
  active in `LaunchConfig` when the ticket is redeemed.
- Each fee remains denominated in its charged asset, and slippage compares the user's net output.
- Zero-output trades abort rather than silently succeeding.
- The curve never strands value in a clamp.
- The terminal state is fully determined by `M`, `Q`, and the two decimal values, which is what makes the
  generic quote of [ADR 0005](0005-quote-asset-generalisation.md) possible.
- Changing any proposed parameter changes every vector and requires regenerating
  [`../vectors/curve.json`](../vectors/curve.json).

## Verification

- [`../vectors/curve.json`](../vectors/curve.json) — buy, sell, threshold crossing, both burn moments,
  one-atomic-unit boundaries, and a round trip.
- Monotonicity: at fixed fee rates, `meme_net` is non-decreasing in `quote_in` and non-increasing in `Q`.
- Inverse/dust: an immediate round trip returns strictly less quote than it spent; the vectored case
  loses `19_900_001` quote atomic units on a `1_000_000_000` input, of which `1` is curve-retained
  rounding dust and the remainder is fees.
- Property test: the sell-back invariant over 256 reachable buy-then-sell scenarios from fixed seed
  `314159`, with the complete failing scenario printed by the assertion.
- Boundary enumeration: zero, one atomic unit, `T - 1`, `T`, `T + 1`, and maximum supported reserve.
- Width test: executable maximum-`u64` checks for `u256` intermediates and checked reserve narrowing.
