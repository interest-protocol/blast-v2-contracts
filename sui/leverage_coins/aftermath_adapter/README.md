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

Public active operations are `initialize`, `mint`, `redeem`, `rebalance`,
`sync_health`, `donate`, and `release_buffer`; Vault also exposes authorized
fee settings and earned-admin cash withdrawal. Mint/redeem return ordinary
native coins and finish atomically. Rebalance has no privileged keeper path,
caller trade sizing or reward. An unresolved external change preserves the
accepted economic checkpoint and emits a deduplicated diagnostic.

Activation records the exact locked seed amount and explicit funder.
`vault::begin_shutdown` requires a shutdown-role witness and no venue or oracle
input. It irreversibly moves Active to Unwinding. Permissionless
`operations::unwind` makes up to 16 bounded close-only market orders using fresh
prices and the immutable emergency tolerance. A frozen market instead uses only
the pinned direct settlement operation and authenticated settlement prices.
`operations::finalize_shutdown` requires exact flat/no-order/settled-funding
state, no negative or fractional collateral, and complete actual cash recovery.
It seals Settled once; no terminal path reopens leverage.

`vault::redeem_shutdown` burns native eligible shares and returns local
`Coin<Collateral>` without venue access or fees. Locked seed is excluded from
the denominator. Claims floor the fraction of remaining cash; the last gets
all dust. A wholly zero cash pool permits an explicit zero-minimum burn, but a
partial claim rounded to zero while cash remains aborts. With no eligible
holders, all recovered cash goes once to the recorded seed funder, never the
finalizer. Admin cash remains separate. See the
[terminal local record](../../../docs/leverage-terminal-local.md) for events,
observer-to-witness operation and the boundary of local evidence.

Run **`bash scripts/verify.sh local`** for offline gates. The default/all lane
includes external evidence gates and is not interchangeable with local testing.
Local official venue ports contain aborting implementations: compilation and
pure/native-custody tests do not prove venue execution or submitted rollback.
See the [active release-candidate record](../../../docs/leverage-active-release-candidate.md)
for parameters, keeper behavior, T-002 handoff facts and outstanding release evidence.
