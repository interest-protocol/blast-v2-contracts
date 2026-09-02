# Blast leverage coins: `blast_leverage_coins`

This package is the core of the `SUI2L` and `SUI2S` leverage coins accepted in
[ADR 0064](../../docs/decisions/0064-aftermath-backed-leverage-coins.md). It is
the `blast_leverage_coins` package of that record. The venue adapter
`blast_leverage_aftermath` is a separate package. It does not exist yet.

Before implementing the Series, the adapter, or any change to this math, read
[the leverage implementation lessons](../../docs/leverage-implementation-lessons.md)
and the latest audit record under `docs/research/`. They are required reading,
not background.

## Product naming

The intended public display names are `SUI 2x Bull` for `SUI2L` and
`SUI 2x Bear` for `SUI2S`. The symbols and Move types remain `SUI2L` and
`SUI2S`. Protocol code uses `long` and `short` for the immutable position side;
Bull and Bear are metadata and UI terms only. Product descriptions must say
that the coins target approximately 2x exposure and can be liquidated.

## This package is not publishable

The current slice contains pure consensus-critical arithmetic, validated
immutable leverage bounds, and an isolated Series lifecycle state machine. It
has no currency, no shared object, no capability custody, no adapter, no event,
and no asset-moving state transition. Do not publish it.

The package deliberately contains none of these:

- `SUI2L` and `SUI2S` currencies, their one-time witnesses, or metadata;
- `TreasuryCap`, `Publisher`, `UpgradeCap`, or any other capability;
- a `Series`, a `VenueAccount`, or any shared object;
- an Aftermath dependency, a venue adapter, or a mock adapter;
- events, an event envelope, or a package-version gate;
- an economic parameter value;
- a placeholder production path.

`scripts/check_source_boundaries.sh` fails if any of those appear before the
gates below are met.

## Modules

- `share_math.move` — pure share, fee, leverage, and proportional-exposure
  arithmetic. Every domain operation is `public(package)`; the narrowing helper
  is private. Its mint formula takes an already-derived contribution; its
  redemption formula takes the valuation pair. Its exposure functions size a
  mint, bound a mint fill, and bound a redemption unwind.
- `maintenance_math.move` — pure shareholder-NAV, reserve-credit, and exact
  negative-funding absorption arithmetic. Its canonical mint and redemption
  quotes derive reserve checkpoints and shareholder NAV together and compute
  each fee exactly once. Its leverage, target-notional, mint-exposure, and
  mint-bound wrappers derive shareholder NAV from venue equity and reserve.
  The later Series must use these reserve-aware functions. This module cannot
  authenticate venue funding; the later adapter and Series transition own that
  obligation.
- `series_lifecycle.move` — the closed four-state Series lifecycle, monotone
  degradation, predicates, and operation-permission guards. It cannot resume a
  Series or finalize shutdown because those upgrades require authority, time,
  venue, funding, custody, and reserve proofs owned by the future Series.
- `leverage_bounds.move` — a validated immutable value satisfying
  `0 < lower < target < upper < hard cap`. It fixes the consensus-critical
  ordering without selecting the production values that simulation still owns.
- `lib/constants.move` — the basis-point denominator.
- `lib/errors.move` — the append-only numeric error registry. It is
  diagnostic-only: it has no state, no authority, and no assertion.

## Units, bounds, and rounding

| Quantity | Unit | Note |
| --- | --- | --- |
| venue equity, shareholder NAV, maintenance reserve | atomic collateral (USDC) | `shareholder_nav = venue_equity - maintenance_reserve` |
| deposit, fee, payout, funding cost | atomic collateral (USDC) | one valuation pair per operation |
| shares | atomic Share units | `SUI2L` or `SUI2S` |
| base exposure | absolute atomic venue base units | direction is never encoded here |
| fee rate | basis points below 10,000 | proves `fee <= amount` |
| leverage rate | basis points of 1x | `20_000` is 2x; no 10,000 ceiling |
| minimum operation size | live venue lots | `min_exposure_lots`, an immutable Series policy value supplied by the caller; this package holds no value for it |

