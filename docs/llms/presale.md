## Presale

### What it is

`blast_presale` runs standalone presales on Sui mainnet. A creator brings a new coin
with zero supply. The sale mints the whole supply once, splits it between buyers, the launch
pool, Blast, and named recipients, and gives up mint authority forever. Buyers commit a Quote coin
(for example SUI) during a commitment window. By default commitments may exceed the raise target:
everyone is then filled at one common rate and the excess is refunded. A creator may instead
hard-cap the sale, from the start or from a later point in the window, so it takes Quote first
come, first served only up to the raise; such a sale may also close as soon as its raise is full. Anyone can migrate a funded sale into a
new full-range Cetus or Bluefin pool, or a 50/50 Aftermath pool behind Aftermath's DAO-fee pool;
the same transaction pays Blast (or, on a sale that names a partner, holds Blast's fees for a
later pay call), the raise recipients, and the token recipients. Buyers then claim their tokens
and overflow refund. A sale that misses its raise, or that someone cancels once its liquidity
deadline passes unmigrated, refunds every commitment in full. After migration a
`presale_vault::Vault` holds the LP position (for Cetus, its LP-burn proof; for Aftermath, the
DAO-fee pool's owner cap, the LP coin itself being sent to `0x0`) and splits its trading fees
between Blast, the creator's fee recipients, and holder-reward rounds.

The package shares no code or state with Blast's bonding-curve launchpad, apart from the
`blast_partners` partner registry both use. Its upgrade capability is sealed for dependency-only
upgrades (`blast_presale::package_admin::PackageAdmin`), so venue dependencies can be relinked but
presale logic never changes. In this guide `SaleToken` is the sale's coin; the venue modules and
the vault call the same type `Meme`.

### Objects and authority

Shared singletons, created once at deployment (`PackageAdmin` by
`blast_presale::package_admin::wrap`, the others when the package is published):

- `fee_policy::FeePolicy`: Blast's current rates (`raise_bps`, `token_bps`, `lp_fee_meme_bps`,
  `lp_fee_quote_bps`, held in a `fee_policy::ProtocolFees`) that new sales snapshot, and the
  `destination` address every Blast payout goes to.
- `creation_policy::CreationPolicy`: the allowlists checked once, when a sale, or a vault without
  a presale, is created: Quote types, migrator witnesses, and Blast partners a sale may name.
- `blast_presale::venue_config::VenueConfig`: holds each Cetus sale's reserved pool-creation
  capability. Migration only borrows it; nothing removes it.
- `blast_presale::aftermath::PoolCreation<Lp, Meme, Quote>`: shared, one per Aftermath sale,
  created by `blast_presale::aftermath::finalize`; holds the Aftermath `CreatePoolCapV2` of the
  sale's fresh LP coin `Lp` and the sale's ID, so only that sale's migration can consume it.
- `blast_presale::package_admin::PackageAdmin`: holds the package's dependency-only upgrade cap.

Per-sale objects:

- `blast_presale::blast_presale::Presale<SaleToken, Quote>`: shared. It holds every commitment, the whole minted
  supply, and the sale's terms until migration or refund. It has `key` only, so it cannot be
  transferred: it must be shared in the transaction that creates it.
- `blast_presale::blast_presale::PresaleCap`: owned by the creator (key, store). It claims the vault's migration
  residuals and can be destroyed after a cancellation. It cannot change any sale term or move
  any commitment.
- `presale_vault::Vault<Meme, Quote>`: shared, created by a Cetus, Bluefin, or Aftermath
  migration or directly from its owner's position (see "Locking your own position without a
  presale"). It holds the LP position (Bluefin), the Cetus LP-burn proof (Cetus), or the DAO-fee
  pool's `OwnerCap` (Aftermath, whose LP coin is owned by `0x0`), the migration residuals, the
  holder-reward share of collected fees, and Blast's held LP fees on partnered sales. An
  Aftermath vault is also the address its DAO-fee pool pays fees to.
- `holder_rewards::Round<Meme, Quote>`: shared, one per published holder-reward round.
- A vesting schedule (`Vesting<T>` from the external, immutable `blast_fun_vesting` package):
  shared, one per vested payout. See "Claiming vested tokens".

Capabilities and who holds them:

| Object | Held by | Authorizes |
| --- | --- | --- |
| `blast_acl::AdminCap` granted a presale role | Blast operations | The calls of each role it holds; see the table below. |
| `blast_presale::blast_presale::PresaleCap` | Sale creator (or a vendor treasury) | `presale_vault::claim_migration_residuals`, `blast_presale::blast_presale::destroy_cap`. |
| `blast_partners::blast_partners::Partner` | Shared, managed in `blast_partners` | Read by the presale to pay a partner its cut of Blast's fees. |

Blast administers presales through the one shared Blast access-control list
(`blast_admin::blast_acl`), as it does its other packages. `blast_presale_domain` declares the presale's roles; an operator's
`blast_acl::AdminCap` granted a role calls `blast_acl::sign_in<Role>` with the shared
`blast_acl::ACL` in the same PTB and passes the returned `blast_acl::AdminWitness<Role>` by
reference. Each admin call names exactly one role in its signature:

| Role | Calls |
| --- | --- |
| `blast_presale_domain::FeeAdmin` | `fee_policy::set_fees`, `blast_presale::blast_presale::set_protocol_fees`, `presale_vault::set_protocol_lp_fees`, `creation_policy::add_partner`, `creation_policy::remove_partner` |
| `blast_presale_domain::TreasuryAdmin` | `fee_policy::set_destination` |
| `blast_presale_domain::ListingAdmin` | `creation_policy::set_quote_allowed` |
| `blast_presale_domain::AdapterAdmin` | `creation_policy::set_migration_witness_allowed` |
| `blast_presale_domain::RewardsAdmin` | `holder_rewards::publish_round` |
| `blast_presale_domain::UpgradeAdmin` | `blast_presale::package_admin::authorize_upgrade`, `blast_presale::package_admin::commit_upgrade` |

A role from another package, such as `blast_fun_domain::FeeAdmin`, is a different type and
cannot reach these calls. No admin can pause a sale, cancel it, move commitments, change windows, recipients, or the fee split. Its
power over a live sale is limited to: its Blast rates before the window starts, its vault's Blast
LP-fee rates (anything from 0 to 10,000 BPS), the fee destination, and how the vault's
holder-reward share is distributed.

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
| `Open` | From `share` until `settle` | Before `start_ms`: `blast_presale::blast_presale::set_protocol_fees` (admin). From `start_ms` until `end_ms`: commits. From `end_ms`, or earlier once the raise is full under a hard cap that closes the sale when filled: `blast_presale::blast_presale::settle` |
| `Funded` | After a settle that met the raise | Migration at any time; `blast_presale::blast_presale::cancel_unlaunched` from the LP deadline |
| `Migrated` | After migration | `blast_presale::blast_presale::claim` (tokens + overflow refund), `blast_presale::blast_presale::pay_protocol_fees_with_partner` once on a partnered sale |
| `Cancelled` | After an underfunded settle or `cancel_unlaunched` | `blast_presale::blast_presale::claim` (full refund), `blast_presale::blast_presale::destroy_cap` |

Migration and cancellation race once the LP deadline passes: whichever transaction lands first
wins. Nobody can withdraw a commitment while the sale is `Open` or `Funded`.

### Flows

PTB conventions used below: `Clock` is the shared object `0x6`. Values such as `Bps`,
`RecipientShare`, and `EligibilityPolicy` are structs, so build them with Move calls and pass the
results; plain numbers, booleans, addresses, and `vector<u8>` go in as pure inputs. Build a
`vector<RecipientShare>` with the PTB `MakeMoveVec` command (it may be empty).

#### Creating a sale

A sale is created in one PTB in three stages, the same shape as the launchpad's
`LaunchInitializer`: a venue migrator's `new` starts it and returns a
`blast_presale::blast_presale::PresaleInitializer<Meme, Quote>`; setters on the initializer record
the creator's terms; `blast_presale::blast_presale::finalize` checks them all together, mints the
supply, and returns the pending `Presale`, which `share` publishes. The initializer has no
abilities: `finalize` is the only way to consume it, so the PTB must finalize it.

Creators call a venue migrator's `new`, never `blast_presale::blast_presale::new` directly: that call needs the
migrator's witness, which only the migrator's module can construct. The venue is fixed for good
at creation. Who may call: *anyone* who owns a zero-supply `TreasuryCap<SaleToken>` and the
matching shared Coin Registry `Currency<SaleToken>`, for a Quote type and migrator the
`CreationPolicy` allows. Every setter and `finalize` take the initializer value from that PTB, so
only its creator can call them.

Value constructors (*anyone*, pure):

