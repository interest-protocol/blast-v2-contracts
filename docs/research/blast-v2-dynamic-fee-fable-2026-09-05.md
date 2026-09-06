# Independent Claude Fable review of dynamic volume fees

Date: 2026-09-05. Claude Code was invoked with `--model claude-fable-5`,
`--effort max`, tools disabled, and a self-contained review brief. The result
reported success; runtime `modelUsage` confirms substantive review by
`claude-fable-5` (20,743 thinking tokens, 25,133 output tokens inclusive of
thinking). A separate 17-output-token Haiku auxiliary call also appears in
runtime accounting; it is not the substantive review. No reviewer file edits,
code execution, web lookup, or deployment occurred.

The brief included the V2 purpose, separate fee custody, optional burns,
no balancing swaps, Quote-only compounding limitation, 0%–2% requested bounds,
admin-adjustable per-pool caps, and the ambiguous later “0.2” wording. It
contained snapshots of the design and model, taken before the later standalone
admin-boundary tests and disposition notes were added.

Prompt SHA-256: `c2595fc34a8c864337dada1a2f15f585294601b4ea6794ab34f01c006b667cff`.

## Disposition by the parent agent

- Accept the mathematical proofs as independent review of the real-arithmetic
  model, not proof of a Move implementation. No production AMM exists here.
- Select round-up fees on both swap directions, reject zero principal/output,
  and compare the actual rounded fee with the signed effective fee limit.
- Require a bounded decay approximation with exact identity at zero elapsed
  time and adversarial update-cadence tests. The review's Q64.64 statement
  conflates absolute factor error with relative error for very small factors;
  it is not adopted as a proved numerical guarantee. Upward bias also needs
  a dust-liveness rule and must not silently pin a nonzero score forever.
- Define buy inversion by the exact integer budget inequality. An analytic
  candidate needs verified correction; “±1” is sufficient only after proving
  an error bound for the selected implementation. The current Decimal check
  supplies experimental evidence, not that production proof.
- Keep the proposed 5% ceiling scoped to the trading fee; burn and price impact
  remain separate, with post-burn minimum receipt enforced. No combined-cost
  percentage guarantee is claimed, especially for dust.
- Accept existing-admin authorization, parameters-only cap updates, actual
  fee limits and reconstructible old/new events. Do not add a revision or
  timelock solely because the reviewer suggested them: fee limits already
  enforce the selected protection, native order sequences events, and those
  additional mechanisms are not selected requirements.
- Treat statements calling 0.2% cosmetic, forecasting routed flow loss, or
  assuming particular competing pool fees as qualitative hypotheses, not
  verified market findings. No demand calibration was performed.
- Preserve the separately noted free-fee-period qualification: volume can be
  accumulated at a zero cap and priced under a subsequent higher cap. The
  manufacturing-cost examples assume stable policy and no admin control.

The review agrees with the mechanism, with numerical implementation and
calibration obligations remaining. The default retained pending clarification
is the user's earlier explicit 0%–2%; 3% and 5% caps are authorized examples,
while a 5% hard ceiling remains our recommendation.

## Original reviewer response

**Reviewer:** Claude Fable 5 (runtime model id `claude-fable-5`), acting as independent mathematical/economic reviewer. Review of `blast-v2-dynamic-fee-recommendation.md` and `volume-fee-model.py` as a design + research model, not deployed code.

## Verdict

The core mechanism is **mathematically coherent**: the potential-based charge gives exact same-timestamp split neutrality (including across the memory cap), fees bounded by `[f0·q, f1·q]` on Quote principal, and a well-posed buy inverse. The capped commit `v'=min(K, v+q)` is compatible with all of this. No path exists from fee-cap updates to pool principal. The real gaps are at the edges: all proofs are real-arithmetic only; integer rounding direction and decay fixed-point direction are the exploitable surfaces; the 5% ceiling does **not** bound total take once burn is included; and the analytic buy inverse is empirically, not provably, equal to the integer definition. `f0=0` makes this a *rate* price, not a *volume* price — slow flow trades asymptotically free by design. That is consistent with "coherent, not profit-maximizing," but its consequences should be stated, not implied.

## Confirmed properties (compact proofs)