Every input is a `u64`. Every product uses a `u128` or wider intermediate, so a
`u64` times a `u64` cannot wrap. Every potentially unbounded result passes the
checked narrowing helper and aborts with code 15 outside the `u64` range. Other
casts follow a documented bound that keeps their source value inside `u64`.

Share rounding never favors the transacting holder at the expense of existing
shares. Exposure rounding favors lower risk but can create underexposure:

| Function | Rounding | Who keeps the remainder |
| --- | --- | --- |
| `fee_up` | up | the maintenance reserve |
| `mint_quote` shares | down | existing holders |
| `redemption_quote` kept equity | up | remaining holders |
| `leverage_bps_up` | up | risk reporting stays conservative |
| `target_notional_down` | down | the planned order stays under target |
| `mint_base_delta_down` | down to the live lot | unopened sub-lot exposure, below `1 / min_exposure_lots` of the target |
| `mint_base_bounds` | `[min(actual, planned), planned]` | a partial fill may leave at most the actual contribution's exposure unopened |
| `redemption_base_bounds` keep | down | remaining holders |
| `redemption_base_bounds` planned reduction | up to the live lot, capped at flat | over-reduction below one lot and below `1 / min_exposure_lots` of the required reduction |

### Proportional exposure and the minimum operation size

`mint_base_delta_down`, `mint_base_bounds`, and `redemption_base_bounds` are
the arithmetic of invariant I26. Every proportional exposure change must be at
least `lot_size * min_exposure_lots`, except a redemption that reaches flat.

A mint is sized before its trade from the expected contribution
`deposit - fee`. After the trade the Series must call
`assert_mint_base_within_bounds` with both the expected contribution and the
actual contribution `nav_after - nav_before`. The admitted final base is
`base_before + [min(actual_delta, planned_delta), planned_delta]`: a full fill
of the plan always passes, a partial fill may not leave the actual
contribution's exposure unopened, and a fill above the plan is rejected. Both
contributions must clear the minimum, so a mint whose actual credited
contribution is dust aborts even if its plan was not. The range does not bound
the over-exposure created by execution cost; the Series' final leverage gate
and the user's slippage bound own that residual.

A redemption returns a two-sided range: the final absolute base must not exceed
the proportional keep `Q_keep` of I11, and it must not be more than one lot
below it. `assert_redemption_base_within_bounds` re-derives both bounds from
the canonical inputs and rejects an actual final base outside them, so every
partial-fill condition is cumulative.

The minimum operation size is what turns the per-operation lot tolerance into
a cumulative bound. With relative under-exposure below
`e = 1 / min_exposure_lots`, each legal mint multiplies accounting leverage by
at least `1 - e * contribution / (nav_before + contribution)`, so after any
sequence of mints from leverage `L0` and NAV `N0` the leverage stays close to
`L0 * (N0 / N)^e` where `N` is the final NAV. The regression test
`repeated_worst_case_mints_leave_the_band_with_a_one_lot_minimum` shows a
one-lot minimum lets 2,508 worst-case mints move a 2.0x pool below 1.8x while
NAV grows 25 percent; its twin proves a hundred-lot minimum keeps the same
sequence above 1.93x after 3,000 mints and NAV growth of sixteen times. The
Series must select `min_exposure_lots` from simulation, keep
`lot_size * min_exposure_lots` small in collateral terms so exits are not
stranded, and verify the live lot size against the deployed market (P16).

These pure modules cannot observe NAV, supply, reserve state, or venue exposure.
Each caller must supply values from one canonical valuation pair. The later
adapter must settle and authenticate funding exactly once first. Signed
direction, reduce-only flags, and the final signed-position check belong to the
later adapter.

## Maintenance reserve accounting

The maintenance reserve is actual USDC collateral in the same isolated venue
account. It improves venue equity and liquidation margin, but it is excluded
from shareholder NAV, share price, accounting leverage NAV, and target-notional
sizing:

