# Leverage coins: implementation lessons and required rules

Status: required reading. Read this file completely before implementing or
changing `sui/boosts/core/`, the `blast_boosts_aftermath`
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
order through `accounting_math::mint_base_to_buy_down`. After the
trade the actual contribution `nav_after - nav_before` prices the shares. The
Series must then call `assert_mint_base_within_bounds` with both
values and the final absolute base. Never pass the post-trade contribution as
the sizing input, and never skip the post-fill assertion because the venue
reported a full fill: the assertion also proves the actual contribution is not
dust.

Why: the audit showed the two inputs can disagree by a whole lot at a rounding
boundary, and a full fill required for mints is a venue claim, not an accounting
proof.

### 1.2 Always supply the Series' immutable `min_order_lots`

Every exposure function takes `min_order_lots`. It must come from the
immutable `VaultPolicy`, never from a caller or a live setter. Selecting the
value is a simulation gate, but the shape of the decision is fixed:

- Relative under-exposure per mint and over-reduction per redemption are both
  below `1 / min_order_lots`.
- After any sequence of legal mints, accounting leverage stays close to
  `L0 * (N0 / N)^(1 / min_order_lots)`, a lower bound whose attained worst
  case is `1 / (min_order_lots + 1)`. With one lot a 2.0x pool leaves the
  1.8x band on worst-case mint 2,229 and sits at 1.7397x after 3,000 mints
  and 32 percent NAV growth. With one hundred lots the same sequence stays at
  1.9455x after 3,000 mints and sixteen times NAV growth. Both facts are
  pinned exactly by package tests.
- The minimum has a sharp lock condition, recorded in `docs/accounting.md`.
  Initialization requires exposure above the minimum operation size; priced
  redemptions enforce their exact proportional bounds. Health synchronization
  does not degrade lifecycle for unavailable ordinary redemption. Explicit
  terminal handling belongs to its separately authorized lifecycle path.
- `lot_size * min_order_lots` must stay small in collateral terms so a
  small holder can still exit. Compute it against the live Aftermath lot size
  for the SUI-USDC market (premise P16) and state the resulting minimum mint
  and redemption in USDC in the Series ADR.
- A redemption that reaches flat is exempt, so a complete close is always
  possible regardless of size.

### 1.3 Cap the redemption gross at the proportional claim, as the mint caps its contribution

`redemption_quote` pays `min(nav_after_sell, nav_before) - equity_keep`, so the
gross never exceeds the redeemer's proportional claim, and
`allocated_mint_quote` credits `min(nav_after - nav_before, deposit - fee)`,
so a depositor never receives shares for more than they paid. Both caps live
inside the quotes; a Series transition cannot bypass them and must not
re-derive either value from a NAV of its own. Any favorable difference between
the two readings stays with the remaining holders. There is no divergence
policy value to select (ADR 0084 D3).

Why: the 2026-09-03 audit showed one share of a million capturing a 100-unit
pool-wide gain, and the canonical suite had never exercised a favorable
unwind. The first remedy was a leveraged divergence allowance with two
simulation-selected bounds; the Perpsplexity review replaced it with the exact
cap, which needs no bound and is what the venue's own accounting does.

### 1.4 Compute every economic value once at its canonical checkpoint

`prepare_mint` computes the fee once and `allocated_mint_quote` takes the
derived contribution; the low-level formula no longer recomputes it. Keep that
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

### 1.6 Keep one error registry per package

Each Boosts package keeps every abort code in its `lib/errors.move`: a
`#[test_only] const EName: u64 = N` with a doc comment stating the violated
condition, and a `macro public(package) fun name(): u64` that raising modules
call. Codes run from zero with no gaps: while the package is unpublished a
removed check renumbers what follows; from the first publish on, codes are
append-only. Tests pin `abort_code = errors::EName, location =
package::module`, never a literal, so renumbering touches only the registry.

Why: with the codes spread across modules a reader had to open each file to
learn what a code meant; one registry per package reads top to bottom and is
the single place a reviewer checks for reuse (founder ruling, 2026-09-17).
Move constants are module-private and macros expand in the caller, so the
registry cannot hand out `#[error]` message constants; the doc comment on each
constant carries the message instead.