1. **Bounds.** `f(x)∈[f0,f1]` for all `x≥0`, so `C(v,q)=∫₀^q f(v+u)du ∈ [f0·q, f1·q]`. Exact.
2. **Split neutrality with capped commit.** `C(v,q)=P(v+q)−P(v)`. If `v+q1≤K`, telescoping is immediate. If `v+q1>K`, the committed state is `K`, and the second charge is `C(K,q2)=P(K+q2)−P(K)=f1·q2`; but `P` is affine with slope `f1` above `K`, so `P(v+q1+q2)−P(v+q1)=f1·q2` as well. Hence `C(v,q1)+C(min(K,v+q1),q2)=C(v,q1+q2)` for all stored states (stored `v≤K` always, since `v` starts at 0, trades cap it, and decay only shrinks it). The cap changes only the decay starting point after over-`K` bursts, exactly as documented.
3. **Buy inverse.** `g(q)=q+C(v,q)` has `g'(q)=1+f(v+q)≥1`, strictly increasing ⇒ unique real root; the rationalized root `q=2A/(b+√(b²+4aA))` and the cap-crossing budget comparison are correct.
4. **No dust-reset vector.** `v` decreases only via clock decay; trades only increase it; failed settlement commits nothing; traders cannot move the Sui Clock. Sustained wash at rate `S` equilibrates at `v*=S/λ`, so sustained activity cannot hold fees at the floor — self-limiting as intended.
5. **`P` changing is safe.** `P` is an accounting device: only differences at a single `(v, params, timestamp)` are used within one atomic swap; no `P` value persists. Persisted state (`v`, timestamps, custody balances) is parameter-independent, so an `f1` update needs **zero state migration** and cannot retroactively reprice — provided nothing ever derives owed fees from `current params × historical volume` (claims must draw on stored balances only) and each swap reads the parameter set once.

## Findings, prioritized

**1. The 5% cap does not bound total charge with burn — and needs an explicit guard.** Counterexample: sell with burn `β=1%`, `f1=5%`: burn shrinks curve input, fee hits gross Quote output; small-trade total take ≈ `β+f1−βf1 = 5.95%`. Buy: `(f1+β)/(1+f1) ≈ 5.71%`. Both exceed 5%. The sell-side expression dominates (algebra: `(f1+β)(1+f1)⁻¹ ≤ β+f1−βf1` always). **Exact guard:** whenever `f1` *or* burn `β` is updated, require `β + f1·(1−β) ≤ F_total_ceiling`; equivalently `(1−β)(1−f1) ≥ 1−F_total_ceiling`. Alternatively, document the ceiling as fee-only and report burn as a separate cost — but pick one and encode it. Note also that any percentage invariant fails at atomic scale: ceil-rounding gives ≥1 unit fee, so a 10-unit trade pays ≥10%. State the invariant as "percentage + 1 atomic unit" or impose a minimum trade size.

**2. `max_fee` semantics: principal-denominated is fine, but say what it implies.** As specified, `f1` caps fee/principal. Consequences: sell fee/gross-curve-output = up to `f1` exactly; buy fee/gross-input = up to `f1/(1+f1)` (4.76% at a 5% cap, 1.96% at 2%). So the principal cap *does* bound fee as a share of trader gross at `f1` in both directions (before burn and rounding). The UI convention warning in the doc is correct; the on-chain cap-check in the buy path must be on `q`, not `A`.

**3. Integer rounding direction is the zero-fee-splitting surface; proofs are real-only.** With round-**down** and `f0=0`, every segment whose exact charge is <1 atomic unit is free; near `v=0` with `K=10⁵` Quote at 9 decimals, segments up to ~0.1 Quote are free. However, the number of zero-fee segments needed to evade `X` atomic units of fee is ≈`X` swaps (per-segment free size is ≈`1/f(v)` units and `∫f(v)dv/K`-style counting gives `N ≈ total fee in units`), so evading even 1 Quote ≈ 10⁹ swaps — uneconomical, but the wrong direction, and the margin shrinks with 6-decimal Quotes. **Mandate round-up on both buy and sell fees** (sell rounding is currently unspecified — pin it), or adopt potential-difference integer rounding with fixed vectors. With round-up, splitting costs ≤1 extra unit per extra segment: safe direction, and the doc's caveat becomes a guarantee.

**4. Decay must be rounded toward keeping `v` larger, with an explicit per-update error budget.** Fixed-point per-update decay breaks exponential composition; if errors shrink `v`, an attacker forces update cadence with dust (or `q=0`) trades to erase memory faster than `H` intends. Illustration: a 2-digit per-minute factor (0.97 vs true 0.97716) turns 30 minute-updates into 0.401 instead of 0.5 — ~20% extra attacker-forced decay. Requirements: (a) round the decay factor toward 1; (b) per-update relative error ≤ ~2⁻⁴⁰ (Q64.64 gives 2⁻⁶⁴ — negligible over millions of updates); (c) `dt=0` ⇒ factor exactly 1 (same-timestamp split neutrality then covers coarse checkpoint timestamps); (d) reject or no-op `q=0` swaps so free update triggers don't exist.

