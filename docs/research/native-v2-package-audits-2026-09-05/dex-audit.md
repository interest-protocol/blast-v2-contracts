# Independent Fable Audit — `blast_fun_dex` (sui/dex)

**Date:** 2026-09-05 · **Auditor:** Claude Fable agent (dex-target of two) · **Basis:** read-only source snapshot; no tools executed by this agent; parent runs pinned build/lint/test gates independently. Route executed per `sui-move-guide`: review orchestrator → architecture (+ events, object-custody, reusable-value refs) → security (+ DeFi, time/oracle, upgrade refs) → source style (+ errors, syntax, function-shape, pinned-library refs) → testing (+ fixtures, custody, adversarial, event-replay, upgrade/dependency refs), with the package-upgrade-posture reference loaded because the target is unpublished.

## 1. Baseline and posture

- **Intended behavior:** ADR 0076 (accepted). Canonical one-pool-per-Meme factory bound to the launch Quote; full-range constant-product principal; Quote-only fees held outside reserves under a cumulative Q64 fee-growth index; capped Q32 volume score with 1800 s half-life and target equal to the initial Quote seed; integrated (progressive) fee rounded up once; signed effective-fee/min-output/deadline bounds; optional immutable Meme burn ≤ 500 bps requiring `BurnOnly` registry authority; sealed native migration locking the complete issued position; live `AdminWitness` administration with an exact-generation factory cutover and no pause.
- **Publication status:** unpublished; no external audit claimed. **Upgrade posture:** evolving shared-state upgradeable — shared `Factory`/`Pool`/`LockedLpVault`, a designed operational generation cutover (`Factory.version` + compiled `VERSION`, next-generation-only `activate`), and publication-time `UpgradeCap` custody deferred to the existing release process (ADR 0076 §Administration). This posture matches accepted intent; custody is a deployment-evidence gap, not a code defect (§7).
- **Compatibility boundary:** pre-publication, so event/error compaction is still a deliberate one-time option; tests already pin event schemas byte-for-byte via BCS, which is strong.

## 2. Verdict

**No critical or high-severity defects were confirmed in `sui/dex`.** The economic core (integrated fee, decay, constant-product accounting, fee-growth index, seed/withdraw rounding) reconciles under adversarial sequencing; every attack I constructed either fails, costs the attacker, or is an ADR-0076-accepted residual. I confirmed three low-severity issues (event discipline, error identity, a config-dependent liveness edge on the native migration seam), several informational items, a set of concrete adversarial test gaps, and deployment-only gates. Details and remediations follow.

## 3. Findings

### F1 (Low) — `claim_fees` emits `FeesClaimed` for zero-amount claims
- **Where:** `sui/dex/sources/pool.move:293-311` (emit at 305–309).
- **Violated rule:** events must record real transitions; a zero claim commits no new economic fact (the checkpoint advance is not a promised replay fact).
- **Concrete path:** `migration::collect` (`sui/dex/sources/migration.move:113-118`) and `auto_lp::vault::compound → collect_own_lp` call `pool::claim_fees` unconditionally. Both callers correctly skip their own zero events, but every empty collection/compound still emits a pool-level `FeesClaimed { quote: 0 }`, spamming the replay stream (replay stays correct — the delta is zero — but the stream carries no-op records).
- **Minimal fix:** in `claim_fees`, emit only when `quote > 0` (keep returning the zero coin for composability). Pre-publication, this is a permitted emission-semantics decision.
- **Regression test:** `empty_fee_claim_emits_no_event` — empty pool claim returns a zero coin and `events_by_type<FeesClaimed>()` stays empty; extend `permissionless_native_migration_locks_complete_position_and_empty_collection_is_safe` to also assert no `FeesClaimed`.