### 1.7 Compute shareholder NAV once and pass it explicitly

`accounting_math` exposes its sizing formulas as package functions that take
shareholder NAV, keeps the raw share quotes private behind the
equity-and-reserve quotes, and `shareholder_nav(venue_equity, reserve)` is the
only way to derive that input. A State transition computes that NAV once at its checkpoint and passes
the same value to every formula it calls; it never re-derives NAV inline and
never passes reserve-inclusive venue equity where NAV is expected. Tests call
the formulas directly.

Why: the reserve-aware wrapper layer that used to hide this derivation doubled
the module's function count without adding a check; the invariant lives in the
single `shareholder_nav` call per checkpoint, which the state tests pin.

### 1.8 Test shape that the package expects

Every formula has an exhaustive small-domain test against an independent
reference, a maximum-width boundary test, a property test for its rounding
beneficiary, and, where a sequence matters, a regression that runs the
sequence. Keep an exhaustive sweep under roughly ten thousand iterations of
the helper it exercises; the test runner's gas budget times out above that,
which the audit hit once at twenty-six thousand.

### 1.9 Pass the depositor's share floor through unchanged

`allocated_mint_quote` takes `min_shares_out`. It is the depositor's own
floor on `shares_out` and the only in-package bound on the rounding loss a
mint can suffer, which is otherwise capped only by the share price the seed
sets. The Series must take it from the depositor's transaction and pass it
through unchanged; it must never substitute zero or a policy value. The seed
sizing rule that keeps one share economically dust is in `docs/accounting.md`
and is a release gate on the seed slice.

### 1.10 Run every price gate at the one operation checkpoint

The `PricePolicy` type in `sui/boosts/core/sources/policy.move` owns the freshness,
confidence, and mark-divergence rules, but it cannot see how many times or
against what a caller applies them. The Series and adapter must:

- capture one on-chain millisecond reading per operation and pass that same
  value as `reference_time_ms` to every `assert_price_fresh` call, so the two
  share-pricing sources are judged against one reference;
- run `assert_price_fresh` and `assert_confidence_within_bound` for both the
  base index and the collateral oracle before deriving pre-operation
  shareholder NAV, and prove the post-operation NAV used the same pair;
- keep `assert_mark_within_oracle_divergence` on the venue margin path only. Its
  operands must never reach `accounting_math`; the
  source-boundary script fails if a standalone or snake-case `mark` identifier
  appears there, while semantic review still verifies arbitrary numeric inputs;
  and
- validate priced observations with their aborting guards before financial
  mutation. Authenticated health captures remain adapter-local and yield raw
  checkpoints, not an unused Series1 economic observation. Temporary economic
  faults do not change lifecycle; checkpoint drift is reported through the
  unresolved/reconciled diagnostic identity. Funding settlement alone changes
  the reserve during synchronization.

### 1.11 Never assign to a stored lifecycle

`Lifecycle` is droppable so transitions can write through `&mut`, which means
`vault.lifecycle = lifecycle::new()` would compile and silently
resurrect a settled Vault. The source-boundary gate rejects any assignment to
a `lifecycle` field, permits exactly one production call of `new()`
outside `lifecycle.move`, and whitelists the variant construction sites. Keep
that rule: construct the lifecycle once during Vault issuance and change it
only through `lifecycle.move`. Because a package upgrade adds modules to the
same package, raw upgrade authority must not remain address-owned once a Vault
can hold value. Series1 is therefore published with
`sui/boosts/core/scripts/publish_immutable.sh`, which consumes the returned
`UpgradeCap` through `0x2::package::make_immutable` in the same PTB. It has no
Publisher, package administrator, version cutover, or post-publication upgrade
path. Series2 is a new immutable package and coin family.

### 1.12 Wire every policy gate, and mind same-typed parameter order

