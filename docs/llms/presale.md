## Presale

### What it is

`blast_presale` runs standalone presales on Sui mainnet. A creator brings a new coin
with zero supply. The sale mints the whole supply once, splits it between buyers, the launch
pool, Blast, and named recipients, and gives up mint authority forever. Buyers commit a Quote coin
(for example SUI) during a commitment window. By default commitments may exceed the raise target:
everyone is then filled at one common rate and the excess is refunded. A creator may instead
hard-cap the sale, from the start or from a later point in the window, so it takes Quote first
come, first served only up to the raise; such a sale may also close as soon as its raise is full.

The creator picks the sale's venue at creation: the venue's `prepare` call records the pool terms
and returns a sealed `blast_core::migration::VenueTicket` that `blast_presale::blast_presale::new`
redeems, so the sale can migrate only to that venue. The venues live in their own packages: the
Cetus and Bluefin venues of `blast_migrators`, which serve the launchpad too, and one-off vendor
venues. The presale imports none of them. Anyone can migrate a funded sale:
`blast_presale::blast_presale::migrate` pays Blast's raise and token fees to the core treasury (or,
on a sale that names a partner, holds them for a later pay call), the raise recipients, and the
token recipients, then returns the pool's balances and the vault's terms in a sealed
`blast_core::migration::Migration`. The same PTB passes it to the venue's `migrate`, which creates
the pool and locks the position in a new shared `blast_vault::vault::Vault` with no removal path.
Buyers then claim their tokens and overflow refund. A sale that misses its raise, or that someone
cancels once its liquidity deadline passes unmigrated, refunds every commitment in full.

The vault (fee split, owner claims, partner payouts, holder-reward rounds) is described in the
vault guide, and the hand-off, owner proof, fee split, payouts, protocol-fee ledger, treasury, and
Merkle primitives in the core guide; both ship in this file. This guide covers what the presale
does and what each call needs.

The presale is separate from the bonding-curve launchpad and reuses the shared Blast ACL, the
partner registry and its partner lists, the core money primitives, and Blast admin's generic
package administration. Publication creates an owned
`blast_admin::package_version::Publication<BLAST_PRESALE_PACKAGE>`; it shares no version.
`blast_admin::package_admin::wrap` consumes it and the fresh matching UpgradeCap, sealing
compatible custody in a shared `blast_admin::package_admin::PackageAdmin<BLAST_PRESALE_PACKAGE>`
and sharing `blast_admin::package_version::PackageVersion<BLAST_PRESALE_PACKAGE>` fully paused;
the presale's own policies start with zero notice. Ordinary ACL-authorized operations then
configure them before release.

See ADR 0137. In this guide `SaleToken` is the sale coin; venues call it `Meme`.
`BLAST_PRESALE_PACKAGE` is `blast_presale::blast_presale_package::BLAST_PRESALE_PACKAGE`, the
package's one-time witness and the type argument of its version, administration and package roles.

Routine state-changing public calls below take `&PackageVersion<BLAST_PRESALE_PACKAGE>` immediately
after their first object argument, including initializer setters, policy administration,
migration, payouts, and `blast_presale::blast_presale::prove_owner`. It is a read-only shared input
except during pause, unpause and upgrade commit-and-advance. A stale or future version aborts in
`blast_admin::package_version` before effects. Pure value constructors, the initializer's
`blast_presale::blast_presale::venue` getter and `blast_presale::blast_presale::destroy_cap` do not
take it. Venue and vault calls take their own packages' versions, because each package checks only
its own version.

### Objects and authority

Shared singletons, created once at deployment (`PackageAdmin` and `PackageVersion` by
`blast_admin::package_admin::wrap`, the others when the package is published):

- `fee_policy::FeePolicy`: Blast's current rates (`raise_bps`, `token_bps`, `lp_fee_meme_bps`,
  `lp_fee_quote_bps`, held in a `fee_policy::ProtocolFees`) that new sales snapshot.
- `creation_policy::CreationPolicy`: the allowlists checked once, when a sale is created: Quote
  types, venue witnesses, and Blast partners a sale may name (a
  `blast_partners::partner_list::PartnerList`).
- `blast_presale::blast_presale::PresaleRegistry`: every presale's object ID derives from it.
- `blast_admin::package_admin::PackageAdmin<BLAST_PRESALE_PACKAGE>`: holds the package's Publisher
  and compatible upgrade cap.
- `blast_admin::package_version::PackageVersion<BLAST_PRESALE_PACKAGE>`: the active version and
  pause bits.

Calls also take objects from other packages:

- Core: `blast_core::blast_treasury::Treasury`, the one address every Blast fee is paid to
  (migration and partner payouts).
- Sui: the sale coin's Coin Registry `Currency<SaleToken>` (mutable at `finalize`) and `Clock` at
  `0x6`.
- Venues and vault: the venue's own objects, the vault's `VaultRegistry` and version (venue and
  vault guides).

Per-sale objects:

- `blast_presale::blast_presale::Presale<SaleToken, Quote>`: shared. It holds every commitment, the whole minted
  supply, the sale's terms until migration or refund, and a `blast_core::protocol_fees::Ledger`
  holding Blast's fees from migration until paid. It has `key` only, so it cannot be transferred:
  it must be shared in the transaction that creates it.
- `blast_presale::blast_presale::PresaleCap`: owned by the creator (key, store). It proves sale
  ownership to the sale's vault through `blast_presale::blast_presale::prove_owner` and can be
  destroyed after a cancellation. It cannot change any sale term or move any commitment.
- `blast_vault::vault::Vault<Meme, Quote>`: shared, created by the venue's migration (vault guide).
- A vesting schedule (`Vesting<T>` from the external, immutable `blast_fun_vesting` package):
  shared, one per vested payout, created through `blast_core::payout::pay_or_vest`. See "Claiming
  vested tokens".

Venue witnesses: each venue defines a sealed witness only its own module constructs. It issues the
venue's tickets, redeems its sales' migrations, and keys its position inside the vault. Blast
admits each witness type in `CreationPolicy` (so sales may start on it) and, for a venue that
creates vaults, in the vault's `VaultRegistry`.

Capabilities and who holds them:

| Object | Held by | Authorizes |
| --- | --- | --- |
| `blast_admin::package_version::Publication` | Deployer, until wrap consumes it permanently | Holds publication provenance until native custody is sealed; no policy authority. |
| `blast_acl::AdminCap` granted a role | Blast operations | The calls of each role it holds; see the table below. |
| `blast_presale::blast_presale::PresaleCap` | Sale creator (or a vendor treasury) | `blast_presale::blast_presale::prove_owner`, `blast_presale::blast_presale::destroy_cap`. |
| `blast_partners::blast_partners::Partner` | Shared, managed in `blast_partners` | Read by the presale ledger and the vault to pay a partner its cut of Blast's fees. |

Blast administers presales through the one shared Blast access-control list
(`blast_admin::blast_acl`). Product roles are `blast_core::blast_domain`'s, shared with the
launchpad, the vault and the venues; package roles are `blast_admin::package_admin`'s, typed by
`BLAST_PRESALE_PACKAGE`. An operator's `blast_acl::AdminCap` granted a role calls
`blast_acl::sign_in<Role>` with the shared `blast_acl::ACL` in the same PTB and passes the returned
`blast_acl::AdminWitness<Role>` by reference. Each admin call names exactly one role in its
signature:

| Role | Calls |
| --- | --- |
| `blast_admin::package_admin::PauseAdmin<BLAST_PRESALE_PACKAGE>` | `blast_admin::package_admin::pause` |
| `blast_admin::package_admin::UnpauseAdmin<BLAST_PRESALE_PACKAGE>` | `creation_policy::unpause` |
| `blast_admin::package_admin::UpgradeAdmin<BLAST_PRESALE_PACKAGE>` | `blast_admin::package_admin::schedule_upgrade`, `blast_admin::package_admin::schedule_make_immutable`, `blast_admin::package_admin::authorize_upgrade`, `blast_admin::package_admin::commit_upgrade_and_advance`, `blast_admin::package_admin::make_immutable`, `blast_admin::package_admin::schedule_upgrade_delay` |
| `blast_admin::package_admin::CancelAdmin<BLAST_PRESALE_PACKAGE>` | `blast_admin::package_admin::cancel_upgrade_action` |
| `blast_core::blast_domain::CancelAdmin` | `fee_policy::cancel_fees`, `creation_policy::cancel_venue`, `creation_policy::cancel_venue_delay` |
| `blast_core::blast_domain::FeeAdmin` | `fee_policy::schedule_fees`, `blast_presale::blast_presale::set_protocol_fees`, `creation_policy::add_partner`, `creation_policy::remove_partner` |
| `blast_core::blast_domain::ListingAdmin` | `creation_policy::set_quote_allowed` |
| `blast_core::blast_domain::VenueAdmin` | `creation_policy::schedule_venue`, `creation_policy::remove_venue`, `creation_policy::schedule_venue_delay` |
| `blast_core::blast_domain::TreasuryAdmin` | The treasury's destination (core guide); the presale has no payee of its own. |

The product roles are shared, so the same administrator governs the launchpad's and the presale's
fees, listings and venues; each product still keeps its own lists. PauseAdmin may freeze creation,
commitments or migration. No admin may cancel a sale, move commitments, change windows,
recipients, or a vault's fee split. Presale admins' power over a live sale is limited to its Blast
rates before the window starts; the core treasury's destination decides where Blast's fees go.
After migration, Blast's per-vault LP-fee share is the vault's own delayed setting (vault guide).

### Lifecycle

`blast_presale::blast_presale::Lifecycle` is one-way:

```
Pending --share--> Open --settle (total >= raise)--> Funded --migrate--> Migrated
                     \--settle (total < raise)--> Cancelled
                                 Funded --cancel_unlaunched (at LP deadline)--> Cancelled
```