### F2 (Low) — `Factory::activate` overflow aborts with the wrong diagnostic identity
- **Where:** `sui/dex/sources/pool.move:157-163` (line 159).
- **Violated rule:** each abort needs one owner with a stable, descriptive meaning. `checked_add` overflow aborts with `EWrongVersion` ("DEX generation must match the active factory"), which misdescribes the condition. Peer code distinguishes these: core has `package_version_overflow` (74), `auto_lp` has `EVersionOverflow`.
- **Concrete path:** unreachable in practice (version counts from 1), but the diagnostic is published API once deployed.
- **Minimal fix:** add `#[error(code = 17)] const EVersionOverflow` and abort with it in the `destroy_or!` branch.
- **Regression test:** mirror `auto_lp`'s `activation_rejects_generation_overflow` (set version to `u64::max` via test seam, expect the new code at `blast_fun_dex::pool`).

### F3 (Low, config-dependent liveness) — degenerate admitted-quote parameters can strand a native-witness launch in `MigrationReady`
- **Where:** seam of `sui/dex/sources/migration.move:65-96` (`migrate` → `create_from_balances`), `sui/dex/sources/pool.move:439-440` (`ESeedTooSmall`), and core `sui/launchpad/sources/launch.move:477-485` (`partition_quote` rounds the migration fee up).
- **Violated invariant:** before an irreversible/state-gating transition, every required exit must remain reachable. `launch.migrate` is the only exit from `MigrationReady`; if `create_from_balances` aborts, the abort is permanent for that launch (trading closed, reserves locked; only accrued fee claims remain live).
- **Exact reachability:** `create_from_balances` requires `meme > 0 && quote > 0 && sqrt(meme·quote) > 1000`. Meme provision is ≥ `floor(1e18/10^4) = 1e14` atoms for even a 1-bps provision, so the product condition holds whenever quote principal ≥ 1. The quote principal is zero only when `ceil(target·fee_bps/10^4) = target`, i.e. **`migration_quote_target = 1` atom with any nonzero `quote_migration_fee_bps`**. `allow_quote` (`launch_config.move:50-79`) only requires target > 0, so an administrator can admit this. Not attacker-reachable; admin misconfiguration only, and far from the documented 8,000-SUI lane.
- **Minimal fix:** enforce a sane floor at admission (core-side `allow_quote`, peer scope — coordinate with the other agent) or record the admission invariant (`target − ceil(target·fee) ≥ 1`, and `provision·quote_principal > 10^6`) as an operational config gate. No clean dex-side fix exists because the abort is the correct fail-closed behavior at that point.
- **Regression test:** core config-boundary test rejecting/exercising the 1-atom target; dex test pinning that a degenerate seed aborts `ESeedTooSmall` at `blast_fun_dex::pool` (documenting the invariant either way).

### F4 (Info) — `buy_and_burn`/`sell_and_burn` are legal on zero-burn pools
- **Where:** `sui/dex/sources/pool.move:343-361, 390-414`.
- The burn entrypoints check only `currency.is_supply_burn_only()`, so on a zero-burn pool with a BurnOnly currency they execute as exact aliases of `buy`/`sell` with a no-op `burn_balance(0)`. Harmless (burn = 0, event records `meme_burn: 0`), but it widens semantics: two equivalent public paths for the same trade. Decide deliberately: either add `assert!(self.burn_bps > 0, EBurnPolicy)` for symmetry with `buy`/`sell`, or keep the alias and pin it with a positive test (`burn_entrypoint_is_noop_alias_on_zero_burn_pool`). Currently unpinned either way.

