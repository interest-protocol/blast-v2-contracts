# Blast Series1 Aftermath adapter

`blast_leverage_aftermath` connects Series1 policy and accounting to
Aftermath-owned venue state. It owns product currencies, its own operational
generation, sealed package custody, and `Vault<Product>` custody while relying on
the shared Series1 administration domain.

Membership is shared, custody is not: administrators authenticate against the
Series1 authority, but this package's generation and `UpgradeCap` belong only to
it, and advancing them leaves Series1 untouched. Its Publisher and `UpgradeCap`
are validated once and sealed inside `blast_admin` custody, from which no call
returns them; a governed upgrade commits its receipt and advances the generation
in one transaction, so a failure at either step rolls the whole upgrade back.

`product::new<Tag>()` creates a stateless `Product<Tag>` identity. It grants no
authority: a live Series1 issuer witness is still required to issue the
corresponding `Vault<Product<Tag>>` currency, and Coin Registry rejects a second
currency with the same tag. Different tags let this package issue multiple
independent leverage products.

The selected risk-module type is an external authorization boundary. The
adapter requires a runtime witness and rejects adapter-origin types, but Move
cannot infer whether a foreign constructor is capability-gated or whether its
package is immutable. Do not issue or activate a production Vault until the
exact risk package source, protected constructor path, immutable publication
digest, and selected market/oracle object IDs are recorded and reviewed.

Read [ADR 0064](../../../docs/decisions/0064-aftermath-backed-leverage-coins.md),
the later Series1 ADRs in the
[decision index](../../../docs/decisions/README.md), and the
[leverage implementation rules](../../../docs/leverage-implementation-lessons.md)
before changing this package. `scripts/verify.sh` is the executable authority
for local and live release gates. The pinned official Move ports own callable
signatures; live inspection supplies object, effect, and compatibility
evidence, not new APIs.

The read-only activation proof first serializes the reviewed PTB, then passes
that exact base64 `TransactionData` to Sui's machine-readable `serialized-tx`
surface with `--dev-inspect --json`. Controlled health outcomes come from a
committed oracle, not caller-supplied expectations, and the atomicity gate
checks the complete expected object/effect/ownership graph for success and
rollback. All three live proof paths enforce the pinned Sui CLI version.

The package has no public share-mint, redemption, rebalance, shutdown, or
donation operation. Mint and redemption are a later slice after deployed
activation and health parity evidence passes.
