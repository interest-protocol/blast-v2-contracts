# Holder distributor review — 2026-09-05

Reviewed the unpublished working-tree implementation using the repository's full
Sui Move review suite: architecture, source style, security, testing, and the
triggered custody, events, DeFi, dependency, and upgrade references. The SDK review
also applied its AGENTS.md and the workspace Ponytail standard.

No unresolved high-severity code defect was confirmed in this review. This is
local review evidence, not a production release approval: the LP settlement and
real upgrade rehearsals below remain outstanding.

## Scope and reviewers

Scope included every distributor Move source/test/manifest, all eight distributor
SDK modules, its CLI launcher, three SDK test files, shared commitment vectors,
package exports/dependencies, and the relevant docs. Traced the upstream creator
cap issuance, launch uniqueness, creator-fee ledgers, curve collection, LP vault
construction/custody, ACL sign-in, and operational package versions.

Codex performed the standards review and implementation verification. A separate
Codex reviewer examined SDK accounting/restarts and then the new version/pause
integration. Claude Code 2.1.261 ran an independent, read-only security review
explicitly on `claude-fable-5`; the substantive model identity was confirmed in
its response metadata. Fable executed no tests and changed no files.

The user refined the upgrade requirements during review. The final accepted
posture is owner-held native UpgradeCap plus launchpad-admin pause and operational
version activation. It supersedes the earlier immutable-release proposal. See
[ADR 0075](../decisions/0075-independent-holder-fee-distributor.md).

The [captured Fable report](holder-distributor-fable-2026-09-05.md) preserves its
original findings. It read some documentation and build artifacts before their
updates; the dispositions below refer to the final checked implementation.

## Findings and disposition

| Finding | Assessment and disposition |
| --- | --- |
| Fable F1: funded-claim pause contradicts immutable/liveness documentation | Documentation corrected to the user's new decision. Launchpad admins explicitly can suspend existing payouts indefinitely. Version/pause checks precede all five economic entry points. Pause/resume, unauthorized sign-in, precedence, and preserved funded claims are tested. |
| Fable F2: immutable dependency linkage can strand curve collection | Immutable release removed from the accepted design. The owner retains the UpgradeCap, preserving a compatible dependency-relink path. A fresh package cannot inherit existing caps/balances. Core cutover coordination and a real relink rehearsal remain release obligations. |
| Fable F3: locale-sensitive address ordering | Replaced all three locale comparisons with explicit codepoint ordering. A regression disables host collation and pins normalized hexadecimal address order through holder weights, allocations, and manifest construction. Existing cross-language vectors remain unchanged. Actual differing ICU output for these restricted hex addresses was not demonstrated; this is deterministic-encoding hardening. |
| Fable F4: empty creator-fee sweep aborts a composed PTB | Confirmed upstream behavior; retained its error semantics. The runbook now explains racing collections, refreshing state, skipping empty sweeps, and separating venue collection when the creator share can be zero. It explicitly rejects treating an aborted multi-operation transaction as completed. |
| Fable F5: a full durable rewrite/file for every checkpoint | Changed to bounded batches of up to 100 checkpoints. Journal persistence precedes the matching state watermark. The CLI regression proves recovery from two interrupted batches, overwrite of a stale journal, and no duplicated balance delta or weight. Large historical replay still requires throughput measurement. |

Additional review improvements: separated callable package ID from original type
origin in SDK/operator reads; added complete funding-event payload assertions;
covered zero recipient, zero claim, insufficient round funding, duplicate-padding
index rejection, and the actual CLI prepare/publish/advance/relay flow. The prior
SDK tests covered helpers but not this full command sequence.

## Invariants checked

- **Custody:** CreatorCap remains a discoverable dynamic object child. Current
  public ABI exposes neither the cap, its borrow, a mutable UID, nor a withdrawal
  returning coins. Distributor, Round, and version state have `key` only.
- **Authority:** the PublisherCap is bound to one distributor. Sui ownership
  authorizes publication. Existing core ACL sign-in supplies the AdminWitness for
  pause and activation; no second ACL or server-message verifier was introduced.
- **Accounting:** Meme and Quote remain separate balances. Publication reserves
  existing assets; claims can spend only their round budget and transfer only to
  the committed beneficiary. Funding and payout events reconcile amounts and
  remaining balances. Protocol fees and LP principal are outside the collector's
  authority.
- **Replay and work bounds:** the leaf commits distributor, round, index,
  beneficiary, and both amounts. Positional proofs use distinct leaf/node domains,
  exact depth, and an index bound. The bitmap pays each leaf once. Maximum supported
  cardinality and the final bitmap bit are exercised.
- **Cutover:** only the publication initializer creates production control state.
  Each economic call reads it at the call site. Activation requires the stored
  generation plus one to equal the compiled generation; it preserves pause and
  cannot choose an arbitrary version or roll back. Sharing newly constructed
  objects is a required consuming sink and moves no already-shared funds.
- **Off-chain accounting:** checkpoint contents/digest continuity and nonnegative
  balances are checked before advancing the ledger. Address balance times elapsed
  milliseconds determines weights; integer division leaves dust in custody.
  Confirmation matches the committed manifest; relay consults the chain bitmap.

