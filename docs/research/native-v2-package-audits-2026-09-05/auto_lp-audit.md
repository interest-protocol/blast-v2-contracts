# Independent audit — `sui/auto_lp` (blast_fun_auto_lp)

**Verdict up front:** custody, authority, conservation, replay, and versioning in `auto_lp` are sound as implemented, and I found no path that extracts the creator cap, the locked position, or pending balances. I did find **one Medium-severity economic design gap**: `compound` carries no signed maximum-input bound, so an honest executor's `min_shares`/deadline cannot stop a third party from inflating the amount of Quote the vault spends by pumping the vault's limiting asset before the compound lands. This is a remaining risk *inside* the accepted executor-trust model, not a challenge to it. Beyond that: one wholly untested public function, a short list of test gaps, and several deployment-only evidence gaps (most importantly, `auto_lp`'s `UpgradeCap` custody is undefined and cannot use the core `PackageAdmin`).

**Method:** this is a read-only review of the supplied line-numbered snapshot. I executed the routed skill sequence (guide → review → architecture → security → source-style → testing) and read every included standard and reference in full. I ran no builds, lints, or tests; the parent process owns pinned-gate execution, and I rely on the stated evidence (dex 50 / auto_lp 16 / core 208 / migrators 39 passing) only as evidence of compilation and the covered behaviors. Upgrade posture (per the review step 1 + posture reference): **evolving shared-state upgradeable** — shared `Control` and `Vault` state reachable by future generations, with use-site generation gates and an admin-witnessed next-generation activation, consistent with ADR 0076.

---

## Findings

### F1 — Medium — `compound` lacks a signed maximum-input bound; `min_shares` does not bound consumption in the pump direction

**Class:** confirmed design defect with a demonstrated economic attack path (bounded to pending custody, never principal or the locked position).

- **Where:** `sui/auto_lp/sources/vault.move:228-274` (deposit computation at 244–247, deposit at 253–262); consumed amounts derive from `sui/dex/sources/math.move:115-132` via `sui/dex/sources/pool.move:219-231`.
- **Violated standard:** the loaded time/ordering reference requires binding a transition that can execute after state changes to "signer-approved **maximum input**, minimum output, and deadline," and the DeFi reference requires "minimum shares or assets, **maximum input**, and deadline" on share mints. `compound` signs only `min_shares` and `deadline_ms`, and its inputs are the *entire* vault custody (`withdraw_all` of both sides).
- **Why `min_shares` fails:** the vault is normally Quote-heavy and Meme-limited — native pool fees are Quote-only (`collect_own_lp`, `collect_native_lp` add only Quote), so Meme arrives mainly from curve claims and contributions. When the vault is Meme-limited, minted shares are `s = meme·S/M`. An attacker who **buys Meme** (M↓, Q↑) *increases* `s` — so any honest `min_shares` still passes — while the Quote consumed, `ceil(s·Q'/S)`, grows with the manipulated price. The signed minimum binds only the direction the ADR analyzed (attacker-chosen minimum); it cannot bind the vault's spend.
- **Concrete reproduction:** pool `M = 100,000` Meme, `Q = 100,000` Quote, `S = 100,000` shares; vault holds `1,000` Meme, `50,000` Quote. Fair compound mints `1,000` shares for `1,000` Meme + `1,000` Quote; executor signs `min_shares = 1,000`. Attacker front-runs the executor's transaction with a ~`41,400`-Quote buy (reserves ≈ `70,711` / `141,421`). Compound now mints `min(1,414, 35,355) = 1,414 ≥ 1,000` shares — the guard passes — consuming ≈ `1,000` Meme and ≈ `2,000` Quote at the pumped valuation. The attacker's back-run recaptures most of the extra Quote net of dynamic fees. Scaling the skew scales extraction toward the vault's Quote balance; ADR 0076's own rejected-scenario arithmetic (16,600 on a 100k/100k custody) confirms the magnitude. Two aggravators: collection is permissionless, so the attacker can also *enlarge* the deposited base by calling `collect_curve`/`collect_native_lp` immediately before the executor's transaction executes (`vault.move:141-181`); and the attacker need not win exact ordering — holding the pool skewed while pending fees are large suffices if the executor prices off stale state.
- **Practical severity:** exploitation requires ordering relative to the executor's transaction (harder on Sui than on public-mempool chains but explicitly in the standard's threat model) or an executor that does not re-price at signing; loss per incident is bounded by pending custody at that moment, and fees accrue continuously, so exposure recurs each compound. Hence Medium.
- **Minimal fix (does not alter any accepted product choice):** add signed `max_meme: u64` and `max_quote: u64` parameters to `compound` and, after the `deposit_amounts` preview, `assert!(meme_used <= max_meme && quote_used <= max_quote, EMaxInputExceeded)` with a new `#[error(code = 6)]`. Because pool state cannot change between the preview and `add_liquidity` within the call, the preview equals the actual charge (your own test `third_party_collects_and_authorized_executor_compounds…` already proves that equality via `remaining + used == before`), so the assert binds real consumption. The package is unpublished, so the ABI change is free. A signed reserve-ratio band is a heavier alternative; the per-asset caps are sufficient and simpler.
- **Regression tests:** (1) pre-fix demonstration — after `collect!`, snapshot fair `(used_m, used_q, s)`; in a prior transaction have `@0xB` buy Meme to skew the pool ~2×; executor compounds with `min_shares = s` and observe it succeeds with `Compounded.quote > used_q`. (2) post-fix — same sequence with `max_quote = used_q` must abort with the new code; the unskewed control case with identical parameters must succeed.
- **Interim operational guidance if the fix is deferred:** the executor should compound only when vault composition approximately matches the pool ratio (then any skew flips the limiting side *down* and `min_shares` aborts), re-price immediately before signing, and use tight deadlines.