`policy.move` has a predicate and an assertion for every stored value:
improvement, strict and emergency max slippage, and the NAV cap. The
Vault and adapter must call each one at its checkpoint; the package cannot
force the call. One guard fails open when its same-typed `u64` arguments are
transposed: `assert_mark_within_oracle_divergence(mark, index)` widens instead
of aborting. Pass the observation outputs positionally from the same tuple,
add a call-site test that swaps the pair and expects the abort, and prefer
single-field wrapper types when the Vault's own API is designed. The mint
contribution and redemption gross caps are applied inside the quotes and have
no call-site arguments to transpose.

Why: the package proves each rule in isolation. It cannot prove that one
captured pair priced both sides of an operation, that a caller did not choose
among historical updates, or that the source is the bound one. Those remain
carrier, binding, and authentication obligations.

### 1.13 Evidence tooling is a protocol boundary

Parse only documented Sui command results, effects, typed events, and canonical
object JSON. Do not add a convenient normalized response shape and then test
only that shape. A controlled economic matrix has fixed case names and exact
expected lifecycle, checkpoint, classification, and event sets; configuration
supplies calls and objects but cannot redefine the cases. Atomic rollback
failpoints use unique standalone source markers, fixed abort identities, and a
complete source-to-published-Blast provenance chain. Offline fixtures run the
same validators but never count as network evidence. Upstream `abort 404` ABI
ports remain the callable authority and are not mistaken for implementation
source.

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
own target, band, max leverage, and NAV cap. Do not launch the short with the
long's numbers.

### 2.2 Tiered max slippage (owner: adapter)

Risk increase uses a strict slippage bound against the canonical index
price. Reduce-only orders above an emergency threshold, proposed 2.5x, use
a wider bound, and no cooldown may block them. A crash with wide spreads must
never be the reason deleveraging fails. The two bounds are immutable policy
values with gates, `is_execution_within_max_slippage` and
`is_execution_within_emergency_max_slippage`, and the package pins that the
strict bound rejects and the wide bound admits the same fill. The adapter
selects which gate each order class uses.

### 2.3 Permissionless emergency deleverage (owner: Series and adapter)

Above max leverage, any caller may reduce the position toward target with the
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
any accounting-sizing bug. If it does not, lower the protocol max leverage instead and
remove the floor from every safety claim.

### 2.6 NAV cap as an admin-adjustable live value (owner: Series)

The NAV cap is tied to executable book depth, not headline open interest. It
lives in one place, `State`: issuance passes it to `state::issue` beside the
order-notional bounds, and the risk admin may move it through `set_nav_cap`, which applies the same bound as issuance
(positive, and the max-leverage notional fits `u64`) and emits `NavCapUpdated`.
Lowering it below current NAV only blocks further mints. The mint transition
applies the live cap to post-mint shareholder NAV. Raising it still deserves
its own depth simulation, but no longer a new deployment (founder ruling,
2026-09-17). The leverage ceiling of 100x and the lot-multiple ceiling of one
million lots are structural fences, not selected values.

## 3. Open gates carried forward

These remain open from ADR 0064 and both audits and are listed so no reader
believes the package closes them:

- production values for the immutable price bounds. The adapter now owns
  operation-scoped source binding, strict activation capture, permissive health
  capture, the raw checkpoint, and permissionless exact-once health and funding
  synchronization under ADR 0074, but simulation has not selected launch
  values for every bound;
- permissionless rebalance sizing bounds; the minimum-improvement gate exists
  but the Vault must still bound the size of a permissionless order;
- maximum supply, minimum NAV per share, minimum seed, the open-from-flat
  primitive, the reserve release path, a loss lifecycle state or an accepted
  decision that shutdown is the answer, and shutdown cash rules. Issuance
  resolves the bootstrap trap by creating zero supply, zero reserve, and no
  asset custody, and ADR 0074 defines the atomic initialization path;
- submitted controlled-network and read-only mainnet evidence for premises P16
  through P20. Offline fixtures and Move unit tests do not close this gate.

## 4. Definition of done for the Series slice

The Series slice is complete only when every rule in section 1 has an
enforcement site and a test, every item in section 2 has either code or an
accepted ADR decision with a stated owner, the package README and this file
are updated to remove what is now enforced, and the full pinned gate passes.
