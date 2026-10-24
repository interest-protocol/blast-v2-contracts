# Blast Boosts Aftermath adapter

`blast_boosts_aftermath` connects the Boosts core policy and accounting to
Aftermath-owned venue state. It owns product currencies, its own operational
generation, sealed package custody, and `Vault<Product, Collateral>` custody
while relying on the core's administration roles.

Membership is shared, custody is not: administrators sign in to the singleton
Blast ACL with a core role, but this package's generation and `UpgradeCap` belong only to
it, and advancing them leaves the core untouched. Its Publisher and `UpgradeCap`
are validated once and sealed inside `blast_admin` custody, from which no call
returns them. An upgrade commits its receipt without changing the active
operational generation. In a follow-up transaction the successor activates its
own compiled generation, which must be exactly next. A wrong version cannot
activate; the previous generation remains usable and live upgrade administrators
can install a repair. Permanently destroying upgrade authority still requires
matching active code. See [ADR 0123](../../../docs/decisions/0123-successor-activated-boosts-upgrades.md)
and the [upgrade procedure](../../../deployments/README.md#boosts-adapter-upgrades).

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

Blast deploys only to Sui mainnet; this package builds, pins and proves only
the `mainnet` environment and has no testnet rehearsal tooling. The read-only
activation proof first serializes the reviewed PTB, then passes that exact
base64 `TransactionData` to Sui's machine-readable `serialized-tx` surface with
`--dev-inspect --json` on mainnet. Both live proof paths enforce the pinned Sui
CLI version. Live activation configurations use schema version 4 and include
`mintDriftProfile`, the full calibrated profile object (see
[`core/scripts/fixtures/nvda-mint-drift.json`](../core/scripts/fixtures/nvda-mint-drift.json)
for the NVDA successor). The tool refuses mismatched band, minimum or cap inputs,
then checks the observed seed NAV, lot and exposure. Starting leverage remains
a separate evidence requirement because `VaultInitialized` omits oracle-valued
notional. The profile's forecast is conditional; the final mint-band guard is
always enforced. Synthetic activation fixtures retain their own schema and do
not stand in for this production calibration.

Public active operations are `initialize`, `mint`, `redeem`,
`needs_rebalance`, `sync_health` and `donate`; Vault also exposes authorized
fee, NAV-cap and order-cap settings, issuer-only coin metadata updates, and
earned-admin cash withdrawal.
`mint_with_partner` and `redeem_with_partner` run the plain operation for a
Blast partner (`blast_partners::Partner`) and then pay it its share of the admin
fee that operation retained, never the reserve fee, in the same transaction
([ADR 0095](../../../docs/decisions/0095-partner-codes.md),
[how it works](../../../docs/partner-codes.md)).
Initialization and mint/redeem return the ClearingHouse after completing their
sessions and checks; mint/redeem return it alongside the native output coin.
The caller can reuse it in later PTB commands and must share it after its
final use (ADR 0087). This return shape requires a fresh adapter publication.
Permissionless `rebalance` and `unwind` are private `entry` functions that share
the market internally and return nothing (ADR 0118). They reject a market
returned by an earlier trading session and end its use in that PTB. Repeated
maintenance, rebalance followed by mint, and unwind followed by finalization
on that market use separate transactions. Rebalance has
no privileged keeper path, caller trade sizing or reward. An unresolved
external change preserves the accepted economic checkpoint and emits
`CheckpointDrifted`.

Activation mints the locked seed shares to the burn address; they are never
redeemable. `vault::begin_shutdown` requires a shutdown-role witness and no venue or oracle
input; the clock it reads fixes when shutdown began. It irreversibly moves Active to Unwinding. Permissionless
`operations::unwind` first reconciles the stored checkpoint with the venue
exactly as `sync_health` does: an explainable funding move is booked and
emitted, anything else emits `CheckpointDrifted`, and the step proceeds from the
live state either way, because shutdown closes what the venue holds whatever
moved it there. It then makes up to 16 bounded close-only immediate-or-cancel
limit orders priced at fresh oracles inside a bound that opens at the ordinary
tolerance and widens to the emergency tolerance over the day after shutdown
began. A market the venue has
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

For a proven size lock, anyone may instead begin protected closure with
`operations::begin_protected_shutdown`. It checks the bound raw checkpoint and
native supply: even burning every circulating share must fail the ordinary
minimum-order guard. It needs no live prices, positive equity or opening
margin. Market-wide settings may change; account facts remain exact.
Already-settled account funding needs `sync_health` first while the venue
permits it; unexplained account drift needs reconciliation. The planner does
not force sync, because venue funding calls can abort on paused markets. The same unwind
and finality protections then apply. At recovery the full recorded reserve
(up to recovered cash) and the locked shares' portion of remaining cash are
segregated in the vault with no holder or admin withdrawal path, including
after the last holder exits. The adapter remains upgradeable; upgrade
governance is a trust assumption.
See [ADR 0130](../../../docs/decisions/0130-protected-permissionless-shutdown.md).

`vault::redeem_shutdown` burns native eligible shares and returns local
`Coin<Collateral>` without venue access or fees. Locked seed is excluded from
the denominator. Claims floor the fraction of remaining cash; the last gets
all holder-pool dust. Protected closure excludes its segregated cash from
that pool; administrator-approved closure keeps its prior allocation.
A wholly zero cash pool permits an explicit zero-minimum burn, but a
partial claim rounded to zero while cash remains aborts. With no eligible
holders at administrator-approved finalization, what the locked seed backed is retained as admin cash, never paid to
the finalizer. Admin cash remains separate. See the
[terminal local record](../../../docs/leverage-terminal-local.md) for events,
observer-to-witness operation and the boundary of local evidence.

Run **`bash scripts/verify.sh local`** for offline gates. The default/all lane
includes external evidence gates and is not interchangeable with local testing.
Local official venue ports contain aborting implementations: compilation and
pure/native-custody tests do not prove venue execution or submitted rollback.
See the [active release-candidate record](../../../docs/leverage-active-release-candidate.md)
for parameters, keeper behavior, T-002 handoff facts and outstanding release evidence.

### Local upgrade regression

`scripts/test_upgrade_runtime.mjs` executes M-3 on a disposable loopback localnet
with the pinned Sui CLI and `@mysten/sui` 2.35.0. Run it under the shared heavy-job
guard. Set `M3_LOCALNET_CONFIG` to a task-owned genesis directory,
`M3_OUTPUT_DIR` to a fresh evidence directory, and `M3_SDK_PATH` to that SDK's
installed package directory. `M3_RPC` defaults to `http://127.0.0.1:52421` and
must use 127.0.0.1. The runner sets its private CLI environment; it never uses the
operator's default client configuration. Stop the task-owned node and remove its
private genesis keys when done.

It copies full first-party source, changes only the copied ACL root recipient
and successor generation constants, and disables the three copied venue-interface
initializers solely for local publication. No venue operation executes. Actual
partner administration exercises the adapter's operational gate; this does not
replace live redemption and dependency verification before deployment. Every
transaction result, version transition, rollback and source hash is recorded in
the output directory. The compile-only publication file uses mainnet's dependency
environment label with localnet package IDs; it is never used to broadcast.

## Margin recovery

Reducing rebalances skip the opening-margin check before and after each fill;
increases and close/reopen profit realization stay strict. Donations allocate
all supplied collateral to the position and may commit partial recovery.
Price, checkpoint, operational, size and progress checks remain in force.

Initialization validates the live market floor and a core-owned conservative
margin budget before creating the account. The activation tool requires a
`venueMargin` preview with raw IFixed decimal strings `marketImr`,
`collateralHaircut`, `takerFee` and `priorityTakerFee` (null if absent). It repeats
the budget offline; Move reads current venue rates, so preview data has no
authority. See [ADR 0124](../../../docs/decisions/0124-margin-recovery-and-initial-headroom.md)
for assumptions and release evidence requirements.
