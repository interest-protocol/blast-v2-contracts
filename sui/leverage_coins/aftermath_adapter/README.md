# Blast Series1 Aftermath adapter

`blast_leverage_aftermath` connects Series1 policy and accounting to
Aftermath-owned venue state. It owns product currencies, adapter versioning,
package capabilities, and `Vault<Product>` custody while relying on the shared
Series1 administrator domain.

Read [ADR 0064](../../../docs/decisions/0064-aftermath-backed-leverage-coins.md),
the later Series1 ADRs in the
[decision index](../../../docs/decisions/README.md), and the
[leverage implementation rules](../../../docs/leverage-implementation-lessons.md)
before changing this package. Run `scripts/verify.sh` for local gates and
`scripts/check_mainnet_abi.mjs` when venue compatibility is in scope. Source,
tests, manifests, and lockfiles own current behavior and dependency facts.