- `blast_presale::bps::new(value)` builds each rate; it aborts with
  `blast_presale::bps::EInvalidBps` above 10,000.
- `blast_presale::blast_presale::vesting_terms(cliff_ms, period_ms, periods)` returns a
  `blast_presale::blast_presale::VestingTerms`.
- `blast_presale::blast_presale::recipient_share(recipient, bps)` or
  `blast_presale::blast_presale::vested_recipient_share(recipient, bps, terms)` build one share. Gather them with
  `MakeMoveVec` into three lists: token recipients, raise recipients, and LP-fee recipients.
- `blast_presale::blast_presale::open_eligibility(wallet_cap, max_participants, min_commitment)` or
  `blast_presale::blast_presale::allowlisted_eligibility(root, leaf_count)` build the eligibility policy.
- `blast_presale::blast_presale::uncapped_for_eligible(starts_after_ms)` or
  `blast_presale::blast_presale::uncapped_for_anyone(starts_after_ms, max_participants, min_commitment)` build an
  uncapped phase.
- `blast_presale::blast_presale::fee_split(fee_recipients, holder_rewards_bps)` builds the LP-fee split.

Steps, type arguments `<Meme, Quote>` throughout:

1. Start the sale:
   - Cetus: `blast_presale::cetus::new(treasury_cap, creation_policy, fee_policy, venue_config,
     cetus_config, pools, tick_spacing)`. It mints the coin's Cetus `PoolCreationCap` from the
     treasury cap, registers the `<Meme, Quote>` pair at `tick_spacing`, and stores the cap in
     `VenueConfig` under `blast_presale::cetus::CreationCapKey`. It records the tier, the tick
     spacing and the fee rate Cetus sets for it, in `VenueConfig` (below). Cetus aborts if it has no fee tier for
     the tick spacing or refuses the pair (the Quote must be in Cetus's permission-pair allowlist
     at that tick spacing).
   - Bluefin: `blast_presale::bluefin::new(treasury_cap, currency, creation_policy, fee_policy,
     venue_config, tick_spacing, pool_fee_rate)`. Tick spacing must be 1..=400 and the fee rate
     1..=20,000 in Bluefin's fee unit (`blast_presale::bluefin::EInvalidTier`); the coin's symbol
     must be at most 32 bytes (`blast_presale::bluefin::ESymbolTooLong`). It records the tier in
     `VenueConfig` (below).
   - Aftermath: `blast_presale::aftermath::new<Meme, Quote>(treasury_cap, creation_policy,
     fee_policy, venue_config, dao_fee_bps)`. `dao_fee_bps` is the DAO fee the pool charges on
     every swap, deposit, and withdrawal and pays to the sale's vault, 1..=10,000 BPS
     (`blast_presale::aftermath::EInvalidDaoFee`); it is the sale's tier, recorded in
     `VenueConfig` (below) with tick spacing 0. The pool's weights and base fee are the module's
     constants (50/50, flatness 0, a 0.01% base swap-in fee). The call returns the
     `PresaleInitializer`, which only `blast_presale::aftermath::finalize` (step 4) can finalize
     usefully: it takes the pool-creation capability and reserves the sale's pool. Beforehand,
     in its own transaction, publish a fresh Aftermath LP coin `Lp` (one per sale, through
     Aftermath's `publish-lp-coin` flow); its publication yields that `CreatePoolCapV2`.

   The pool tier belongs to the venue, not the sale: the `Presale` and `PresaleCreated` carry
   none, and a venue without a tier, such as a vendor's weighted pool, passes none. Cetus and
   Bluefin record a `blast_presale::venue_config::PoolTier` under
   `blast_presale::venue_config::PoolTierKey<Meme>` (each sale token has exactly one sale) and
   emit `blast_presale::venue_config::PoolTierReserved<Meme, Quote, Venue>`, whose third type
   argument is `blast_presale::cetus::Venue`, `blast_presale::bluefin::Venue`, or
   `blast_presale::aftermath::Venue` (tick spacing 0, fee rate the DAO fee in BPS). All three
   then check the `CreationPolicy`, that the sale coin differs from Quote, and that the treasury
   cap has minted nothing; snapshot Blast's current rates from the `FeePolicy`; and return the
   `PresaleInitializer`.
2. Required setters, each taking the initializer by mutable reference:
   - `blast_presale::blast_presale::set_supply(initializer, token_supply, burnable)`.
   - `blast_presale::blast_presale::set_token_allocations(initializer, token_allocation_bps,
     liquidity_token_allocation_bps, recipient_allocations)`.
   - `blast_presale::blast_presale::set_raise(initializer, raise_target, raise_allocations)`.
   - `blast_presale::blast_presale::set_windows(initializer, duration_ms, liquidity_window_ms)`.
   - `blast_presale::blast_presale::set_eligibility(initializer, eligibility)`.
   - `blast_presale::blast_presale::set_fee_split(initializer, fee_split)`.
3. Optional setters:
   - `blast_presale::blast_presale::set_participant_vesting(initializer, vesting)`: each buyer's tokens vest from
     that buyer's claim. Without it, claims pay tokens out at once.
   - `blast_presale::blast_presale::set_uncapped_phase(initializer, phase)`: lifts wallet caps from the phase's
     start. Without it, caps hold for the whole window.
   - `blast_presale::blast_presale::set_hard_cap(initializer, starts_after_ms, closes_when_filled)`: holds the
     sale to its raise from that point (below). Without it, the sale overflows for its whole window.
   - `blast_presale::blast_presale::set_partner(initializer, creation_policy, partner, clock)`: names a
     `blast_partners::blast_partners::Partner` the `CreationPolicy` currently accepts. This is the only
     time a partner can be named.

   A setter called twice keeps its last value.
4. `blast_presale::blast_presale::finalize(initializer, currency)` checks every setting together, mints the supply,
   consumes the `TreasuryCap`, and returns `(Presale<Meme, Quote>, PresaleCap)`. The Coin Registry
   supply becomes `Fixed`, or `BurnOnly` when `burnable` is true. Emits
   `blast_presale::blast_presale::PresaleCreated`. An Aftermath sale calls
   `blast_presale::aftermath::finalize<Lp, Meme, Quote>(initializer, currency, create_pool_cap)`
   instead, with the `CreatePoolCapV2` of its LP coin `Lp` by value. It aborts with
   `blast_presale::aftermath::EWrongMigrator` unless `blast_presale::aftermath::new` started the
   initializer, runs the same finalization, then shares the
   `blast_presale::aftermath::PoolCreation<Lp, Meme, Quote>` bound to the new sale's ID and emits
   `blast_presale::aftermath::PoolCreationReserved` (`presale_id`, `pool_creation_id`,
   `create_pool_cap_id`). An Aftermath sale finalized through
   `blast_presale::blast_presale::finalize` instead has no reservation, can never migrate, and
   refunds after its liquidity deadline.
5. Optional, Blast admin only (`FeeAdmin`): `blast_presale::blast_presale::set_protocol_fees` on the pending sale.
6. `blast_presale::blast_presale::share(presale, start_ms, clock)`, same caller, fixes the windows and shares the
   sale. The start is `max(start_ms, now)`, so a sale can be published ahead of its start. Emits
   `blast_presale::blast_presale::PresaleOpened`.
7. `TransferObjects([presale_cap], creator)`.

Settings:

| Setting | Meaning and rule |
| --- | --- |
| `token_supply` | Whole supply in atomic units, > 0. |
| `burnable` | `true`: supply becomes burn-only; `false`: fixed. |
| `token_allocation_bps` | Buyers' share of the supply, > 0. |
| `liquidity_token_allocation_bps` | Tokens seeded into the pool, > 0. |
| `recipient_allocations` | Up to 64 token recipients, distinct nonzero addresses, each > 0 BPS, optionally vested. Buyers + LP + Blast's token rate + recipients = exactly 10,000 BPS. |
| `participant_vesting` | Optional `VestingTerms` for every buyer's tokens. |
| `raise_target` | Quote the sale must raise, atomic units, > 0. |
| `raise_allocations` | Up to 64 raise recipients paid in Quote at migration, optionally vested. Their BPS plus Blast's raise rate must stay below 10,000; the LP keeps the rest. |
| `duration_ms` | Commitment window length, > 0. |
| `liquidity_window_ms` | Time after the window before anyone may cancel an unmigrated funded sale; at least 7 days. |
| `eligibility` | `EligibilityPolicy::Open` or `EligibilityPolicy::Allowlisted` (below). |
| uncapped phase | Optional `blast_presale::blast_presale::UncappedPhase` (below). |
| hard cap | Optional `starts_after_ms` and `closes_when_filled` (below). |
| `fee_split` | `blast_presale::blast_presale::FeeSplit`: up to 16 unvested, distinct LP-fee recipients plus a holder-reward share, totalling exactly 10,000 BPS. The creator takes LP fees by listing itself as a recipient. An empty list with 10,000 holder BPS is valid. |
| `tick_spacing`, `pool_fee_rate` | Pool tier, given to the venue's `new` and kept in `VenueConfig`. Cetus derives the fee rate from the tick spacing. |

A setting never set is zero (supply, raise, window lengths, token BPS), so `finalize` rejects it
with that setting's error. A missing eligibility policy or LP-fee split aborts with
`EMissingSetting`.

Eligibility policies (`blast_presale::blast_presale::EligibilityPolicy`):

- `Open { wallet_cap, max_participants, min_commitment }`: every wallet has the same cap; at most
  `max_participants` distinct wallets (1..=65,536); each wallet's total must reach
  `min_commitment` (0 < min <= cap). `min_commitment × max_participants` must reach the raise
  (`EUnreachableRaise`), so dust wallets cannot fill every slot and block the sale.
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
`duration_ms`, `EInvalidHardCap`), a commitment takes only what is left of the raise and returns
the excess at once; when the raise is full, commitments abort with `EPresaleFilled`. Before that
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