The publisher remains trusted for fair allocation, the upgrade owner for future
code, admins for resumption/cutover, and the RPC provider for derived balance
changes. Public manifest availability is operationally required. These are
accepted trust boundaries, not claims of fully decentralized accounting.

## Verification evidence

Commands below ran on 2026-09-05 with `sui 1.77.2-51d177ad7d65`, the package's
locked framework revision, and the SDK's installed locked dependencies.

| Gate | Result |
| --- | --- |
| `sui move test --path sui/distributor --build-env testnet --lint --coverage` | 45/45 passed |
| `sui move build --path sui/distributor --build-env testnet` | Passed |
| `sui move lint --path sui/distributor --build-env testnet --warnings-are-errors` | Passed |
| `sui move summary --path sui/distributor --build-env testnet` plus production-surface inspection | Passed; nine public calls across the two state-owning modules; no public control constructor or cap/withdrawal escape |
| `sui move coverage summary --path sui/distributor --build-env testnet --summarize-functions` | 95.46% reported instruction coverage; limitations below apply |
| SDK `npm run check` | 189/189 tests plus ABI, formatting, lint and typecheck passed; lint retains non-blocking warnings |
| Migrator `node scripts/check_mainnet_abi.mjs --self-test` | 61/61 passed |
| Migrator `node scripts/check_mainnet_abi.mjs` | Live mainnet ABI check passed: 6 packages, 29 modules, 67 functions, 26 structs |
| Core and migrator `bash scripts/check_source_boundaries.sh` | Both passed |
| Move formatting, `git diff --check`, unchanged core/migrator source diff | Passed |

The locale test first failed on the prohibited collation call, then passed after
the comparator change. The batch regression first failed against the old
per-checkpoint journal layout, then passed with batched persistence. The CLI test
uses actual command handlers and filesystem writes with mocked RPC responses; it
covers indexing failure at checkpoints 100 and 101, resumed holdings, prepared
amounts, pending-round freeze, unsigned publication, repeated confirmation, and
skipping an already-paid allocation.

## Remaining validation gaps

1. **LP collection execution:** no Move test executes `collect_lp_fees` through a
   real venue/vault lifecycle. The live ABI check verifies interface compatibility,
   not venue settlement or fee conservation. Exercise both assets and stale-core
   linkage behavior with a deployed migration before enabling this route.
2. **Native upgrade rehearsal:** version transitions were tested using controlled
   test state and source/production-ABI inspection. Publish/upgrade/activate/resume
   the same lineage on a test network, including old and new calls and dependency
   relinking, before relying on recovery. Native capability custody and explorer
   child lookup likewise require deployment evidence.
3. **Coverage boundaries:** the foreign-launch failure branch and publication
   initializer remain source-reviewed rather than directly executed in this
   package's tests. Coverage percentage is not an exploit-resistance guarantee.
4. **Provider and scale:** bootstrap archival RPC behavior and real execution of
   signed relays are not covered by the mocked CLI test. Measure maximum-round gas,
   object limits, provider history availability, and mature-coin indexing backlog
   on the intended network. Batching reduces persistence overhead without skipping
   any checkpoint or proving provider-supplied balance changes cryptographically.

No package was deployed, no live funds moved, and no UpgradeCap was transferred
or destroyed. Existing launchpad and migrator production code remains unchanged.

## Follow-up full-suite review

The user requested another complete Sui Move standards pass on 2026-09-05.
Codex reread the current suite and reviewed all distributor Move declarations,
function bodies, tests, dependency pins, SDK transaction callers, and the upstream
creator-cap, fee-ledger, launch, vault, and ACL boundaries. This pass did not rerun
the separate Claude audit.

Two test-quality findings were corrected: seven publication tests accessed the
scenario directly, and ordinary fixture teardown destroyed the scenario without
calling its finalization function. Publication now goes through the fixture API,
context access is centralized, and teardown explicitly accounts for its resources
and calls `scenario.end()`. Production cleanup separates validation, mutation,
emission, and return paragraphs and documents the economic event types.

Added direct tests for stale bytecode attempting to resume paused rewards and
independent changes to every committed leaf field. The pinned compiler rejects
assignment directly to an index expression, so the existing supported
`*&mut self.claimed[word]` syntax is intentionally retained.

Fresh verification passed: 47/47 Move tests with coverage, build, warning-as-error
Move lint, Move formatting, 189/189 SDK tests and its full check command, both
source-boundary scripts, the Turbos dependency-pin gate, 61/61 offline ABI checks,
and the live ABI check across six venue packages. Reported Move instruction
coverage remains 95.46%. All three production module ABIs match the preceding
review after excluding documentation; no function signature, type layout,
capability, guard, or payout behavior changed. Both repositories pass
`git diff --check`; core and migrator source remains unchanged.

No new security defect or unresolved actionable source-style finding was
confirmed. The deployment, LP execution, archival-provider, scale, and direct
branch-coverage gaps listed above remain applicable.