**5. Cap updates cannot extract principal; the needed protections are ordering ones.** Fees are carved solely from the swapping party's own gross in the swap that pays them (buy: from `A` before reserves; sell: from the output owed to the trader); reserves move only via curve math; `f1 ≤ 5% < 100%` bounds the skim. So no admin path to principal. Residual risks are *ordering*: an admin raise landing before a victim's pending swap. Since min-out is on the post-fee, post-burn received asset, a tight min-out already catches raises in both directions (buys: less principal ⇒ less Meme out; sells: fee directly cuts Quote out). Still add an explicit per-swap `max_effective_fee_bps` (or fee-params-revision assertion) for users with loose slippage. The update function must mutate only the fee-params field (assert reserves, `v`, timestamps unchanged in tests), enforce `f0 ≤ f1 ≤ hard ceiling` with the ceiling as an on-chain module constant, emit `FeePolicyUpdated{old, new, revision, ts}` under the existing protocol-admin capability (no new per-pool authority), and bump a revision echoed in swap events. A timelock on raises is cleaner but is a product decision.

**6. `f0=0` prices rate, not volume — say so.** Volume `V` executed at rate `ρ→0` pays `→0` (holding `v≤ε` needs time `V/(λε)`); all revenue comes from bursts. Quiet-pool short-horizon manipulation is nearly free at small size (round trip of `q` from empty costs `2dq²/K` ≈ 0.4 Quote on a 1,000-Quote round trip at the 2% cap) — do not let anything use this pool as an oracle. Both are acceptable under the authorized 0% floor, but they are policy consequences, not test-covered accidents.

**7. Economics at the selected bounds (2% vs 0.2%).** Soundness is identical; only scale changes. At `f1=2%`: burst `K` from empty costs `K·(f0+f1)/2 = 1,000` Quote (model asserts this); sustaining full score ≈ 2,773 Quote/hr gross, ~555/hr net at 80% recapture. At `f1=0.2%`: 100 Quote burst, ~277/hr gross, ~55/hr net — surge response is nearly cosmetic and manufactured-fee-pressure griefing is trivially cheap, though griefers mostly want fees *low*, which requires idleness they can't force. Neither 2% nor 5% deters launch snipers expecting 10%+ moves; frame this as surge *revenue capture*, not sniping prevention. Surging to 2–5% while external pools charge 0.3–1% sheds exactly the flow being priced unless Blast holds dominant depth — the doc's own routing-elasticity citation applies; the proposed replay experiment is the right next step. The creator-wash calibration rule `K ≥ B·H/((1−r)·f1·ln2)` is correct and honestly caveated at `r→1`; check the actual creator fee share before fixing `K`. If "start with 0.2" means launching at 0.2% and raising later, note that *raises* are the trust-sensitive direction (event + delay matter more); launching at 2% and lowering is governance-cheap.

**8. Model evidence limits and integer-width gap.** The 2,000 cases run at 1-Quote granularity (`K=10⁵`), test no decay paths, no sell-side rounding, no overflow, and the analytic-inverse-equals-integer-search assertion is empirical (an exact-integer root truncating under 80-digit Decimal would break it; none was sampled). Production should *define* the answer by the integer inequality and verify the analytic candidate ±1 in-contract. Overflow: `d·(2vq+q²)/(2K)` at atomic scale (9-decimal Quote, `q` up to ~10¹⁷–10¹⁸) with bps scaling can exceed u128; use u256 intermediates or explicit trade-size bounds — currently unanalyzed.

## Minimal corrections preserving authorized policy

1. Specify fee rounding **up** on both directions (or potential-difference rounding) with contract/SDK vectors.
2. Specify decay fixed-point: factor rounded toward 1, error budget, `dt=0 ⇒ 1`, reject `q=0`.
3. Add combined guard `β + f1(1−β) ≤ F_total_ceiling` at every `f1`/burn update, or explicitly scope the ceiling as fee-only.
4. Hard ceiling as an on-chain constant; update = params-only mutation + event + revision; gate on existing protocol admin authority.
5. Per-swap `max_effective_fee` (or revision pin) alongside net min-out; abort zero-principal swaps.
6. Define the integer buy inverse by its inequality; analytic root as candidate with ±1 correction.
7. u256 intermediates or documented amount bounds.

## Unresolved production decisions

Final ceiling value (5%?) and its constness; timelock vs guard-only for raises; exact rounding rule choice (ceil vs potential-difference) and dust policy/minimum trade size; decay fixed-point format and error budget; whether the ceiling covers burn; `K`/`H` governance semantics if ever made updatable (does `v` rescale to preserve fill fraction?); disambiguation of "start with 0.2"; and the Quote-only settlement's auto-LP limitation remains real — own-pool Quote fees still cannot self-compound without Meme from elsewhere, which the doc correctly keeps explicit.
