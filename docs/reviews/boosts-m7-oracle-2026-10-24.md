# M-7 oracle rotation regression review — 2026-10-24

Scope: `codex/boosts-m7-oracle-rotation` against main
`1bfb90e7975087db095b22d4f02e99950a1e6114`. The reference is Ticket 7 in the
repository's Asymptotic audit restatement. The original report is unavailable;
this is not acceptance by Asymptotic.

## Decision and audit alignment

Keep ADR 0115: account, registry and clearing-house identities remain fixed;
the authenticated market owns current oracle storage/source selection. A caller
cannot choose another source. A recreated feed origin is not an account change.
Terminal checkpoint capture authenticates those objects without reading a feed.
The outdated `Binding` comment is corrected.

This follows the finding's objective. There is no new override, fallback price,
administrator permission, public API, state layout or economic policy. The two
existing storage assertions are moved into a private macro so tests execute
the same guards as production. Macro expansion preserves base validation before
either collateral getter, including the exact abort module and code.

## Risk-to-evidence map

| Risk | Local evidence |
| --- | --- |
| Valid new storage is refused | Move tests feed matching current ids into the real storage guards, independently and together; existing funding tests cover current storage matching |
| Caller supplies obsolete/wrong storage | Exact-abort tests for both legs and funding; base-before-collateral failure and getter precedence |
| Adapter retains old source/origin | Structural checks require current market storage/source reads, forbid origin pinning, and restrict Binding, VenueAccount and Checkpoint storage and scan every production module |
| Mint bypasses current capture | Structural checks trace synchronization and final capture; existing Move tests exercise mint accounting with captured states |
| Terminal checkpoint requires a feed | Exact checkpoint-capture body plus raw-checkpoint and settlement/finalization routing checks |
| Structural gate silently stops detecting regressions | 25 deliberate source mutations must be rejected; gate runs through the adapter source-boundary check and Move-style CI |

The structural checks inspect source; they do not execute Move or prove all
possible rewrites safe. The decoded-id tests do not change a real market.
No asset accounting, lifecycle, composition, event or upgrade behavior changes.
Those layers retain existing package tests; the live external-input layer has
the release gate below.

## Validation and independent review

- Adapter: **494/494** Move tests, including six new M7 tests. `verify.sh test --threads 1` uses the pinned mainnet build.
- `verify.sh build`, `lint` and `boundaries` pass. The boundary gate includes
  five routing assertions and rejection of all **25** source mutations.
- Builder/initial-margin tests: **26/26**; ABI self-tests: **11/11**; live ABI:
  **5 packages / 75 functions**; activation proof self-tests: **19/19**.
- Move style covers **198** modules; its **10** mutation tests pass. Generated
  references were regenerated and checked; `git diff --check` passes.

The requested fresh Fable review hit its model usage limit before a verdict.
The user selected a fresh `claude-opus-5-5` review instead. Opus found no
critical, high or medium findings and accepted the production guard semantics.
Its four low-severity findings were addressed: scan every production module for
saved oracle object/feed identities and pin `VenueAccount` fields; add four
mutation cases and run the routing suite in CI; remove the contradictory audit
summary; distinguish fixed-settlement finalization from live-market deallocation.
Duplicate funding tests and an always-true assertion were also removed. Opus
independently verified every correction, reported no remaining actionable
finding, and approved opening the source-coverage PR with the live release gates.
Both initial and follow-up model metadata identify `claude-opus-5-5`.

`post-review-gates.log` owns the final 494-test, boundary and style results.
`gates.log` owns the build/lint, builder, ABI, proof and generated-reference
results; their production inputs did not change after that run. All nine files
were staged before the successful `git diff --cached --check`.
Detailed logs and reviewer model metadata belong to workspace
`outputs/verification/2026-10-24-boosts-m7-oracle/`.

## Release limits

Local Aftermath interfaces are aborting ABI ports. Neither these tests nor an
ABI match proves that a full mint or shutdown succeeds after exchange rotation.
Before deployment, a controlled venue must exercise both price legs:

1. Change storage and source ids independently and together; recreate the feed
   under a different origin while keeping storage/source unchanged.
2. Mint successfully with valid new feeds; reject obsolete storages and keep
   price equality, freshness and validity checks effective.
3. Close at venue settlement prices with live feeds removed, then finalize
   recovery using current storage objects. The venue settlement close should
   move the collateral into the account; finalization then withdraws free cash
   without deallocation or live price reads.
4. Separately, flatten on a live market with collateral still allocated, then
   remove a feed. Finalization is expected to abort because deallocation reads
   both live prices. Restore the feed or use the venue's closed-market
   settlement route before retrying. This removal case is outside M7's rotation
   finding and does not weaken its expected acceptance of valid replacement feeds.

These expectations follow the [venue bytecode evidence](../research/aftermath-venue-bytecode-2026-09-20.md#session-path-deallocation-and-account-calls-re-read-2026-09-21),
including the preceding settlement-close analysis. They still need controlled
execution against the pinned venue: ABI compatibility alone does not prove them.

Current storage objects are still required. Priced operations intentionally
abort for unavailable/invalid feeds. The external venue controls its own exit
conditions; a price-free checkpoint does not prove all withdrawal calls are
price-free. Fresh publication and new vaults follow ADR 0115; historical
deployed vaults are not upgraded by this source change. No deployment or
exchange-admin mutation was performed.
