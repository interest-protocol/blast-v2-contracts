# Leverage coins: implementation lessons and required rules

Status: required reading. Read this file completely before implementing or
changing `sui/leverage_coins/series_one/`, the `blast_leverage_aftermath`
adapter, or any SDK code that mirrors their math.

This file collects the rules that the pure Series1 accounting library cannot
enforce by itself. Each rule came out of the
[2026-09-01 design review](research/claude-opus-5-leverage-design-audit-2026-09-01.md),
the [2026-09-02 Phase 1 code audit](research/claude-fable-5-1-leverage-coins-audit-2026-09-02.md),
or the [2026-09-03 Series1 audit](research/claude-fable-5-1-leverage-coins-audit-2026-09-03.md).
The audit records explain the evidence; this file states what the next
implementer must do. When a rule below is implemented and tested, move it to
the package README or the relevant ADR and delete it here.

## 1. Rules for the Series and adapter

### 1.1 Size the mint order from the expected contribution, verify with both

The pure sizing formula takes a contribution. Before the trade only the
expected contribution `deposit - fee` exists, and that is what sizes the sealed
order through `accounting_math::mint_base_delta_from_equity_down`. After the
trade the actual contribution `nav_after - nav_before` prices the shares. The
Series must then call `assert_mint_base_within_bounds_from_equity` with both
values and the final absolute base. Never pass the post-trade contribution as
the sizing input, and never skip the post-fill assertion because the venue
reported a full fill: the assertion also proves the actual contribution is not
dust.

Why: the audit showed the two inputs can disagree by a whole lot at a rounding
boundary, and a full fill required for mints is a venue claim, not an accounting
proof.

### 1.2 Always supply the Series' immutable `min_exposure_lots`

Every exposure function takes `min_exposure_lots`. It must come from the
immutable `SeriesPolicy`, never from a caller or a live setter. Selecting the
value is a simulation gate, but the shape of the decision is fixed:

- Relative under-exposure per mint and over-reduction per redemption are both
  below `1 / min_exposure_lots`.
- After any sequence of legal mints, accounting leverage stays close to
  `L0 * (N0 / N)^(1 / min_exposure_lots)`, a lower bound whose attained worst
  case is `1 / (min_exposure_lots + 1)`. With one lot a 2.0x pool leaves the
  1.8x band on worst-case mint 2,229 and sits at 1.7397x after 3,000 mints
  and 32 percent NAV growth. With one hundred lots the same sequence stays at
  1.9455x after 3,000 mints and sixteen times NAV growth. Both facts are
  pinned exactly by package tests.
- The minimum has a sharp lock condition, recorded in `docs/accounting.md`.
  The Vault must evaluate `accounting_math::is_redemption_possible` and
  `is_exposure_above_minimum_operation` in its health transition and degrade
  on a false result, and it must ship a primitive that reopens exposure from
  flat, because a flat position with live shares can never mint again.
- `lot_size * min_exposure_lots` must stay small in collateral terms so a
  small holder can still exit. Compute it against the live Aftermath lot size
  for the SUI-USDC market (premise P16) and state the resulting minimum mint
  and redemption in USDC in the Series ADR.
- A redemption that reaches flat is exempt, so a complete close is always
  possible regardless of size.

### 1.3 Bound the redemption gross exactly as the mint contribution

`redemption_accounting_quote` returns `proportional_claim` beside `gross`. The
redemption transition must call
`policy::assert_redemption_gross_within_bound(proportional_claim, gross)` with
those two values before it pays `net`, never with a claim it derived itself.
Without the call, every unit by which the post-unwind reading exceeds the
pre-unwind one is paid to the redeemer in full, however few shares they burn,
and no non-dilution invariant can see it. The production
`max_redemption_gross_divergence_bps` is a simulation gate selected separately
for the long and short Series, like its mint twin.

Why: the 2026-09-03 audit showed one share of a million capturing a 100-unit
pool-wide gain, and the canonical suite had never exercised a favorable unwind.

### 1.4 Compute every economic value once at its canonical checkpoint

`mint_accounting_quote` computes the fee once and passes the derived
contribution down; the low-level formula no longer recomputes it. Keep that
discipline in every state transition: a value that the transition reads back
from a helper must be the same value it used to mutate state. A discarded
return from a second computation is a hazard, not a convenience.

### 1.5 Cheap checks before wide arithmetic, and precedence is API

Every guard that needs no computed value runs before any `mul_div`. The
package pins guard precedence with pairwise invalid-input tests. When the
Series adds guards in front of these functions, follow the ADR order: version
and authority, object binding, lifecycle, input bounds, external health,
arithmetic, then post-execution reconciliation. Add a precedence test for each
new pair of overlapping invalid inputs.

### 1.6 Every new error code ships with four things

A registry assertion in `errors_tests.move`, at least one `expected_failure`
test that pins both the code and the raising module, a row in the package
README registry, and, when the code is raised from more than one module, every
module listed in that row. The launchpad's `docs/error-codes.md` points at the
package registry; the numeric spaces are independent.

