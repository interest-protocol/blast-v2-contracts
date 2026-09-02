# Sui Move skill-suite update audit

- Date: 2026-08-30
- Status: primary-source research applied to `.agents/skills/sui-move-*` on 2026-08-30
- Blast toolchain: Sui CLI `1.77.2-51d177ad7d65` (`mainnet-v1.77.2`)
- Blast framework source: `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`
- Upstream comparison snapshot: `MystenLabs/sui@60f0e8a6abb0523d5c9c7f5edc006f40d8dead03`

## Verdict

The suite is broadly current. Keep its architecture, upgrade-compatibility,
randomness, event-schema, and stable-edition rules. Make four targeted updates:

1. add versioned `TxContext` PTB signature rules;
2. make gRPC/checkpoint-watermarked event verification the current indexing
   baseline and reject new JSON-RPC guidance;
3. add post-publication `sui client verify-source` to release verification; and
4. add two version-gated framework/tooling notes: `UpgradeCap` original-package
   resolution and the unit-test package-arena bound.

Do not copy current `main` behavior into a Blast rule without an explicit
toolchain upgrade. The repository fixes both the CLI and framework source:
[`launchpad/README.md`](../../sui/launchpad/README.md) names CLI
`1.77.2-51d177ad7d65`, and the package lockfiles resolve the primary framework
to [`sui@06734f6`](../../sui/launchpad/Move.lock). The official release record
identifies that CLI as `mainnet-v1.77.2`, protocol version 133
([release](https://github.com/MystenLabs/sui/releases/tag/mainnet-v1.77.2)).

## Prioritized changes

### P0 — distinguish `TxContext` style from PTB validity

Update `sui-move-source-style`, `sui-move-security`, `sui-move-testing`, and the
review checklist.

- Keep “`TxContext` last” only as Blast parameter-order style. Sui 1.64 made a
  PTB-injected `TxContext` callable in any parameter position, so last position
  is not a language or adapter requirement
  ([official release notes](https://github.com/MystenLabs/sui/blob/60f0e8a6abb0523d5c9c7f5edc006f40d8dead03/docs/content/references/release-notes.mdx#L489-L499)).
- Add a version-gated rule for protocol version 135 and later: a PTB Move-call
  signature may take `TxContext` at most once as `&mut TxContext`, or any number
  of times as `&TxContext`; it may not take it by value or return it by value or
  reference. Violations become `InvalidTxContext`
  ([upstream implementation and release note](https://github.com/MystenLabs/sui/commit/fe96658af33d7a85217aad939a754323611553e8)).
- Require lint/test coverage when a public or `entry` signature contains
  `TxContext`. Current upstream extended `uncallable_function` to flag the new
  return-position rule
  ([compiler lint](https://github.com/MystenLabs/sui/commit/6ef8c23b8685d151f71ff507ff4987f2a01e46cc)).

Blast's pinned protocol/toolchain predates that protocol-135 enforcement. The
skill text must say to verify activation in the target network's protocol
configuration before asserting the exact runtime error.

### P0 — update the event/indexing transport baseline

Update `sui-move-events-errors`, `sui-move-testing`, and `sui-move-review`.

- Preserve the existing rule that application counters do not replace native
  event order and checkpoint coverage.
- State that new event reducers and replay tests must use gRPC ledger positions,
  cursors/watermarks, or GraphQL where appropriate. JSON-RPC is deprecated; Sui
  Foundation mainnet full nodes disabled it in the week of 2026-07-27, with
  full code removal scheduled for mid-October 2026
  ([official gRPC status](https://docs.sui.io/develop/accessing-data/grpc/what-is-grpc#release-status)).
- Add a gap-free indexer test rule: open the live subscription, retain its first
  progress marker, backfill through the matching list API to that marker, then
  consume the buffered stream. Full-node gRPC has no implicit archival fallback,
  so replay tests that require old data must select an archival service
  explicitly
  ([official subscription and retention guidance](https://docs.sui.io/develop/accessing-data/grpc/what-is-grpc#subscriptions-for-streaming-data)).

This is a skills update, not a contract ABI change. The existing event payload,
identity, wrapper, and replay-completeness rules remain valid.

### P1 — add reproducible onchain source verification

Update `sui-move-testing` and the final step in `sui-move-review`.

For a published or upgraded package, add `sui client verify-source
<PACKAGE_PATH>` to the release evidence. In the pinned 1.77.2 toolchain, the
command rebuilds with the toolchain recorded at publication and compares the
root package's bytecode and linkage table with the onchain package. It reads the
address, original ID, and toolchain version from publication metadata; it does
not recursively verify dependency source
([official source-verification contract](https://github.com/MystenLabs/sui/blob/60f0e8a6abb0523d5c9c7f5edc006f40d8dead03/docs/content/develop/manage-packages/source-verification.mdx#L8-L46)).

The skill must keep local build, lint, unit tests, ABI checks, and dependency
pin checks. `verify-source` proves reproducible correspondence with a deployed
artifact; it does not prove protocol correctness or dependency-source trust.

### P1 — use native original-package resolution when the pin provides it

Update `sui-move-architecture` and `sui-move-security` with a version gate.

Current upstream adds `sui::package::original_package_id(&UpgradeCap)`, which
resolves the first-version package ID and rejects a cap with an upgrade in
progress or inconsistent version data
([framework addition](https://github.com/MystenLabs/sui/blob/f144de01f1ae50bf7a56b83d1c9618444978c391/crates/sui-framework/packages/sui-framework/sources/package.move#L317-L327)).
When a future Blast pin includes it, prefer this native check when accepting an
`UpgradeCap` after one or more upgrades. The current pin lacks the function, so
do not change existing Blast code or examples to call it now. Initial-publication
intake can continue comparing the cap's current package ID with the marker
type's original ID under the repository's established invariant.

### P2 — expose the package-arena test knob only after a toolchain upgrade

Update `sui-move-testing` with a short version-gated note. Current upstream
adds `sui move test --package-size <MB>` and a 10 MB protocol package-arena
limit at protocol version 136
([official implementation note](https://github.com/MystenLabs/sui/commit/ae59d7718668b468ce65702ecb0440aa2330f389)).
Use it for unusually large packages or regression tests near the package-load
limit. The pinned `1.77.2` CLI does not expose this option, so it must not enter
the current mandatory Blast gate.

## Claims checked with no update required

- **Stable edition:** Module extensions remain gated by `2024.alpha`; they are
  still absent from stable `2024` in current upstream
  ([current feature lists](https://github.com/MystenLabs/sui/blob/60f0e8a6abb0523d5c9c7f5edc006f40d8dead03/external-crates/move/crates/move-compiler/src/editions/mod.rs#L148-L181)). Keep test-only seams in defining modules on the Blast pin.
- **Upgrade compatibility:** Existing public function signatures remain fixed
  except that generic ability constraints may be removed; existing datatype
  layouts and abilities remain fixed; private, package/friend, and `entry`
  signatures may change under the compatible policy; initializers do not rerun
  ([official upgrade requirements](https://docs.sui.io/develop/publish-upgrade-packages/upgrade#upgrade-requirements)). Keep the current suite wording, including enum compatibility, which the bytecode checker enforces
  ([checker](https://github.com/MystenLabs/sui/blob/60f0e8a6abb0523d5c9c7f5edc006f40d8dead03/external-crates/move/crates/move-binary-format/src/compatibility.rs#L120-L218)).
- **Randomness:** Keep private `entry` endpoints, function-local
  `RandomGenerator` construction, post-random PTB restrictions, balanced
  resource paths, and commit-reveal for high-stakes flows
  ([official guidance](https://docs.sui.io/sui-stack/on-chain-primitives/randomness-onchain#best-practices)).
- **Strict lint gate:** Current upstream adds warnings for statically
  always-failing expressions, but the existing warning-as-error lint/build gate
  already catches them
  ([compiler change](https://github.com/MystenLabs/sui/commit/42fa92c3bc74927d10a59f84678bfdf0aebc5365)). No separate design rule is needed.

## Suggested edit order

1. `sui-move-source-style` and `sui-move-security`: `TxContext` and native
   original-package resolution.
2. `sui-move-events-errors`: gRPC event order, progress markers, and archival
   retention.
3. `sui-move-testing`: signature tests, gap-free event ingestion,
   `verify-source`, and the version-gated package-arena option.
4. `sui-move-review` and `sui-move-guide`: route and gate the new checks without
   duplicating the detailed rules.
5. Recompute `skills-lock.json` hashes and run
   `bash .agents/check-required-skills.sh` only after the skill edits are made.
