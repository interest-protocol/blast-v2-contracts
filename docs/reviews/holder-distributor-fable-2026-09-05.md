# Independent Fable security review — captured report

Ran with Claude Code 2.1.261, explicitly selecting `claude-fable-5`; the substantive review completed on that model. Read-only tools; no deployment or test execution by Fable. The working tree changed during the review. This is the original report, including findings based on intermediate documentation and build artifacts. The current disposition and verified results are in [the consolidated review](holder-distributor-2026-09-05.md).

---

Audit complete. One important process note first: **the working tree changed while I was auditing** — partway through, a distributor-local `package_version` module (pause + generation gate) landed in both the Move package and the SDK (version-threaded call signatures, `decodeDistributorVersion`, operator config keys). I re-read everything and this report reflects the **current** on-disk state. The ADR and SDK doc did **not** change and now lag the code, which drives the top finding.

# Security findings

## F1 — High: launchpad-admin pause now gates existing funded claims; the accepted ADR and public SDK doc still promise the opposite

**Where:** `/home/ubuntu/blast-v2/contracts/sui/distributor/sources/distributor.move:262` (`claim` begins with `rewards_version.assert_enabled()`), `/home/ubuntu/blast-v2/contracts/sui/distributor/sources/package_version.move:51-57` (`set_paused` under `blast_fun::acl::AdminWitness`) and `:73-76` (`assert_enabled` = exact generation AND not paused).

**Trace:** any active launchpad `AdminCap` holder calls `acl::sign_in` (launchpad `acl.move:242-255`) → `package_version::set_paused(control, witness, true)`. From that moment every `claim` on every already-funded, already-shared `Round` aborts with `EPaused`, along with enrollment, collection, and publication. There is deliberately no sweep, cancel, or cap-extraction path, so if the AdminCaps are lost or maliciously withheld while paused, all round balances and distributor custody are frozen permanently in an immutable package. This is a genuinely new, indefinite freeze authority over user settlement held by a *different* authority domain (launchpad routine admins) than the distributor's own publisher.

**Why it's a finding and not accepted trust:** the code is deliberate and well-tested (`pause_stops_existing_claims_before_proof_validation`, `launchpad_admin_can_resume_existing_funded_claims`, `unrelated_admin_cannot_obtain_pause_authority` in `distributor_tests.move:532-716`), but it contradicts the accepted design record it must live under: ADR 0075 line 76-77 states "Existing funded claims never depend on core version state or a live publisher" and lines 11-13 enumerate the absent authority surfaces without any pause; `sdk/docs/holder-distributor.md:138` states "Existing funded claims remain payable if the publisher or keeper disappears." Under `contracts/AGENTS.md`, a durable authority decision requires an ADR amendment. The security skill's pause rule ("preserve user exits and mandatory settlement unless the design explicitly rejects them") requires that rejection to be explicit and recorded.

**Smallest remediation:** either narrow `claim` to version-only gating (pause blocks enrollment/collect/publish but not settlement of already-committed rounds), or keep the behavior and amend ADR 0075 plus `holder-distributor.md` to record the pause scope, its holder, and the lost-admin worst case. Also update the SDK doc's operator config and enrollment example, which no longer match the code: `operator.ts:136-145` now hard-requires `originalPackageId` and `distributorVersionId` absent from the documented config (`holder-distributor.md:42-56`), and the documented `DistributorCalls` constructor call (`holder-distributor.md:16`) lacks the now-mandatory `packageVersion` field (`transactions.ts:22-28`).

**Missing test:** none on-chain — this is a documentation/decision-record defect, not a code defect.

## F2 — Medium: "immutable release" and the pause/version machinery are mutually exclusive answers to the documented curve-fee stranding gate

**Where:** `/home/ubuntu/blast-v2/contracts/sui/distributor/sources/distributor.move:155-167` → launchpad `launch.move:320-328` → launchpad `package_version.move:32-37` (exact `version == PACKAGE_VERSION`); distributor `package_version.move:61-68` (`activate` requires `stored + 1 == compiled`).

