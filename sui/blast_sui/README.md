# Blast SUI

This independently deployed package implements the single-validator `funSUI`
and `blastSUI` vault accepted in
[ADR 0053](../../docs/decisions/0053-single-validator-funsui-and-blastsui.md).
It depends only on `SuiSystem` and the immutable `blast_admin` package, and owns
its package version and capability custody independently of the launchpad.

Administration is not implemented here. `blast_admin` owns the singleton Blast
ACL and the operational-generation and package-custody primitives; this package
declares its roles in `blast_sui_domain`
([ADR 0097](../../docs/decisions/0097-one-singleton-acl-with-typed-roles.md)).
A role from any other package is a different type and cannot administer this
package. Publication shares no usable package version: `package_admin::wrap`
consumes the owned publication proof, seals the Publisher, UpgradeCap, both
metadata capabilities and the deposit-receipt display capability, and shares the
version with deposits paused. Upgrades and redemption-fee changes wait a 48-hour
notice, and exits never pause
([ADR 0136](../../docs/decisions/0136-blast-sui-custody-before-activation-and-delayed-administration.md)).

Use the task-specific material only when needed:

- [deployment runbook](DEPLOYING.md)
- [upgrade runbook](UPGRADING.md)
- [release evidence requirements](../../docs/testing.md)

For local verification, run `scripts/verify.sh` with the required target. Move
source and tests are authoritative for modules, events, errors, and vault
behavior.