### 1.7 Keep raw NAV-taking formulas private

`accounting_math` owns both raw formulas and their reserve-aware package API.
Every function that accepts already-derived shareholder NAV stays private. A
new NAV-taking formula must ship with a reserve-aware package function in the
same module; expose the raw form only through an explicit test-only seam. The
Series must only ever supply venue equity and reserve, never a NAV it derived
itself.

### 1.8 Test shape that the package expects

Every formula has an exhaustive small-domain test against an independent
reference, a maximum-width boundary test, a property test for its rounding
beneficiary, and, where a sequence matters, a regression that runs the
sequence. Keep an exhaustive sweep under roughly ten thousand iterations of
the helper it exercises; the test runner's gas budget times out above that,
which the audit hit once at twenty-six thousand.

### 1.9 Pass the depositor's share floor through unchanged

`mint_accounting_quote` takes `min_shares_out`. It is the depositor's own
floor on `shares_out` and the only in-package bound on the rounding loss a
mint can suffer, which is otherwise capped only by the share price the seed
sets. The Series must take it from the depositor's transaction and pass it
through unchanged; it must never substitute zero or a policy value. The seed
sizing rule that keeps one share economically dust is in `docs/accounting.md`
and is a release gate on the seed slice.

### 1.10 Run every valuation gate at the one operation checkpoint

The `ValuationPolicy` type in `series_one/sources/policy.move` owns the freshness,
confidence, and mark-divergence rules, but it cannot see how many times or
against what a caller applies them. The Series and adapter must:

- capture one on-chain millisecond reading per operation and pass that same
  value as `reference_time_ms` to every `assert_price_fresh` call, so the two
  share-pricing sources are judged against one reference;
- run `assert_price_fresh` and `assert_confidence_within_bound` for both the
  base index and the collateral oracle before deriving pre-operation
  shareholder NAV, and prove the post-operation NAV used the same pair;
- keep `assert_mark_within_index_divergence` on the venue margin path only. Its
  operands must never reach `accounting_math`; the
  source-boundary script fails if a standalone or snake-case `mark` identifier
  appears there, while semantic review still verifies arbitrary numeric inputs;
  and
- use `is_price_fresh`, `is_confidence_within_bound`, and
  `is_mark_within_index_divergence` inside the objective health transition,
  rather than their aborting guards, so any valuation-policy failure degrades
  the lifecycle instead of rolling the observing transaction back;
- evaluate the health predicates in the documented order, `is_reserve_backed`,
  then `is_shareholder_nav_positive`, then valuation, then leverage against
  `is_hard_emergency`, then `is_redemption_possible`, and persist the result
  through `lifecycle::degrade_to_reduce_only` or `degrade_to_shutdown_pending`.
  The strict `enter_*` transitions abort on an already-degraded Vault and are
  for explicit action only; a wiped account is still reserve-backed, and
  leverage math aborts at zero NAV, so the positivity check is not optional.

### 1.11 Never assign to a stored lifecycle

`Lifecycle` is droppable so transitions can write through `&mut`, which means
`vault.lifecycle = lifecycle::new()` would compile and silently
resurrect a settled Vault. The source-boundary gate rejects any assignment to
a `lifecycle` field, permits exactly one production call of `new()`
outside `lifecycle.move`, and whitelists the variant construction sites. Keep
that rule: construct the lifecycle once during Vault issuance and change it
only through `lifecycle.move`. Because a package upgrade adds modules to the
same package, raw upgrade authority must not remain address-owned once a Vault
can hold value. Series1 now permanently wraps its `UpgradeCap` and Publisher in
`PackageAdmin`; it exposes exact-digest authorization and no capability release
or mutable-borrow path.

### 1.12 Wire every policy gate, and mind same-typed parameter order

`policy.move` now has a predicate and an assertion for every stored value:
improvement, strict and emergency execution tolerance, the NAV cap, the mint
contribution, and the redemption gross. The Vault and adapter must call each
one at its checkpoint; the package cannot force the call. Two guards fail open
when their same-typed `u64` arguments are transposed:
`assert_mint_contribution_within_bound(deposit, contribution)` and
`assert_redemption_gross_within_bound(proportional_claim, gross)` both pass
whenever the second argument is at most the first, and
`assert_mark_within_index_divergence(mark, index)` widens instead of aborting.
Pass the quote outputs positionally from the same tuple, add a call-site test
that swaps each pair and expects the abort, and prefer single-field wrapper
types when the Vault's own API is designed.

Why: the package proves each rule in isolation. It cannot prove that one
captured pair priced both sides of an operation, that a caller did not choose
among historical updates, or that the source is the bound one. Those remain
carrier, binding, and authentication obligations.

## 2. Lowering liquidation odds

