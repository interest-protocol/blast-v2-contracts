# Claude Opus 5 review of the Blast leverage-coin design

Date: 2026-09-01

Status: independent design review before implementation

Model: `claude-opus-5`, max effort

Authorized Claude account: `jose@ilovemochi.com`

Run facts: 22 minutes, no web access, read-only tools, no subagents, no
repository edits, USD 3.913262 reported by the Claude CLI.

This document records the Opus verdict and a separate Codex verification. It is
not a claim that the design or a future implementation has passed a security
audit. No Move contract existed for this review.

## Scope

Opus read these documents completely:

- `contracts/docs/decisions/0064-aftermath-backed-leverage-coins.md`
- `contracts/docs/research/perp-backed-leveraged-token-design-2026.md`
- `contracts/docs/research/aftermath-perps-package-frontend-2026.md`
- `contracts/docs/research/deepbook-margin-leveraged-coin-design-2026.md`
- `contracts/docs/decisions/0053-single-validator-funsui-and-blastsui.md`

The audit prompt required adversarial review of I1 through I25, algebraic
falsification of mint and redemption, rebalance and lifecycle analysis,
capability and upgrade review, comparison with researched protocols, and five
dangerous tests. Public Aftermath interface stubs were treated as ABI evidence,
not as proof of runtime behavior.

## Opus verdict

Opus returned **CONDITIONAL PASS**.

It found that the top-level architecture is viable. It specifically accepted:

- one isolated Aftermath account for each of `SUI2L` and `SUI2S`;
- capability custody in a one-to-one adapter instead of `ctx.sender` authority;
- atomic deposit, trade, reconciliation, and share minting;
- actual recoverable NAV instead of gross notional or a promised peg;
- separate shareholder NAV and venue-margin calculations;
- the floor-mint and ceil-keep non-dilution formulas;
- permanent locked seed shares;
- no-ability handoffs and old-bytecode version gates;
- fail-closed liquidation, ADL, and venue-unavailability behavior; and
- exact coin-type allowlisting without a launchpad dependency in the Series.

It did not give a full pass because it found specification gaps and external
Aftermath premises that must be resolved before deployment.

## Opus findings index

The table below preserves the findings and severities returned by Opus. The next
section records where the independent Codex check changes that assessment.

| ID | Opus severity | Class | Opus finding |
| --- | --- | --- | --- |
| F-01 | Critical | A | Redemption payout allegedly escapes risk gates when a reduce order partially fills. |
| F-02 | Critical | A/B | Adapter upgrade authority is a full-custody path without a specified timelock mechanism. |
| F-03 | High | A | A sub-lot mint can mint shares after depositing cash but opening no proportional exposure. |
| F-04 | High | B/D | Permissionless rebalance has no specified execution tolerance, size cap, cooldown, or minimum improvement. |
| F-05 | High | A/C | An immutable oracle pair does not by itself constrain transaction timing or oracle selection. |
| F-06 | High | B/C | The checkpoint does not explicitly enumerate Aftermath conditional-order state. |
| F-07 | High | B | `sync_health` does not specify when a mutation checkpoint may be refreshed. |
| F-08 | High | B | Blast quote admission has no on-chain Series attestation in addition to exact coin type. |
| F-09 | Medium | B/C | Redemption does not specify Aftermath margin-deallocation ordering. |
| F-10 | Medium | B | NAV numeraire and the collateral oracle's exact role need a precise definition. |
| F-11 | Medium | B | The share-pricing path does not explicitly prohibit venue mark-based valuation getters. |
| F-12 | Medium | A/B | No supply cap or minimum NAV-per-share floor is specified near insolvency. |
| F-13 | Medium | B | Series construction authority and pre-Series `TreasuryCap` custody are not specified. |
| F-14 | Medium | B | Guardian shutdown authority and declared-versus-settled shutdown phases need clearer separation. |
| F-15 | Medium | B | Admin and guardian rotation, revocation, and delayed transfer are not specified. |
| F-16 | Medium | B/C | Active Aftermath package lineage and semantic compatibility are publication gates, not continuous on-chain assertions. |
| F-17 | Medium | A | I11 limits under-reduction but does not bound deliberate over-reduction to flat. |
| F-18 | Medium | B/D | Immediate collateral donations can be captured by holders who enter before the donation. |
| F-19 | Medium | B | The immutable valuation pair has no dedicated linear carrier type. |
| F-20 | Medium | D | Long and short show the same preliminary parameters despite asymmetric risk. |
| F-21 | Medium | B | Shared-object congestion can obstruct the emergency reduce path. |
| F-22 | Medium | B | Burn-only and shutdown cash-snapshot APIs are incomplete in the public API plan. |
| F-23 | Medium | B | Core/adapter version skew can freeze risk reduction during upgrade activation. |
| F-24 | Low | B | Seed conversion hardcodes decimal constants inside a collateral-generic Series. |
| F-25 | Low | B | Locked seed is pari passu, not economically first-loss. |
| F-26 | Low | B | Retained fees are levered collateral, not a protected reserve. |
| F-27 | Low | B | Account isolation does not isolate venue-wide socialized loss or clearing-house liveness. |
| F-28 | Low | B | No public `can_rebalance` projection or keeper backoff policy is specified. |
| F-29 | Low | B | `SessionSummary` acceptance needs exhaustive default-deny handling. |
| F-30 | Informational | B | Minimum seed and operation sizes are missing; read-only NAV projections can become stale. |