`finalize` aborts unless the LP's tokens and Quote give a seed price both venues can pool
(`EUnseedablePrice`; see Economics).

#### Committing

Who may call: *anyone* the policy admits. The commitment is always credited to the transaction
sender, so a relayer cannot commit for someone else. Each commit returns a `Coin<Quote>`: the part
a hard cap could not accept, or a zero coin. It has no `drop`, so the PTB must transfer it (or
destroy a zero coin).

1. `coin = SplitCoins(source, [amount])`, where `source` is a `Coin<Quote>` the sender owns (the
   gas coin when Quote is SUI and the sender pays gas; under sponsored gas the gas coin is the
   sponsor's).
2. One of, with type arguments `<SaleToken, Quote>`:
   - `blast_presale::blast_presale::commit_open(presale, coin, clock)` under an open policy.
   - `blast_presale::blast_presale::commit_allowlisted(presale, coin, index, wallet_cap, proof, clock)` under an
     allowlist; `proof` is a `vector<vector<u8>>`. Also used by allowlisted wallets during an
     uncapped phase (the proof is still checked; the cap no longer limits).
   - `blast_presale::blast_presale::commit_uncapped(presale, coin, clock)` once a phase open to anyone has
     started.
3. `TransferObjects([returned_coin], sender)`.

Each commit emits `blast_presale::blast_presale::Committed`. Rules:

- The window is `start_ms <= now < end_ms`.
- A wallet's first commit takes a participant slot; later commits top it up by any positive
  amount. The minimum applies to the wallet's total after the commit, so the first commit must
  reach it. The commit that exactly fills a hard cap may be below the minimum.
- Before the uncapped phase, the wallet's total must stay within its cap. The cap a wallet first
  committed under is stored with its commitment; under an allowlist, later commits must present
  the same cap (`EInvalidEligibilityProof`).
- Under an open policy, `commit_open` keeps working in either uncapped phase: caps are lifted,
  its minimum still applies, and an anyone-phase uses the phase's participant bound.

#### Allowlist proofs

Leaf digest, for the wallet at position `index` with cap `wallet_cap`:

```
leaf = blake2b256( b"\x00blast-presale-v1"            // 0x00 then the ASCII bytes
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

Who may call: *anyone*. `blast_presale::blast_presale::settle(presale, clock)` while `Open`, once either:

- `now >= end_ms`; or
- the sale closes early: its hard cap has `closes_when_filled`, the hard cap is in force
  (`now >= start_ms + hard cap starts_after_ms`), and `total_commitments >= raise_target`. The
  sale can then take no more Quote.

If total commitments reach the raise the sale becomes `Funded` and emits
`blast_presale::blast_presale::PresaleFunded`; otherwise it becomes `Cancelled` and emits
`blast_presale::blast_presale::PresaleCancelled`. Closing early ends the window at the settle: the
stored `duration_ms` becomes the time the sale ran, so `end_ms` and the LP deadline count from the
close. `PresaleFunded` carries both. A sale without a hard cap never closes early.

Closing early and migrating can run in one PTB: `settle`, then the venue's `migrate`. Because
migration is permissionless, the wallet whose commitment fills the raise can also commit, settle,
migrate, and buy from the new pool in one transaction. The pool's seed price is the same either
way; creators who want a public start choose `closes_when_filled = false`.

#### Migrating to Cetus

Who may call: *anyone*, while `Funded`, until someone cancels. Usually one keeper PTB:

1. `blast_presale::blast_presale::settle(presale, clock)` if not yet settled.
2. `blast_presale::cetus::migrate<Meme, Quote, CoinA, CoinB>(sale, fee_policy, venue_config,
   cetus_config, pools, burn_manager, clock)`. `CoinA` and `CoinB` are the
   sale's two types in Cetus's canonical order: the order Cetus's own `is_right_order` check (in
   its `factory` module) accepts. Find it by dev-inspecting either order; the wrong order aborts
   with `blast_presale::cetus::EInvalidCoinOrder`, and a pair that is not exactly the sale's two
   types aborts with `blast_presale::cetus::EWrongCoinPair`. Shared objects: the presale
   (`sale`), `FeePolicy`, `VenueConfig` (read), Cetus `GlobalConfig` (`cetus_config`, read),
   Cetus `Pools` (mutable), and the Cetus LP-burn `BurnManager` (mutable).
3. On a partnered sale, `blast_presale::blast_presale::pay_protocol_fees_with_partner(presale, fee_policy,
   partner, clock)`.

Migration calls `blast_presale::blast_presale::migrate`, which pays Blast (or holds its fees on a partnered
sale), pays or vests each raise recipient, pays or vests each token recipient, and returns the
LP's tokens and Quote. The adapter creates the pool with the reserved `PoolCreationCap` at the
tick spacing `new` recorded in `VenueConfig`, seeds a full-range position at the price the LP balances imply, burns the
position through Cetus LP-burn for its fee-claiming proof, and shares a new `Vault` holding
that proof and whatever the pool did not take. Nothing returns to the caller. Any venue failure
rolls the whole transition back.

#### Migrating to Bluefin

Who may call: *anyone*, while `Funded`, until someone cancels.

1. `blast_presale::blast_presale::settle(presale, clock)` if not yet settled.
2. `creation_fee = SplitCoins(GasCoin, [amount])`, where `amount` is the fee amount (the `u64` in
   the `(bool, u64)` pair) that Bluefin's `get_pool_creation_fee_amount<SUI>` (its `config`
   module) returns at submission time; Bluefin rejects another amount.
3. `blast_presale::bluefin::migrate<Meme, Quote>(sale, fee_policy, venue_config, currency,
   quote_currency, bluefin_config, creation_fee, clock)`. `venue_config` is the shared
   `VenueConfig` (read for the tier `new` recorded). `currency` and `quote_currency` are the
   shared Coin Registry `Currency<Meme>` and `Currency<Quote>` (read for both symbols and decimals
   and the Quote's icon URL); the Bluefin `GlobalConfig` (`bluefin_config`) is mutable.
4. On a partnered sale, `blast_presale::blast_presale::pay_protocol_fees_with_partner(...)`.

The adapter creates the pool `Pool<Meme, Quote>` (Meme is always coin A) named
`<Meme symbol>-<Quote symbol>` at the recorded tier, opens a full-range position aligned inward to
the tick spacing, adds the LP balances, moves the position into a new shared `Vault`, and
shares the pool.

#### Migrating to Aftermath

Who may call: *anyone*, while `Funded`, until someone cancels.

1. `blast_presale::blast_presale::settle(presale, clock)` if not yet settled.
2. `blast_presale::aftermath::migrate<Lp, Meme, Quote>(sale, pool_creation, fee_policy,
   venue_config, pool_registry, dao_fee_version, clock)`. `pool_creation` is the sale's shared
   `PoolCreation<Lp, Meme, Quote>`, passed by value and deleted; another sale's aborts with
   `blast_presale::aftermath::EWrongPresale` before anything else. `venue_config` is the shared
   `VenueConfig` (read for the DAO fee `new` recorded); `pool_registry` is Aftermath's shared
   `PoolRegistry` (mutable); `dao_fee_version` is the DAO-fee package's shared `Version`. The
   module sorts the coins into Aftermath's order itself.
3. On a partnered sale, `blast_presale::blast_presale::pay_protocol_fees_with_partner(...)`.

The adapter runs `blast_presale::blast_presale::migrate`, creates the pool from all LP tokens
and Quote (50/50 weights, flatness 0, a 0.01% swap-in fee that compounds into the LP, no other
pool fees, name "Blast Presale Pool"), checks it holds every unit
(`blast_presale::aftermath::EPoolMismatch`), builds the `Vault` with no position yet, wraps the
pool in a DAO-fee pool at the recorded `dao_fee_bps` whose fee recipient is the vault's ID
(`blast_presale::aftermath::EDaoFeePoolMismatch` if Aftermath reports anything else), attaches
the DAO-fee pool's `OwnerCap` as the vault's position with the LP coin's amount (the pool's whole
liquidity) as its `liquidity`, shares the vault, shares the DAO-fee pool (the object traders
use), and sends the LP coin to `0x0`, where nobody can ever use it. Emits
`blast_presale::aftermath::DaoFeePoolCreated` with the vault, base pool, DAO-fee pool, owner cap,
and LP coin IDs before `presale_vault::VaultCreated`, whose `pool_id` is the base pool and
`position_id` the owner cap. Nothing in the package borrows or removes the owner cap, so the fee
or its recipient cannot be changed, and the liquidity is locked for good. If the
`CreatePoolCapV2` belongs to a different LP coin than `Lp`, or Aftermath retires the versions
this package links to, migration aborts and the sale becomes refundable at its LP deadline.

#### Locking your own position without a presale

Who may call: *anyone*, with their own position. A team that adds liquidity to Cetus or Bluefin
itself, without a presale, can lock that position for good in a `Vault`, which then splits
its LP fees exactly as a migrated sale's vault does: Blast's LP-fee share first, then the team's
`FeeSplit` between its fee recipients and holder-reward rounds.

1. Create the pool and open and fund the position with the venue's own calls; keep whatever the
   venue did not take.
2. `fee_split = blast_presale::blast_presale::fee_split(...)`, as for a presale.
3. Cetus: `blast_presale::cetus::new_vault<Meme, Quote, CoinA, CoinB>(position,
   fee_split, partner_id, creation_policy, fee_policy, pool, burn_manager, clock)`, where `pool` is the
   `Pool<CoinA, CoinB>` holding the position (read) and `CoinA` and `CoinB` are Meme and Quote in
   the pool's order. The position is burned through Cetus LP-burn for its fee-claiming proof,
   which Cetus's `BurnManager` (mutable) issues only for positions it accepts.
   Bluefin: `blast_presale::bluefin::new_vault<Meme, Quote>(position, fee_split, partner_id,
   creation_policy, fee_policy, pool, clock)`, where `pool` is the `Pool<Meme, Quote>` holding the
   position (read); a pool whose first coin is not Meme is not supported.

The `CreationPolicy` must allow Quote and the venue's migrator witness, the same check a presale
passes. The vault snapshots the `FeePolicy`'s current LP-fee rates. It names no presale: its
`presale_id` and `presale_cap_id` are the zero ID, so no `PresaleCap` claims from it, and it holds
no residuals. `partner_id` (an `Option<ID>`) optionally names a Blast partner, which the
`CreationPolicy` must accept now (`creation_policy::EPartnerNotAccepted` otherwise) and the vault
keeps for good; Blast's LP fees are then held for `presale_vault::pay_protocol_lp_fees_with_partner`,
as on a partnered sale's vault, and the partner earns only its cut of them. A position from another pool aborts with
`blast_presale::cetus::EPositionPoolMismatch` or `blast_presale::bluefin::EPositionPoolMismatch`;
a position with no liquidity aborts with `presale_vault::EZeroLiquidity`. Fees are then collected
with the venue's `collect_fees`, and holder-reward rounds work as for any vault.

#### Paying a partnered sale's Blast fees

Who may call: *anyone*, once, after migration. `blast_presale::blast_presale::pay_protocol_fees_with_partner(presale,
fee_policy, partner, clock)` takes the Blast raise fee the migration held, pays the partner its
cut through `blast_partners::blast_partners::pay`, then pays Blast the rest of the raise fee and its whole token
fee at the `FeePolicy`'s current destination. Emits `blast_partners::blast_partners::PartnerPaid` (when the cut is
positive) and `blast_presale::blast_presale::ProtocolFeesPaid`. The partner is paid as an owned coin at its
recipient address using `public_transfer`.

#### Claiming tokens and refunds

Who may call: *anyone* may relay; payment always goes to `participant`.
`blast_presale::blast_presale::claim(presale, participant, clock)` while `Migrated` or `Cancelled`. Batch many
claims in one PTB. It removes the wallet's commitment record, so each wallet claims once.

- `Migrated`: pays the wallet's pro-rata tokens and its share of the overflow refund.
- `Cancelled`: pays back the full commitment; no tokens.
- With participant vesting, the tokens go into a new shared, irrevocable schedule for the
  participant that starts at this claim; the Quote refund is always paid at once. A claim whose
  token amount is zero creates no schedule.

Emits `blast_presale::blast_presale::Claimed` with `tokens`, `quote_refund`, `remaining_participants`, and
`vesting_id`.

#### Claiming vested tokens

Vested raise shares (Quote) and token shares start at migration; vested participant tokens start
at the participant's claim. Each schedule is a shared `Vesting<T>` from the immutable
`blast_fun_vesting` package, with a fixed beneficiary and no cancellation authority. Find its ID
in the `vesting_id` field of `blast_presale::blast_presale::RaiseAllocated`, `blast_presale::blast_presale::RecipientAllocated`,
or `blast_presale::blast_presale::Claimed`.

- Claim: `blast_fun_linear_vesting::claim<T>(vesting, clock)`. *Anyone* may call; it transfers all
  newly vested value to the beneficiary as a coin and aborts with
  `blast_fun_linear_vesting::ENothingClaimable` when nothing new has vested.
- Vested amount at time `t`: zero before `start + cliff_ms`; the whole amount from
  `start + period_ms × periods`; otherwise `floor(total × floor((t − start) / period_ms) / periods)`.
  The cliff only gates: once it passes, every whole period since the start counts.
- `blast_fun_linear_vesting::close_irrevocable<T>(vesting)` deletes a drained schedule; anyone.

#### Cancelling an unlaunched sale and refunds

Who may call: *anyone*. `blast_presale::blast_presale::cancel_unlaunched(presale, clock)` once `now >=
end_ms + liquidity_window_ms` while `Funded`. The sale becomes `Cancelled` and emits
`blast_presale::blast_presale::PresaleCancelled`. Every wallet then claims a full refund with
`blast_presale::blast_presale::claim`. A sale nobody settled can be settled and cancelled in one PTB after the
LP deadline. All minted tokens stay locked in the cancelled sale forever.

#### Collecting LP fees

Who may call: *anyone*. Each collection pays Blast (or, on a partnered vault, holds Blast's part)
and every fee recipient at once. It pays the holder Meme remainder to the governed
`FeePolicy` destination and retains holder Quote in the vault. Shared objects only; nothing returns.

- Cetus: `blast_presale::cetus::collect_fees<Meme, Quote, CoinA, CoinB>(vault, fee_policy,
  cetus_config, burn_manager, pool)` where `pool` is the vault's
  `Pool<CoinA, CoinB>` (same coin order as migration; another pool aborts with
  `blast_presale::cetus::EPositionPoolMismatch`).
- Bluefin: `blast_presale::bluefin::collect_fees<Meme, Quote>(vault, fee_policy, bluefin_config,
  pool, clock)` where `pool` is the vault's `Pool<Meme, Quote>`
  (`blast_presale::bluefin::EPositionPoolMismatch` otherwise).
- Aftermath: `blast_presale::aftermath::collect_fees<Meme, Quote>(vault, fee_policy, meme_fees,
  quote_fees)`. Aftermath pays the DAO fee of every swap, deposit, and withdrawal as a separate
  `Coin<Meme>` or `Coin<Quote>` sent to the vault's address, so the vault owns those coins.
  `meme_fees` and `quote_fees` are `vector<Receiving<Coin<Meme>>>` and
  `vector<Receiving<Coin<Quote>>>`: list the IDs of the coins the vault owns (query the vault
  address's owned objects) as PTB receiving inputs and gather each list with `MakeMoveVec`;
  either list may be empty. The call receives every listed coin into the vault, joins them, and
  splits the totals exactly as the other venues split a collected position's fees. A coin the
  vault does not own aborts in `sui::transfer`; a coin left unlisted waits for a later call.

Emits `presale_vault::FeesCollected`, followed by `presale_vault::HolderMemePaid`
when the holder Meme remainder is positive. The former records allocation; the latter
records payment and the remaining unallocated Meme. A collection of zero is valid and emits nothing. Neither
adapter collects venue incentive rewards.

On a partnered vault, follow with `presale_vault::pay_protocol_lp_fees_with_partner(vault,
fee_policy, partner, clock)`: *anyone*; it pays the partner its cut of each held asset and Blast
the rest, emitting `presale_vault::ProtocolLpFeesPaid` and `blast_partners::blast_partners::PartnerPaid`. Holding
nothing is valid and emits nothing, so it can follow every collection.

#### Migration residuals and the PresaleCap

- `presale_vault::claim_migration_residuals(vault, presale_cap)`: *cap holder* (`PresaleCap`).
  Returns `(Coin<Meme>, Coin<Quote>)` holding what the pool did not take when it was seeded;
  transfer both in the same PTB. Aborts with `presale_vault::ENoMigrationResiduals` when both are
  empty, so it works once. Emits `presale_vault::MigrationResidualsClaimed`.
- `blast_presale::blast_presale::destroy_cap(presale, presale_cap)`: *cap holder*, only when the sale is
  `Cancelled`. A migrated sale's cap cannot be destroyed.

#### Holder-reward rounds

The holder Quote share of LP fees accrues in the vault. Blast decides off chain
who receives holder assets and whether each round reimburses gas. A single
`holder_rewards::Round` holds its holder balances separately from its optional
Quote gas reserve.

1. `holder_rewards::publish_round`: *Blast admin* (`RewardsAdmin`). It takes the
   mutable shared vault, shared governed `FeePolicy`, expected treasury address,
   interval and commitments,
   exact holder Meme/Quote amounts, an explicit gas reserve amount, future
   deadline and Clock. The number is the vault's next round (starting at zero).
   The checkpoint interval is nonempty and starts at or after the previous
   round ended; skipped periods need no funded round or number. Root and
   manifest digest are 32 bytes, with 1..=65,536 leaves and a positive holder
   budget. Before funding, the expected treasury must equal the governed
   destination; `holder_rewards::ETreasuryChanged` rejects a policy change after
   planning or signing. Holder funding plus reserve must fit available balances.
   It snapshots the checked treasury and emits `holder_rewards::RoundPublished`. Zero reserve
   disables reimbursement for this round and requires no settlement. A positive
   reserve creates separate pending custody. Blast may cover gas and allocate
   the entire holder Quote budget to holder leaves.
2. `holder_rewards::claim`: *anyone* may relay. It takes the mutable shared
   round and beneficiary/amount proof and pays that beneficiary only, once
   per index. It emits `holder_rewards::RewardClaimed` and leaves gas custody
   untouched. Leaf:

   ```
   blake2b256( b"\x00blast-presale-holder-rewards-v1"
               || bcs(vault_id: ID)        // 32 bytes
               || bcs(round_number: u64) || bcs(index: u64)
               || bcs(beneficiary: address)
               || bcs(meme_amount: u64) || bcs(quote_amount: u64) )
   ```

   The proof follows the allowlist rules above (same node hash, positional
   order, exact depth). Claims have no deadline check: they last until close.
3. `holder_rewards::settle_gas_reserve`: *Blast admin* (`RewardsAdmin`). It takes
   the mutable shared round and its mutable shared vault and an amount from
   zero through an enabled reserve. It pays the publication-time treasury,
   returns all unused Quote to the vault and consumes settlement once.
   `holder_rewards::GasReserveSettled` records payment, return and remaining
   vault Quote. Disabled reimbursement and repeated settlement abort. The
   contract bounds custody; verified off-chain effects determine actual cost.
4. `holder_rewards::close_round`: *anyone*, once `now >= claim_deadline_ms`.
   It consumes the shared round and returns unclaimed holder assets and any
   unsettled reserve to the correct mutable vault. It emits
   `holder_rewards::RoundClosed` and deletes the round. Missing settlement
   authority cannot strand reserve. Elapsed time alone moves nothing.
   Closing before reimbursement leaves that cost with Blast.

#### Blast admin operations

Integrators cannot call these; they explain state changes. Each takes the
`blast_acl::AdminWitness` of the role listed in "Objects and authority" (*Blast admin*).

| Call | Effect |
| --- | --- |
| `fee_policy::set_fees` | Rates new sales snapshot. Raise rate < 10,000 BPS; token rate <= 9,998. Emits `fee_policy::FeesChanged`. |
| `fee_policy::set_destination` | Redirects every later Blast payout, existing sales included. Emits `fee_policy::DestinationChanged`. |
| `blast_presale::blast_presale::set_protocol_fees` | Replaces one sale's four rates in its creation PTB before `share` (`Pending`), or while `Open` and before `start_ms`. Emits `blast_presale::blast_presale::ProtocolFeesChanged`. |
| `presale_vault::set_protocol_lp_fees` | Replaces one vault's Blast LP-fee rates for later collections. Emits `presale_vault::ProtocolLpFeesChanged`. |
| `creation_policy::set_quote_allowed` | Allows or disallows a Quote type for later sales. Emits `creation_policy::QuoteSet`. |
| `creation_policy::set_migration_witness_allowed` | Allows or disallows a migrator witness for later sales; rejects primitives, vectors, and `0x1`/`0x2` types. Emits `creation_policy::MigrationWitnessSet`. |
| `creation_policy::add_partner` | Lets new sales name a partner at once (also cancels a pending removal). Emits `creation_policy::PartnerAdded`. |
| `creation_policy::remove_partner` | New sales may still name the partner for `blast_partners::blast_partners::delay_ms` (7 days). Sales that already name it keep paying it. Emits `creation_policy::PartnerRemoved`. |
| `holder_rewards::publish_round`, `holder_rewards::settle_gas_reserve` | See above. |
| `blast_presale::package_admin::authorize_upgrade`, `blast_presale::package_admin::commit_upgrade` | Dependency-only upgrades. |

`blast_presale::package_admin::wrap` seals the never-upgraded publication cap once, at deployment.

### Economics

All amounts are atomic units. All rates are BPS out of 10,000. `floor` rounds down.

#### Largest-remainder apportionment

Supply, raise, and every LP-fee split use one method. For shares `s_i` summing to 10,000 and a
total `X`: each share gets `floor(X × s_i / 10,000)`; the leftover units (fewer than the number of
shares) go one each to the shares with the largest remainder `(X × s_i) mod 10,000`; ties go to
the earlier share. Every unit lands in exactly one share.

- Supply, at creation, in order: buyers (`token_allocation_bps`), LP, Blast (`token_bps`), then
  token recipients in list order. Buyers, LP, and every recipient must get > 0
  (`EInvalidTokenAllocation`); Blast may get 0.
- Raise, at creation, in order: raise recipients, Blast (`raise_bps`), then the LP with
  `10,000 − recipients − Blast`. Every recipient and the LP must get > 0
  (`EInvalidRaiseAllocation`).
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
already overflowed before its hard cap started, the hard cap accepts nothing (`EPresaleFilled`)
and the earlier overflow fills pro rata as usual.

#### Blast's fees

Blast takes three fees, all from the sale's snapshot (`Presale.protocol_fees`), copied from
`FeePolicy` at creation. Later `fee_policy::set_fees` calls never touch existing sales. Nothing is
charged at creation, on commitment, on refund, or when a sale does not migrate.

- Raise fee: Blast's Quote, apportioned with the raise at creation, paid at migration. Overflow
  refunds are never charged.
- Token fee: Blast's tokens, apportioned with the supply at creation, paid at migration.
- LP fees: at each collection, Blast takes `ceil(gross × lp_fee_meme_bps / 10,000)` of the Meme
  and `ceil(gross × lp_fee_quote_bps / 10,000)` of the Quote (rounded up), at the vault's current
  rates. The vault starts with the sale's snapshot rates; `presale_vault::set_protocol_lp_fees`
  can change them later.
- Every payout goes to `FeePolicy.destination` as it is when paid.

Per-sale changes before the start (`blast_presale::blast_presale::set_protocol_fees`): a changed raise rate
becomes `floor(R × raise_bps / 10,000)` and takes from or gives to the LP's Quote; a changed token
rate becomes `floor(supply × token_bps / 10,000)` and takes from or gives to the buyers'
allocation `A`. A rate equal to the sale's current one keeps its current amount (the creation
amount unless an earlier change replaced it). Recipients keep their amounts. The
new amounts must leave the LP some Quote and the buyers some tokens, and the LP must still seed a
poolable price.

#### Partners

A sale may name one `blast_partners::blast_partners::Partner`, named on the initializer and fixed
at `finalize`. The partner earns a cut of Blast's raise fee and of Blast's LP fees, never of Blast's
token fee. The cut is
`floor(fee × share_bps / 10,000)` using the partner's share in force when paid (at most 8,000
BPS; Blast's changes to it take effect 7 days after being scheduled). Blast keeps the rest. On a
partnered sale, migration holds Blast's raise fee and tokens in the sale, and each collection
holds Blast's LP fees in the vault, until the two pay calls run.

#### LP-fee split

After Blast's LP fees, the rest of each asset is apportioned by largest remainder over the fee
recipients in order, then the holder-reward share. Ties favor fee recipients over holders and
earlier recipients over later ones. Recipients are paid as coins in the same transaction (a zero
amount sends nothing); holder Quote stays in the vault for rounds and holder Meme
is paid to the governed fee-policy destination. The split never changes
after creation.

#### Seed price bound

Creation (and any per-sale rate change) aborts with `EUnseedablePrice` unless the LP's Quote per
LP token, in atomic units, lies inside both venues' price range with a margin: roughly 2^-62 to
2^62 (about 2.2e-19 to 4.6e18). A huge raise against a tiny LP-token allocation, or the reverse,
fails this check.

### Time rules

All times are Unix milliseconds from `Clock`.

- `start_ms = max(requested start, time of share)`; `end_ms = start_ms + duration_ms`; LP deadline
  `= end_ms + liquidity_window_ms`; uncapped phase from `start_ms + starts_after_ms`, or `end_ms`
  when the sale has none; hard cap from `start_ms + starts_after_ms`. `share` aborts with
  `EInvalidWindow` if these overflow u64. An early close sets `end_ms` to the settle time, which
  moves the LP deadline forward too.
- Commits: allowed for `start_ms <= now < end_ms`. Before the start: `EPresaleNotStarted`. At or
  after the end: `EPresaleEnded`.
- Caps lift at `now >= uncapped start`.
- `blast_presale::blast_presale::set_protocol_fees`: in the creation PTB before `share`, or after it while
  `now < start_ms`. A sale shared with a start in the past can be repriced only in its creation PTB.
- `blast_presale::blast_presale::settle`: from `now >= end_ms`, at any later time, or earlier once the sale can close
  early.
- Migration: any time while `Funded`, including after the LP deadline, until someone cancels.
- `blast_presale::blast_presale::cancel_unlaunched`: from `now >= LP deadline`. The 7-day minimum means a funded
  sale stays migratable for at least a week after its end.
- Vesting starts at migration for recipients and at each claim for participants.
- `blast_presale::blast_presale::set_partner` needs `now < accepted_until_ms` for that partner.
- Hard cap: commitments are held to the raise from `now >= hard cap start`.
- Holder rounds: the deadline must be in the future at publish; claims work until close; close
  needs `now >= claim_deadline_ms`.

### Reading state

The package exposes no public read functions on its objects. Read object fields over RPC
(object content and dynamic fields), and use events for history.

`Presale<SaleToken, Quote>` fields:

- Lifecycle and timing: `lifecycle`, `start_ms` (zero until shared), `duration_ms` (the time the
  sale ran, once it closed early), `liquidity_window_ms`, `uncapped` (with `starts_after_ms`,
  `access`), `hard_cap` (with `starts_after_ms`, `closes_when_filled`).
- Raise progress: `raise_target`, `total_commitments`, `participants` (wallets that have
  committed and not yet claimed), `quote` (Quote held).
- Terms: `eligibility`, `token_allocation` (buyers' tokens), `participant_vesting`,
  `recipient_payouts` and `raise_payouts` (each recipient's exact amount and vesting),
  `fee_split`, `migration_witness` (the venue: the type name of
  `blast_presale::cetus::Witness`, `blast_presale::bluefin::Witness`,
  `blast_presale::aftermath::Witness`, or a vendor migrator's witness).
- Blast: `protocol_fees` (the snapshot), `protocol_quote`, `protocol_tokens`, `partner_id`,
  `unpaid_protocol_quote` (`some` only between a partnered migration and its pay call).
- Custody balances: `sale_tokens`, `liquidity_tokens`, `recipient_tokens`.

One wallet's commitment is a dynamic field on the presale's ID: name type
`blast_presale::blast_presale::CommitmentKey` (a positional struct wrapping the wallet address; BCS is the
32-byte address), value `blast_presale::blast_presale::Commitment` with `quote` and `wallet_cap`. The field is
absent before the first commit and after the claim.

Common answers:

- Is it open? `lifecycle == Open` and `start_ms <= now < start_ms + duration_ms`.
- Fill rate? `raise_target / total_commitments` once `total_commitments >= raise_target`.
- Has a wallet claimed? After `Migrated`/`Cancelled`, its commitment field is gone (and a
  `blast_presale::blast_presale::Claimed` names it).
- Preview a claim: apply the formulas in Economics to `token_allocation`, `total_commitments`,
  `raise_target`, and the wallet's `quote`; the last claimant gets the remainder.

Other objects:

- `FeePolicy`: `destination`, `fees`.
- `CreationPolicy`: `allowed_quotes` and `allowed_migration_witnesses` (sets of type names with
  original package IDs); accepted partners are dynamic fields keyed by
  `creation_policy::PartnerKey` (the partner's ID) whose `u64` value is the time the partner stops
  being accepted (the maximum u64 while accepted).
- `Vault`: `presale_id`, `presale_cap_id`, `pool_id`, `fee_split`, `protocol_fees`
  (current LP rates), `partner_id`, `unpaid_protocol_meme`, `unpaid_protocol_quote`,
  `migration_meme_residual`, `migration_quote_residual`, `holder_rewards_meme`,
  `holder_rewards_quote` (unallocated holder share), `next_round`, `last_checkpoint`. The position
  is a dynamic object field keyed by `presale_vault::PositionKey`; on Aftermath it is the DAO-fee
  pool's owner cap, and the vault's pending DAO fees are the coins owned by the vault's address.
- `Round`: `vault_id`, `number`, `claim_deadline_ms`, `root`, `leaf_count`, `meme`, `quote`,
  `claimed_bitmap` (leaf `i` is bit `i % 256` of word `i / 256`), `treasury`,
  and `gas_reserve`. A present gas balance is pending; `none` means disabled
  reimbursement or completed settlement. Publication and settlement events distinguish them.
- `Vesting<T>`: `balance`, `beneficiary`, `start_ms`, `cliff_ms`, `period_ms`, `periods`,
  `released`.

To find a sale's vault, read `presale_vault::VaultCreated` for its `presale_id`; a vault
created without a presale has the zero `presale_id`.

### Events

Sale events carry the type arguments `<SaleToken, Quote>`; vault and round events carry
`<Meme, Quote>`. Filter by the full generic type or by the emitting module. Payloads are emitted
directly (no envelope).

| Flow | Event | Indexer use |
| --- | --- | --- |
| Create | `blast_presale::venue_config::PoolTierReserved`, then `blast_presale::blast_presale::PresaleCreated`, then on Aftermath `blast_presale::aftermath::PoolCreationReserved` | The venue's pool tier (`tick_spacing`, `pool_fee_rate`; on Aftermath 0 and the DAO fee in BPS), typed `<Meme, Quote, Venue>` with the venue's marker; then all terms: supply split (BPS), recipients and vesting, raise split (BPS), window lengths, eligibility, uncapped phase, hard cap, `migration_witness`, fee split, Blast's snapshot rates and amounts, `treasury_cap_id`, `presale_cap_id`; then on Aftermath the reservation (`presale_id`, `pool_creation_id`, `create_pool_cap_id`), typed `<Lp, Meme, Quote>`. |
| Share | `blast_presale::blast_presale::PresaleOpened` | `start_ms`, scheduled `end_ms` and `liquidity_deadline_ms`, `uncapped_from_ms`, `hard_cap_from_ms` (`none` without a hard cap), `partner_id`. |
| Per-sale rates | `blast_presale::blast_presale::ProtocolFeesChanged` | New rates, Blast amounts, and new buyer `token_allocation`. |
| Commit | `blast_presale::blast_presale::Committed` | `quote` accepted, `wallet_commitment` (new total), `total_commitments`, `participants`. It has no wallet field: the wallet is the transaction sender. |
| Settle | `blast_presale::blast_presale::PresaleFunded` / `blast_presale::blast_presale::PresaleCancelled` | Funded: `accepted_quote`, `refundable_quote`, `token_allocation`, and the actual `end_ms` and `liquidity_deadline_ms`, earlier than `PresaleOpened`'s after an early close. Cancelled: total refundable. |
| Migrate | `blast_presale::blast_presale::ProtocolFeesPaid` (unpartnered), `blast_presale::blast_presale::RaiseAllocated` (per raise recipient), `blast_presale::blast_presale::RecipientAllocated` (per token recipient), `blast_presale::blast_presale::PresaleMigrated`, then on Aftermath `blast_presale::aftermath::DaoFeePoolCreated`, then `presale_vault::VaultCreated` | Payouts with `vesting_id`; LP amounts; vault, pool, and position IDs. The vault event's third type argument is `blast_presale::cetus::Venue`, `blast_presale::bluefin::Venue`, or `blast_presale::aftermath::Venue`. On Aftermath the vault's `pool_id` is the base pool, `position_id` the DAO-fee pool's owner cap, and the DAO-fee event adds the shared DAO-fee pool, owner cap, and LP coin (owned by `0x0`) IDs. |
| Partner pay | `blast_partners::blast_partners::PartnerPaid`, `blast_presale::blast_presale::ProtocolFeesPaid` | `partner_quote` is the partner's cut. |
| Claim | `blast_presale::blast_presale::Claimed` | `tokens`, `quote_refund`, `remaining_participants`, `vesting_id`. |
| Collect | `presale_vault::FeesCollected`, `presale_vault::HolderMemePaid` | Gross, Blast's part, per-recipient amounts aligned with the vault's recipients, holder share. `protocol_destination` is `none` when held for a partner. |
| Vault partner pay | `presale_vault::ProtocolLpFeesPaid` | Partner and Blast amounts per asset. |
| Vault without a presale | `presale_vault::VaultCreated` | Zero `presale_id` and residuals; pool, position, liquidity, fee split, and Blast's rates. |
| Residuals | `presale_vault::MigrationResidualsClaimed` | Amounts claimed. |
| Rounds | `holder_rewards::RoundPublished`, `holder_rewards::RewardClaimed`, `holder_rewards::GasReserveSettled`, `holder_rewards::RoundClosed` | Holder funding separate from optional gas reserve, snapshotted treasury, exact reimbursement and returns; zero reserve disables reimbursement. |
| Vesting | `VestingCreated`, `VestingClaimed` (from `blast_fun_vesting`) | Schedule terms and releases. |

Admin events are listed in "Blast admin operations".

### Aborts

Errors are Move clever errors: the abort names the module and constant, and the message explains
it. Common ones by flow (module `blast_presale` unless named):

- Start (`new`): `creation_policy::EQuoteNotAllowed` / `creation_policy::EMigrationWitnessNotAllowed`
  (ask Blast to list it); `EInvalidAssetPair` (sale coin equals Quote); `EInitialSupplyNotZero`;
  `blast_presale::bluefin::EInvalidTier`; `blast_presale::bluefin::ESymbolTooLong`;
  `blast_presale::aftermath::EInvalidDaoFee` (1..=10,000 BPS).
- Finalize: `EMissingSetting` (no eligibility policy or LP-fee split); `EInvalidRaiseTarget`
  (raise unset or zero); `EInvalidTokenAllocation` (BPS not exactly 10,000 with Blast's token rate, duplicate or zero
  recipient, more than 64, or a zero apportioned amount); `EInvalidRaiseAllocation` (no LP share
  left after Blast, duplicates, zero amounts); `EInvalidWindow` (zero duration or LP window under
  7 days); `EUnreachableRaise` (minimum × slots below raise); `EInvalidEligibilityPolicy`;
  `EInvalidUncappedPhase`; `EInvalidHardCap` (hard cap starts at or after the window's end);
  `EInvalidFeeSplit`; `EInvalidVestingTerms`; `EUnseedablePrice`.
- Partner: `creation_policy::EPartnerNotAccepted`.
- Share: `EInvalidLifecycle` (already shared); `EInvalidWindow`.
- Commit: `EPresaleNotStarted`, `EPresaleEnded` (check the window); `EZeroCommitment`;
  `EWrongEligibilityPolicy` (wrong commit function for the policy); `EInvalidEligibilityProof`
  (wrong index, cap, proof, sender, or a different cap than the wallet's first commit);
  `EWalletCapExceeded` (lower the amount, or wait for the uncapped phase);
  `EBelowMinimumCommitment` (first commit must reach the minimum); `EParticipantCapacityReached`;
  `EUncappedPhaseNotOpen` (no anyone-phase, or not started); `EPresaleFilled` (hard cap reached).
- Settle: `EPresaleNotEnded` (the window has not ended and the sale cannot close early);
  `EInvalidLifecycle` (already settled).
- Migrate: `EInvalidLifecycle` (not `Funded`: unsettled, underfunded, cancelled, or migrated);
  `EWrongMigrationWitness` (wrong venue); `blast_presale::cetus::EInvalidCoinOrder` (swap
  `CoinA`/`CoinB`); `blast_presale::cetus::EWrongCoinPair`;
  `blast_presale::aftermath::EWrongPresale` (pass the `PoolCreation` whose `presale_id` is the
  sale's); `blast_presale::aftermath::EPoolMismatch` and
  `blast_presale::aftermath::EDaoFeePoolMismatch` (Aftermath did not take every unit or did not
  record the vault as the recipient at the recorded fee; nothing to fix by retrying); venue aborts (Bluefin creation fee amount, an Aftermath `CreatePoolCapV2`
  of another LP coin).
- Collect (Aftermath): an abort in `sui::transfer` means a listed coin is not owned by the vault;
  list only the vault's own coins.
- Partner pay: `EWrongPartner`; `ENoPartnerPayout` (not migrated yet, or already paid).
  Vault: `presale_vault::EWrongPartner` (also on an unpartnered vault).
- Claim: `EInvalidLifecycle` (not `Migrated`/`Cancelled`); `ENoCommitment` (never committed or
  already claimed).
- Cancel: `ELiquidityDeadlineNotReached`; `EInvalidLifecycle` (not `Funded`).
- Cap: `EWrongPresaleCap`, `presale_vault::EWrongPresaleCap`;
  `presale_vault::ENoMigrationResiduals`; `EInvalidLifecycle` on `destroy_cap` before
  cancellation.
- Rounds: `holder_rewards::EInvalidIndex`, `holder_rewards::EAlreadyClaimed`,
  `holder_rewards::EInvalidProof`, `holder_rewards::EEmptyClaim`,
  `holder_rewards::EInvalidBeneficiary`, `holder_rewards::EWrongVault`,
  `holder_rewards::EClaimsStillOpen`. An overcommitted root aborts in the framework's balance
  split when the round runs out.
- Admin-only: `blast_acl::sign_in` aborts for a revoked `AdminCap` or one without the role;
  then `EPresaleStarted`,
  `EProtocolFeesUnchanged`, `fee_policy::EInvalidFees`, `fee_policy::EFeesUnchanged`,
  `fee_policy::EInvalidDestination`, `presale_vault::EProtocolLpFeesUnchanged`,
  `creation_policy::EAllowanceUnchanged`, `creation_policy::EInvalidMigrationWitness`, and the
  `holder_rewards` publish checks (`EWrongRound`, `EInvalidInterval`, `EInvalidCommitment`,
  `EInvalidLeafCount`, `EEmptyBudget`, `EInvalidClaimDeadline`).

### Pitfalls

- Start, set, `finalize`, and `share` in one PTB. The `PresaleInitializer` must be finalized and
  the `Presale` cannot be transferred, so a PTB that skips either step fails. The partner can be
  named only on the initializer.
- An early close needs a hard cap with `closes_when_filled`. A sale without a hard cap always
  runs to `end_ms`, even when it reached its raise on day one.
- Every commit returns a coin. Transfer it back to the sender, even when it is zero.
- Commits always credit the sender. Sponsored transactions work (the user stays the sender), but
  take Quote from the user's coins, not the sponsor's gas coin.
- A keeper PTB of `settle` then `migrate` aborts as a whole when the sale is underfunded
  (`settle` cancels, then `migrate` hits `EInvalidLifecycle`). Compare `total_commitments` with
  `raise_target` first and send `settle` alone when it falls short.
- Cetus calls need `CoinA`/`CoinB` in Cetus's order, both for `migrate` and for the pool type in
  `collect_fees`. Bluefin always has Meme as coin A. Aftermath takes `<Lp, Meme, Quote>` and
  orders the coins itself.
- Bluefin migration needs a `Coin<SUI>` of exactly Bluefin's current pool-creation fee.
- An Aftermath sale needs a fresh LP coin published before creation, must be finalized with
  `blast_presale::aftermath::finalize` (which takes the LP coin's `CreatePoolCapV2`; a sale
  finalized in `blast_presale` never migrates), and its DAO fees are not in a position: they sit
  as coins at the vault's address until someone
  lists them in `blast_presale::aftermath::collect_fees`. A collection that lists none is valid
  and emits nothing.
- Partnered sales and vaults hold Blast's fees until the pay calls run. Add
  `blast_presale::blast_presale::pay_protocol_fees_with_partner` after migration and
  `presale_vault::pay_protocol_lp_fees_with_partner` after each collection.
- The last claimant takes the rounding remainder. Show earlier previews as exact and the last one
  as "at least".
- Participant vesting starts when the claim lands, and anyone may relay a claim. Claiming late
  delays the schedule.
- The minimum commitment applies to a wallet's running total; top-ups below it are fine.
- `min_commitment × max_participants` must reach the raise; size the policy before creating.
- Holder-reward claims stop the moment anyone closes the round, which anyone may do from its
  deadline.
- A cancelled sale's tokens are locked forever and its supply is already fixed or burn-only; the
  coin type cannot run another sale.
- Payouts are pushed to recipients in the same transaction. If a regulated coin's issuer blocks a
  recipient, the paying transaction can abort: a blocked raise recipient can stall migration until
  the LP deadline, and a blocked fee recipient stalls that vault's collections.
- `Committed` has no wallet field; take the wallet from the transaction sender.

### Vendor migrators: the Aftermath DAO-pool presale

#### How a vendor migrator works

`blast_presale::blast_presale::new` and `blast_presale::blast_presale::migrate` are public. Any module can be a migrator if it
defines a `drop` witness struct only it can construct. It creates sales by calling
`blast_presale::blast_presale::new` with that witness; the sale records the witness type in `migration_witness`,
and only `blast_presale::blast_presale::migrate` called with the same witness type releases its liquidity
(`EWrongMigrationWitness` otherwise). `blast_presale::blast_presale::migrate` pays Blast, raise recipients, and
token recipients exactly as for Cetus and Bluefin, then returns the LP's `(Balance<SaleToken>,
Balance<Quote>)`, which the migrator must put into its venue in the same call. Blast must first
allow the witness with `creation_policy::set_migration_witness_allowed`; delisting it later never
blocks existing sales. Only the package's own Cetus, Bluefin, and Aftermath adapters create a
`Vault`, so a vendor sale has no vault: no Blast LP fees, no holder-reward rounds, and no
residual claims. Every other sale rule (eligibility, claims, refunds, LP deadline, the seed-price
check) applies unchanged.

#### `blast_aftermath_dao_presale`

A one-off, immutable package for one partner. Its sales migrate into a new 50/50 Aftermath
weighted pool wrapped in Aftermath's DAO-fee pool, which charges 2% on every swap, deposit, and
withdrawal and sends it straight to the partner treasury compiled into the module.

Objects:

- `blast_aftermath_dao_presale::blast_aftermath_dao_presale::Witness`: the sealed migrator witness.
- `blast_aftermath_dao_presale::blast_aftermath_dao_presale::AdminCap`: the vendor's own admin, sent to the publisher. Its one
  power is creating sales, through `new` and `finalize`. It is not Blast's `blast_acl::AdminCap`.
- `blast_aftermath_dao_presale::blast_aftermath_dao_presale::PoolCreation<Lp>`: shared; binds one sale to the Aftermath
  `CreatePoolCapV2` of a freshly published LP coin `Lp`.

Create (*cap holder*, `blast_aftermath_dao_presale::blast_aftermath_dao_presale::AdminCap`), one PTB:

1. Beforehand, in its own transaction, publish a fresh Aftermath LP coin `Lp` (one per sale); its
   publication yields the `CreatePoolCapV2` that the `AdminCap` holder passes in.
2. Build the arguments as for any sale (no fee split or tier).
3. `blast_aftermath_dao_presale::blast_aftermath_dao_presale::new<SaleToken, Quote>(admin_cap, treasury_cap,
   creation_policy, fee_policy)` calls `blast_presale::blast_presale::new` and returns the `PresaleInitializer`.
   Its pool's weights and fees are the module's constants, so it records no tier.
4. The `blast_presale::blast_presale` setters as for any sale (no LP-fee split needed), including the optional
   `blast_presale::blast_presale::set_partner`.
5. `blast_aftermath_dao_presale::blast_aftermath_dao_presale::finalize<Lp, SaleToken, Quote>(admin_cap, initializer,
   currency, create_pool_cap)` sets a fee split giving the treasury 10,000 BPS and holders 0
   (replacing any split set earlier), runs `blast_presale::blast_presale::finalize`, sends the `PresaleCap` to the
   treasury, shares the `PoolCreation<Lp>`, emits
   `blast_aftermath_dao_presale::blast_aftermath_dao_presale::PoolCreationReserved`, and returns the unshared `Presale`. A
   vendor sale finalized with `blast_presale::blast_presale::finalize` directly has no `PoolCreation`, so it
   can never migrate and refunds after its LP deadline. It aborts with
   `blast_aftermath_dao_presale::blast_aftermath_dao_presale::EWrongMigrator` when the initializer was started by another
   migrator (it reads `blast_presale::blast_presale::migration_witness`).
6. Optional `blast_presale::blast_presale::set_protocol_fees(...)` to change this sale's Blast rates, which needs
   Blast's presale `FeeAdmin` signed in within the same transaction; then
   `blast_presale::blast_presale::share(presale, start_ms, clock)`.

Migrate (*anyone*, while `Funded`):

1. `blast_presale::blast_presale::settle` if needed.
2. `blast_aftermath_dao_presale::blast_aftermath_dao_presale::migrate<Lp, SaleToken, Quote>(presale, pool_creation,
   fee_policy, pool_registry, dao_fee_version, clock)`. `pool_creation` is the sale's shared
   `PoolCreation<Lp>`, passed by value and deleted; `pool_registry` is Aftermath's shared
   `PoolRegistry` (mutable); `dao_fee_version` is the DAO-fee package's shared `Version`. Type
   arguments are always `<Lp, SaleToken, Quote>`; the module sorts the coins into Aftermath's
   order itself.
3. On a partnered sale, `blast_presale::blast_presale::pay_protocol_fees_with_partner(...)`.

The call checks the binding (`blast_aftermath_dao_presale::blast_aftermath_dao_presale::EWrongPresale`), runs
`blast_presale::blast_presale::migrate`, creates the pool from all LP tokens and Quote (50/50 weights, flatness
0, a 0.01% swap-in fee that compounds into the LP, no other pool fees, name "Blast Presale Pool"),
checks it holds every unit (`blast_aftermath_dao_presale::blast_aftermath_dao_presale::EPoolMismatch`), wraps it in a DAO-fee
pool at 200 BPS paying the treasury (`blast_aftermath_dao_presale::blast_aftermath_dao_presale::EDaoFeePoolMismatch`), shares
the DAO-fee pool (the object traders use), sends its `OwnerCap` to the treasury, and sends the
whole LP coin to `0x0`, where nobody can ever use it. Emits
`blast_aftermath_dao_presale::blast_aftermath_dao_presale::Migrated` with the pool, DAO-fee pool, owner cap, and LP coin IDs.

With the `OwnerCap` the treasury can change its pool's DAO fee or recipient directly through
Aftermath. The `PresaleCap` can only be destroyed after a cancellation. If the `CreatePoolCapV2`
belongs to a different LP coin than `Lp`, or Aftermath retires the versions this package links
to, migration aborts and the sale becomes refundable at its LP deadline.

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

**Who migrates a funded sale, and what if nobody does?** Anyone, through the venue chosen at
creation, at any time until the sale is cancelled. From the LP deadline (`end_ms +
liquidity_window_ms`, at least 7 days) anyone may call `blast_presale::blast_presale::cancel_unlaunched` instead,
which makes every commitment fully refundable.

**What does Blast charge?** A snapshot, taken at creation, of a raise rate, a token rate, and two
LP-fee rates. The raise and token fees are paid at migration; the LP-fee rates apply at each fee
collection, rounded up. Nothing is charged on commitments, refunds, or failed sales.

**Can Blast or the creator change a sale after it opens?** The creator cannot. Blast's
`FeeAdmin` can change the sale's four rates only before `start_ms` (including in its creation
transaction, before `share`), can redirect the fee
destination at any time, and after migration can change the vault's Blast LP-fee rates. Windows,
recipients, eligibility, and the fee split never change.

**How is an allowlist leaf built?** `blake2b256(0x00 || "blast-presale-v1" || u64 LE index ||
32-byte wallet || u64 LE cap)`. Internal nodes are `blake2b256(0x01 || left || right)`. The
proof is positional with exactly `ceil(log2(leaf_count))` siblings. The wallet must be the
transaction sender.

**How do vested tokens get released?** Each vested payout sits in its own shared `Vesting<T>`.
Anyone calls `blast_fun_linear_vesting::claim` on it, and newly vested value goes to the fixed
beneficiary. Nothing vests before the cliff; after it, whole periods since the start count.

**How does a partner get paid?** The creator names it with `blast_presale::blast_presale::set_partner` on the
initializer, before `finalize`. After migration, anyone calls `blast_presale::blast_presale::pay_protocol_fees_with_partner` once. After
each fee collection, anyone calls `presale_vault::pay_protocol_lp_fees_with_partner`. The partner
receives its current share of Blast's raise and LP fees, never of the token fee.

**Where is the liquidity, and can anyone withdraw it?** A Cetus position is burned through
Cetus LP-burn and the vault keeps only its fee-claiming proof. A Bluefin position, or an
Aftermath sale's LP coin and DAO-fee owner cap, sits in the vault, and no function in the package
removes or borrows it. Upgrades can only relink dependencies, so this cannot change. On the
Aftermath vendor route, the LP coin is sent to `0x0`.
