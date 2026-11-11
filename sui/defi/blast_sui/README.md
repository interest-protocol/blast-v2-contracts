# Blast SUI

This independently deployed package implements the `funSUI` and `blastSUI` vault
accepted in
[ADR 0053](../../../docs/decisions/0053-single-validator-funsui-and-blastsui.md),
staking across the short list of validators set by
[ADR 0141](../../../docs/decisions/0141-blast-sui-validator-list.md).
It depends only on `SuiSystem` and the workspace `blast_admin` package.

Administration is not implemented here. `blast_admin` owns the singleton Blast
ACL, the generic `PackageAdmin` and `PackageVersion` typed by `BLAST_SUI_PACKAGE`,
and the delayed-value primitives; this package declares its domain roles in
`blast_sui_domain`. The vault holds both treasury caps, both metadata capabilities
and the deposit-receipt Display capability as sealed children
([ADR 0136](../../../docs/decisions/0136-blast-sui-custody-before-activation-and-delayed-administration.md)).

Use the task-specific material only when needed:

- [deployment runbook](DEPLOYING.md)
- [upgrade runbook](UPGRADING.md)
- [release evidence requirements](../../../docs/testing.md)

For local verification, run `scripts/verify.sh` with the required target. Move
source and tests are authoritative for modules, events, errors, and vault
behavior.
