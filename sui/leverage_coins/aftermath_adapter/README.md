# Blast Series1 Aftermath adapter

`blast_leverage_aftermath` connects Series1 policy and accounting to
Aftermath-owned venue state. It owns product currencies, adapter versioning,
package capabilities, and `Vault<Product>` custody while relying on the shared
Series1 administrator domain.

`product::new<Tag>()` creates a stateless `Product<Tag>` identity. It grants no
authority: a live Series1 issuer witness is still required to issue the
corresponding `Vault<Product<Tag>>` currency, and Coin Registry rejects a second
currency with the same tag. Different tags let this package issue multiple
independent leverage products.

Read [ADR 0064](../../../docs/decisions/0064-aftermath-backed-leverage-coins.md),
the later Series1 ADRs in the
[decision index](../../../docs/decisions/README.md), and the
[leverage implementation rules](../../../docs/leverage-implementation-lessons.md)
before changing this package. Run `scripts/verify.sh` for local gates and
`scripts/check_mainnet_abi.mjs` when venue compatibility is in scope. Source,
tests, manifests, and lockfiles own current behavior and dependency facts.
The pinned official Move ports are the authority for call signatures; deployed
inspection is evidence about real objects and effects, not a source of APIs.

`scripts/verify.sh local` runs the complete offline source, build, lint, test,
and proof-tool self-test gates. The default `scripts/verify.sh all` additionally
runs the live proof and fails closed when its deployment inputs are absent.
`scripts/verify.sh proof-self-test` runs only synthetic comparator regressions.
`scripts/verify.sh proof` requires public-object configuration through
`BLAST_ACTIVATION_CONFIG` and a separately controlled submitted-transaction
configuration through `BLAST_ATOMICITY_CONFIG`. It never treats offline vectors
or read-only inspection as rollback evidence.

The package has no public share-mint, redemption, rebalance, shutdown, or
donation operation. Mint and redemption are a later slice after deployed
activation and health parity evidence passes.
