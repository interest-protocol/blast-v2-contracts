# Blast SUI

This independently deployed package implements the single-validator `funSUI`
and `blastSUI` vault accepted in
[ADR 0053](../../docs/decisions/0053-single-validator-funsui-and-blastsui.md).
It depends only on `SuiSystem` and owns its authority, package version, and
capability custody independently of the launchpad.

Use the task-specific material only when needed:

- [deployment runbook](DEPLOYING.md)
- [upgrade runbook](UPGRADING.md)
- [release evidence requirements](../../docs/testing.md)

For local verification, run `scripts/verify.sh` with the required target. Move
source and tests are authoritative for modules, events, errors, and vault
behavior.
