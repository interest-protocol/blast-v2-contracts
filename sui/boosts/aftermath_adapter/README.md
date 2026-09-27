# Blast Boosts Aftermath adapter

`blast_boosts_aftermath` connects the Boosts core policy and accounting to
Aftermath-owned venue state. It owns product currencies, its own operational
generation, sealed package custody, and `Vault<Product, Collateral>` custody
while relying on the core's administration roles.

Membership is shared, custody is not: administrators sign in to the singleton
Blast ACL with a core role, but this package's generation and `UpgradeCap` belong only to
it, and advancing them leaves the core untouched. Its Publisher and `UpgradeCap`
are validated once and sealed inside `blast_admin` custody, from which no call
returns them; a governed upgrade commits its receipt and advances the generation
in one transaction, so a failure at either step rolls the whole upgrade back.

A product is any non-primitive type. The share currency is
`blast_boost::BlastBoost<Product>`, a never-constructed marker registered
through this package, and Coin Registry rejects a second currency for the same
tag; `vault::Vault<Product, Collateral>` is the shared custody object, not the
coin, and names its collateral at the type level like every venue object it is
called with. Issuing requires a live core issuer witness, and the Vault is
activated in the transaction that issues it (ADR 0087). Product tags are
declared in `blast_boosts_products` so the inner type also reads as Blast.

Read [ADR 0064](../../../docs/decisions/0064-aftermath-backed-leverage-coins.md),
the later Boosts ADRs in the
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
`needs_rebalance`, `sync_health` and `donate`; Vault also exposes authorized
fee, NAV-cap and order-cap settings, issuer-only coin metadata updates, and
earned-admin cash withdrawal.
`mint_with_partner` and `redeem_with_partner` run the plain operation for a
Blast partner (`blast_partners::Partner`) and then pay it its share of the admin
fee that operation retained, never the reserve fee, in the same transaction
([ADR 0095](../../../docs/decisions/0095-partner-codes.md),
[how it works](../../../docs/partner-codes.md)).
Mint/redeem return ordinary native coins and finish atomically. Rebalance has
no privileged keeper path, caller trade sizing or reward. An unresolved
external change preserves the accepted economic checkpoint and emits
`CheckpointDrifted`.

Activation mints the locked seed shares to the burn address; they are never
redeemable. `vault::begin_shutdown` requires a shutdown-role witness and no venue or oracle
input. It irreversibly moves Active to Unwinding. Permissionless
`operations::unwind` first reconciles the stored checkpoint with the venue
exactly as `sync_health` does: an explainable funding move is booked and
emitted, anything else emits `CheckpointDrifted`, and the step proceeds from the
live state either way, because shutdown closes what the venue holds whatever
moved it there. It then makes up to 16 bounded close-only market orders using
fresh prices and the immutable emergency tolerance. A market the venue has
paused admits no session, funding update or settlement; once the venue has
closed it and enabled settlement prices, the step reconciles without a venue
call and uses only the pinned direct settlement operation at those prices. That
settlement is also how collateral still allocated to a position the market
orders had already flattened leaves a closed market, which refuses
deallocation. A frozen clearing house aborts every venue call until it is
unfrozen, and `unwind` refuses it.
`operations::finalize_shutdown` requires exact flat/no-order/settled-funding
state, no negative collateral, and complete whole-atom cash recovery. The exact
nonnegative allocated raw remainder below one collateral atom remains in the
final checkpoint and `ShutdownFinalized`; callers cannot choose a tolerance or
write-off, and free collateral must be zero.
It seals Settled once; no terminal path reopens leverage.

`vault::redeem_shutdown` burns native eligible shares and returns local
`Coin<Collateral>` without venue access or fees. Locked seed is excluded from
the denominator. Claims floor the fraction of remaining cash; the last gets
all dust. A wholly zero cash pool permits an explicit zero-minimum burn, but a
partial claim rounded to zero while cash remains aborts. With no eligible
holders, what the locked seed backed is retained as admin cash, never paid to
the finalizer. Admin cash remains separate. See the
[terminal local record](../../../docs/leverage-terminal-local.md) for events,
observer-to-witness operation and the boundary of local evidence.

Run **`bash scripts/verify.sh local`** for offline gates. The default/all lane
includes external evidence gates and is not interchangeable with local testing.
Local official venue ports contain aborting implementations: compilation and
pure/native-custody tests do not prove venue execution or submitted rollback.
See the [active release-candidate record](../../../docs/leverage-active-release-candidate.md)
for parameters, keeper behavior, T-002 handoff facts and outstanding release evidence.