```text
shareholder_nav = venue_equity - maintenance_reserve
```

Mint and redemption fees credit the reserve. The canonical
`mint_accounting_quote` computes the fee once, derives post-mint NAV with the
credited reserve, requires a positive contribution, and only then calls the
share formula, so the fee is excluded exactly once and cannot be subtracted
twice. `redemption_accounting_quote` derives post-unwind NAV with the old
reserve, then credits the new fee. Final shareholder NAV is exactly
`equity_keep`, not `equity_keep + fee`. The pure sequence removes the
split-redemption fee-recapture path; the later atomic state transition must use
these canonical functions and reconcile their outputs.

The source-boundary gate rejects any future production module other than
`maintenance_math` that directly calls the low-level `share_math` mint or
redemption quote or its NAV-sensitive leverage, mint-exposure, and mint-bound
functions. It also rejects any production caller of bare funding-cost
absorption until the typed funding-completion path exists.

Only an exact authenticated negative funding settlement may debit the reserve
during normal operation:

```text
absorbed      = min(reserve_before, funding_cost)
reserve_after = reserve_before - absorbed
uncovered     = funding_cost - absorbed
```

If venue equity has already fallen by `funding_cost`, shareholder NAV falls
only by `uncovered`. Positive funding leaves the reserve unchanged. Trading
fees, slippage, price PnL, liquidation, ADL, and socialized loss are not funding
costs. The future adapter must derive the exact cost from an authoritative
Aftermath funding accumulator or checkpoint; it may not infer funding from a
total-equity delta. The reserve mutation and checkpoint update must be atomic
and exactly once.

The reserve is bookkeeping inside a margin account, not bankruptcy-remote
custody. A non-funding loss can physically impair the account. Ordinary priced
operations require `maintenance_reserve <= venue_equity`; an observed breach
must enter a loss lifecycle through a separate successful health transition,
not clamp NAV and continue. No admin or keeper can claim the reserve. A future
shutdown transition may reclassify the remaining reserve into distributable
cash only after it proves a flat account, no pending orders, and no unsettled
funding. That required release path is not implemented in Phase 1.

## Error registry

Codes are append-only. A retired code stays reserved. Each new code must ship
with a registry assertion that pins its number and an exact `expected_failure`
test that pins the abort code and raising module. Each macro in
`sources/lib/errors.move` inlines its number into the raising module, so the
abort location is the module that owns the invariant. The launchpad keeps a
separate registry in `docs/error-codes.md`; the two numeric spaces are
independent because Sui scopes abort codes to the raising package.

| Code | Macro | Raised from | Meaning |
| ---: | --- | --- | --- |
| 0 | `zero_amount` | `share_math` | A fee calculation requires a positive atomic collateral amount. |
| 1 | `invalid_fee_bps` | `share_math` | A fee rate must be below the 10,000 basis-point denominator. |
| 2 | `invalid_nav` | `share_math` | A priced operation requires positive Series NAV. |
| 3 | `invalid_share_supply` | `share_math` | A priced operation requires positive share supply. |
| 4 | `invalid_share_amount` | `share_math` | Presented shares must be positive and below the live supply. |
| 5 | `nonpositive_contribution` | `maintenance_math`, `share_math` | A mint requires a positive shareholder NAV contribution. |
| 6 | `zero_shares_out` | `share_math` | A positive credited contribution rounded down to zero shares. |
| 7 | `nonpositive_gross` | `share_math` | Post-unwind NAV does not exceed the equity kept for remaining shares. |
| 8 | `zero_net_payout` | `share_math` | The redemption fee consumed the complete gross claim. |
| 9 | `invalid_target_leverage_bps` | `share_math` | A target leverage rate must be positive. |
| 10 | `invalid_lot_size` | `share_math` | A venue lot size must be positive. |
| 11 | `invalid_base_exposure` | `share_math` | A proportional mint requires positive pre-mint absolute base. |
| 12 | `sub_lot_exposure_delta` | `share_math` | A proportional mint or redemption exposure delta is below the required minimum lot multiple. |
| 13 | `redemption_under_reduced` | `share_math` | The final absolute base exceeds the proportional remaining base. |
| 14 | `redemption_over_reduced` | `share_math` | The final absolute base is more than one lot below the proportional remaining base without reaching flat. |
| 15 | `arithmetic_overflow` | `share_math`, `maintenance_math` | A wide intermediate, reserve credit, or mint upper bound exceeds the supported `u64` range. |
| 16 | `maintenance_reserve_exceeds_equity` | `maintenance_math` | The maintenance reserve exceeds the venue equity that backs it. |
| 17 | `invalid_lifecycle_transition` | `series_lifecycle` | The current Series lifecycle cannot make the requested state transition. |
| 18 | `operation_not_permitted_in_lifecycle` | `series_lifecycle` | The current Series lifecycle does not permit the requested operation. |
| 19 | `mint_over_exposed` | `share_math` | The final absolute base exceeds the pre-mint base plus the planned proportional delta. |
| 20 | `mint_under_exposed` | `share_math` | The final absolute base is below the pre-mint base plus the delta funded by the actual credited contribution. |
| 21 | `invalid_min_exposure_lots` | `share_math` | A minimum exposure lot multiple must be positive. |
| 22 | `invalid_leverage_bounds` | `leverage_bounds` | Series leverage bounds do not satisfy `0 < lower < target < upper < hard cap`. |

