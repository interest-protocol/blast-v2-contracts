# 0002: Coin creation, currency authority, and the launch transaction sequence

- Status: proposed
- Date: 2026-08-22

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@ae60d06` | `ae60d065ed27576d25ac1c94145e5ffe3ddcf89e` | MystenLabs/sui |
| `cetus@ddfbdeb` | `ddfbdeba174319998b012de876ab7ec23c3ab0bc` | CetusProtocol/cetus-contracts |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |

Every citation below gives the full repository-relative path at the pinned commit.

## Context

Blast Fun creates one coin per launch. On Sui a coin type is a Move type, so each launch requires a
published package that defines it. The Coin Registry is the current creation primitive
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move`), and
`sui::coin::create_currency` is deprecated in favour of it
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/coin.move:223-224`).

Three facts from the framework determine the whole design.

**A. TreasuryCap creation is first-come for non-OTW coin types.** `coin::new_treasury_cap` is
`public(package)`
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/coin.move:523`), so the only route to
a `TreasuryCap<T>` is through the registry. `new_currency<T: key>` takes **no witness** and asserts only
that the currency does not already exist
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:174-202`, `ECurrencyAlreadyExists`). Any third party can
therefore register an already-published but unregistered key-only type and receive mint authority over
someone else's coin.

**B. The OTW path costs a second transaction; the non-OTW path cannot reach `init`.** `finalize` shares
the `Currency` immediately for the non-OTW case but transfers it to the registry address for the OTW
case, requiring a separate, permissionless `finalize_registration`
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:319-330, 348-389`).
The second half of B — that `init` cannot accept `&mut CoinRegistry`, so `new_currency` is unreachable
from `init` — is **premise P13**, not a cited fact. The pinned sources establish only that
`new_currency` requires `&mut CoinRegistry`
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:174-182`);
the restriction on `init` signatures is a runtime rule this review could not verify against a pinned
toolchain.

**C. `Currency<T>` is a shared object and can never be wrapped.** It is declared with `key` only
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:96`).

Together: **the OTW path is mandatory** for creator-published coin packages, and the bootstrap is a
three-transaction sequence.

## Decision

### Transaction sequence

**tx1 — publish the generated coin package.** Its `init` runs during publish and:

1. calls `coin_registry::new_currency_with_otw<OTW>(otw, decimals, symbol, name, description, icon_url, ctx)`
   (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:209-237`), which verifies one-time-witness uniqueness
   (`ENotOneTimeWitness`) and ASCII-printable symbol (`EInvalidSymbol`);
2. mints the entire supply from the returned `TreasuryCap`;
3. calls `finalize`, which claims the `MetadataCap` and transfers the `Currency` to the registry address;
4. calls `blast_fun::new_launch_ticket`, which packages the minted `Coin<Meme>`, the `TreasuryCap<Meme>`,
   the `MetadataCap<Meme>`, and the creator address into a `LaunchTicket<Meme>`, and transfers it to the
   creator. That an `init` may call into a dependency package and construct an object defined there is
   **premise P6**.

`init` is believed to have no access to shared objects, so a transfer is structurally forced here rather
than chosen for convenience — this is **premise P13** and the reason the step is not the self-transfer
convenience API rejected in `../protocol-scope.md`. If P13 is falsified, the transfer becomes a choice
and must be re-justified rather than inherited.

**tx2 — `coin_registry::finalize_registration<Meme>`.** Permissionless — the framework documents it as
"Can be performed by anyone" (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:348-357`). It promotes the
`Currency<Meme>` to its derived shared address, claimed with `CurrencyKey<Meme>` against the registry UID
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:376-388`). The address is therefore deterministic from the type alone
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/derived_object.move:54-56`), so an
indexer can compute it without watching the transaction.

**tx3 — the launch programmable transaction block.**