Classes used by Opus:

- A: definite design bug
- B: under-specified design choice
- C: premise that requires live Aftermath implementation evidence
- D: parameter that requires economic simulation

## Codex verification and corrections

### F-01 is not a demonstrated Critical exploit

Opus's failure sequence assumes that a partial fill can leave more than the
proportional remaining base while the contract pays the full redemption.
ADR-0064 already forbids that state before payout:

```text
Q_keep = floor(Q0 * (S0 - x) / S0)
abs(Q_final) <= Q_keep
```

The later partial-fill conditions are additional requirements. They do not
replace `Q_final <= Q_keep`. If the adapter requests the minimum proportional
reduction and receives only a 10% fill, the redemption must abort.

Let `r = (S0 - x) / S0`. When I11 holds:

```text
V_final <= V0 * r
N_final >= N0 * r
V_final / N_final <= V0 / N0
```

Therefore a correctly implemented redemption cannot create the 18x survivor
position in Opus's example. Opus's F-01 should be downgraded from a definite
Critical bug to a specification-clarity and defense-in-depth issue.

The ADR should still state all final redemption postconditions together:

- `abs(Q_final) <= Q_keep`;
- final direction is the original direction or flat;
- post-payout accounting leverage does not exceed pre-redemption leverage or
  the hard cap;
- final venue margin is above the protocol buffer; and
- a partial fill that does not reach `Q_keep` causes a full transaction abort.

This removes any chance that an implementer reads the partial-fill paragraph as
an exception to I11.

### F-02 is material, but it is an authority premise rather than an algebra bug

The ADR already states that the adapter upgrade authority is equivalent to
custody and requires multisig and delay controls. Opus is correct that the
mechanism is not specified. Before mainnet, the design must choose and test one
concrete policy: on-chain timelock, externally enforced governance timelock, or
immutable adapter code. A public authorization event and an exit window are
strongly preferred.

This blocks production custody, but it does not block implementation of pure
share math, lifecycle types, mock adapters, and adversarial tests.

### F-03 and F-04 are confirmed

A mint that rounds its required exposure increase to zero can pass the written
NAV non-dilution proof while moving the Series below its leverage target. A
later rebalance charges the pooled account for exposure that the new cohort
should have opened during mint. The implementation needs a live-lot-derived
minimum mint and a post-mint proportional-exposure bound.

Permissionless rebalance also needs an immutable execution bound measured
against the canonical index valuation, a maximum notional per call, and a
minimum risk improvement. Cooldown and sizing parameters require simulation;
emergency risk reduction must never be disabled by the cooldown.

### F-05 is overstated but exposes a real missing bound

With exact pinned shared oracle object IDs, Sui resolves current shared-object
versions through consensus. A caller cannot normally inject an arbitrary old
version of that shared object. The caller can choose when to submit within the
accepted freshness window, which is true of every on-chain oracle consumer.