The next new error must use code 23.

## Verification

Run with the workspace-pinned Sui CLI `1.77.2-51d177ad7d65` from this
directory, or use `bash scripts/verify.sh [build|lint|test|boundaries|all]`.
`Move.lock` pins the same framework revision and environment mapping as
`sui/launchpad`.

```bash
sui move build
sui move lint --warnings-are-errors
sui move test --lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

## Gates before this package can hold value

The pre-Series package stops here on purpose. Each item below is a separate
accepted decision, implementation slice, and review.

1. Close the design items that ADR 0064, the
   [design audit](../../docs/research/claude-opus-5-leverage-design-audit-2026-09-01.md),
   the [Phase 1 code audit](../../docs/research/claude-fable-5-1-leverage-coins-audit-2026-09-02.md),
   and the [implementation lessons](../../docs/leverage-implementation-lessons.md)
   leave open: the immutable valuation carrier and its freshness, confidence,
   and index-versus-mark rules; the exhaustive external-mutation checkpoint and
   `sync_health` refresh rules; permissionless rebalance execution and sizing
   bounds; emergency deleverage tolerance; construction authority and ACL
   rotation; maximum supply, minimum NAV per share, minimum seed, and shutdown
   cash rules.
2. Resolve premises P16 through P20 against the deployed Aftermath
   implementation and state. The public Aftermath interface aborts in every
   function body, so it proves type layouts and call signatures only. No
   premise is resolved today.
3. Select the final band, hard leverage cap, margin buffer, fee rates, seed,
   `min_exposure_lots`, and Series NAV cap from historical and book-depth
   simulation, separately for the long and the short Series. This package
   contains no economic parameter, and the 1.8x to 2.2x band in ADR 0064 stays
   a hypothesis.
4. Add the `Series` object and integrate its lifecycle, currencies, treasury
   custody, package administration, the operational version gate, and wrapped
   events. Resume and shutdown finalization must arrive only with their complete
   Series proofs.
5. Add the `blast_leverage_aftermath` adapter, its sealed witness, the
   no-ability funding proof and handoffs, and its account-capability custody.
   Choose and test one concrete adapter-upgrade delay policy first; adapter
   upgrade authority is equivalent to custody of the Aftermath account.
6. Complete independent core, adapter, economic, and upgrade-authority audits,
   then publish deployment records and SDK parity vectors.

Blast may allowlist the exact `SUI2L` and `SUI2S` coin types as launchpad
`Quote` only after every gate passes. No release may describe the coins as
non-liquidatable, guaranteed 2x, or insured against Aftermath loss.