| State | Exists | Allows |
| --- | --- | --- |
| `Pending` | Only inside the creation PTB, between `finalize` and `share` | `blast_presale::blast_presale::set_protocol_fees` (admin, when the creation PTB also signs in as `FeeAdmin`), `blast_presale::blast_presale::share` |
| `Open` | From `share` until `settle` | Before `start_ms`: `blast_presale::blast_presale::set_protocol_fees` (admin), which may only keep or lower each rate. From `start_ms` until `end_ms`: commits. From `end_ms`, or earlier once the raise is full under a hard cap that closes the sale when filled: `blast_presale::blast_presale::settle` |
| `Funded` | After a settle that met the raise | Migration at any time; `blast_presale::blast_presale::cancel_unlaunched` from the LP deadline |
| `Migrated` | After migration | `blast_presale::blast_presale::claim` (tokens + overflow refund), `blast_presale::blast_presale::pay_protocol_fees_with_partner` on a partnered sale |
| `Cancelled` | After an underfunded settle or `cancel_unlaunched` | `blast_presale::blast_presale::claim` (full refund), `blast_presale::blast_presale::destroy_cap` |

`blast_presale::blast_presale::prove_owner` works in every state, but only a migrated sale has a
vault to present the proof to. Migration and cancellation race once the LP deadline passes:
whichever transaction lands first wins. Nobody can withdraw a commitment while the sale is `Open`
or `Funded`. The vault never closes and its position is never removed.

### Flows

#### Publication and initial configuration

1. Publish the package. The deployer receives the unique
   `blast_admin::package_version::Publication<BLAST_PRESALE_PACKAGE>`, holding its canonical
   Publisher, initial version and pause bits. `FeePolicy`, `CreationPolicy` and
   `PresaleRegistry` are shared; no PackageVersion exists yet.
2. Call `blast_admin::package_admin::wrap<BLAST_PRESALE_PACKAGE>` with the Publication by value and
   the matching never-upgraded UpgradeCap. It consumes the Publication permanently, seals native
   custody in the shared `PackageAdmin` with the 48-hour upgrade notice, and shares the
   `PackageVersion` with every bit paused (create 1, commit 2, migrate 4).
3. Grant the required roles on the real Blast ACL. Configure fees and reviewed venue admission
   through the ordinary schedule/apply operations with Clock. At zero delay these can run in one
   PTB. Quote admission and partners use their ordinary setters. No publication proof authorizes
   policy changes. Each venue that creates vaults, and the presale's own
   `blast_presale::blast_presale_package::PackageWitness` as the package witness that seals its vault terms, must
   also be listed in the vault's `VaultRegistry` (`blast_vault_package::schedule_witness`), or its
   migrations abort.
4. Apply or cancel every outstanding zero-delay proposal. Use each operation's own role to
   schedule and apply its intended value and next notice. The PackageAdmin already holds its 48-hour
   notice from wrap. Read back every operation's notice and configured value before release.
5. Sign in as `UnpauseAdmin<BLAST_PRESALE_PACKAGE>` and clear the intended bits (all = 7) with
   `creation_policy::unpause(creation_policy, package_version, unpause_admin, package_admin,
   fee_policy, treasury, bits)`. Unpause is immediate once every notice is guarded: the fee rates,
   the venue set, and the core treasury destination each need a nonzero applied notice, no
   pending proposal that would set it to zero, and no pending venue admission; otherwise it
   aborts with
   `blast_presale::errors::EUnguardedDelay` (0). The generic administration then requires the
   upgrade notice to be guarded too (`blast_admin::errors::EUnguardedUpgradeDelay`).

Setup may span transactions. Pausing and upgrades never reset the administrative
policy or recreate Publication. An outstanding zero-delay proposal remains ready
after enabling positive notices, which is why setup must settle those proposals
before release. Venue admission remains checked when creating sales.

PTB conventions used below: `Clock` is the shared object `0x6`. Values such as `Bps`,
`Recipient`, `RecipientShare`, `EligibilityPolicy`, and `FeeSplit` are structs, so build them with
Move calls and pass the results; plain numbers, booleans, addresses, and `vector<u8>` go in as pure
inputs. Build a `vector<RecipientShare>` or `vector<Route>` with the PTB `MakeMoveVec` command (a
recipient list may be empty).

#### Creating a sale

A sale is created in one PTB in four stages, the same shape as the launchpad's: the venue's
`prepare` records the coin's pool terms and returns a `VenueTicket<Meme, Quote>`;
`blast_presale::blast_presale::new` redeems the ticket and returns a
`blast_presale::blast_presale::PresaleInitializer<Meme, Quote>`; setters on the initializer record
the creator's terms; `blast_presale::blast_presale::finalize` checks them all together, mints the
supply, and returns the pending `Presale`, which `share` publishes. Neither the ticket nor the
initializer has abilities: `new` is the only way to consume the ticket and `finalize` the only way
to consume the initializer, so the PTB must do both.

The venue is fixed for good at creation. Who may call: *anyone* who owns a zero-supply
`TreasuryCap<SaleToken>` and the matching shared Coin Registry `Currency<SaleToken>`, for a Quote
type and venue the `CreationPolicy` allows. The sale currency must have confirmed `Unregulated`
status; regulated coins and legacy currencies with `Unknown` status are rejected, including legacy
coins whose deny cap has not been registered. Create the sale coin through Coin Registry without
enabling regulation. Every setter and `finalize` take the initializer value from that PTB, so only
its creator can call them.

Value constructors (*anyone*, pure):

- `blast_core::bps::new(value)` builds each rate; it aborts with
  `blast_core::errors::EInvalidBps` above 10,000.
- `blast_core::payout::vesting_terms(cliff_delay_ms, period_duration_ms, periods)` returns a
  `blast_core::payout::VestingTerms` (`blast_core::errors::EInvalidVestingTerms` unless the period
  and count are positive, the cliff is within the schedule, and the whole fits in 2^63 ms).
- `blast_core::payout::recipient(destination, vesting_terms)` returns a
  `blast_core::payout::Recipient`: paid outright with `none`, vested under `some(terms)` from the
  migration. It rejects `0x0` (`blast_core::errors::EInvalidRecipient`).
- `blast_presale::blast_presale::recipient_share(recipient, bps)` builds one share. Gather them
  with `MakeMoveVec` into two lists: token recipients and raise recipients.
- `blast_presale::blast_presale::open_eligibility(wallet_cap, max_participants, min_commitment)` or
  `blast_presale::blast_presale::allowlisted_eligibility(root, leaf_count)` build the eligibility policy.
- `blast_presale::blast_presale::uncapped_for_eligible(start_delay_ms)` or
  `blast_presale::blast_presale::uncapped_for_anyone(start_delay_ms, max_participants, min_commitment)` build an
  uncapped phase.
- The vault's starting LP-fee split is a `blast_core::fee_split::FeeSplit`: build each destination
  with `blast_core::fee_split::address_destination`, `blast_core::fee_split::owner_destination`,
  `blast_core::fee_split::auto_lp_destination`, `blast_core::fee_split::holder_rewards_destination`,
  or `blast_core::fee_split::burn_destination`, each route with `blast_core::fee_split::route`,
  gather the routes with `MakeMoveVec`, and call `blast_core::fee_split::new` (core guide).

Steps, type arguments `<Meme, Quote>` throughout:

