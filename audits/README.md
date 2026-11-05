# Security audits

No audit covers the current launch stack. The seven packages of
[ADR 0137](../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md),
the templates and the vendors are a fresh lineage that awaits its own audit;
the vault is made immutable only after that audit and a quiet period (#195).

Earlier reports covered launchpad code that no longer exists and were removed
on 2026-11-05; they remain in Git history. Boosts' review record is
[`docs/reviews/boosts-asymptotic-2026-10.md`](../docs/reviews/boosts-asymptotic-2026-10.md).

Add each new report here with its reviewed repository commits, scope, findings
and remediation status, and the SHA-256 of the original file.

## Internal deep review — Blast launch stack, November 2026

[Download the report](blast-launch-stack-internal-review-nov-2026.pdf) (7 pages). An
internal adversarial review by a Claude session (Fable), written in the format of
the Asymptotic report above. It is a source and local-test review, not a formal
proof and not a substitute for the external audit.

### Reviewed source

- Repository: [interest-protocol/blast-v2-contracts](https://github.com/interest-protocol/blast-v2-contracts), branch `main`.
- Reviewed commit: [`4fe8d739f04bafd0775691795eb9f3727e984089`](https://github.com/interest-protocol/blast-v2-contracts/commit/4fe8d739f04bafd0775691795eb9f3727e984089) (#212).

### Scope

`blast_admin`, `blast_core`, `blast_vault`, `blast_fun`, `blast_presale` and
`blast_migrators`, the seams between them, and the fidelity of the Cetus and Bluefin
interface stubs against mainnet bytecode. `blast_partners`, the generated coin
packages, the vesting package, the Sui Framework and the Move Standard Library are
trusted dependencies. No venue bytecode ran in the review; the PTB fork gate remains
the evidence for venue behaviour.

### Findings and remediation

The report records **0 critical, 0 high, 0 medium, 1 low, and 4 informational**
findings and one hypothesis (H-1, whether Bluefin's auto-LP add can ask more than
the venue's local estimate). All five findings are **remediated** in
[#217](https://github.com/interest-protocol/blast-v2-contracts/pull/217) (ADR 0134,
amendment of 5 November 2026): the vault's `unpause` is version-gated (L-1); every
`unpause` requires the core treasury's notice guarded (I-1);
`MigrationAllocationPaid` carries the vesting schedule IDs (I-2); holder-reward
leaves are documented as account addresses (I-3); auto-LP compounding is the
venues' own `compound_auto_lp`, apart from collection (I-4). H-1 can no longer
block collection; exercising the add against venue bytecode is
[#218](https://github.com/interest-protocol/blast-v2-contracts/issues/218).

The report's supporting records (system map, function inventory, checked-clean
record, proof-of-concept tests and logs) are kept in the Blast workspace, not in
this repository.

### File integrity

SHA-256 of the PDF:

```text
19b316954d16a3dc51009de4a0b2336b6c4aadfd1873722c18b7cca3bb3e63ab
```
