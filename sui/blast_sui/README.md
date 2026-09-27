# Blast SUI

This independently deployed package implements the single-validator `funSUI`
and `blastSUI` vault accepted in
[ADR 0053](../../docs/decisions/0053-single-validator-funsui-and-blastsui.md).
It depends only on `SuiSystem` and the immutable `blast_admin` package, and owns
its package version and capability custody independently of the launchpad.

Administration is not implemented here. `blast_admin` owns the singleton Blast
ACL and the operational-generation and package-custody primitives; this package
declares its two roles, `blast_sui_domain::UpgradeAdmin` and `FeeAdmin`
([ADR 0097](../../docs/decisions/0097-one-singleton-acl-with-typed-roles.md)).
A role from any other package is a different type and cannot administer this
package. `PackageAdmin` embeds
the shared custody value while keeping the two metadata capabilities and the
deposit-receipt display capability as sealed children, and it still refuses to
be shared until all three are attached.

Use the task-specific material only when needed:

- [deployment runbook](DEPLOYING.md)
- [upgrade runbook](UPGRADING.md)
- [release evidence requirements](../../docs/testing.md)

For local verification, run `scripts/verify.sh` with the required target. Move
source and tests are authoritative for modules, events, errors, and vault
behavior.
