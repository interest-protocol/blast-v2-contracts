# Blast leverage Series1

`blast_leverage_series_one` is the venue-neutral core shared by Series1
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

Series1 exposes no public user mint or redemption. Adapter activation may mint
only the fixed seed supply and permanently deliver it to `@0x0`; user-facing
mint and redemption remain a later adapter slice after deployed activation and
health parity evidence passes.