| # | Command | Package | Shape |
| --- | --- | --- | --- |
| 1 | `launch::prepare<Meme, Quote>` | `blast_fun` | `(&mut Config, &Currency<Meme>, &Currency<Quote>, LaunchTicket<Meme>, RouteParams, &Clock, &mut TxContext) -> (PreparedLaunch<Meme, Quote>, TreasuryCap<Meme>, RouteRequest<Meme, Quote>, Coin<Meme>, MetadataCap<Meme>)` |
| 2 | `cetus_route::reserve<Meme, Quote>` | `blast_fun_cetus` | `(PreparedLaunch<Meme, Quote>, TreasuryCap<Meme>, RouteRequest<Meme, Quote>, &GlobalConfig, &mut Pools, &mut TxContext) -> (PreparedLaunch<Meme, Quote>, TreasuryCap<Meme>, RouteCommitment<Meme, Quote>)` |
| 3 | `launch::finish<Meme, Quote>` | `blast_fun` | `(&mut Config, PreparedLaunch<Meme, Quote>, TreasuryCap<Meme>, RouteCommitment<Meme, Quote>, Coin<Meme>, MetadataCap<Meme>, &Clock, &mut TxContext) -> Launch<Meme, Quote>` |

Core performs no venue call. The transaction threads core-defined values through one adapter call, so
the dependency direction of [ADR 0001](0001-sui-package-and-module-layout.md) is preserved.

A PTB command result cannot be a Move reference, so `prepare` cannot hand out a `&mut TreasuryCap<Meme>`.
The cap therefore moves **by value** into command 2 and back out. **The meme inventory never enters the
adapter call** — `Coin<Meme>` passes from command 1 to command 3 — so mint authority is the only thing
ever exposed.

### The guard: a non-droppable prepared launch

`PreparedLaunch<Meme, Quote>` has **no abilities** — no `drop`, `store`, `key`, or `copy`. It cannot be
dropped, stored, or transferred, so a transaction that acquires one has exactly one legal ending:
`launch::finish`. It carries the pre-adapter snapshot:

| Field | Purpose |
| --- | --- |
| `treasury_cap_id` | detects cap substitution |
| `total_supply_snapshot` | detects any mint or burn during the window |
| `meme_inventory_expected` | detects inventory diversion |
| `launch_id` | binds the commitment to this launch |
| `route_request_digest` | binds the commitment to the parameters actually requested |
| `route_params` | tick spacing, fee rate, venue, orientation |

`RouteCommitment<Meme, Quote>` is **defined in core**, also has no abilities, and is constructible only
through `route::seal_commitment`, which consumes an adapter **witness type** (`Witness: drop`) whose
`TypeName` must be in the approved-adapter set. This is the typed one-use mechanism adapted from the
historical migrator, which checked `type_name::get<Witness>() == witness` before releasing balances
(`memez@00596fd:fun/sources/memez_fun.move:71-88`). Core therefore accepts only an adapter-specific
sealed result and cannot be handed a commitment forged by an arbitrary package.

`launch::finish` validates before mutating, in this order:

1. `coin::total_supply(&treasury) == prepared.total_supply_snapshot` — **the mint check**. The getter is
   verified callable on a `TreasuryCap<T>`: the framework itself calls `cap.total_supply()` at
   `sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:285`.
2. `object::id(&treasury) == prepared.treasury_cap_id`.
3. `coin::value(&meme_coin) == prepared.meme_inventory_expected`.
4. commitment witness is in the approved-adapter set, and its digest binds
   `(launch_id, Meme, Quote, venue, tick_spacing, fee_rate, orientation, reservation_id)` to
   `prepared.route_request_digest`.
5. commitment is single-use and is recorded against the launch.

Only then does it consume the cap into `Launch`, open the curve, and emit.

### The TreasuryCap trust window, stated honestly

Move cannot attenuate a `&mut TreasuryCap<T>`, and it cannot forbid a package holding a `TreasuryCap` by
value from calling `coin::mint`. **During command 2 the adapter package has, in principle, full mint
authority.** This ADR does not claim a type-level guarantee. The protection is three concrete things:

1. `blast_fun` exposes **no public mint entrypoint at all**, so no external caller reaches mint through
   core ([ADR 0001](0001-sui-package-and-module-layout.md) public-surface inventory);
2. the adapter is a Blast-authored, audited package whose entire public surface is inventoried;
3. the non-droppable `PreparedLaunch` makes the post-condition **mandatory** — any mint, burn, or cap
   substitution causes `finish` to abort and the whole transaction to revert atomically, leaving no
   reservation, no launch, and no minted supply.

Cetus itself does not mint: `mint_pool_creation_cap` binds the cap as `_: &mut TreasuryCap<Coin>` and
ignores it, using it purely as proof of ownership
(`cetus@ddfbdeb:packages/cetus_clmm/sources/factory.move:607-621`).

Bluefin and Turbos expose no reservation primitive at the pinned commits (premise **P4**), so their
`reserve` command is a no-op that returns a commitment describing Route B or C **without ever receiving
the `TreasuryCap`**. The cap window exists only on the Cetus reservation path.

### Metadata authority and coin Display

Coin metadata lives in `Currency<Meme>` and is gated by `MetadataCap`:

- setters are `set_name`, `set_description`, `set_icon_url`
  (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:416-428`);
- **`symbol` has no setter** and is fixed at creation;
- `delete_metadata_cap` is irreversible and blocks re-claiming
  (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:391-397`, and `claim_metadata_cap` asserts `EMetadataCapAlreadyClaimed` at
  `:244-254`).

Decision: the protocol holds the `MetadataCap` during bonding under a creator claim, so a creator can
correct an icon or description while the launch is live; at migration `launch::settle_migration` calls
`delete_metadata_cap`, making the coin's metadata **permanently immutable exactly when the token becomes
a traded asset**.

Explorers resolve the coin through the derived `Currency<Meme>` address. Object-level `Display` for
Blast's own types is decided separately in [ADR 0001](0001-sui-package-and-module-layout.md) (option
D-opt2: non-generic types only).

### What P1 actually changes

**P1 as stated:** a transaction *cannot* pass a type argument naming a package published in the same
transaction.

**If P1 holds (the assumption this ADR is written on).** Nothing outside a coin package can name the new
type in the publishing transaction, so currency creation must happen inside `init`. `init` can only reach
`new_currency_with_otw`, whose `finalize` transfers the `Currency` to the registry address rather than
sharing it. A separate `finalize_registration` is therefore required, and **tx2 exists**. Three
transactions.

**If P1 is falsified.** A caller could name the freshly published type directly, which unlocks the
non-OTW `new_currency` — the constructor that **shares the `Currency` immediately** and needs no
promotion step. Then:

- currency creation moves out of `init` into an explicit command;
- **tx2 disappears entirely**, because there is nothing to promote;
- tx1 and tx3 merge into one transaction that publishes, creates the shared `Currency`, and launches.

Critically, this does **not** make `new_currency` safe in general. Fact A is unchanged: `new_currency`
still takes no witness, so the type remains claimable by whoever calls first. What a P1 reversal buys is
*atomicity* — publish and register in one transaction leaves no window — not a change in the
constructor's authorization model. A creator who publishes without launching in the same transaction is
exposed either way, which is why the launch is atomic under both branches.

Two transactions is the ceiling of the improvement, not one: under P1-holds the count is 3, under
P1-falsified it is 1. Nothing else in this ADR changes — same guard, same commitment, same metadata
policy — so a P1 reversal edits this section and the sequence table, not the design.

## Alternatives considered

**Non-OTW `new_currency<T: key>` called by `blast_fun`.** Rejected on fact A: between publish and
registration any third party can claim the `TreasuryCap` for the creator's type.

**Hold the `MetadataCap` forever.** Rejected: it leaves a permanent mutable-metadata authority over a
traded asset.

**Delete the `MetadataCap` at launch.** Rejected: creators legitimately fix icons and descriptions during
bonding, and deletion is irreversible.

