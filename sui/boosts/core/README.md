# Blast leverage Series1

`blast_boosts_core` is the venue-neutral core shared by Series1
adapters. It owns policy, lifecycle, accounting, observations, and the Series1
administration roles; adapters own currencies, venue accounts, package
capabilities, and outer `Vault<Product>` objects.

Administration belongs to the singleton Blast ACL in the immutable `blast_admin`
package. This package declares only the role types every Series1 adapter shares:
`VaultIssuer`, `RiskAdmin`, `ShutdownAdmin`, and `UpgradeAdmin`
([ADR 0097](../../../docs/decisions/0097-one-singleton-acl-with-typed-roles.md)).
Series1 is published immutably, so it holds no operational generation, no
package custody, and no surviving `UpgradeCap`; an adapter that uses these roles
still owns and advances its own generation.

Read the accepted Series1 ADRs from the
[decision index](../../../docs/decisions/README.md) and the
[leverage implementation rules](../../../docs/leverage-implementation-lessons.md)
before changing this package. Run `scripts/verify.sh` for local gates. Source,
tests, `Move.toml`, and `Move.lock` own current behavior, errors, and dependency
facts.

Series1 provides sealed, transaction-local plans for active mint, proportional
redemption, donation and permissionless rebalance. Adapters authenticate venue
facts and own native cash and share custody. Positive net funding credits the
reserve; costs consume reserve before backing. Ordinary health observation never
retires a product. The single public maintenance band has inclusive healthy
endpoints and strict outside-band eligibility.

An explicit permissionless shutdown can retire a position only when every
accessible ordinary burn fails the minimum-order guard. This seals a protected
settlement mode: recovered reserves and the locked seed's cash share are
excluded from holder claims and remain in adapter custody with no exposed
withdrawal path; adapter upgrade governance remains trusted
([ADR 0130](../../../docs/decisions/0130-protected-permissionless-shutdown.md)).

This is pre-publication source preparation, not a deployment or live-parity
claim. Series1 remains immutable after publication. The
[active release-candidate record](../../../docs/leverage-active-release-candidate.md)
separates local evidence from outstanding market, ABI and submitted-transaction gates.