### F2 — Low — `collect_external_lp` has zero test evidence

**Class:** test gap. `sui/auto_lp/sources/vault.move:157-167` is the only public function never executed by any test: the auto_lp fixture exercises only the native migration path, and no migrators `LpVault` is ever constructed (its constructor is `public(package)` in `blast_fun_migrators::vault` with no test-only seam). The function is three lines mirroring `collect_native_lp` and its abort behavior comes from core `fees.move:69-72` (`ENothingAccrued`), so code risk is low, but the standard requires evidence for every public path and ADR 0076's Verification section requires auto-LP custody coverage. **Fix:** add a `#[test_only]` constructor in `blast_fun_migrators::vault` that builds an `LpVault` with a pre-accrued creator ledger (or drive a real external migration in a shared fixture), then add a test asserting collected amounts, `FeesCollected.source_id == object::id(lp_vault)`, and custody totals.

### F3 — Low — remaining test gaps

All are gaps, not defects:

- **Empty-claim surface for permissionless callers:** no test that a second `collect_curve` (nothing accrued) aborts with core `ENothingAccrued` (code 38, location `blast_fun::fees`) — this is observable API for third-party collectors and should be pinned.
- **Compound deadline exact boundary:** `deadline_ms == now` acceptance is pinned for the dex check but not for auto_lp's own `EDeadlineExpired` at `vault.move:242` (inclusive `<=`).
- **Revoked-admin activation:** dex pins `revoked_administrator_cannot_change_pool_cap`; auto_lp has no test that a revoked admin cannot `activate` the `Control` (the guard lives in core `sign_in`, but precedence through this seam is untested here).
- **External-migration enrollment composition:** no end-to-end test enrolling a vault against a *creator-funded* pool (external-witness launch), where `collect_external_lp` works and `collect_native_lp` correctly finds no `LockedLpVault`.
- **F1 regression tests** as specified above.

### F4 — Deployment-only evidence gaps (release gates, not code defects)

