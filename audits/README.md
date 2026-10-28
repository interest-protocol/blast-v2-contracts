# Security audits

## Asymptotic — Blast Launchpad, October 2026

[Download the complete report](blast-launchpad-asymptotic-oct-2026.pdf) (30 pages).
This is the supplied updated report, preserved without modification.

### Reviewed source

- Repository: [interest-protocol/blast-v2-contracts](https://github.com/interest-protocol/blast-v2-contracts), branch `commit-launchpad`.
- Review start: [`b549bb16e02e4c6e8ff59e1958435a638c784973`](https://github.com/interest-protocol/blast-v2-contracts/commit/b549bb16e02e4c6e8ff59e1958435a638c784973).
- Final reviewed commit, including remediation review: [`01d7659617abcd552cece6d05b9db409ec4ff2c0`](https://github.com/interest-protocol/blast-v2-contracts/commit/01d7659617abcd552cece6d05b9db409ec4ff2c0).

### Scope

The report covers only `blast_fun` in `sui/launchpad`: the launch lifecycle and
bonding curve, fee custody and claims, creator authority, configuration, package
administration, and migration handoff.

Presale, Blast SUI, Boosts, migrators, and the generated-coin template are outside
the review. `blast_admin`, `blast_partners`, and `blast_fun_timelock` are treated
as trusted dependencies. Migration adapters, receiving DEX venues, and off-chain
services are also outside scope. See the report's Scope and Coverage and
Limitations sections for the full boundaries.

### Findings and remediation

The report records **0 critical, 0 high, 0 medium, 5 low, and 5 informational**
findings. L-1, L-2, L-5, and I-1 through I-5 are **remediated**. L-3 and L-4,
concerning upgrade and root administrator custody, are **acknowledged**.
These statuses are the auditor's assessment at the final reviewed commit.

Audit coverage is tied to those revisions. For a later release, compare its
source and [deployment records](../deployments/README.md) with the reviewed
commit; the report does not establish that a current deployment matches it.

### File integrity

SHA-256 of the original PDF:

```text
09d627f8c5e58374ed28f1e1237a8472e3749b19c259fc3da82635e731e7801b
```
