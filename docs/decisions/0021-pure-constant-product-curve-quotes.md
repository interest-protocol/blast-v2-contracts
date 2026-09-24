# 0021: Pure constant-product curve quotes

- Status: accepted
- Date: 2026-08-23
- Partially accepts: [0004](0004-bonding-curve.md)
- Amended by: [0041](0041-launch-config-owned-trade-fees.md), [0077](0077-fixed-creator-selected-sell-burn.md), [0078](0078-explicit-curve-invariant-primitives.md), and [0079](0079-compact-launch-state-and-events.md)

## Sources

This record introduces no new external ABI fact. The formula and historical evidence remain cited by
[ADR 0004](0004-bonding-curve.md); this record accepts only the Blast-owned arithmetic boundary below.

## Context

The next launchpad slice needs deterministic buy and sell arithmetic before launch storage, coin
movement, migration, or a venue adapter can be audited. Accepting a stored `Launch` layout at the same
time would mix lifecycle, accounting, and arithmetic concerns. Hard-coding the example values in ADR
0004 would also turn unapproved deployment economics into package constants.

The future launch module is the concrete production consumer. It needs package-internal quotes that
return every amount required for slippage checks, reserve mutation, fee accounting, burn accounting,
threshold transition, and event construction without making any of those effects happen inside the
math module.

## Decision

`curve.move` owns package-only quote and invariant functions. They are pure
numeric functions. `quote_buy` and `quote_sell` share `get_amount_out`, and `k`
computes the widened reserve product. An inverse helper is deferred until an
exact-output consumer exists. They create no objects, hold no state,
accept no coins or balances, emit no events, transfer nothing, and import no venue package. The future launch module remains responsible for
checking lifecycle and slippage, applying the returned deltas, splitting fees,
moving the returned burn-designated meme amount into pending custody, and
emitting the completed trade fact. ADR 0026 owns its terminal destruction.

Both functions accept the launch-specific reserves, action input, and configured rates as `u64`
atomic units or basis points. Each
future launch stores the `quote_fee_bps` and `meme_fee_bps` pair snapshotted from
`LaunchConfig`; those rates are fixed for that launch. A zero rate disables fees in that asset, so `(0, 0)`, quote-only, meme-only, and both are
represented without a mode enum. No deployment value is hard-coded. The concrete values in ADR 0004
and `docs/vectors/curve.json` remain proposed fixtures, not accepted protocol defaults.

The accepted formulas and rounding are:

- buy quote fee: `ceil(quote_in_gross * quote_fee_bps / 10_000)`, before curve math;
- buy gross meme output: `floor(M * quote_in_net / (V + Q + quote_in_net))`;
- buy meme fee: `ceil(meme_out_gross * meme_fee_bps / 10_000)`, after curve math;
- buy user output: gross meme output minus meme fee;
- sell meme fee: `ceil(meme_in_gross * meme_fee_bps / 10_000)`, before burn and curve math;
- sell burn rate: the immutable creator-selected rate, capped at 5,000 basis points by ADR 0077;
- sell pending-burn allocation: ceiling on the post-fee meme input, because it is the seller's obligation;
- sell gross quote output: `floor((V + Q) * meme_in_effective / (M + meme_in_effective))`;
- sell quote fee: `ceil(quote_out_gross * quote_fee_bps / 10_000)`, after curve math; and
- sell net quote output: gross output minus that fee.

User payouts round down. Protocol fees and seller pending-burn obligations round up. Each quote returns
only the fees, gross output, net output, and sell pending-burn amount required by its caller. `Launch`
derives reserve movement and lifecycle from the balances it actually mutates. On a buy the curve reserve loses the gross meme output while the caller
separates the meme fee from the user's net output. On a sell neither the meme fee nor pending-burn meme enters
the curve; only `meme_in_effective` increases its reserve. Tuples keep the interface package-only and
avoid committing a public quote struct before an external consumer exists.

Validation order is part of the package contract: reserves, quote-fee bound,
meme-fee bound, sell-burn bound when applicable, nonzero input, derived post-fee/effective input,
representable post-trade reserve, nonzero gross output, sell-back invariant, and nonzero net output.
Named errors in `blast_fun::errors` identify these failures.

All products and effective-reserve sums widen to `u256`. Narrowing is permitted only after the formula
or an explicit invariant bounds the result by an input `u64`. Stored post-trade reserve additions use
checked arithmetic. This supports the full accepted `u64` input domain without relying on the still
proposed supply and reserve ceilings in ADR 0004.

The sell calculation never clamps. It computes the full quote in `u256`, asserts that it does not exceed
real quote, and only then narrows and subtracts. A violation aborts with
`sell_back_invariant_violated`.

The launch layer derives threshold crossing from its final real Quote balance.

## Alternatives considered

**Implement `Launch` state and curve arithmetic together.** Rejected for this slice: a reviewer would
have to audit lifecycle, storage, coins, fees, events, and math at once.

**Return a public quote struct.** Rejected until an external-package consumer exists. It would create an
immutable public type commitment only to make an internal call site more descriptive.

**Hard-code the proposed parameters.** Rejected: review vectors need concrete examples, but deployment
economics have not been accepted.

**Store a fee-asset enum.** Rejected: two independently bounded rates express every choice directly.
An enum would duplicate information already carried by whether each rate is zero and would need a
separate variant for every combination.

**Clamp sell output to real quote.** Rejected: a binding clamp silently strands meme value and conceals
an impossible reserve state.

**Use `u128` because the proposed values fit.** Rejected: the functions accept `u64` parameters, while
the proposed parameter ceilings are not accepted preconditions. `u256` makes the actual function domain
match its arithmetic proof.

## Consequences

- The next slice can introduce one launch-state module and treat curve arithmetic as a reviewed leaf.
- There is no new public transaction ABI, stored object layout, event schema, or external dependency.
- Quote and meme fees are quoted here but remain assets owned and distributed by the future accounting
  caller.
- Parameter bounds beyond basis-point validity remain a launch-configuration decision.
- An EVM implementation must reproduce the same formulas, order, and rounding from shared vectors.

## Verification

- Exact committed vectors cover opening and mid buys, threshold crossing, mid and maximum-live sells,
  the pure full-progress boundary, and immediate round-trip dust.
- Named tests cover no fees, quote-only, meme-only, and both; negative tests cover every error and guard
  precedence, including zero input/output, full fee, full burn, reserve overflow, and the no-clamp
  invariant abort.
- Monotonicity tests cover buy output against increasing input and existing quote reserve.
- Maximum-`u64` tests exercise widened reserve sums, products, and checked post-trade reserves.
- The sell-back test uses fixed seed `314159` for `256` deterministic reachable buy-then-sell scenarios
  cycling through all four fee-asset choices; the seed, generator, operation count, and parameter set
  are committed in `curve_tests.move`.
- Build, strict lint, full tests, structural source checks, and Move coverage are release gates.