The required correction is a quantified two-sided freshness rule, confidence
handling, exact source binding, and index-versus-mark divergence gate. This is
an under-specified oracle policy and live-integration premise, not a demonstrated
caller-selected-price exploit.

### Additional confirmed findings

F-06, F-07, F-09, F-10, F-11, F-12, F-13, F-15, F-16, F-17, F-19,
F-21, F-22, F-23, F-25, F-26, F-27, F-29, and F-30 are valid.

Their exact severities depend on the Aftermath implementation spike, but each
identifies a real fact that the implementation or release gates must make
explicit.

The most important of these are:

- exhaustive pending-order and conditional-order checks;
- checkpoint refresh only together with objective degradation or fully
  explained reconciliation;
- exact NAV numeraire and no mark-price getter in share pricing;
- supply, minimum NAV/share, seed, and operation bounds;
- two-sided proportional exposure bounds, not only a maximum remaining base;
- construction and ACL authority machinery;
- adapter/core version activation ordering that preserves reduction;
- explicit shutdown cash snapshot behavior; and
- confirmation of every Aftermath premise against deployed code and state.

### F-08 is optional hardening, not a required invariant

Exact Sui coin type identity is stronger than a symbol or metadata check. If the
unique `TreasuryCap<Share>` is trapped in its Series during atomic construction,
and Blast governance allowlists that exact type only after the release gates,
another package cannot counterfeit that type. An additional Series attestation
can improve operational safety, but type identity is not itself a design bug.

### F-18 and F-20 are economic-policy decisions

A permissionless donation is explicitly a gift to current holders. Donation
capture matters if Blast deposits predictable protocol revenue in large lumps;
that use should stream or distribute revenue over time. An unsolicited donor
does not need protection from their chosen transfer.

The 1.8x to 2.2x bands in ADR-0064 are explicitly preliminary. Long and short
must receive separately simulated caps, buffers, bands, and funding assumptions
before `SUI2S` launches.

## Algebraic verification

### Mint

Let:

```text
C = N1 - N0 - F > 0
m = floor(S0 * C / N0)
S1 = S0 + m
```

Because `m <= S0*C/N0`:

```text
S1 <= S0 * (N0 + C) / N0
```

Also `N1 = N0 + C + F` and `F >= 0`, so:

```text
N1 / S1
>= N0 * (N0 + C + F) / (S0 * (N0 + C))
>= N0 / S0
```

The inequality is correct when all values use the same valuation pair, funding
is counted once, hidden liabilities are absent, and multiplication uses checked
wide intermediates. It proves NAV/share non-dilution. It does not prove that
exposure/share is preserved; the sub-lot finding is why that second invariant
is required.

### Redemption

Let `S1 = S0 - x` and:

```text
equity_keep = ceil(N0 * S1 / S0)
gross = Nu - equity_keep
F = ceil(gross * fee_bps / 10_000)
net = gross - F
```

After withdrawing `net`:

```text
N_final = Nu - net = equity_keep + F
```

Because `equity_keep >= N0*S1/S0` and `F >= 0`:

```text
N_final / S1 >= N0 / S0
```

This inequality is also correct. It requires `gross > 0`, `F <= gross`, exact
withdrawal reconciliation, checked wide intermediates, and the same valuation
pair before and after the unwind.

### Missing combined invariant

Add an invariant equivalent to Opus's proposed I26:

> Every share-changing operation must change signed exposure in proportion to
> the equity attributed to the entering or exiting shares, within an immutable
> lot-rounding tolerance. No later holder-funded rebalance can repair an
> operation that violates this bound.

For redemption, use a tight two-sided bound around `Q0*S1/S0`, with the safe
rounding direction and a deliberate emergency exception only when no user
payout occurs. For mint, require the post-operation leverage or exposure/share
to remain within its stated tolerance.

## Verified invariant status