### F5 (Info) — minor style/diagnostic items
- Public event types `PoolCreated`…`VersionActivated` (`pool.move:109-145`) lack `///` documentation, unlike every other public type in the suite ("document public types").
- `math.move` error codes start at 1 with no code 0 (`math.move:16-23`) — legal, but inconsistent with `pool.move`/`migration.move`; harmless pre-publication.
- `migration::claim_creator_fees`/`claim_protocol_fees` events carry only `quote`. That is correct today (the vault ledger's Meme side is structurally always zero — the only accrual is `accrue_from_runtime(balance::zero(), quote, …)` at `migration.move:119-121`), but if a Meme-side accrual is ever added the event schema becomes an indexing migration. A one-line doc note on `LockedLpVault` would lock this in.
- `pool::new_position` (`pool.move:191-201`) is not factory-version-gated. Acceptable — the position is inert until used with gated operations, matching the "pure/inert path" exemption — but worth recording as deliberate.

## 4. Economic-attack analysis (attempted, with outcomes)

All of the following were traced end-to-end; none succeeds beyond ADR-accepted residuals:

- **Fee-splitting neutrality:** each split rounds the integral up, so splitting a trade never lowers the total fee (pinned by `split_fees_preserve_integral_with_bounded_ceiling_dust`). `buy_principal`'s binary search is exact and maximal; refund ≤ 1 atom at ≤ 500 bps (pinned).
- **Decay cadence gaming:** the ceil-chained Q64 factor upper-bounds true decay, so checkpointing more often can only keep the score (and fees) *higher*, never lower; sub-atom bound pinned by `checkpoint_cadence_has_subatom_rounding_difference`.
- **Volume-cap safety:** stored `volume_x32` is always ≤ `target·2^32` (`next_volume` saturates; `decay ≤ identity`), so `EVolumeCap` is unreachable from pool paths and the fee integral cannot abort a legitimate trade.
- **Donation/first-depositor:** reserves are private `Balance` fields with no receive path (coins sent to the pool address strand, never join accounting); initial issuance is floor-sqrt with 1,000 shares permanently unrepresented; deposits mint floor and charge ceil; withdrawals pay floor. I additionally verified the share/reserve ratio `S/m` is non-increasing under deposits and withdrawals, and that swap-driven ratio inflation is bounded by u64 quote reserves, so `settle_position`'s u256 intermediates (`pool.move:496-505`) cannot overflow and `EShareOverflow`/`EAccountingOverflow` are fail-closed guards, not reachable bricks. Even in the theoretical `fee_growth` overflow state, principal withdrawal remains live (exits preserved).
- **Fee-history capture:** new positions checkpoint at current growth; the fee pot always covers Σ owed because entitlements per accrual are `(S−1000)·⌊F·2^64/S⌋/2^64 < F`; claims cannot underflow the pot. Locked-share and rounding dust stays in the pot with no sweep right, exactly as ADR 0076 states (test evidence: the 11-atom residue in `pool_tests`).
- **Duplicate/preemption of native migration:** for a native-witness launch, no pool can pre-exist (creator `create` requires `assert_migrated`; the sealed `Witness` is redeemable only by `migration.move`), so `EDuplicatePool` cannot block a first native migrate; duplicates and creator preemption abort (tested). The permissionless `migrate` takes no caller economic parameters; price derives from terminal reserves.
- **Reserve drain / division-by-zero:** `amount_out` output is strictly below `reserve_out`; withdrawals leave ≥ 1 atom per side while ≥ 1000 shares remain; `total_shares ≥ 1000` always, so all divisions are safe.
- **Accepted residuals (per ADR 0076, restated with remaining exposure):** (a) self-trading plus own-LP fee recovery cheapens volume manipulation — saturating the score costs roughly `max_bps/2` of one target's turnover minus the attacker's LP share of those fees, and elevates other traders' fees to at most the cap for ~1–2 half-lives; the signed effective-fee limit keeps every victim's cost consented. (b) Public LP deposits are sandwichable within the band implied by the signed maxima + `min_shares` (standard V2-style exposure). (c) On the AutoLP seam: a *compromised* executor key recreates exactly the ADR's rejected public-compounding drain (skew price → compound with loose bounds → revert), because the vault has no bound the executor does not choose; and executor key loss permanently halts deposits while collection stays live. Both are explicitly accepted in ADR 0076; I confirm the dex primitives (`deposit_amounts` at spot ratio) add no protection beyond that assumption and no extraction path exists (position/cap sealed in dynamic object fields with no removal API). Peer-agent scope for auto_lp specifics.
- **Cross-package generation abuse:** revoked admins cannot mint `AdminWitness` (live-registry check in `acl::sign_in`); stale dex generation blocks every economic path including adapter no-op paths (tested); `activate` accepts only the exact next compiled generation.

## 5. Test gaps (no defect proven; adversarial coverage to add)

Existing evidence (dex 50 passing per parent) is strong on exact arithmetic, event-byte replay, burn conservation, guard identity, and generation precedence. Missing, in priority order:

1. **Pool-level decay integration** — trade, advance `Clock` by 1 s / 1800 s / boundary, trade again; assert the charged fee reflects the decayed score and `last_trade_seconds` re-anchors (`decayed_volume_reduces_next_trade_fee`). Currently decay is only tested pure.
2. **Sequence conservation property** — N mixed swaps/deposits/withdrawals/claims asserting per-asset identities (`quote_in = reserves + fee_pot + payouts + refunds`; `Σ position shares + 1000 = total_shares`; `Σ claims ≤ Σ fees`).
3. **Unexercised aborts:** `EClockReversed` (`pool.move:514`); `EExpired` on `add_liquidity`/`remove_liquidity`; `EInsufficientShares`; direct `EMinimumShares` and `EMinimumOutput` on `remove_liquidity`; `EZeroAmount` dust withdrawal; `EPositionNotEmpty`; `ESeedTooSmall` at the exact `shares == 1000` boundary; `EIdenticalAssets` directly.
4. **Guard-precedence pairs:** deadline-vs-zero-input on swaps (deadline is checked inside `aged_volume` *before* `input > 0` at `pool.move:533-534` — stable but unpinned); stale-factory-vs-wrong-pool on `migration::collect` (only the claim variant is pinned).
5. **Position transfer** — transfer a `Position` to a second owner and prove settled/claimable fees follow the object and combined entitlement is preserved.
6. **`max_fee_bps = 0` trading** — zero-fee accrual still updates volume/anchor and growth stays flat.
7. **`sell_and_burn` minimum-output boundary** (buy-side is pinned; sell-side is not) and the F4 alias decision.

## 6. Deployment-only evidence gaps (not code defects)

- `blast_fun_dex` `UpgradeCap`/custody and normalized deployment evidence exist only as process commitments (ADR 0076); "permanently locked" language for the native position is valid only after immutable deployment, as the ADR itself states.
- **Cross-package cutover:** `migration::migrate` and the AutoLP curve-collection path statically link core gen-1 (`launch.migrate` / `launch.claim_creator_fees` assert core's compiled generation). Activating core to generation 2 will abort these routes until dex/auto_lp are upgraded against the new core and re-activated. This is the standard dependent-relink obligation ("a dependent stays linked to the generation it was published against") — it must be sequenced in the core activation runbook, with pending native-witness launches drained or the relink published first.
- Live object-API verification that the locked `Position` (and AutoLP children) remain discoverable by original ID through dynamic-object-field metadata — unit tests cannot substitute for the network check in the object-custody reference.
- `Factory.pools` is deliberately unbounded (one entry per Meme ever, matching core's retired quote-cap precedent); record gas/size behavior at scale as informational evidence.
- `docs/vectors/dex-fees.json` regeneration from `generate_dex_fees.py` must stay a release gate (test expectations already cite the generator; never hand-edit).

## 7. Skill-compliance table

| Standard / reference | Applied | Result for `sui/dex` |
| --- | --- | --- |
| sui-move-guide (routing) | ✔ full-review route executed once per skill | Complete |
| sui-move-review + upgrade-posture ref | ✔ posture classified: evolving shared-state upgradeable | Matches accepted intent; custody = deployment gap (§6) |
| sui-move-architecture | ✔ | Boundaries clean: dex depends inward on core; core imports nothing from dex; invariants owned once (math pure; pool state/lifecycle; migration custody); sealed `Witness`; no speculative seams |
| — events reference | ✔ | Replay-complete (reserves, fee balance, volume, totals per event; type/pool_id partitioning); F1 zero-claim emission is the one discipline slip |
| — object custody reference | ✔ | Position under `dynamic_object_field` with emitted IDs; intentional permanent custody; live-API check deferred (§6) |
| — reusable value invariants | ✔ | `Trade` sealed proposed-settlement value; core `Bps`/`FeeLedger` reused at the boundary; no redundant wrappers |
| sui-move-security (+ DeFi, time/oracle, upgrade refs) | ✔ | Fail-fast ordering sound; typed authority; linear migration payload; bounded work (≤ 64-iteration search, bounded loops); conservation and fee-index solvency proven (§4); deadlines inclusive and pinned; version cutover per pattern; F2/F3 as noted |
| sui-move-source-style (+ errors, syntax, function-shape, pinned-library refs) | ✔ | Sections/imports/naming/rounding-direction names conform; `#[error(code)]` messages descriptive; F2 diagnostic conflation and F5 doc gaps are the deviations; pinned framework methods (`checked_add`, `mul_div_ceil`, `div_ceil`, `sqrt`) used per lockfile revision `06734f6…` |
| sui-move-testing (+ all five triggered refs) | ✔ | Exact-abort/location pinning, BCS event-byte replay, fixtures per convention; gaps enumerated in §5 |

## 8. Reviewed files

**Target (full):** `sui/dex/Move.toml`, `sui/dex/Move.lock`, `sui/dex/sources/math.move`, `sui/dex/sources/pool.move`, `sui/dex/sources/migration.move`, `sui/dex/tests/math_tests.move`, `sui/dex/tests/pool_tests.move`, `sui/dex/tests/pool_policy_tests.move`, `sui/dex/tests/migration_tests.move`.
**Transitive seams and context (read for invariants):** launchpad `launch.move`, `launch_config.move`, `launch_ticket.move`, `curve.move`, `fees.move`, `acl.move`, `runtime_config.move`, `package_version.move`, `package_admin.move`, `creator_authority.move`, `bps.move`, `constants.move`, `errors.move`, `events.move`, `events_wrapper.move`, `blast.move`; `sui/auto_lp/{Move.toml,Move.lock,sources/vault.move,tests/vault_tests.move}`; `sui/migrators/{Move.toml,sources/vault.move}`; pinned framework sources `coin_registry.move`, `dynamic_object_field.move`, `balance.move`, `coin.move`; `AGENTS.md`, `docs/architecture.md`, `docs/testing.md`, ADR 0076; all suite skills and triggered references.

## 9. Residual release gates

1. Parent-executed pinned `sui move build` / `--warnings-are-errors` lint / `test --lint` (and any source-boundary/diff gates), with results recorded per `docs/testing.md` — console output alone is not a release record.
2. Resolve F1–F3 (and the F4 decision) with the listed regression tests before publication, while event/error compaction is still permitted.
3. Publication-time `UpgradeCap`/`Publisher` custody and normalized deployment evidence for `blast_fun_dex`; defer any "permanently locked" public claim until immutable deployment.
4. Cross-package cutover runbook: prove or relink the dex→core static routes before any core `PackageVersion` activation.
5. Live network verification of dynamic-object-field discoverability for locked positions; vectors regeneration gate; factory-table scale note.

**Limitations:** this is a source-snapshot review; I did not execute builds, tests, or network checks, and the passing-test counts (dex 50, core 208, auto_lp 16, migrators 39) are taken as parent-supplied evidence. Deployed-bytecode and indexer checks are inherently out of scope pre-publication.