**Trace:** the launchpad is built to upgrade (its `activate` exists and is reachable). The moment launchpad generation 2 activates, `collect_curve_fees` in a distributor linked against generation 1 aborts forever; the `CreatorCap` is sealed with no extraction path, so creator curve fees accrued inside the launch become unclaimable by anyone. The distributor's own `activate` can only ever succeed after a distributor package upgrade relinking to the new launchpad generation — which is exactly what the intended immutable posture forbids. If released immutable, `activate` is permanently dead code and the stranding gate is unresolved; if released upgradeable, "irrevocable custody" cannot be claimed. ADR 0075 lines 69-77 already names this gate, so this is a documented open obligation, not a bug — but the new machinery makes the choice binary and it must be settled before release. Note the LP-fee path deliberately takes no launchpad version (`vault.move:55-82`), so the post-graduation stream survives launchpad upgrades; only the pre-graduation curve stream is at risk.

**Smallest remediation:** record the release decision: either retain a custodied `UpgradeCap` (distributor upgradeable, `activate` is the cutover) and stop describing custody as irrevocable, or obtain and record a launchpad commitment that generation 1's `claim_creator_fees` seam stays callable.

**Missing test:** a pinned test that `collect_lp_fees` succeeds while the launchpad generation is stale (the property that the LP stream survives core upgrades). No such test exists — and see the coverage gap below: `collect_lp_fees` has no Move test at all.

## F3 — Low: locale-dependent `localeCompare` makes manifest construction and third-party validation environment-dependent

**Where:** `/home/ubuntu/blast-v2/sdk/src/distributor/allocations.ts:74-76` and `:119` (beneficiary sort fixes leaf indexes and therefore the committed root), `/home/ubuntu/blast-v2/sdk/src/distributor/holders.ts:116`.

**Trace:** `String.prototype.localeCompare` with no arguments uses the host's default locale/ICU build. A manifest built on host A commits that ordering on-chain. An independent relayer on host B whose collation orders the hex addresses differently runs `relay` → `pendingRewardAllocations` → `validateRewardManifest`, which rebuilds the manifest with B's ordering and throws "manifest allocation mismatch" — locking honest third parties out of the documented "anyone can relay" path. No funds are at risk (the root and proofs stay valid), but the design's permissionless-delivery liveness claim depends on an unpinned host setting. Equal-length lowercase-hex strings make divergence unlikely in practice, which is why this is Low rather than Medium.

**Smallest remediation:** replace all three sorts with a plain codepoint comparator (`a < b ? -1 : a > b ? 1 : 0`).

**Missing test:** a determinism test pinning the exact sort order for a fixed address set (digits versus letters, boundary values).

## F4 — Low: zero-accrual abort in the upstream fee ledger makes permissionless collection composition-fragile

**Where:** launchpad `fees.move:64-78` (`nothing_accrued` abort when both creator balances are zero), reached from `distributor.move:165` and `:179`.

**Trace:** anyone may collect, so a bot can front-run the keeper's collect transaction; the keeper's transaction then aborts (funds are already in the distributor, so this is benign griefing). More materially, the documented PTB pattern "compose the venue fee collector with `collectLpFees`" (`holder-distributor.md:86-89`) aborts *entirely* — including reverting the venue collection accrual — whenever the newly collected creator share is zero. Liveness nuisance only; upstream is frozen so a contract fix is out of scope.

**Smallest remediation:** keeper-side tolerance — treat this abort as a no-op success and prefer separate transactions for venue collection versus sweep. Worth a note in `holder-distributor.md`.

## F5 — Low: per-checkpoint durable rewrite makes "replay from coin creation" impractical for older coins

**Where:** `/home/ubuntu/blast-v2/sdk/src/distributor/operator.ts:335-350`.