1. Prepare the coin on the venue (*cap holder*: the `TreasuryCap<Meme>` holder): the venue's
   `prepare`, for example `blast_migrators::cetus::prepare` or `blast_migrators::bluefin::prepare`,
   with the `TreasuryCap` by reference, records the pool terms (tick spacing, fee rate, and for
   Cetus the coin's pool-creation capability) under the venue's own key and returns a
   `blast_core::migration::VenueTicket<Meme, Quote>` sealed by the venue's witness. The pool terms
   belong to the venue, not the sale: the `Presale` and `PresaleCreated` carry none. The migrators
   guide lists each venue's arguments, bounds and events.
2. `blast_presale::blast_presale::new(treasury_cap, package_version, venue_ticket,
   creation_policy, fee_policy)` takes the `TreasuryCap` by value and the ticket from step 1. In
   order it checks the package version and the create pause bit, redeems the ticket, checks that
   the `CreationPolicy` allows Quote and then the ticket's venue, that the sale coin differs from
   Quote, and that the treasury cap has minted nothing; snapshots Blast's current rates from the
   `FeePolicy`; and returns the `PresaleInitializer`.
3. Required setters, each taking the initializer by mutable reference and the `PackageVersion`:
   - `blast_presale::blast_presale::set_supply(initializer, package_version, token_supply, burnable)`.
   - `blast_presale::blast_presale::set_token_allocations(initializer, package_version,
     token_allocation_bps, liquidity_token_allocation_bps, recipient_allocations)`.
   - `blast_presale::blast_presale::set_raise(initializer, package_version, raise_target, raise_allocations)`.
   - `blast_presale::blast_presale::set_windows(initializer, package_version,
     commitment_duration_ms, liquidity_window_duration_ms)`.
   - `blast_presale::blast_presale::set_eligibility(initializer, package_version, eligibility)`.
   - `blast_presale::blast_presale::set_fee_split(initializer, package_version, fee_split)`: the
     vault's starting LP-fee split.
4. Optional setters:
   - `blast_presale::blast_presale::set_participant_vesting(initializer, package_version, vesting_terms)`:
     each buyer's tokens vest from that buyer's claim. Without it, claims pay tokens out at once.
   - `blast_presale::blast_presale::set_uncapped_phase(initializer, package_version, phase)`: lifts
     wallet caps from the phase's start. Without it, caps hold for the whole window.
   - `blast_presale::blast_presale::set_hard_cap(initializer, package_version, start_delay_ms,
     closes_when_filled)`: holds the sale to its raise from that point (below). Without it, the
     sale overflows for its whole window.
   - `blast_presale::blast_presale::set_partner(initializer, package_version, creation_policy,
     partner, clock)`: names a `blast_partners::blast_partners::Partner` the `CreationPolicy`
     currently accepts. This is the only time a partner can be named.

   A setter called twice keeps its last value.
5. `blast_presale::blast_presale::finalize(initializer, package_version, registry, currency)`,
   with the shared `blast_presale::blast_presale::PresaleRegistry` mutable, first requires
   confirmed `Unregulated` currency status, then checks every setting together, mints the supply,
   consumes the `TreasuryCap`, and returns `(Presale<Meme, Quote>, PresaleCap)`. The Coin Registry
   supply becomes `Fixed`, or `BurnOnly` when `burnable` is true. Emits
   `blast_presale::blast_presale::PresaleCreated`.
6. Optional, Blast admin only (`FeeAdmin`): `blast_presale::blast_presale::set_protocol_fees` on the pending sale.
7. `blast_presale::blast_presale::share(presale, package_version, commitment_starts_at_ms, clock)`,
   same caller, fixes the windows and shares the sale. The start is
   `max(commitment_starts_at_ms, now)`, so a sale can be published ahead of its start. Emits
   `blast_presale::events::PresaleOpened`.
8. `TransferObjects([presale_cap], creator)`.

Settings:

| Setting | Meaning and rule |
| --- | --- |
| `token_supply` | Whole supply in atomic units, > 0. |
| `burnable` | `true`: supply becomes burn-only; `false`: fixed. |
| `token_allocation_bps` | Buyers' share of the supply, > 0. |
| `liquidity_token_allocation_bps` | Tokens seeded into the pool, > 0. |
| `recipient_allocations` | Up to 64 token recipients with distinct destinations, each > 0 BPS, each paid or vested as its `Recipient` says. Buyers + LP + Blast's token rate + recipients = exactly 10,000 BPS. |
| `participant_vesting` | Optional `blast_core::payout::VestingTerms` for every buyer's tokens. |
| `raise_target` | Quote the sale must raise, atomic units, > 0. |
| `raise_allocations` | Up to 64 raise recipients paid in Quote at migration, optionally vested. Their BPS plus Blast's raise rate must stay below 10,000; the LP keeps the rest. |
| `duration_ms` | Commitment window length, > 0; set with `commitment_duration_ms`. |
| `liquidity_window_ms` | Time after the window before anyone may cancel an unmigrated funded sale; at least 7 days. |
| `eligibility` | `EligibilityPolicy::Open` or `EligibilityPolicy::Allowlisted` (below). |
| uncapped phase | Optional `blast_presale::blast_presale::UncappedPhase` (below). |
| hard cap | Optional `starts_after_ms` and `closes_when_filled` (below). |
| `fee_split` | `blast_core::fee_split::FeeSplit`: up to 20 routes with distinct destinations (addresses, the vault's owner, auto-LP, holder rewards, burn), each positive, totalling exactly 10,000 BPS. The creator takes LP fees through the owner route, claimed with an owner proof, or by listing its own address. |
| pool terms | Given to the venue's `prepare` and kept by the venue (migrators guide). |

A setting never set is zero (supply, raise, window lengths, token BPS), so `finalize` rejects it
with that setting's error. A missing eligibility policy or LP-fee split aborts with
`blast_presale::errors::EMissingSetting`.

Eligibility policies (`blast_presale::blast_presale::EligibilityPolicy`):

- `Open { wallet_cap, max_participants, min_commitment }`: every wallet has the same cap; at most
  `max_participants` distinct wallets (1..=65,536); each wallet's total must reach
  `min_commitment` (0 < min <= cap). `min_commitment × max_participants` must reach the raise
  (`blast_presale::errors::EUnreachableRaise`), so dust wallets cannot fill every slot and block the sale.
- `Allowlisted { root, leaf_count }`: a 32-byte Merkle root over leaves `(index, wallet,
  wallet_cap)`, 1..=65,536 leaves. Caps may be equal, tiered, or custom. Any positive commitment
  counts; there is no minimum.

Uncapped phase (`blast_presale::blast_presale::UncappedPhase`): it starts `starts_after_ms` into the window
(must be below `duration_ms`; zero means from the start) and lifts wallet caps until the end.
Whether the sale then overflows or stops at its raise is the hard cap's job.

- `uncapped_for_eligible`: only wallets the policy admits, with the policy's participant bound
  and, for an open policy, its minimum.
- `uncapped_for_anyone`: any wallet through `blast_presale::blast_presale::commit_uncapped`. `max_participants`
  must be at least the policy's bound (its `max_participants`, or the allowlist's `leaf_count`)
  and at most 65,536. `min_commitment` times the slots held to it must reach the raise: all slots
  under an open policy, only the slots beyond `leaf_count` under an allowlist.

Hard cap (`blast_presale::blast_presale::HardCap`): from `starts_after_ms` into the window (must be below
`duration_ms`, `blast_presale::errors::EInvalidHardCap`), a commitment takes only what is left of the raise and returns
the excess at once; when the raise is full, commitments abort with `blast_presale::errors::EPresaleFilled`. Before that
point the sale overflows. It does not lift wallet caps. Common shapes:

| Shape | Settings |
| --- | --- |
| Overflow for the whole window, pro-rata fill | No hard cap |
| First come, first served within wallet caps | Hard cap at `0` |
| First come, first served without caps | Uncapped phase and hard cap both at `0` |
| Capped overflow round, then a first-come uncapped round | Uncapped phase and hard cap at the same offset |

With `closes_when_filled`, anyone may settle the sale as soon as its raise is full under the hard
cap, without waiting for the window's end (see Settling). Without it, a full sale runs to its
end, so the pool can open at an announced time.

`finalize` aborts unless the LP's tokens and Quote give a seed price both CLMM venues can pool
(`blast_presale::errors::EUnseedablePrice`, checked with `blast_core::migration::is_seedable_price`;
see Economics).

#### Committing

Who may call: *anyone* the policy admits. The commitment is always credited to the transaction
sender, so a relayer cannot commit for someone else. Each commit returns a `Coin<Quote>`: the part
a hard cap could not accept, or a zero coin. It has no `drop`, so the PTB must transfer it (or
destroy a zero coin).

1. `coin = SplitCoins(source, [amount])`, where `source` is a `Coin<Quote>` the sender owns (the
   gas coin when Quote is SUI and the sender pays gas; under sponsored gas the gas coin is the
   sponsor's).
2. One of, with type arguments `<SaleToken, Quote>`:
   - `blast_presale::blast_presale::commit_open(presale, package_version, coin, clock)` under an open policy.
   - `blast_presale::blast_presale::commit_allowlisted(presale, package_version, coin, index,
     wallet_cap, proof, clock)` under an allowlist; `proof` is a `vector<vector<u8>>`. Also used
     by allowlisted wallets during an uncapped phase (the proof is still checked; the cap no
     longer limits).
   - `blast_presale::blast_presale::commit_uncapped(presale, package_version, coin, clock)` once a
     phase open to anyone has started.
3. `TransferObjects([returned_coin], sender)`.

Each commit emits `blast_presale::events::Committed`. Rules:

- The window is `start_ms <= now < end_ms`.
- A wallet's first commit takes a participant slot; later commits top it up by any positive
  amount. The minimum applies to the wallet's total after the commit, so the first commit must
  reach it. The commit that exactly fills a hard cap may be below the minimum.
- Before the uncapped phase, the wallet's total must stay within its cap. The cap a wallet first
  committed under is stored with its commitment; under an allowlist, later commits must present
  the same cap (`blast_presale::errors::EInvalidEligibilityProof`).
- Under an open policy, `commit_open` keeps working in either uncapped phase: caps are lifted,
  its minimum still applies, and an anyone-phase uses the phase's participant bound.

#### Allowlist proofs

The presale hashes leaves and verifies proofs with the core Merkle primitives
(`blast_core::merkle::leaf`, `blast_core::merkle::node`, `blast_core::merkle::verify`) under the
leaf domain `b"blast-presale-v1"`. Leaf digest, for the wallet at position `index` with cap
`wallet_cap`:

```
leaf = blake2b256( 0x00 || b"blast-presale-v1"            // the ASCII bytes
                   || bcs(index: u64)                  // 8 bytes, little-endian
                   || bcs(wallet: address)             // 32 bytes
                   || bcs(wallet_cap: u64) )           // 8 bytes, little-endian
node(left, right) = blake2b256( 0x01 || left || right )
```

The proof is positional: starting from the leaf digest with `i = index`, for each sibling in
order, `digest = node(digest, sibling)` when `i` is even, else `node(sibling, digest)`; then
`i = i / 2`. The result must equal the root. The proof must contain exactly
`ceil(log2(leaf_count))` siblings (zero for one leaf, where the root is the leaf itself), each 32
bytes, and `index < leaf_count`. The verifier takes each sibling as given, so the tree builder
picks one rule for an unpaired node at an odd-width level (for example, pairing it with itself)
and puts that sibling in the proof. The `wallet` in the leaf must be the transaction sender, and
`wallet_cap` must be positive.

#### Settling

Who may call: *anyone*. `blast_presale::blast_presale::settle(presale, package_version, clock)` while `Open`, once either:

- `now >= end_ms`; or
- the sale closes early: its hard cap has `closes_when_filled`, the hard cap is in force
  (`now >= start_ms + hard cap starts_after_ms`), and `total_commitments >= raise_target`. The
  sale can then take no more Quote.

If total commitments reach the raise the sale becomes `Funded` and emits
`blast_presale::events::PresaleFunded`; otherwise it becomes `Cancelled` and emits
`blast_presale::events::PresaleCancelled`. Closing early ends the window at the settle: the
stored `duration_ms` becomes the time the sale ran, so `end_ms` and the LP deadline count from the
close. `PresaleFunded` carries both. A sale without a hard cap never closes early.

Closing early and migrating can run in one PTB: `settle`, then the venue's `migrate`. Because
migration is permissionless, the wallet whose commitment fills the raise can also commit, settle,
migrate, and buy from the new pool in one transaction. The pool's seed price is the same either
way; creators who want a public start choose `closes_when_filled = false`.

#### Migrating

Who may call: *anyone*, while `Funded`, until someone cancels. One keeper PTB, type arguments
`<SaleToken, Quote>`:

1. `blast_presale::blast_presale::settle(presale, package_version, clock)` if not yet settled.
2. `blast_presale::blast_presale::migrate(presale, package_version, treasury, clock)` with the
   shared core `Treasury` read. It checks the version, the migrate pause bit, and that the sale is
   `Funded`; moves Blast's raise and token fees into the sale's ledger and pays them to the
   treasury's current destination (on a partnered sale it holds them for
   `blast_presale::blast_presale::pay_protocol_fees_with_partner`); pays or vests each raise
   recipient and each token recipient through `blast_core::payout::pay_or_vest`; marks the sale
   `Migrated`; emits `blast_presale::events::PresaleMigrated`; and returns a sealed
   `blast_core::migration::Migration<SaleToken, Quote>`. The hand-off holds the LP's tokens and
   Quote and the vault's `blast_core::migration::VaultTerms`: origin = the sale's ID, the sale's
   `FeeSplit`, Blast's LP-fee rates from the sale's snapshot (`lp_fee_meme_bps`,
   `lp_fee_quote_bps`), the sale's partner, and migration residuals held for the owner.
3. The venue's `migrate`, for example `blast_migrators::cetus::migrate` or
   `blast_migrators::bluefin::migrate`, with the `Migration` from step 2 as its first argument and
   the venue's and vault's objects (migrators guide). Only the stored venue's witness can redeem
   the hand-off (`blast_core::errors::EWrongVenue` otherwise), and it cannot be dropped or stored,
   so an unredeemed hand-off fails the whole transaction.
4. On a partnered sale, `blast_presale::blast_presale::pay_protocol_fees_with_partner(presale,
   package_version, treasury, partner)` (below).

The venue creates the pool, builds the vault (which requires the `VaultRegistry` to admit the venue
and the presale's `PackageWitness` as the sealing package witness), attaches the position, and shares the vault.
Whatever the pool did not take waits in the vault as the owner's residuals. Nothing returns to the
caller. Any venue failure rolls the whole transition back and leaves the sale `Funded`.

#### Paying a partnered sale's Blast fees

Who may call: *anyone*, after migration.
`blast_presale::blast_presale::pay_protocol_fees_with_partner(presale, package_version, treasury,
partner)` pays out the sale's ledger with `blast_core::protocol_fees::pay_with_partner`: the
partner receives its cut of each of Blast's fees (the raise fee in Quote and the token fee in the
sale token), rounded down, through `blast_partners::blast_partners::pay`, and the treasury's current
destination the rest. It aborts with `blast_core::errors::EPartnerMismatch` unless `partner` is the
sale's partner (always, on a sale without one). A ledger holding nothing, before migration, after a
cancellation, or once paid, sends and emits nothing. Emits
`blast_partners::blast_partners::PartnerPaid` per asset with a positive cut and
`blast_core::blast_core_events::ProtocolFeesPaid`. Blast's LP fees on the sale's vault are held and
paid separately, by the vault (below).

#### Claiming tokens and refunds

Who may call: *anyone* may relay; payment always goes to `participant`.
`blast_presale::blast_presale::claim(presale, package_version, participant, clock)` while
`Migrated` or `Cancelled`. Batch many claims in one PTB. It removes the wallet's commitment record,
so each wallet claims once.

- `Migrated`: pays the wallet's pro-rata tokens and its share of the overflow refund.
- `Cancelled`: pays back the full commitment; no tokens.
- With participant vesting, the tokens go into a new shared, irrevocable schedule for the
  participant that starts at this claim; the Quote refund is always paid at once. A claim whose
  token amount is zero creates no schedule.

Emits `blast_presale::events::Claimed` with `tokens`, `quote_refund`, `remaining_participants`, and
`vesting_id`.

#### Claiming vested tokens

Vested raise shares (Quote) and token shares start at migration; vested participant tokens start
at the participant's claim. Each schedule is a shared `Vesting<T>` from the immutable
`blast_fun_vesting` package, with a fixed beneficiary and no cancellation authority. Find its ID
in the `vesting_id` field of `blast_presale::events::RaiseAllocated`,
`blast_presale::events::RecipientAllocated`, or `blast_presale::events::Claimed`.

- Claim: `blast_fun_linear_vesting::claim<T>(vesting, clock)`. *Anyone* may call; it transfers all
  newly vested value to the beneficiary as a coin and aborts with
  `blast_fun_linear_vesting::ENothingClaimable` when nothing new has vested.
- Vested amount at time `t`: zero before `start + cliff_ms`; the whole amount from
  `start + period_ms × periods`; otherwise `floor(total × floor((t − start) / period_ms) / periods)`.
  The cliff only gates: once it passes, every whole period since the start counts.
- `blast_fun_linear_vesting::close_irrevocable<T>(vesting)` deletes a drained schedule; anyone.

#### Cancelling an unlaunched sale and refunds

Who may call: *anyone*. `blast_presale::blast_presale::cancel_unlaunched(presale, package_version,
clock)` once `now >= end_ms + liquidity_window_ms` while `Funded`. The sale becomes `Cancelled`
and emits `blast_presale::events::PresaleCancelled`. Every wallet then claims a full refund
with `blast_presale::blast_presale::claim`. A sale nobody settled can be settled and cancelled in
one PTB after the LP deadline. All minted tokens stay locked in the cancelled sale forever.
`blast_presale::blast_presale::destroy_cap(presale, presale_cap)` (*cap holder*) then deletes the
`PresaleCap`; a migrated sale's cap cannot be destroyed.

#### Owner calls on the vault

The `PresaleCap` holder acts on its sale's vault with an owner proof:
`blast_presale::blast_presale::prove_owner(presale, package_version, presale_cap)` (*cap holder*)
returns a `blast_core::owner_proof::OwnerProof` naming the sale, after checking the cap
(`blast_presale::errors::EWrongPresaleCap` for another sale's cap). The proof has no abilities:
pass it in the same PTB to one vault call, which consumes it and aborts with
`blast_core::errors::EWrongOwner` when the vault belongs to another sale.

- Claim migration residuals and owner-route fees: `blast_vault::vault::claim_owner_balances(vault,
  proof, vault_version)` returns a `Coin<Meme>` and a `Coin<Quote>`; transfer both in the same PTB.
  It aborts with `blast_vault::errors::ENothingToClaim` when nothing has accrued.
- Change the fee split: `blast_vault::vault::schedule_fee_split(vault, proof, vault_version,
  proposed, clock)` with a new `blast_core::fee_split::FeeSplit`, ready after a fixed 48-hour
  notice; `blast_vault::vault::cancel_fee_split` cancels it, even once ready. The venue's
  settle-and-apply call (migrators guide) activates it.

#### Collecting LP fees

Who may call: *anyone*, as often as they like, through the venue's collection calls (migrators
guide). Each collection takes the fees, then `blast_vault::vault::split_fees` pays Blast its share
of each asset (rounded up) to the `Treasury`, or holds it for the partner on a partnered sale, and
divides the rest over the vault's fee split (vault guide). On a partnered sale's vault, follow
with `blast_vault::vault::pay_protocol_fees_with_partner(vault, vault_version, treasury, partner)`:
*anyone*; it pays the partner its cut of each held asset and the `Treasury` the rest. Holding
nothing is valid and moves nothing, so it can follow every collection.

Applying a ready fee split, holder-reward rounds funded by the holder-reward route, Blast's
per-vault LP-fee share changes, and buybacks are the venue's and the vault's own calls (migrators
and vault guides).

#### Blast admin operations

Integrators cannot call these; they explain state changes. Each takes the
`blast_acl::AdminWitness` of the role listed in "Objects and authority" (*Blast admin*).

| Call | Effect |
| --- | --- |
| `fee_policy::schedule_fees` | Rates new sales snapshot. Raise and token rates at most 1,000 BPS each; each LP-fee rate at most `blast_core::constants::max_lp_fee_bps` (3,000) (`blast_presale::errors::EInvalidFees`). Compiled maximums: raising one needs a package upgrade. Anyone applies it once ready with `fee_policy::apply_fees`, which emits `delayed::DelayedApplied<fee_policy::FeesKey, fee_policy::ProtocolFees>`. |
| `blast_presale::blast_presale::set_protocol_fees` | Takes the live `FeePolicy`; each proposed rate must be at or below its applied rate (`blast_presale::errors::EAboveFeePolicy`). Replaces one sale's four rates in its creation PTB before `share` (`Pending`), where a rate may rise, or while `Open` and before `start_ms`, where each rate may only stay or fall (`blast_presale::errors::EProtocolFeesIncreased` otherwise). Emits `blast_presale::events::ProtocolFeesChanged`. |
| `creation_policy::set_quote_allowed` | Allows or disallows a Quote type for later sales. Emits `blast_presale::events::QuoteAllowed`, typed by the Quote. |
| `creation_policy::schedule_venue` | Schedules admission of a venue witness; rejects primitives, vectors, and `0x1`/`0x2` types (`blast_presale::errors::EInvalidVenue`). Anyone applies it once ready with `creation_policy::apply_venue`, which emits `delayed_set::SetApplied<creation_policy::VenueKey, TypeName>`. `creation_policy::remove_venue` removes immediately (emitting `delayed_set::MemberRemoved` for an admitted venue) and cancels a pending admission. |
| `creation_policy::add_partner` | Lets new sales name a partner at once (also cancels a pending removal). Emits `blast_partners::partner_list::PartnerAdded` with the policy's ID as `owner`. |
| `creation_policy::remove_partner` | New sales may still name the partner for `blast_partners::blast_partners::delay_ms` (7 days). Sales that already name it keep paying it. Emits `blast_partners::partner_list::PartnerRemoved`. |
| `blast_admin::package_admin::schedule_upgrade`, `blast_admin::package_admin::authorize_upgrade`, `blast_admin::package_admin::commit_upgrade_and_advance` | Compatible upgrades with atomic version cutover, typed `<BLAST_PRESALE_PACKAGE>` (admin guide). |

`blast_admin::package_admin::wrap` consumes the Publication and the never-upgraded matching cap
once. Each upgrade raises the compiled version and commits and advances the version in one
PTB; old bytecode then rejects the advanced version.

### Delayed administration

Each fee, admission or upgrade operation owns its applied notice period. A delayed-value
schedule accepts a proposed value and **next** `delay_ms`, but its execution deadline is
`ready_at_ms = now + currently_applied_delay_ms`. Passing zero cannot shorten the
current wait. The proposed value and next notice become active together only after
explicit application with the current version and canonical Clock. A value-only
change supplies the applied delay; a delay-only change supplies the applied value.
Different operations, including operations in the same package, can use different delays.

Rescheduling replaces the proposal and restarts the full currently applied notice.
`CancelAdmin` can cancel even a ready proposal, preserving the applied value and delay.
Ordinary value applications need no role; code authorization and immutability execution
still need UpgradeAdmin. Overflow is rejected at scheduling and actual application;
later schedules check their own timestamp addition too. A value proposal that changes neither
value nor notice, or a notice-only proposal equal to the applied notice, aborts with code 16
(`EUnchanged`) from Blast admin's `delayed` module (`delayed_action` for the upgrade notice,
`delayed_set` for the admission notice).
Read the live notice before relying on a cancellation window.

