# Blast leverage Series1

`blast_boosts_core` is the venue-neutral core shared by Series1
adapters. It owns policy, lifecycle, accounting, observations, and the Series1
administration domain; adapters own currencies, venue accounts, package
capabilities, and outer `Vault<Product>` objects.

The administration lifecycle itself belongs to the immutable `blast_admin`
package. This package contributes only the domain one-time witness, its
governance configuration, and the role meanings every Series1 adapter shares.
Series1 is published immutably, so it holds no operational generation, no
package custody, and no surviving `UpgradeCap`; an adapter that reuses this
domain still owns and advances its own generation.

Read the accepted Series1 ADRs from the
[decision index](../../../docs/decisions/README.md) and the
[leverage implementation rules](../../../docs/leverage-implementation-lessons.md)
before changing this package. Run `scripts/verify.sh` for local gates. Source,
tests, `Move.toml`, and `Move.lock` own current behavior, errors, and dependency
facts.

Series1 provides sealed, transaction-local plans for active mint, proportional
redemption, donation and permissionless rebalance. Adapters authenticate venue
facts and own native cash and share custody. Positive net funding credits the
buffer; costs consume buffer before backing. Ordinary health observation never
retires a product. The single public maintenance band has inclusive healthy
endpoints and strict outside-band eligibility.

This is pre-publication source preparation, not a deployment or live-parity
claim. Series1 remains immutable after publication. The
[active release-candidate record](../../../docs/leverage-active-release-candidate.md)
separates local evidence from outstanding market, ABI and submitted-transaction gates.