**Reservation in its own transaction.** Retained as the fallback if premises **P10** or **P11** fail. It
costs one extra transaction and needs a persisted single-use reservation record, but preserves every
invariant here.

## Consequences

- Bootstrap is three transactions; the UI must present it as one flow and handle a stalled tx2.
- Between tx1 and tx3 the creator holds a `LaunchTicket<Meme>` containing the whole supply and the caps.
  Its only consumer is `launch::prepare`, and it has no other useful behaviour.
- The launch transaction is atomic: reservation and curve opening either both happen or neither does.
- Adapter authorship is a trust boundary and must be treated as such in review and audit.
- Coin metadata is mutable during bonding and permanently immutable after migration.

## Verification

Adversarial tests required by this ADR:

- adapter mints one atomic unit during the window → `finish` aborts on the supply check;
- adapter burns during the window → aborts (a decrease is equally a violation);
- adapter substitutes a different `TreasuryCap<Meme>` → aborts on the cap-id check;
- adapter diverts meme inventory → aborts on the inventory check;
- commitment sealed with a non-approved witness type → aborts;
- commitment digest naming a different launch id, `Meme`, `Quote`, venue, tick spacing, fee rate, or
  orientation → aborts, one test per field;
- commitment replayed into a second launch → aborts on single-use;
- transaction calls `prepare` and omits `finish` → fails because `PreparedLaunch` has no `drop`;
- transaction attempts to transfer or store `PreparedLaunch` → fails to compile;
- Cetus reservation succeeds but `finish` aborts → whole transaction reverts, no orphaned
  `PoolCreationCap`, no registered permission pair;
- adapter command called twice in one transaction → second call aborts;
- guard precedence: with both a mint and a forged witness present, the supply check fires first;
- tx2 skipped → tx3 aborts because the shared `Currency<Meme>` input does not exist;
- tx3 attempted twice on the same ticket → second attempt has no ticket to consume;
- metadata setters succeed during bonding and abort after `delete_metadata_cap`.

Unresolved premises carried by this ADR:

- **P1** — whether a type argument may name a package published in the same transaction. Test: localnet
  transaction with a publish command followed by a call using the new type.
- **P10** — whether a no-ability struct defined in core can be returned by a core call, passed into a
  call in a **different** package, and returned again within one transaction. Framework precedent exists
  for the same-package case: `Borrow<T>` is a no-ability potato explicitly designed for
  return-in-the-same-transaction (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:91-92, 497-547`). Test:
  two-package compile fixture plus a localnet transaction.
- **P11** — whether `TreasuryCap<Meme>` can be passed by value across a transaction command boundary
  (it has `key, store`). Test: compile fixture plus localnet transaction.
- **P4** — whether Bluefin or Turbos expose a reservation primitive not visible in their interface
  packages.
- **P6** — whether an `init` may call a dependency package to construct and return an object. Carries
  step 4 of tx1. Test: a two-package compile fixture whose `init` calls into the dependency and transfers
  the result. If false, `init` must transfer the raw `Coin<Meme>`, `TreasuryCap<Meme>` and
  `MetadataCap<Meme>` separately and tx3 reassembles them, which weakens the single-consumer property of
  the ticket and needs its own negative tests.
- **P13** — whether a module's `init` can accept a shared object such as `&mut CoinRegistry`. Carries
  fact B's second half, the necessity of the OTW path, and the justification for transferring the ticket
  out of `init`. Test: a compile fixture declaring `fun init(otw: OTW, registry: &mut CoinRegistry, ctx:
  &mut TxContext)` and observing whether it compiles and publishes.
- **P14** — whether a transaction command result can be a Move reference. Carries the by-value
  `TreasuryCap` hand-off and therefore the entire shape of the tx3 table. Test: a compile fixture whose
  public function returns `&mut TreasuryCap<T>`, plus an attempt to consume that result in a following
  command.

Fallback if P10 or P11 fails: reservation moves to its own transaction with a persisted, single-use
reservation record; the dependency direction and every invariant above are unchanged.