**Trace:** every indexed checkpoint performs a full-ledger JSON serialization and fsync of `state.json`, plus one checkpoint JSON file and a directory fsync. Mainnet produces several checkpoints per second; a coin a few months old implies tens of millions of iterations and files. This quietly contradicts the practical availability of the documented recovery procedure ("replay to each published round's end", `holder-distributor.md:123-126`) for anything but young coins. Not exploitable; it degrades publisher/keeper liveness, which the ADR treats as operational.

**Smallest remediation:** persist `state.json` every N checkpoints (the sequence-gap check in `applyHolderCheckpoint` already makes resume-after-crash safe) and chunk or make optional the per-checkpoint journal.

# Accepted trust assumptions (verified as implemented, not reported as exploits)

- Publisher fairness: the on-chain contract binds budget ≤ balances, 32-byte commitments, ≤65,536 leaves, contiguous intervals, and monotone round numbers, but deliberately cannot prove leaf totals or historical eligibility (ADR 19-21). A malicious publisher can commit a tree whose leaf sum exceeds its funding, causing late claimants to abort — within the accepted misallocation power; SDK-built manifests bind sum exactly to budget.
- The operator trusts provider-derived balance changes and does not verify checkpoint signatures; the implemented completeness checks (chain-ID pin, contents/transaction digest matching, sequence and digest contiguity, monotone timestamps, non-negative balances) match what the doc claims (`holder-distributor.md:60-64`).
- Eligibility policy is publisher-defined: address-owned custody (exchanges, coins transferred to object addresses) counts as a holder unless excluded via config; the doc says so explicitly.

# Verified sound (no findings)

Merkle leaf/node domain separation with fixed-width BCS fields; exact positional depth (`ceil(log2 n)` matches the Move loop for all n ≤ 65,536); duplicate-last-node padding cannot mint phantom claims because `index >= leaves` is rejected and the index is bound inside the leaf; the claim bitmap enforces exactly-once payment; leaves bind distributor ID + round number so cross-round/cross-distributor replay fails; one launch per Meme type is enforced by `coin_registry::new_currency_with_otw`, which makes the type-only `CreatorCap<Meme>` binding sound; `Distributor` and `Round` are key-only, so sharing in the creation PTB is forced and funded claims cannot be withheld by the publisher; no cap withdrawal/borrow surface exists; SDK↔Move byte vectors are pinned both ways (`creator_cap_key_bcs_matches_sdk`, `merkle_tests` fixture hashes, `holder-rewards.json`, `RewardPaid` BCS layout test); operator crash-safety (atomic rename + dir fsync, single-writer lock, `pending.json` indexing freeze, idempotent `advance`, on-chain bitmap as the only retry authority) holds; no key material enters artifacts (0600 files, env-only Ed25519 relay key).

# Coverage gaps

- **No Move test exercises `collect_lp_fees` at all** (vault construction is package-private in migrators; a test-only vault constructor is needed). `EWrongSource` (foreign launch passed to `collect_curve_fees`) is also untested.
- No claim-path tests for `EInvalidBeneficiary` (zero address), `EEmptyBudget` (0/0 leaf), or `EInsufficientFunds` (leaf amount exceeding round balance under an adversarial root).
- `merkle_tests` does not pin the phantom-index forgery vector at the duplicated-padding position (for example leaves=3, index=3 with the self-duplicated sibling path).
- The operator command handlers (`index`/`prepare`/`publish-tx`/`advance`/`relay`) have no tests — only the pure helpers and transaction construction are covered.
- `contracts/sui/distributor/build/` contains a compiled artifact set predating the `package_version` module; any deployment evidence must come from a rebuild.

# Limitations

- Concurrent edits landed mid-audit; I audited the final on-disk state, but if editing continues, F1's specifics (especially doc drift) should be rechecked once the tree settles.
- I could not compile or run tests (read-only session); argument-order and BCS-layout conclusions are from source inspection, and the parent session's `sui move test` / `npm run typecheck` / `npm test` runs remain the executable gate.
- Live-venue LP behavior, real gRPC provider semantics for embedded-`Balance` custody, and mainnet checkpoint-rate assumptions were assessed only against the documented interfaces (the ADR already flags venue link stubs as a release-evidence gate).