Each delayed field is a Blast admin delayed value: a `delayed::Delayed` setting, the
`delayed_action::DelayedAction` upgrade slot, or the `delayed_set::DelayedSet` of venues. The
module of each type emits every schedule, cancel and apply event; the presale package emits none
of its own. The events are generic in the operation's key and value type and carry `owner` (the
ID of the object that stores the field) and `key`. A value schedule emits
`delayed::DelayedScheduled` (after `delayed::DelayedCancelled` for a replaced proposal), a cancel
emits `delayed::DelayedCancelled`, and an application emits `delayed::DelayedApplied` with the
previous and new value and the applied notice. Creating a setting emits
`delayed::DelayedCreated`, the upgrade slot `delayed_action::ActionCreated`, and the admission set
`delayed_set::SetCreated`. Upgrade actions and their notice changes emit
`delayed_action::ActionScheduled`, `delayed_action::ActionCancelled` and
`delayed_action::ActionApplied`, whose `change` is `Action(...)` or `Delay` (a notice change).
Venue admissions and their notice changes emit `delayed_set::SetScheduled`,
`delayed_set::SetCancelled` and `delayed_set::SetApplied`, whose `change` is `Admission(...)` or
`Delay`. Their `delay_ms` is the proposed next notice for a notice change and the applied notice
for an action or admission. `delayed_set::MemberRemoved` records an immediate venue removal.

