# 0004: Constant-product bonding curve

- Status: proposed
- Date: 2026-08-22

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

**All trade fees are charged in the quote asset.** On a buy the fee is taken from the quote in, before
the curve math. On a sell the fee is taken from the quote out, after the curve math. This removes
meme-side fee accounting from the curve entirely and makes conservation a single-asset statement per
side.

### Buy

```text
fee        = ceil(quote_in_gross * TRADE_FEE_BPS / 10_000)
quote_net  = quote_in_gross - fee
meme_out   = floor(M * quote_net / (V + Q + quote_net))
M'         = M - meme_out
Q'         = Q + quote_net
crossed    = Q' >= T
```

`meme_out` rounds **down**: a user payout rounds down, per `../engineering-principles.md`.
`fee` rounds **up**: a protocol fee rounds up.

A buy producing `meme_out == 0` is **rejected with a named error**. The vector
`buy_one_atomic_unit` shows the case: one atomic quote unit is entirely consumed by the ceiling fee,
leaving a zero net and a zero output.

### Sell

```text
progress_bps = min(Q * 10_000 / T, 10_000)                 // floor
burn_bps     = MAX_BURN_BPS * progress_bps / 10_000         // floor
burned       = ceil(meme_in * burn_bps / 10_000)            // ceil, seller obligation
meme_eff     = meme_in - burned
quote_gross  = floor((V + Q) * meme_eff / (M + meme_eff))
fee          = ceil(quote_gross * TRADE_FEE_BPS / 10_000)
quote_net    = quote_gross - fee
M'           = M + meme_eff
Q'           = Q - quote_gross
```

The burn is specified in [ADR 0003](0003-treasury-cap-lifetime-and-burn.md); it appears here because it
changes the curve inputs. A sell producing `quote_net == 0`, or `meme_eff == 0`, is rejected with a named
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

This invariant is **not yet backed by committed evidence**. It is asserted here as a design requirement
and must be converted at the implementation stage by a seeded property test that is reproducible from the
repository:

- the generator, the fixed CI seed, the operation count, and the parameter set are committed alongside
  the test, so any reviewer can re-run it and obtain the identical sequence;
- a failure prints the full operation trace needed to reproduce it, per `../testing.md`;
- the parameters are those in [`../vectors/curve.json`](../vectors/curve.json).

No violation count is claimed in this document, because no generator is committed to substantiate one.

If a parameter set can violate the invariant, the correct response is a named abort, not a silent
clamp.

### The fee-ordering hazard, closed

The historical buy path checked slippage against a net figure while splitting a gross amount from the
reserve and taking fees from the resulting coin afterwards
(`memez@00596fd:fun/sources/structs/constant_product.move:96-112`). Blast takes the fee **before** the
curve math on buys and **after** it on sells, and checks the slippage bound against exactly the amount
the user receives. There is one fee deduction per trade and one slippage comparison, against the same
number.

### Terminal threshold

`crossed` becomes true when `Q >= T` after a buy. Crossing closes trading and moves the launch to
`MigrationPending`; it never happens on a sell. The launch state at the moment of crossing — `M`, `Q`,
and both decimals — is the sole input to the migration price
([ADR 0005](0005-quote-asset-generalisation.md), [ADR 0010](0010-migration-and-venue-adapters.md)).

### Intermediate width

`M <= 10^18 < 2^60`. `quote_net <= u64::MAX < 2^64`. The product `M * quote_net < 2^124`, so a `u128`
intermediate is sufficient with margin, and the division result is bounded by `M`, so the narrowing back
to `u64` is proved rather than assumed. `(V + Q) * meme_eff` is bounded identically. Helpers are named by
rounding direction.

### Proposed parameters

| Parameter | Proposed value | Unit |
| --- | --- | --- |
| meme total supply | `1_000_000_000_000_000_000` | meme atomic (10^9 tokens at 9 decimals) |
| `M0` curve inventory | `800_000_000_000_000_000` | meme atomic |
| `V` virtual quote | `1_000_000_000_000` | quote atomic |
| `T` terminal threshold | `3_000_000_000_000` | quote atomic |
| `TRADE_FEE_BPS` | `100` | basis points |
| `MAX_BURN_BPS` | `100` | basis points |

**Every value above is proposed, not accepted.** They exist so the vectors are concrete and reviewable.

At these parameters the terminal state is `M_T = 196_608_503_317_768_494` meme atomic and
`Q_T = 3_069_000_000_000` quote atomic for the vectored buy sequence.

## Alternatives considered

**Fees on both sides, as in the historical code.** Rejected: it doubles the fee accounting surface and
was the source of the gross/net ordering hazard.

**Clamping the sell payout.** Rejected: a binding clamp destroys value with no accounting entry. An
invariant plus a named abort is strictly more honest.

**Rounding `meme_out` up.** Rejected: it pays the user more than the curve earned and breaks the
sell-back invariant.

**No virtual liquidity.** Rejected: without it the opening price is zero-divided and the first buy takes
the entire inventory.

## Consequences

- One fee asset, one slippage comparison, one rounding beneficiary per division.
- Zero-output trades abort rather than silently succeeding.
- The curve never strands value in a clamp.
- The terminal state is fully determined by `M`, `Q`, and the two decimal values, which is what makes the
  generic quote of [ADR 0005](0005-quote-asset-generalisation.md) possible.
- Changing any proposed parameter changes every vector and requires regenerating
  [`../vectors/curve.json`](../vectors/curve.json).

## Verification

- [`../vectors/curve.json`](../vectors/curve.json) — buy, sell, threshold crossing, both burn moments,
  one-atomic-unit boundaries, and a round trip.
- Monotonicity: `meme_out` is non-decreasing in `quote_in` and non-increasing in `Q`.
- Inverse/dust: an immediate round trip returns strictly less quote than it spent; the vectored case
  loses `19_900_001` quote atomic units on a `1_000_000_000` input, of which `1` is curve-retained
  rounding dust and the remainder is fees.
- Property test: the sell-back invariant, with a fixed CI seed and enough operations printed to
  reproduce any failure.
- Boundary enumeration: zero, one atomic unit, `T - 1`, `T`, `T + 1`, and maximum supported reserve.
- Width test: an executable check that the `u128` intermediate cannot overflow at maximum supported
  inputs, per `../engineering-principles.md` requiring toolchain-backed evidence rather than prose.
