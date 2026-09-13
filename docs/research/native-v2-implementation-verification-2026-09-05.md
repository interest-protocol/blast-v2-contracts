# Native V2 implementation verification — 2026-09-05

The contracts, design text and SDK adapters are implemented locally. The authoritative
policy is [ADR 0076](../decisions/0076-native-v2-and-auto-lp.md); usage is in the
[DEX README](../../sui/dex/README.md) and
[AutoLP README](../../sui/auto_lp/README.md). Changes remain uncommitted and
unpublished.

## Implemented behavior

- Canonical Meme/Quote full-range pools, paired deposits with refunds, owned
  positions, principal withdrawals and separate Quote fee claims.
- Progressive recent-volume fee integral, zero floor, default 200-bps marginal
  cap, protocol-admin per-pool cap changes through 500 bps, exact rounded fee
  limits, net receipt bounds and millisecond deadlines.
- Optional native Meme supply destruction on swaps; fixed-supply currencies
  cannot opt into burns. No balancing swaps.
- Optional native graduation route using the existing migration fee policy,
  sealed witness and permanently held LP position. Claimed position fees use
  the current core protocol/creator split without resplitting earlier accruals.
- AutoLP seals the CreatorCap and position, collects creator fees, retains
  unmatched/dust assets and deposits supported paired amounts.

## Review correction

The initial public compound function exposed vault funds to a forced-deposit
sandwich. With pool reserves 100,000/100,000 and the same pending vault balances,
buying for 101,000 Quote, forcing the skewed-ratio deposit, then selling back
produces 117,600 Quote. An attacker-selected minimum share amount is ineffective.

Enrollment now commits a nonzero immutable executor chosen by the CreatorCap
owner. Only that executor can select compounding timing and signed maximum
Meme/Quote consumption, minimum shares and deadline bounds;
collection stays public. A regression first executes a real reserve-skewing
buy, then requires the unauthorized compound to fail with its precise module
and error. The executor must choose meaningful limits, and key loss stops future
deposits. It has no extraction right. This tradeoff is recorded in the ADR.

Two independent Claude Fable package reviews and their finding dispositions
are recorded in [the package audit response](native-v2-package-audits-2026-09-05/README.md).
They found and prompted the per-asset consumption limits, migration-target
admission guard, zero-event suppression, diagnostic correction and extra tests.

## Executed local gates

| Gate | Result |
| --- | --- |
| DEX strict build / tests with strict lint | pass / 69 of 69 |
| AutoLP strict build / tests with strict lint | pass / 23 of 23 |
| Launchpad strict build / full tests | pass / 210 of 210 |
| Existing migrator tests with strict lint | 39 of 39 pass |
| Migrator offline ABI self-test | 61 of 61 pass |
| SDK complete check (ABI, format, lint, types, tests) | pass / 214 tests |
| Launchpad and migrator source-boundary scripts | pass |
| Existing Turbos dependency-pin script | pass |
| Reproducible DEX vector generator | all 1,800 fractional decay exponents pass |
| Independent rational fee review | 10,000 full-width random cases match |
| Whitespace diff check | pass |

Tests cover fee/principal conservation in both swap directions, real Currency
supply deltas, old/new LP eligibility and post-withdrawal claims, exact event
payloads and replay, creator-funded pool admission and native preemption,
cap updates without repricing accrued fees, revoked administration, stale
generations, exact deadline boundaries, native terminal fees/burns, shared
custody IDs, retained leftovers, and attacker-compound rejection.

Core adds a read-only migrated-lifecycle assertion. Quote admission rejects
targets below two atomic units; together with the 500-bps migration-fee ceiling,
this guarantees positive Quote principal before launch construction. The
boundary gate admits exactly the extra signature and verifies its body. No
existing migration interface or venue dependency revision changed.

## Evidence limits

No deployed RPC child-object lookup, historical indexer replay, live external
venue harvest/claim, upgrade-custody/relink rehearsal or external security audit
was performed. External collection executes against a funded test-only fixture of the existing
migrator fee ledger; actual upstream harvesting still needs the live release checks. Source custody is conditional on deployment upgrade authority, so no
immutable-deployment claim is made.

The SDK includes calls, transactions, previews, reads and replay for both packages.
Frontend, aggregator routing and an executor service remain outside this change. An executor must submit transactions; the vault cannot schedule
its own execution.