| Operation | Object and field | Key | Value or action type |
| --- | --- | --- | --- |
| Blast's rates | `FeePolicy.fees` | `fee_policy::FeesKey` | `fee_policy::ProtocolFees` |
| Upgrades and immutability | `PackageAdmin.upgrade` | `blast_admin::package_admin::UpgradeKey<BLAST_PRESALE_PACKAGE>` | `blast_admin::package_admin::UpgradeAction` |
| Venue admissions | `CreationPolicy.venues` | `creation_policy::VenueKey` | `TypeName` |

A vault's fee split and Blast's per-vault LP-fee share are the vault's own delayed fields, each
with a fixed 48-hour notice (vault guide).

Upgrades and immutability are Blast admin's generic administration (admin guide): its
`blast_admin::package_admin` calls, typed `<BLAST_PRESALE_PACKAGE>`, schedule, cancel, authorize
and commit each action under the stored upgrade notice. Blast's fee destination is the core
treasury's own delayed setting (core guide).

Publication-owned policy singletons start with zero notice for ordinary
role-authorized setup; the PackageAdmin starts at 172,800,000 ms (48 hours), so
no upgrade or immutability action can run without notice, even during setup. Configure
and apply each other operation's intended notice, and drain or cancel all earlier setup
proposals before release. `creation_policy::unpause` enforces the minimum: it aborts unless the
fee rates, the venue set, and the core treasury destination each have a nonzero applied notice, no
pending proposal that would set one to zero, and no pending venue admission; the generic
administration then checks the upgrade slot.
Raising a notice never changes previously scheduled deadlines or next delays.
Pausing and upgrades cannot reset notices. This source requires a fresh stack.

Venue admissions share one applied notice across witness types, held in the
`delayed_set::DelayedSet` `CreationPolicy.venues`; a fresh type cannot reopen setup.
`creation_policy::schedule_venue` accepts only the witness type in addition to its state,
authority and Clock inputs. It snapshots the applied notice and deadline; application only admits
that witness and preserves the live notice. `creation_policy::schedule_venue_delay` proposes a new
notice under VenueAdmin; anyone calls `creation_policy::apply_venue_delay`, and CancelAdmin uses
`creation_policy::cancel_venue_delay`. Existing admission deadlines remain fixed; settle or cancel
all zero-notice admissions before completing setup. Immediate venue removal cancels that type's
pending admission and preserves the applied notice. Scheduling an admitted venue, or removing one
that is neither admitted nor pending, aborts with code 16 from `delayed_set`.

### Emergency pause

A `PauseAdmin<BLAST_PRESALE_PACKAGE>` calls `blast_admin::package_admin::pause` to set selected
bits on the shared version. Only `UnpauseAdmin<BLAST_PRESALE_PACKAGE>` may clear bits, with
`creation_policy::unpause`, which takes the `CreationPolicy`, the `PackageVersion`, the
`PackageAdmin`, the `FeePolicy` and the core `blast_core::blast_treasury::Treasury` and first
checks that every presale notice and the treasury's are guarded (see above). Bits:
create is 1, commit is 2, migrate is 4. Pauses never expire; a paused call aborts with
`blast_admin::errors::EPaused` from `blast_admin::package_version`, and pause and unpause events are
`blast_admin::blast_admin_events::Paused` and `blast_admin::blast_admin_events::Unpaused`, typed
by `BLAST_PRESALE_PACKAGE`. `blast_presale::blast_presale::new` and
`blast_presale::blast_presale::share` check the create bit, all three commitment paths the commit
bit, and `blast_presale::blast_presale::migrate` the migrate bit. Settlement, claims, refunds,
`cancel_unlaunched`, partner payouts, owner proofs, and fee collections stay open.

`blast_presale::blast_presale::set_protocol_fees` remains immediate before the
sale starts, but takes the live `FeePolicy`; every rate must be at or below
its applied rates. Scheduled increases cannot authorize larger sale overrides.
Once a sale is shared it is public, so an override there may only keep or lower
each of its four rates; only the creation PTB may raise one.
VenueAdmin may immediately remove a venue with `creation_policy::remove_venue`.

### Economics

Publication defaults follow the [Blast visual map](https://map.blast.fun/#fees): 200 BPS (2%) of the successful raise target, 100 BPS (1%) of total Meme supply, and 1,500 BPS (15%) of each collected LP-fee asset. Administrators can change the policy; sales snapshot their rates. Changing source defaults does not update an existing policy, sale or vault.

All amounts are atomic units. All rates are BPS out of 10,000. `floor` rounds down.

#### Largest-remainder apportionment

Supply, raise, and every LP-fee split use one method (`blast_core::bps::apportion`). For shares
`s_i` summing to 10,000 and a total `X`: each share gets `floor(X × s_i / 10,000)`; the leftover
units (fewer than the number of shares) go one each to the shares with the largest remainder
`(X × s_i) mod 10,000`; ties go to the earlier share. Every unit lands in exactly one share.

- Supply, at creation, in order: buyers (`token_allocation_bps`), LP, Blast (`token_bps`), then
  token recipients in list order. Buyers, LP, and every recipient must get > 0
  (`blast_presale::errors::EInvalidTokenAllocation`); Blast may get 0.
- Raise, at creation, in order: raise recipients, Blast (`raise_bps`), then the LP with
  `10,000 − recipients − Blast`. Every recipient and the LP must get > 0
  (`blast_presale::errors::EInvalidRaiseAllocation`).
- These amounts are fixed at creation, except that a per-sale rate change before the start
  replaces Blast's amounts (below). Migration pays them from exactly `raise_target`; the LP
  Quote is `raise_target − Blast's Quote − raise recipients' Quote`.

#### Fill rate, claims, and dust

Let `T` be total commitments, `R` the raise target, `A` the buyers' token allocation, and `c` one
wallet's commitment. A migrated sale requires `T >= R`. The common fill rate is `R / T`.

- Tokens: `floor(A × c / T)`.
- Overflow refund: `floor((T − R) × c / T)`.
- Cancelled sale: refund `floor(T × c / T) = c`; no tokens.
- The last wallet to claim, whichever it is, takes everything left of the tokens and Quote
  instead, so no rounding dust is stranded. Its extra is under one atomic unit per other
  claimant, per asset.
- Buyers together pay `R` for `A` tokens: the presale price is `R / A` Quote per atomic token.
  The pool opens at `LP Quote / LP tokens`.

Worked example: supply 20,001 at 5,000 / 1,000 / 0 / 2,500 / 1,500 BPS (buyers, LP, Blast,
recipient A, recipient B) apportions to 10,001 / 2,000 / 0 / 5,000 / 3,000 (the buyers' 0.5
remainder is the largest). Raise 1,000; Alice commits 1,000 and Bob 3,000, so `T = 4,000`. Alice
claims first: `floor(10,001 × 1,000 / 4,000) = 2,500` tokens and `floor(3,000 × 1,000 / 4,000) =
750` Quote. Bob claims last and takes the rest: 7,501 tokens and 2,250 Quote.

When the raise fills under a hard cap, `T` equals `R` and every refund is zero. If the sale
already overflowed before its hard cap started, the hard cap accepts nothing (`blast_presale::errors::EPresaleFilled`)
and the earlier overflow fills pro rata as usual.

#### Blast's fees

Blast takes three fees, all from the sale's snapshot (`Presale.protocol_fees`), copied from
`FeePolicy` at creation. Later `fee_policy::schedule_fees` calls never touch existing sales. Nothing is
charged at creation, on commitment, on refund, or when a sale does not migrate.

- Raise fee: Blast's Quote, apportioned with the raise at creation, moved into the sale's
  `blast_core::protocol_fees::Ledger` at migration and paid to the core `Treasury`'s destination as
  it is when paid. Overflow refunds are never charged.
- Token fee: Blast's tokens, apportioned with the supply at creation, moved into the same ledger at
  migration and paid with the raise fee.
- LP fees: migration seals the sale's `lp_fee_meme_bps` and `lp_fee_quote_bps` into the vault's
  terms. At each collection the vault takes `ceil(gross × bps / 10,000)` of each asset at its
  current share and pays it to the core `Treasury`. Blast can change one vault's share only
  through the vault's own delayed call, `blast_vault::vault::schedule_protocol_bps` (core
  `FeeAdmin`, fixed 48-hour notice, at most `blast_core::constants::max_lp_fee_bps`, 3,000 BPS per
  asset; vault guide).

Per-sale changes before the start (`blast_presale::blast_presale::set_protocol_fees`): a rate may rise
only in the creation PTB; on a shared sale each rate may only stay or fall. A changed raise rate
becomes `floor(R × raise_bps / 10,000)` and takes from or gives to the LP's Quote; a changed token
rate becomes `floor(supply × token_bps / 10,000)` and takes from or gives to the buyers'
allocation `A`. A rate equal to the sale's current one keeps its current amount (the creation
amount unless an earlier change replaced it). Recipients keep their amounts. The
new amounts must leave the LP some Quote and the buyers some tokens, and the LP must still seed a
poolable price.

