# Native DEX and auto-LP package audit response

Review period: 2026-09-05–2026-09-06. Two independent Claude Fable agents reviewed `sui/dex` and
`sui/auto_lp`, including their transitive invariant boundaries. Both received
the complete repository `sui-move-guide`, review orchestrator, four focused
standards and required references, along with line-numbered source snapshots.
They ran through the Claude CLI with `--model claude-fable-5 --effort max`.
The model usage receipts in `review-metadata.json` confirm Fable execution.

These are model-assisted source reviews. The reviewers had no tools enabled;
the implementing agent ran the local build, lint, test and ABI gates. Neither
review certifies deployed code. `snapshot.json` identifies the **pre-fix** source
reviewed by the initial agents. The local gates are recorded in [local-checks.json](local-checks.json), with
[the verified source hashes](verified-source-snapshot.json).
The two original reports are preserved verbatim:

- [DEX review](dex-audit.md)
- [Auto-LP review](auto_lp-audit.md)

## Finding dispositions

| Finding | Resolution and evidence |
| --- | --- |
| DEX F1: zero fee-claim events | Keep the composable zero coin; emit only for positive Quote. Empty-claim regression verifies no economic event. |
| DEX F2: generation overflow diagnostic | Dedicated `EVersionOverflow`; exact-error regression. |
| DEX F3: zero migration Quote seed | Core launch creation validates the snapshotted target against the rounded terminal fee before consuming the ticket. Target=1/nonzero-fee rejects; target=1/zero-fee remains valid. |
| DEX F4: zero-burn aliases | Retained deliberately. Both registry burn entrypoints have a positive zero-policy test verifying unchanged supply. |
| DEX F5: public type documentation | Added event documentation and documented the native ledger's structurally empty Meme side. Inert position creation remains ungated; economic use is gated. No numeric error renumbering was necessary. |
| Auto-LP F1: signed maximum input absent | Added maximum Meme and Quote arguments. Actual paired consumption must fit both before withdrawal/deposit. The attack regression first failed against the old code, then passes by requiring `EMaximumInput`. Exact unskewed caps succeed; an independent Meme-cap test rejects excess. SDK requires all input, share and deadline limits explicitly. |
| Auto-LP F2: external creator-fee collection untested | Added a test-only funded external ledger fixture and public collection test. It verifies both custody amounts and the complete event, including source ID. No production constructor or extraction path was added. |
| Auto-LP F3: missing boundaries/composition | Added repeated empty curve-claim, exact-deadline, revoked-admin activation, and external-witness creator-funded pool enrollment/collection tests. External venue harvesting itself remains a live venue gate. |

Additional DEX regressions exercise pool-level half-life decay before fee charging,
zero-fee trades in both directions, minimum sell receipts after burn and fees,
position transfer with earned fees, and the missing seed, time, share, withdrawal
and position-destruction abort boundaries.
The existing mixed swap/deposit/withdraw/claim vector verifies conservation;
the SDK now replays that same vector through all DEX event kinds and rejects an
inconsistent policy event without mutating its projection.

## Follow-up review

Both originally requested Fable audits completed. One additional auto-LP
follow-up was stopped after 3,024 seconds without returning a report. It is
recorded as cancelled in `followup-metadata.json`, with no inferred findings or
approval. The completed DEX follow-up independently reviewed both adapters and
verified the auto-LP remediation. There is no pending background reviewer.

The [DEX follow-up](dex-followup.md) verifies the original fixes and independently
checks both SDK adapters. It reports no remaining high or medium defect. Its
reviewed inputs are in `followup-snapshot.json`; later test additions and SDK
fixes are identified by `verified-source-snapshot.json`.

- L1: event decoding now accepts an explicit `historicalPackageIds` allow-list
  alongside the current execution ID and stable original ID. Tests admit a
  trusted prior emitter for both adapters and reject unknown emitters or a
  changed type lineage.
- L2: pool creation and liquidity coin intents now normalize types explicitly,
  matching swaps. This was a consistency improvement: inspection of the pinned
  Sui SDK confirmed `tx.coin` already normalizes these intent types, so the
  suggested short-type selection failure was not reproduced. Both builders have
  positive short-type tests.
- The reported missing reducer branches, custody reads and burn-sell preview now
  have SDK regressions. `check:abi` also compares the SDK's DEX fee vectors with
  the contract source; `check:abi:write` copies the canonical generated fixture.
- Missing Move abort boundaries, position transfer and fee-accounting overflow
  now have exact-error/behavior regressions. The overflow fixture is test-only;
  it adds no production mutation path.

## Corrections to review reasoning

The auto-LP maximum-input finding is valid, but the report's illustrative
1,000-Meme / 50,000-Quote vault and 41,400-Quote front-run do **not** establish
positive attacker profit at the default dynamic fee. Independent integer
calculation gives a loss of 516 Quote atoms. The same reserve-consumption issue
can be profitable with more pending Meme: 5,000 Meme yields 114 Quote profit,
and 10,000 yields 838, with the same 50,000 Quote and front-run. The regression
pins the violated spending bound directly rather than relying on the flawed
profit example. Signed caps still require an honest executor to choose them.

The DEX report also overstates that extra decay checkpoints can only increase
the score. Upward Q64 factors are followed by a final Q32 floor, which can lose
a sub-quantum amount per checkpoint. ADR 0076 explicitly records that bounded
rounding loss; the review sentence is not a monotonicity proof.

## SDK verification boundary

The new `dex` and `auto-lp` SDK exports provide composable calls, complete common
transactions, integer previews, BCS object reads, canonical/child discovery,
event decoding and replay, and deployment identity adapters. The native ABI
snapshot covers all 28 public functions and 17 events; tests compare builder
arity, generic counts, pure argument widths and event field order against it.
The copied arithmetic vectors match the contract fixture. A canonical lookup
regression caught and fixed the distinction between RPC type strings and Move's
stored TypeName strings without `0x` prefixes.

The SDK does not fabricate deployment IDs, run an executor service, or grant
execution authority based on previews. Usage and transaction bounds are in the
SDK's `docs/native-dex-and-auto-lp.md`.

## Release evidence still required

- Name custodians and final disposition for both new UpgradeCaps. Core
  PackageAdmin only accepts its own original package; it cannot hold these caps.
- Rehearse dependency relinking and generation cutover across core, DEX,
  migrators and auto-LP. Old linked code must fail closed; updated paths must work.
- Pin the intended mainnet environment and run existing external-venue live ABI,
  dev-inspect, harvesting and residual checks. The offline ABI self-test is not
  live venue evidence.
- Verify dynamic-object child discovery and ownership through network RPC after
  enrollment, migration and compounding. Mocked SDK reads cover encoding and
  validation locally, not network behavior.
- Record deployed bytecode/transaction evidence and immutable-cap disposition
  before describing the custody as immutable.

The executor remains trusted on economic timing and price, and losing its key
stops deposits. Maximum-input limits prevent unapproved spending by an honest
executor; a malicious executor can sign permissive limits. These accepted
tradeoffs remain explicit in ADR 0076.