The pure package makes the product conservative by construction. These are the
design decisions that make it durable under stress. Each has an owner and must
close before the coins hold value. Numbers below use an illustrative 5 percent
maintenance margin ratio; replace them with the deployed Aftermath values once
premises P16 to P18 are resolved.

| Accounting leverage | Adverse move from 2.0x to reach it | Long liquidated at | Short liquidated at |
| ---: | ---: | ---: | ---: |
| 1.8x | — | 53% | 48% |
| 2.0x target | 0% | 47% | 43% |
| 2.2x upper band | 8.3% | 43% | 39% |
| 2.5x | 16.7% | 37% | 33% |
| 3.0x | 25% | 30% | 27% |

Long liquidation distance is `(1 - MMR * L) / (L * (1 - MMR))`; short is
`(1 - MMR * L) / (L * (1 + MMR))`; the rebalance trigger from 2.0x to `L` is
`(L - 2) / (2L - 2)`.

### 2.1 Asymmetric short parameters (owner: simulation, Series ADR)

The short is liquidated four to five points earlier than the long at every
leverage because its loss grows with the price it is short. `SUI2S` needs its
own target, band, hard cap, and NAV cap. Do not launch the short with the
long's numbers.

### 2.2 Tiered execution tolerance (owner: adapter)

Risk increase uses a strict slippage bound against the canonical index
valuation. Reduce-only orders above an emergency threshold, proposed 2.5x, use
a wider bound, and no cooldown may block them. A crash with wide spreads must
never be the reason deleveraging fails. The two bounds are immutable policy
values with gates, `is_execution_within_strict_tolerance` and
`is_execution_within_emergency_tolerance`, and the package pins that the
strict bound rejects and the wide bound admits the same fill. The adapter
selects which gate each order class uses.

### 2.3 Permissionless emergency deleverage (owner: Series and adapter)

Above the hard cap, any caller may reduce the position toward target with the
wide tolerance, in any lifecycle state that still has a position. Keeper
liveness is the single largest residual risk; the fix is to let anyone be the
keeper when it matters most, with sizing and direction fixed by Series1 so the
caller chooses nothing.

### 2.4 Reserve as a margin policy (owner: simulation, Series ADR)

The reserve is real margin. Select mint and redemption fee rates so the
reserve trends toward a stated share of venue equity, and record that target
in the ADR. The pure package already excludes the reserve from NAV, so a larger
reserve makes the accounting band strictly more conservative than the venue.

### 2.5 Position IMR floor (owner: adapter, premise P18)

If `set_position_initial_margin_ratio` proves to hold across partial
liquidation and parameter changes, set it as a venue-enforced backstop against
any accounting-sizing bug. If it does not, lower the protocol hard cap instead and
remove the floor from every safety claim.

### 2.6 NAV cap as a compiled constant (owner: Series)

The hard Series NAV cap is tied to executable book depth, not headline open
interest. It is an immutable policy value per Series with no setter and a gate,
`assert_within_nav_cap`, that the mint transition must apply to post-mint
shareholder NAV; raising it is a new deployment decision with its own
simulation. The leverage ceiling of 100x and the lot-multiple ceiling of one
million lots are structural fences, not selected values.

## 3. Open gates carried forward

These remain open from ADR 0064 and both audits and are listed so no reader
believes the package closes them:

- the operation-scoped linear valuation carrier, plus exact source binding and
  authentication. `series_one/sources/policy.move` now fixes the freshness, confidence,
  and index-versus-mark rules through its distinct `ValuationPolicy` type, and
  the package README records their boundary, unit, and zero-policy semantics.
  The adapter now wraps `State<Product>` directly, so the future operation must
  capture and validate the valuation inside one adapter call. Premise P17 must
  still fix its normalized fields, and no value for any bound is selected;
- exhaustive external-mutation checkpoint and `sync_health` refresh rules;
- permissionless rebalance sizing bounds; the minimum-improvement gate exists
  but the Vault must still bound the size of a permissionless order;
- operation-specific adapter code that authenticates the selected risk-module
  witness and Aftermath account. Adapter versioning, package custody, product
  issuance, and risk-module rotation are implemented under ADR 0073;
- the production `max_mint_contribution_divergence_bps` value, which simulation
  must select separately for the long and short Series;
- maximum supply, minimum NAV per share, minimum seed, the open-from-flat
  primitive, the reserve release path, a loss lifecycle state or an accepted
  decision that shutdown is the answer, the atomic initialization path out of
  `Uninitialized`, and shutdown cash rules. Issuance resolves the bootstrap
  trap by creating zero supply, zero reserve, and no asset custody, so no value
  can exist before that initialization succeeds;
- premises P16 through P20 against deployed Aftermath state.

## 4. Definition of done for the Series slice

The Series slice is complete only when every rule in section 1 has an
enforcement site and a test, every item in section 2 has either code or an
accepted ADR decision with a stated owner, the package README and this file
are updated to remove what is now enforced, and the full pinned gate passes.