#### Partners

A sale may name one `blast_partners::blast_partners::Partner`, named on the initializer and fixed
at `finalize`; the sale's ledger is bound to it. The partner earns a cut of every Blast fee: the
raise fee, the token fee, and, through the sale's vault, Blast's LP fees (ADR 0137). The cut is
`floor(fee × share_bps / 10,000)` of each asset, using the partner's share applied when paid (at
most 8,000 BPS; a change Blast proposes can be applied by anyone 7 days later). Blast keeps the
rest. On a partnered sale, migration holds Blast's raise and token fees in the sale's ledger until
`blast_presale::blast_presale::pay_protocol_fees_with_partner` runs; the vault inherits the partner
and holds Blast's LP fees until `blast_vault::vault::pay_protocol_fees_with_partner` runs.

#### LP-fee split and residuals

After Blast's LP fees, the rest of each asset is apportioned by largest remainder over the vault's
fee-split routes, in route order (the sale's `fee_split` until the owner changes it). Address
routes are paid as coins in the same transaction; owner, auto-LP, and holder-reward routes accrue
in the vault; the burn route burns its Meme and keeps its Quote. Migration residuals, whatever the
venue did not take when seeding, wait in the vault for the owner, who claims them with
`blast_vault::vault::claim_owner_balances`. The vault guide has the details.

#### Seed price bound

Creation (and any per-sale rate change) aborts with `blast_presale::errors::EUnseedablePrice` unless the LP's Quote per
LP token, in atomic units, lies inside both CLMM venues' price range with a margin: roughly 2^-62 to
2^62 (about 2.2e-19 to 4.6e18). A huge raise against a tiny LP-token allocation, or the reverse,
fails this check. The CLMM seed's opening sqrt price is `floor(sqrt(coin_b / coin_a) × 2^64)`
from the atomic amounts; display decimals never enter it.

### Time rules

All times are Unix milliseconds from `Clock`.

- `start_ms = max(requested start, time of share)`; `end_ms = start_ms + duration_ms`; LP deadline
  `= end_ms + liquidity_window_ms`; uncapped phase from `start_ms + starts_after_ms`, or `end_ms`
  when the sale has none; hard cap from `start_ms + starts_after_ms`. `share` aborts with
  `blast_presale::errors::EInvalidWindow` if these overflow u64. An early close sets `end_ms` to the settle time, which
  moves the LP deadline forward too.
- Commits: allowed for `start_ms <= now < end_ms`. Before the start: `blast_presale::errors::EPresaleNotStarted`. At or
  after the end: `blast_presale::errors::EPresaleEnded`.
- Caps lift at `now >= uncapped start`.
- `blast_presale::blast_presale::set_protocol_fees`: in the creation PTB before `share`, or after it while
  `now < start_ms`, when it may only lower rates. A sale shared with a start in the past can be
  repriced only in its creation PTB. After the start, `blast_presale::errors::EPresaleStarted` precedes the rate checks.
- `blast_presale::blast_presale::settle`: from `now >= end_ms`, at any later time, or earlier once the sale can close
  early.
- Migration: any time while `Funded`, including after the LP deadline, until someone cancels.
- `blast_presale::blast_presale::cancel_unlaunched`: from `now >= LP deadline`. The 7-day minimum means a funded
  sale stays migratable for at least a week after its end.
- Vesting starts at migration for recipients and at each claim for participants.
- `blast_presale::blast_presale::set_partner` needs the policy's partner list to accept the
  partner now: added, and any removal's `acceptance_ends_at_ms` not yet reached.
- Hard cap: commitments are held to the raise from `now >= hard cap start`.
- Vault fee-split and Blast-share changes wait a fixed 48 hours; collections have no deadline or
  cooldown (vault guide).

### Reading state

- Find a coin's presale without an indexer: its object ID is derived from the shared
  `blast_presale::blast_presale::PresaleRegistry` and the key
  `blast_presale::blast_presale::PresaleKey<SaleToken>`, a field-less struct whose BCS is the single
  byte `0x00` (Move gives it a `dummy_field: bool`): `0x2::dynamic_field::hash_type_and_key(registry_id,
  0x2::derived_object::DerivedObjectKey<PresaleKey<SaleToken>>, [0])`, with types named by original
  package IDs. A coin has at most one presale.

The package exposes no public read functions on its shared objects (the initializer's
`blast_presale::blast_presale::venue` is the only getter). Read object fields over RPC (object
content and dynamic fields), and use events for history.

`Presale<SaleToken, Quote>` fields:

- Lifecycle and timing: `lifecycle`, `start_ms` (zero until shared), `duration_ms` (the time the
  sale ran, once it closed early), `liquidity_window_ms`, `uncapped` (with `starts_after_ms`,
  `access`), `hard_cap` (with `starts_after_ms`, `closes_when_filled`).
- Raise progress: `raise_target`, `total_commitments`, `participants` (wallets that have
  committed and not yet claimed), `quote` (Quote held).
- Terms: `eligibility`, `token_allocation` (buyers' tokens), `participant_vesting`,
  `recipient_payouts` and `raise_payouts` (each `Recipient`, with its destination and vesting
  terms, and its exact amount), `fee_split` (the vault's starting `FeeSplit`), `venue` (the venue
  witness's type name, with original package IDs).
- Blast: `protocol_fees` (the snapshot), `protocol_quote` and `protocol_tokens` (Blast's amounts,
  the tokens escrowed until migration), `partner_id`, and `fee_ledger`, the
  `blast_core::protocol_fees::Ledger` whose `meme` (sale tokens) and `quote` balances hold Blast's
  fees from a partnered migration until its pay call.
- Custody balances: `sale_tokens`, `liquidity_tokens`, `recipient_tokens`.
- `presale_cap_id`: the ID of the sale's `PresaleCap`.

One wallet's commitment is a dynamic field on the presale's ID: name type
`blast_presale::blast_presale::CommitmentKey` (a positional struct wrapping the wallet address; BCS is the
32-byte address), value `blast_presale::blast_presale::Commitment` with `quote` and `wallet_cap`. The field is
absent before the first commit and after the claim.

Common answers:

- Is it open? `lifecycle == Open` and `start_ms <= now < start_ms + duration_ms`.
- Fill rate? `raise_target / total_commitments` once `total_commitments >= raise_target`.
- Has a wallet claimed? After `Migrated`/`Cancelled`, its commitment field is gone (and a
  `blast_presale::events::Claimed` names it).
- Preview a claim: apply the formulas in Economics to `token_allocation`, `total_commitments`,
  `raise_target`, and the wallet's `quote`; the last claimant gets the remainder.
- Which vault? The `blast_vault_events::VaultCreated` whose `terms` has the sale's ID as its
  `origin`, emitted in the migration transaction.

Other objects:

Delayed policy fields are Blast admin `delayed::Delayed` values. A `Delayed<K, T>` contains `owner` (the ID of
the object that stores it), `key`, the applied `value`, applied `delay_ms`, and an optional `pending`
proposal with the proposed `value`, next `delay_ms`, and `ready_at_ms` (Unix milliseconds). Read the applied value even after a
pending proposal becomes ready; only a successful apply call changes it. Each `Bps` is a
positional struct wrapping one u64.

- `FeePolicy`: `fees` is `Delayed<FeesKey, ProtocolFees>`; `fees.value` holds the applied
  `raise_bps`, `token_bps`, `lp_fee_meme_bps` and `lp_fee_quote_bps`, each a `Bps`. Blast's payee
  is the core `Treasury`'s `destination` (core guide).
- `CreationPolicy`: `allowed_quotes` (a set of type names with original package IDs) and
  `venues`, a `DelayedSet<VenueKey, TypeName>`. Its `members` holds the admitted venue type names
  (original package IDs), `delay_ms` the applied admission notice, `admissions` maps each pending
  type name to its snapshotted `delay_ms` and `ready_at_ms`, and `pending_delay` holds a proposed
  next notice. An admission becomes active only when applied into `members`, which preserves the
  applied notice. `partners` is a `blast_partners::partner_list::PartnerList` whose
  `acceptance_ends_at_ms` table maps each partner's ID to the time it stops being accepted (the
  maximum u64 while accepted).
- The sale's `Vault` (terms, fee split, Blast's share, balances, positions): vault guide.
- `Vesting<T>`: `balance`, `beneficiary`, `start_ms`, `cliff_ms`, `period_ms`, `periods`,
  `released`.

### Events

Sale events carry the type arguments `<SaleToken, Quote>`. Filter by the full generic type or by
the emitting module. Payloads are emitted directly (no envelope), from `blast_presale::events`
except `blast_presale::blast_presale::PresaleCreated`, which stays beside the sale terms it records.

| Flow | Event | Indexer use |
| --- | --- | --- |
| Prepare | The venue's own events (migrators guide) | The venue's pool terms. |
| Create | `blast_presale::blast_presale::PresaleCreated` | All terms: supply split (BPS), token recipients (`blast_core::payout::Recipient`: destination and vesting terms), raise split (BPS) and raise recipients, participant vesting, window lengths, eligibility, uncapped phase, hard cap, `venue`, `fee_split`, Blast's snapshot rates and amounts, `treasury_cap_id`, `presale_cap_id`. |
| Share | `blast_presale::events::PresaleOpened` | `start_ms`, scheduled `end_ms` and `liquidity_deadline_ms`, `uncapped_from_ms`, `hard_cap_from_ms` (`none` without a hard cap), `partner_id`. |
| Per-sale rates | `blast_presale::events::ProtocolFeesChanged` | New rates, Blast amounts, and new buyer `token_allocation`. |
| Commit | `blast_presale::events::Committed` | `quote` accepted, `wallet_commitment` (new total), `total_commitments`, `participants`. It has no wallet field: the wallet is the transaction sender. |
| Settle | `blast_presale::events::PresaleFunded` / `blast_presale::events::PresaleCancelled` | Funded: `accepted_quote`, `refundable_quote`, `token_allocation`, and the actual `end_ms` and `liquidity_deadline_ms`, earlier than `PresaleOpened`'s after an early close. Cancelled: total refundable. |
| Migrate | `blast_core::blast_core_events::ProtocolFeesPaid` (unpartnered, when Blast's fees are not both zero), `blast_presale::events::RaiseAllocated` (per raise recipient), `blast_presale::events::RecipientAllocated` (per token recipient), `blast_presale::events::PresaleMigrated`, then the venue's and the vault's events (`blast_vault_events::VaultCreated`) | Blast's payment (`origin` is the sale, `meme_amount` its tokens, `quote_amount` its Quote, `treasury` the payee); payouts with `vesting_id`; `venue` and LP amounts; the vault and its sealed terms. |
| Partner pay | `blast_partners::blast_partners::PartnerPaid` (per asset with a positive cut), `blast_core::blast_core_events::ProtocolFeesPaid` | The partner's cut of each asset (`partner_meme_amount`, `partner_quote_amount`) and Blast's rest. |
| Claim | `blast_presale::events::Claimed` | `tokens`, `quote_refund`, `remaining_participants`, `vesting_id`. |
| Partner list | `blast_partners::partner_list::PartnerAdded`, `blast_partners::partner_list::PartnerRemoved` | `owner` is the `CreationPolicy`'s ID. |
| Quote list | `blast_presale::events::QuoteAllowed` | Typed by the Quote; `allowed`. |
| Vesting | `VestingCreated`, `VestingClaimed` (from `blast_fun_vesting`) | Schedule terms and releases. |

Collections, owner claims, partner LP payouts, and holder-reward rounds emit the venue's and the
vault's events (migrators and vault guides). Pauses emit
`blast_admin::blast_admin_events::Paused` and `blast_admin::blast_admin_events::Unpaused`; other
admin events are listed in "Blast admin operations" and "Delayed administration".

### Aborts

Presale errors are numeric codes from `blast_presale::errors`, raised in the module named; the SDK
maps each code to its name. Common ones by flow:

- Any call: `blast_admin::package_version` aborts with code 9 for a stale package ID (call the current
  presale package); `blast_admin::errors::EPaused` from `blast_admin::package_version` while the
  call's pause bit is set.
- Start (`new`): `blast_presale::errors::EQuoteNotAllowed` / `blast_presale::errors::EVenueNotAllowed`
  (ask Blast to list it); `blast_presale::errors::EInvalidAssetPair` (sale coin equals Quote);
  `blast_presale::errors::EInitialSupplyNotZero`.
- Value constructors: `blast_core::errors::EInvalidBps`; `blast_core::errors::EInvalidVestingTerms`
  and `blast_core::errors::EInvalidRecipient` (`0x0`) from `blast_core::payout`;
  `blast_presale::errors::EInvalidEligibilityPolicy`, `blast_presale::errors::EInvalidUncappedPhase`;
  `blast_core::errors::EInvalidRoute` and `blast_core::errors::EInvalidFeeSplit` from the fee-split
  builders (core guide).
- Finalize: `blast_presale::errors::ESaleTokenNotUnregulated` (regulated or unknown legacy currency; use a new
  Coin Registry currency created without regulation); `blast_presale::errors::EMissingSetting` (no eligibility policy or LP-fee split); `blast_presale::errors::EInvalidRaiseTarget`
  (raise unset or zero); `blast_presale::errors::EInvalidTokenAllocation` (BPS not exactly 10,000 with Blast's token rate, duplicate
  destination, more than 64, or a zero apportioned amount); `blast_presale::errors::EInvalidRaiseAllocation` (no LP share
  left after Blast, duplicates, zero amounts); `blast_presale::errors::EInvalidWindow` (zero duration or LP window under
  7 days); `blast_presale::errors::EUnreachableRaise` (minimum × slots below raise); `blast_presale::errors::EInvalidEligibilityPolicy`;
  `blast_presale::errors::EInvalidUncappedPhase`; `blast_presale::errors::EInvalidHardCap` (hard cap starts at or after the window's end);
  `blast_presale::errors::EUnseedablePrice`. A PTB that leaves the `VenueTicket` or the
  `PresaleInitializer` unconsumed fails at its end with Sui's unused-value error, not a Move abort.
- Partner: `blast_partners::errors::EPartnerNotAccepted` from `blast_partners::partner_list`.
- Share: `blast_presale::errors::EInvalidLifecycle` (already shared); `blast_presale::errors::EInvalidWindow`.
- Commit: `blast_presale::errors::EPresaleNotStarted`, `blast_presale::errors::EPresaleEnded` (check the window); `blast_presale::errors::EZeroCommitment`;
  `blast_presale::errors::EWrongEligibilityPolicy` (wrong commit function for the policy); `blast_presale::errors::EInvalidEligibilityProof`
  (wrong index, cap, proof, sender, or a different cap than the wallet's first commit);
  `blast_presale::errors::EWalletCapExceeded` (lower the amount, or wait for the uncapped phase);
  `blast_presale::errors::EBelowMinimumCommitment` (first commit must reach the minimum); `blast_presale::errors::EParticipantCapacityReached`;
  `blast_presale::errors::EUncappedPhaseNotOpen` (no anyone-phase, or not started); `blast_presale::errors::EPresaleFilled` (hard cap reached);
  `blast_presale::errors::ETotalCommitmentOverflow`.
- Settle: `blast_presale::errors::EPresaleNotEnded` (the window has not ended and the sale cannot close early);
  `blast_presale::errors::EInvalidLifecycle` (already settled).
- Migrate: `blast_presale::errors::EInvalidLifecycle` (not `Funded`: unsettled, underfunded,
  cancelled, or migrated); `blast_core::errors::EWrongVenue` in `blast_core::migration` (another
  venue's `migrate`); the venue's and the vault's own aborts (migrators and vault guides).
- Partner pay: `blast_core::errors::EPartnerMismatch` from `blast_core::protocol_fees` (not the
  sale's partner, or a sale without one).
- Claim: `blast_presale::errors::EInvalidLifecycle` (not `Migrated`/`Cancelled`); `blast_presale::errors::ENoCommitment` (never committed or
  already claimed).
- Cancel: `blast_presale::errors::ELiquidityDeadlineNotReached`; `blast_presale::errors::EInvalidLifecycle` (not `Funded`).
- Cap and owner: `blast_presale::errors::EWrongPresaleCap` (`prove_owner`, `destroy_cap`);
  `blast_presale::errors::EInvalidLifecycle` on `destroy_cap` before cancellation;
  `blast_core::errors::EWrongOwner` (proof presented to another sale's vault);
  `blast_vault::errors::ENothingToClaim`.
- Admin-only: `blast_acl::sign_in` aborts for a revoked `AdminCap` or one without the role;
  then `blast_presale::errors::EPresaleStarted`, `blast_presale::errors::EProtocolFeesIncreased` (a shared sale's override raises a rate),
  `blast_presale::errors::EAboveFeePolicy`, `blast_presale::errors::EProtocolFeesUnchanged`, `blast_presale::errors::EInvalidFees`,
  `blast_presale::errors::EAllowanceUnchanged` (Quote already in that state), `blast_presale::errors::EInvalidVenue`,
  `blast_presale::errors::EUnguardedDelay`, `blast_partners::errors::EUnchanged` (partner already
  accepted, or its removal already pending); pause, unpause and upgrade aborts are the generic
  administration's (admin guide).
- Delayed administration (policy fees, venue admission, upgrades): Blast admin's
  delayed modules abort with plain codes. 13 `ENotReady`: applied before `ready_at_ms` (from
  `delayed_set` for an early admission, otherwise from `delayed`). 14 `ENoPending`: applied or
  cancelled with nothing pending (from the type's own module: `delayed` for a setting,
  `delayed_action` for an upgrade, `delayed_set` for an admission). 15 `EInvalidDelay`: a deadline
  or notice would overflow (from `delayed`). 16 `EUnchanged`: the proposal changes nothing, the
  venue is already admitted, or the removed venue is unknown (from the type's own module). 18
  `EWrongChange` (from `delayed_action`): `authorize_upgrade` or `make_immutable` while a notice
  change is pending, or `apply_upgrade_delay` while an action is pending.

### Pitfalls

- Prepare, `new`, set, `finalize`, and `share` in one PTB. The `VenueTicket` and the
  `PresaleInitializer` must be consumed and the `Presale` cannot be transferred, so a PTB that
  skips a step fails. The partner can be named only on the initializer.
- Passing the `TreasuryCap` by value to the venue's `prepare`: it takes the cap by reference;
  `new` takes it by value afterwards.
- An early close needs a hard cap with `closes_when_filled`. A sale without a hard cap always
  runs to `end_ms`, even when it reached its raise on day one.
- Every commit returns a coin. Transfer it back to the sender, even when it is zero.
- Commits always credit the sender. Sponsored transactions work (the user stays the sender), but
  take Quote from the user's coins, not the sponsor's gas coin.
- A keeper PTB of `settle` then `migrate` aborts as a whole when the sale is underfunded
  (`settle` cancels, then `migrate` hits `blast_presale::errors::EInvalidLifecycle`). Compare `total_commitments` with
  `raise_target` first and send `settle` alone when it falls short.
- `blast_presale::blast_presale::migrate` returns a `Migration` that must be redeemed by the sale's
  venue in the same PTB: pass it to that venue's `migrate`.
- A venue missing from the vault's `VaultRegistry` cannot migrate even though `CreationPolicy`
  admitted it at creation.
- Partnered sales and vaults hold Blast's fees until the pay calls run. Add
  `blast_presale::blast_presale::pay_protocol_fees_with_partner` after migration and
  `blast_vault::vault::pay_protocol_fees_with_partner` after each collection.
- An `OwnerProof` cannot be stored or dropped: call `blast_presale::blast_presale::prove_owner` in
  the PTB that uses it.
- The last claimant takes the rounding remainder. Show earlier previews as exact and the last one
  as "at least".
- Participant vesting starts when the claim lands, and anyone may relay a claim. Claiming late
  delays the schedule.
- The minimum commitment applies to a wallet's running total; top-ups below it are fine.
- `min_commitment × max_participants` must reach the raise; size the policy before creating.
- A cancelled sale's tokens are locked forever and its supply is already fixed or burn-only; the
  coin type cannot run another sale.
- Payouts are pushed to recipients in the same transaction. If a regulated Quote's issuer blocks a
  recipient, the paying transaction can abort: a blocked raise recipient can stall migration until
  the LP deadline, and a blocked address route stalls that vault's collections.
- `Committed` has no wallet field; take the wallet from the transaction sender.

### Vendor venues: the Aftermath DAO-pool presale

#### How a vendor venue works

`blast_presale::blast_presale::new` and `blast_presale::blast_presale::migrate` are public, and
the hand-off types are in the core package. Any module can be a venue if it defines a `drop`
witness struct only it can construct. It issues a ticket with `blast_core::migration::issue_ticket`
and passes it to `blast_presale::blast_presale::new`; the sale records the witness type in
`venue`. At migration, only `blast_core::migration::redeem` called with the same witness opens the
sale's `Migration` (`blast_core::errors::EWrongVenue` otherwise); the venue receives the LP's
`Balance<SaleToken>` and `Balance<Quote>` and the `VaultTerms`, and must put the balances into its
pool in the same call. `blast_presale::blast_presale::migrate` pays Blast, raise recipients, and
token recipients exactly as for every other venue. Blast must first admit the witness with
`creation_policy::schedule_venue`; removing it later never blocks existing sales. A venue creates a
vault only if the vault's `VaultRegistry` admits it; a vendor sale without a vault has no Blast LP
fees, no holder-reward rounds, and no owner claims. Every other sale rule (eligibility, claims,
refunds, LP deadline, the seed-price check) applies unchanged.

#### `blast_aftermath_dao_presale`

A one-off, immutable package for one partner: a plain venue over `blast_core` that imports no
product, so a presale upgrade never strands it. Its sales migrate into a new 50/50 Aftermath
weighted pool wrapped in Aftermath's DAO-fee pool, which charges 2% (200 BPS) on every swap,
deposit, and withdrawal and sends it straight to the partner treasury compiled into the module. It
creates no vault.

Objects:

- `blast_aftermath_dao_presale::blast_aftermath_dao_presale::Venue`: the sealed venue witness. It
  issues the ticket `prepare` returns and redeems that sale's migration hand-off.
- `blast_aftermath_dao_presale::blast_aftermath_dao_presale::AdminCap`: the vendor's own admin, sent
  to the publisher. Its one power is preparing sale tokens through `prepare`. It is not Blast's
  `blast_acl::AdminCap`.
- `blast_aftermath_dao_presale::blast_aftermath_dao_presale::PoolCreation<Lp, SaleToken>`: shared;
  reserves one sale token's pool creation with the Aftermath `CreatePoolCapV2` of a freshly
  published LP coin `Lp`.

Create (*cap holder*, `blast_aftermath_dao_presale::blast_aftermath_dao_presale::AdminCap`, who also
holds the sale token's `TreasuryCap`), one PTB:

1. Beforehand, in its own transaction, publish a fresh Aftermath LP coin `Lp` (one per sale); its
   publication yields the `CreatePoolCapV2` that the `AdminCap` holder passes in.
2. `blast_aftermath_dao_presale::blast_aftermath_dao_presale::prepare<Lp, SaleToken, Quote,
   PackageWitness>(admin_cap, create_pool_cap)`, with the presale's package witness
   `blast_presale::blast_presale_package::PackageWitness` as `PackageWitness`, shares the
   `PoolCreation<Lp, SaleToken>` bound to that package witness, emits
   `blast_aftermath_dao_presale::blast_aftermath_dao_presale::PoolCreationReserved`
   (`pool_creation_id`, `package_witness`), and returns the venue's `VenueTicket<SaleToken, Quote>`.
   A primitive, standard-library, or framework `PackageWitness` aborts with
   `blast_aftermath_dao_presale::blast_aftermath_dao_presale::EInvalidPackageWitness` (code 2). Its pool's weights
   and fees are the module's constants, so it records no tier.
3. `blast_presale::blast_presale::new` with the `TreasuryCap` and the ticket, as for any sale. The
   `CreationPolicy` must admit the vendor's `Venue`.
4. The `blast_presale::blast_presale` setters as for any sale, including the optional
   `blast_presale::blast_presale::set_partner`. The sale's LP-fee split never applies, because no
   vault exists.
5. `blast_presale::blast_presale::finalize`, the optional
   `blast_presale::blast_presale::set_protocol_fees(...)` (which needs Blast's presale `FeeAdmin`
   signed in within the same transaction), then `blast_presale::blast_presale::share`.

Migrate (*anyone*, while `Funded`), one PTB:

1. `blast_presale::blast_presale::settle` if needed.
2. `blast_presale::blast_presale::migrate`, which returns the sale's `Migration<SaleToken, Quote>`.
3. `blast_aftermath_dao_presale::blast_aftermath_dao_presale::migrate<Lp, SaleToken,
   Quote>(migration, pool_creation, pool_registry, dao_fee_version)`. `migration` is the
   result of step 2; `pool_creation` is the sale token's shared `PoolCreation<Lp, SaleToken>`, passed
   by value and deleted; `pool_registry` is Aftermath's shared `PoolRegistry` (mutable);
   `dao_fee_version` is the DAO-fee package's shared `Version`.
   Type arguments are always `<Lp, SaleToken, Quote>`; the module sorts the coins into Aftermath's
   order itself.
4. On a partnered sale, `blast_presale::blast_presale::pay_protocol_fees_with_partner(...)`.

The call redeems the hand-off with its `Venue` (`blast_core::errors::EWrongVenue` for a hand-off
sealed for any other venue), refuses terms another package sealed
(`blast_aftermath_dao_presale::blast_aftermath_dao_presale::EWrongPackageWitness`, code 3), keeping only
the sale's ID from the vault terms (no vault exists for
its pools), creates the pool from all LP tokens and Quote (50/50 weights, flatness 0, a 0.01%
swap-in fee that compounds into the LP, no other pool fees, name "Blast Presale Pool"), checks it
holds every unit (`blast_aftermath_dao_presale::blast_aftermath_dao_presale::EPoolMismatch`, code
0), wraps it in a DAO-fee pool at 200 BPS paying the treasury
(`blast_aftermath_dao_presale::blast_aftermath_dao_presale::EDaoFeePoolMismatch`, code 1), shares
the DAO-fee pool (the object traders use), sends its `OwnerCap` to the treasury, and
sends the whole LP coin to `0x0`, where nobody can ever use it. Emits
`blast_aftermath_dao_presale::blast_aftermath_dao_presale::Migrated` with the sale ID, the pool,
DAO-fee pool, owner cap, and LP coin IDs and the LP amount.

With the `OwnerCap` the treasury can change its pool's DAO fee or recipient directly through
Aftermath. If the `CreatePoolCapV2` belongs to a different LP coin than `Lp`, or Aftermath retires the
versions this package links to, migration aborts and the sale becomes refundable at its LP
deadline.

### Q&A

**How many tokens will a buyer get?** After migration, `floor(token_allocation × commitment /
total_commitments)`, plus an overflow refund of `floor((total_commitments − raise_target) ×
commitment / total_commitments)` Quote. Every wallet gets the same fill rate,
`raise_target / total_commitments`. The last wallet to claim also receives the rounding
remainder.

**Can a buyer withdraw before the sale ends?** No. Quote stays locked while the sale is `Open` or
`Funded`. It comes back only as the overflow refund after migration, or in full after a
cancellation.

**Can a sale end before its window does?** Only a hard-capped sale whose hard cap has
`closes_when_filled`, once its raise is full under the hard cap. Anyone may then call
`blast_presale::blast_presale::settle`, and the LP deadline counts from that moment. An overflowing sale always
runs its full window, since later wallets can still join at the common fill rate.

**What happens if the raise is not met?** From `end_ms` anyone calls `blast_presale::blast_presale::settle`,
which cancels the sale. Each wallet (or a relayer) then calls `blast_presale::blast_presale::claim` for a full
refund. Blast charges nothing, and the minted tokens stay locked forever.

**Who migrates a funded sale, and what if nobody does?** Anyone, through the venue whose ticket
started the sale, at any time until the sale is cancelled. From the LP deadline (`end_ms +
liquidity_window_ms`, at least 7 days) anyone may call `blast_presale::blast_presale::cancel_unlaunched` instead,
which makes every commitment fully refundable.

**What is the PTB to start a sale on Cetus?** `blast_migrators::cetus::prepare` with the
`TreasuryCap` by mutable reference (returns the `VenueTicket`), `blast_presale::blast_presale::new`
with the `TreasuryCap` by value and the ticket, the setters, `blast_presale::blast_presale::finalize`,
`blast_presale::blast_presale::share`, and a transfer of the `PresaleCap`, in that order.

**What does Blast charge?** A snapshot, taken at creation, of a raise rate, a token rate, and two
LP-fee rates. The raise and token fees are paid at migration to the core `Treasury` (or held for a
partnered sale's pay call); the LP-fee rates pass to the vault, which takes them at each fee
collection, rounded up, for the same `Treasury`. Nothing is charged on commitments, refunds, or
failed sales.

**How does the creator get its LP fees and the migration residuals?** Through the vault's fee
split: an address route is paid at each collection, and an owner route accrues. The `PresaleCap`
holder calls `blast_presale::blast_presale::prove_owner` and
`blast_vault::vault::claim_owner_balances` in one PTB to take owner fees and residuals, and uses
the same proof with `blast_vault::vault::schedule_fee_split` to change the split after 48 hours.

**Can Blast or the creator change a sale after it opens?** The creator cannot. Blast's presale
`FeeAdmin` can change the sale's four rates only before `start_ms` (raising one only in its
creation transaction), and the core `TreasuryAdmin` can redirect every Blast fee after the
treasury's notice. Windows, recipients and eligibility never change. After migration, Blast's per-vault
LP share changes only through the vault's own 48-hour delayed call.

**How is an allowlist leaf built?** `blake2b256(0x00 || "blast-presale-v1" || u64 LE index ||
32-byte wallet || u64 LE cap)`, as `blast_core::merkle::leaf` hashes it. Internal nodes are
`blake2b256(0x01 || left || right)`. The proof is positional with exactly
`ceil(log2(leaf_count))` siblings. The wallet must be the transaction sender.

**Where is the liquidity, and can anyone withdraw it?** A Cetus position is burned through
Cetus LP-burn and the vault keeps only its fee-claiming proof. A Bluefin position sits in the
vault under the venue's key, which only borrows it to collect fees and never removes it. The
Aftermath DAO-pool vendor sends its LP coin, the pool's whole liquidity, to `0x0`.