1. **`UpgradeCap` custody for `auto_lp` is undefined and cannot reuse core custody.** `package_admin::wrap` binds strictly to the BLAST original package (`sui/launchpad/sources/package_admin.move:31-40`), so auto_lp's cap cannot enter the existing `PackageAdmin`. ADR 0076 concedes "until then upgrade authority remains a trust assumption" and that permanence claims require immutable deployment; before publication, record where the auto_lp (and dex) caps live and under what authorization. Every "no extraction / permanent custody" claim in `vault.move` is conditional on this.
2. **Cross-package cutover sequencing.** After a *dex* generation activation, `compound`, `collect_own_lp`, and `collect_native_lp` abort in old auto_lp bytecode (`factory.assert_current()` in linked dex code); after a *core* activation, `collect_curve` and even auto_lp's own `activate` (via `acl::sign_in`) abort until auto_lp is republished against the new generation and activated. Rejection is tested (`retired_dex_generation_rejects_even_empty_compound`, `stale_generation_*`); relink liveness is a release-time obligation per the upgrade-dependency reference — add it to the runbook. Nothing is lost in the interim; `collect_external_lp` and `contribute` remain live.
3. **Lockfile environments.** `sui/auto_lp/Move.lock` pins `testnet` only; a mainnet environment pin (and, transitively, the migrators venue ABI gates from `docs/testing.md`) precede mainnet publication. Note auto_lp cannot publish before `blast_fun_migrators` publishes, which is itself gated on live venue evidence.
4. **Off-chain child discoverability.** Per the object-custody tests reference, verify via network RPC (not Move tests) that the `CreatorCapKey`/`PositionKey` children resolve by original ID and traverse back to the vault parent after enrollment and after compounds.

### F5 — Informational / residual risks under the accepted executor model

- **Executor compromise ≈ loss of the pending fee stream.** A malicious executor can self-sandwich each compound (`min_shares = 0`, chosen timing) and extract most pending custody per round — economically a withdrawal right over *pending* value, though never over principal, position, or the cap. This is exactly the accepted trust ("deliberately trusts the immutable creator-selected executor"); I state it so the acceptance is made with its full scope. F1's max-input caps do not change this (the executor signs the caps). Executor *loss* permanently stops deposits while collection continues — accepted in ADR 0076. A future compatible addition (executor-signed rotate-forward) exists if ever wanted; not recommended now.
- **Zero-amount `FeesClaimed` event on every compound.** `pool::claim_fees` (`sui/dex/sources/pool.move:293-311`) emits even when `quote == 0`, and `compound` triggers it unconditionally via `collect_own_lp`. Peer-owned seam; flagging for the dex auditor as replay noise, not a defect.
- **Vault events carry no `TypeName`s.** `Enrolled`/`FeesCollected`/`Contributed`/`Compounded` identify the pair only via `pool_id` joined against dex's typed `PoolCreated<Meme, Quote>`. Compliant (the events standard permits reconstruction "in combination"); indexers must implement the join.
- **Coins transferred to the vault's address are unreachable** (no `receive` path; `contribute` is the sole sanctioned donation route). They are never counted, so accounting cannot be corrupted; same as sending to any object.

---

## Verified sound (what I checked and how it held)

- **Custody:** `CreatorCap` and `Position` live as `dynamic_object_field` children with no `remove` anywhere; `Vault` is key-only with `share` as its sole sink, so an unshared vault aborts the transaction; the parent can never be destroyed, so no child is strandable. Uniqueness of `CreatorCap<Meme>` bounds enrollment to one vault per Meme; the single publication-time `Factory` and Meme-keyed pool table make the passed `Pool<Meme, Quote>` necessarily canonical.
- **Conservation:** per-asset identity `custody_before + collected = deposited + custody_after` holds and is event-verifiable (delta + post totals on every event); preview/actual equality of `deposit_amounts` vs `add_liquidity` is guaranteed by no intervening pool mutation and is pinned by the existing conservation assertion. `deposit_amounts` rounding (shares floor, contributions ceil) provably keeps `used ≤ offered` for both assets; double `settle_position` in a compound is idempotent (`Δgrowth = 0` leaves `fee_fraction_x64` intact); zero/dust/one-sided balances skip with custody intact and no fake `Compounded` event.
- **Authority and versioning:** every mutator gates `Control.assert_current()` at its use site before other guards (pinned precedence tests, including version-before-creator-consumption); `activate` accepts only the exact next compiled generation under a live, revocable core `AdminWitness`, cannot run at initial publication, and rejects overflow; nonzero-executor and wrong-pool guards are pinned.
- **Replay:** all promised mutable facts (pending balances, executor, bindings, child IDs, generation) are reconstructible from the event stream plus native effects; event assertions in tests are byte-exact for the main payloads.
- **Zero/overflow:** wide `u256` intermediates in the transitive math with proven bit bounds; `EShareOverflow` guarded; pool reserves and `total_shares` provably never reach zero in production pools, so no division-by-zero is reachable from `compound`.
- **Style/errors:** section order, consolidated imports, `#[error(code = N)]` constants with descriptive messages raised at their invariant owners, receiver naming, documented irreversibility, and test-only seams isolated at the end all conform; the test fixture follows the stateful-fixture pattern (single `start_*`, `next_tx!`/`ctx!` macros, one consuming `end`).

