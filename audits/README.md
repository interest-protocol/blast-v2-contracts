# Security audits

One review covers the current launch stack: the Claude (Fable 5.1) security
report below, at the stack's commit `4fe8d739`, with its findings remediated
in #217. It is an AI-conducted review, not the external audit the vault's
immutability waits for (#195): the seven packages of
[ADR 0137](../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md),
the templates and the vendors are a fresh lineage that still awaits that audit
and a quiet period.

Earlier reports covered launchpad code that no longer exists and were removed
on 2026-11-05; they remain in Git history. Boosts' review record is
[`docs/reviews/boosts-asymptotic-2026-10.md`](../docs/reviews/boosts-asymptotic-2026-10.md).

Add each new report here with its reviewed repository commits, scope, findings
and remediation status, and the SHA-256 of the original file.

## Claude (Fable 5.1) — Blast launch stack, November 2026

[Download the complete report](blast-launch-stack-claude-nov-2026.pdf) (27 pages).
A deep adversarial security review conducted by Claude (Fable 5.1), Anthropic's
model, in an agentic review session for Interest Protocol, written in the format
of the Asymptotic report above. The system map, the function inventory and the
checked-and-holding record are its appendices.

### Reviewed source

- Repository: [interest-protocol/blast-v2-contracts](https://github.com/interest-protocol/blast-v2-contracts), branch `main`.
- Reviewed commit: [`4fe8d739f04bafd0775691795eb9f3727e984089`](https://github.com/interest-protocol/blast-v2-contracts/commit/4fe8d739f04bafd0775691795eb9f3727e984089) (#212).
- Remediation reviewed at [#217](https://github.com/interest-protocol/blast-v2-contracts/pull/217)
  (`claude/deep-audit-fixes`, rebased on `main` at `88951fe9`).

### Scope

`blast_admin`, `blast_core`, `blast_vault`, `blast_fun`, `blast_presale` and
`blast_migrators`, the seams between them, and the fidelity of the Cetus and Bluefin
interface stubs against mainnet bytecode. `blast_partners`, the generated coin
packages, the vesting package, the Sui Framework and the Move Standard Library are
trusted dependencies. The review tests; it does not prove. No venue bytecode ran in
it; the PTB fork gate remains the evidence for venue behaviour.

### Findings and remediation

The report records **0 critical, 0 high, 0 medium, 1 low, and 4 informational**
findings and one hypothesis (H-1, whether Bluefin's auto-LP add can ask more than
the venue's local estimate). All five findings are **remediated** in #217 (ADR 0134,
amendment of 5 November 2026): the vault's `unpause` is version-gated (L-1); every
`unpause` requires the core treasury's notice guarded (I-1);
`MigrationAllocationPaid` carries the vesting schedule IDs (I-2); holder-reward
leaves are documented as account addresses (I-3); auto-LP compounding is the
venues' own `compound_auto_lp`, apart from collection (I-4). H-1 can no longer
block collection, and the launchpad fork gate exercises the add on both venues
after each collection; adversarial pool states are
[#218](https://github.com/interest-protocol/blast-v2-contracts/issues/218).

The proof-of-concept tests and run logs behind the report are held by Blast beside
the report's source, not in this repository.

### File integrity

SHA-256 of the PDF:

```text
f42835edd92decf8501f6d240134a81e96c1d1d93fb365fb54ffcc830a709535
```