| ID | Verified status | Main condition or correction |
| --- | --- | --- |
| I1 | Under-specified | State construction authority and pre-Series cap custody. |
| I2 | Depends on Aftermath | Prove admin-cap uniqueness and vendor authority semantics. |
| I3 | Depends on Aftermath/governance | Prove no assistant exists; secure adapter upgrades. |
| I4 | Pass | Narrow claim to account-level isolation; venue liveness remains shared. |
| I5 | Under-specified | Pin and check all bindings plus deployed venue lineage. |
| I6 | Pass with bounds needed | Locked seed prevents zero supply; add supply and NAV/share limits. |
| I7 | Under-specified/premise | Define numeraire and prove normalized Aftermath NAV parity. |
| I8 | Depends on Aftermath | Prove funding settlement and exactly-once accounting. |
| I9 | Pass algebraically | Add proportional exposure and minimum-operation invariant. |
| I10 | Pass algebraically | Require exact post-withdrawal reconciliation. |
| I11 | Pass as written, clarify | Make `Q_final <= Q_keep` mandatory after every fill; add a lower bound. |
| I12 | Pass | Test sign, size, full-fill, and final-position checks. |
| I13 | Depends on Aftermath | Prove reduce-only semantics and assert final sign. |
| I14 | Under-specified/premise | Exhaustively reject all order and conditional-order states. |
| I15 | Under-specified | Define rebalance execution protection. |
| I16 | Pass for risk-increase operations | Also check final redemption leverage and margin. |
| I17 | Under-specified/premise | Preserve reduction across pauses, upgrades, congestion, and settlement. |
| I18 | Depends on Aftermath | Prove checkpoint completeness and safe sync refresh. |
| I19 | Pass | Retained fees have no claim path; label them levered collateral. |
| I20 | Pass | Burn changes supply only and cannot improve venue margin. |
| I21 | Pass | Bind handoffs to exact type, Series, VenueAccount, and valuation. |
| I22 | Pass | Gate every v1 mutator and define upgrade activation ordering. |
| I23 | Pass | Exact quote type only; optional Series attestation is hardening. |
| I24 | Under-specified | Define two shutdown phases, cash snapshot, late inflows, and burn API. |
| I25 | Under-specified/premise | Add typed valuation carrier, source/freshness rules, and getter prohibition. |
| I26 | Missing | Preserve proportional exposure within immutable rounding tolerance. |

## Required before adapter implementation

1. Make the redemption final-state and partial-fill rules unambiguous.
2. Add I26 and minimum live-lot-derived operation sizes.
3. Define permissionless rebalance execution and sizing bounds.
4. Define the immutable valuation carrier, numeraire, freshness, confidence, and
   index/mark separation.
5. Exhaustively define the checkpoint, reconciliation, and `sync_health`
   refresh rules.
6. Define construction authority, ACL rotation, adapter upgrade delay, events,
   and version activation ordering.
7. Add maximum supply, minimum NAV/share, minimum seed, and shutdown cash rules.
8. Resolve P16 through P20 against the deployed Aftermath implementation. An
   interface whose function bodies abort is not behavioral evidence.

Pure share math, lifecycle state types, linear handoffs, and a malicious mock
adapter can be implemented before the external premises are resolved. Production
custody, mint, redemption, and rebalance cannot be considered safe until the
items above are closed.

## Five dangerous tests

1. Thin-book redemption with fill ratios from zero through 99.999%. Full payout
   must be impossible unless `Q_final <= Q_keep` and every final risk gate holds.
2. Repeated sub-lot mints followed by rebalance. Every sub-minimum mint must
   abort, and legal operations must preserve exposure/share within tolerance.
3. Identical operations at both oracle-freshness boundaries, every confidence
   bound, long and short signs, and one-lot rounding error. Pre-NAV, sizing, and
   post-NAV must consume the same typed valuation.
4. Malicious adapter plus upgrade tests: forged completion, wrong Series,
   assistant creation, unauthorized digest, early activation, old-bytecode call,
   and authority-drain attempt.
5. Out-of-band mutation matrix: partial/full liquidation, ADL, socialized loss,
   settlement, bad debt, conditional orders, funding-only change, oracle outage,
   and changed margin parameters. Sync must degrade safely without laundering
   the checkpoint, while every venue-supported reduction path remains live.

## Conclusion

The architecture remains the correct base for Blast leverage coins. The
non-dilution math is sound. The design is not ready for Move adapter code or
mainnet custody because exposure proportionality, rebalance execution, oracle
carriage, checkpoint reconciliation, upgrade governance, and live Aftermath
semantics still need exact enforcement rules.

The verified result is **CONDITIONAL PASS for the architecture, not for a
contract**.