## Skill compliance

| Standard / reference | Read | Applied | Outcome |
|---|---|---|---|
| sui-move-guide (routing) | ✔ | Full-audit route: review → arch → security → style → testing | Pass |
| sui-move-review + package-upgrade-posture | ✔ | Posture: evolving shared-state upgradeable; baseline = ADR 0076 | Pass; custody evidence gap → F4.1 |
| sui-move-architecture | ✔ | Boundaries, invariant ownership, abilities, seams | Pass |
| ├ events reference | ✔ | Replay completeness, totals, identity joins | Pass; note in F5 |
| ├ indexer-visible object custody | ✔ | DOF children, no wrapping, terminal lifecycle | Pass; RPC check → F4.4 |
| └ reusable value invariants | ✔ | No sealed value types defined in target | N/A beyond review |
| sui-move-security | ✔ | Guard order, authority, replay, custody, liveness | **F1**; otherwise pass |
| ├ defi-security | ✔ | Checkpointing, rounding, donation paths, sequences | **F1** (max input); otherwise pass |
| ├ time-oracles-randomness | ✔ | Deadline semantics, adversarial ordering | **F1** |
| └ upgrade-security | ✔ | Use-site gates, activation, concurrent generations | Pass; F4.1–F4.2 gaps |
| sui-move-source-style (+ errors, function-shape, move-2024, pinned-library refs) | ✔ | All changed declarations checked | Pass |
| sui-move-testing (+ fixtures, object-custody, adversarial, event-replay, upgrade-dependency refs) | ✔ | Risk matrix vs 16 tests | Partial — F2, F3; adversarial-ordering coverage missing (F1 test) |

## Files reviewed

Target: `sui/auto_lp/sources/vault.move`, `sui/auto_lp/tests/vault_tests.move`, `sui/auto_lp/Move.toml`, `Move.lock`. Transitive seams read in full: `sui/dex/sources/{pool,migration,math}.move` and dex tests (as evidence), `sui/migrators/sources/vault.move`, `sui/migrators/Move.toml`, core `blast_fun` sources (`launch`, `fees`, `creator_authority`, `acl`, `package_version`, `package_admin`, `runtime_config`, `launch_config`, `launch_ticket`, `blast`, `curve`, `lib/*`), pinned framework `coin_registry`, `dynamic_object_field`, `balance`, `coin`, plus `AGENTS.md`, `docs/architecture.md`, `docs/testing.md`, ADR 0076, and the complete skill suite with all references.

## Residual release gates

1. F1 remediation (or a documented decision to accept the max-input gap with the interim executor guidance) plus its regression tests.
2. F2/F3 test additions.
3. Parent-executed pinned build, warning-as-error lint, and test gates for `auto_lp` (not run here); `git diff --check` and source-boundary scripts where present.
4. `UpgradeCap` custody records for `auto_lp` (and dex) before publication; permanence/no-extraction claims remain conditional until then (F4.1).
5. Cross-package activation/relink runbook entry (F4.2); mainnet environment pins and inherited migrators venue ABI gates (F4.3); RPC child-discoverability verification post-deploy (F4.4).