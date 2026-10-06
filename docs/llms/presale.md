## Presale

### What it is

`blast_presale` runs standalone overflow presales on Sui mainnet. A creator brings a new coin
with zero supply. The sale mints the whole supply once, splits it between buyers, the launch
pool, Blast, and named recipients, and gives up mint authority forever. Buyers commit a Quote coin
(for example SUI) during a fixed window. Commitments may exceed the raise target: everyone is then
filled at one common rate and the excess is refunded. Anyone can migrate a funded sale into a
new full-range Cetus or Bluefin pool; the same transaction pays Blast (or, on a sale that names a
partner, holds Blast's fees for a later pay call), the raise recipients, and the token recipients.
Buyers then claim their tokens and overflow refund. A sale that misses its raise, or that someone
cancels once its liquidity deadline passes unmigrated, refunds every commitment in full. After a
Cetus or Bluefin migration a `presale_vault::Vault` holds the LP position (for Cetus, its
LP-burn proof) and splits its trading fees between Blast, the creator's fee recipients, and
holder-reward rounds.

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
- `creation_policy::CreationPolicy`: the allowlists checked once, when a sale is created: Quote
  types, migrator witnesses, and Blast partners a sale may name.
- `blast_presale_admin::AdminRegistry`: records the one `blast_presale_admin::AdminCap` the package
  accepts.
- `blast_presale::venue_config::VenueConfig`: holds each Cetus sale's reserved pool-creation
  capability. Migration only borrows it; nothing removes it.
- `blast_presale::package_admin::PackageAdmin`: holds the package's dependency-only upgrade cap.

Per-sale objects:

- `blast_presale::blast_presale::Presale<SaleToken, Quote>`: shared. It holds every commitment, the whole minted
  supply, and the sale's terms until migration or refund. It has `key` only, so it cannot be
  transferred: it must be shared in the transaction that creates it.
- `blast_presale::blast_presale::PresaleCap`: owned by the creator (key, store). It claims the vault's migration
  residuals and can be destroyed after a cancellation. It cannot change any sale term or move
  any commitment.
- `presale_vault::Vault<Meme, Quote>`: shared, created by a Cetus or Bluefin migration or
  directly from its owner's position (see "Locking your own position without a presale"). It
  holds the LP position (Bluefin) or the Cetus LP-burn proof (Cetus), the migration residuals,
  the holder-reward share of collected fees, and Blast's held LP fees on partnered sales.
- `holder_rewards::Round<Meme, Quote>`: shared, one per published holder-reward round.
- A vesting schedule (`Vesting<T>` from the external, immutable `blast_fun_vesting` package):
  shared, one per vested payout. See "Claiming vested tokens".

Capabilities and who holds them:

| Object | Held by | Authorizes |
| --- | --- | --- |
| `blast_presale_admin::AdminCap` | Blast operations | Blast's rates and destination, per-sale rates before start, vault LP-fee rates, the creation allowlists, holder-reward rounds, dependency-only upgrades. Accepted only while `AdminRegistry` records its ID. |
| `blast_presale_admin::SuperAdminCap` | Blast cold storage | Only `blast_presale_admin::replace_admin_cap`, `blast_presale_admin::revoke_admin_cap`, and `blast_presale_admin::transfer_super_admin`. Key-only, so it moves only through that last call. |
| `blast_presale::blast_presale::PresaleCap` | Sale creator (or a vendor treasury) | `presale_vault::claim_migration_residuals`, `blast_presale::blast_presale::destroy_cap`. |
| `blast_partners::blast_partners::Partner` | Shared, managed in `blast_partners` | Read by the presale to pay a partner its cut of Blast's fees. |

Every `AdminCap` call also takes the shared `AdminRegistry` and aborts with
`blast_presale_admin::EInvalidAdminCap` unless the registry accepts that cap. The admin cannot
pause a sale, cancel it, move commitments, change windows, recipients, or the fee split. Its
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
| `Pending` | Only inside the creation PTB, before `share` | `blast_presale::blast_presale::set_partner`, `blast_presale::blast_presale::set_protocol_fees` (admin, when the creation PTB also holds the `AdminCap`), `blast_presale::blast_presale::share` |
| `Open` | From `share` until `settle` | Before `start_ms`: `blast_presale::blast_presale::set_protocol_fees` (admin). From `start_ms` until `end_ms`: commits. From `end_ms`: `blast_presale::blast_presale::settle` |
| `Funded` | After a settle that met the raise | Migration at any time; `blast_presale::blast_presale::cancel_unlaunched` from the LP deadline |
| `Migrated` | After migration | `blast_presale::blast_presale::claim` (tokens + overflow refund), `blast_presale::blast_presale::pay_protocol_fees_with_partner` once on a partnered sale |
| `Cancelled` | After an underfunded settle or `cancel_unlaunched` | `blast_presale::blast_presale::claim` (full refund), `blast_presale::blast_presale::destroy_cap` |

Migration and cancellation race once the LP deadline passes: whichever transaction lands first
wins. Nobody can withdraw a commitment while the sale is `Open` or `Funded`.

### Flows

PTB conventions used below: `Clock` is the shared object `0x6`. Values such as `Bps`,
`RecipientShare`, and `EligibilityPolicy` are structs, so build them with Move calls and pass the
results; plain numbers, booleans, addresses, and `vector<u8>` go in as pure inputs. Build an
`Option<VestingTerms>` or `Option<UncappedPhase>` with the Move standard library's `option`
module (`some` or `none`, with the struct type as type argument). Build a `vector<RecipientShare>`
with the PTB `MakeMoveVec` command (it may be empty).

#### Creating a sale

Creators call a venue migrator's `new`, never `blast_presale::blast_presale::new` directly: that call needs the
migrator's witness, which only the migrator's module can construct. The venue is fixed for good
at creation. Who may call: *anyone* who owns a zero-supply `TreasuryCap<SaleToken>` and the
matching shared Coin Registry `Currency<SaleToken>`, for a Quote type and migrator the
`CreationPolicy` allows.

Steps 1 to 6 are pure value constructors that *anyone* may call.

1. Build each rate with `blast_presale::bps::new(value)`; it aborts with
   `blast_presale::bps::EInvalidBps` above 10,000.
2. Optional vesting: `blast_presale::blast_presale::vesting_terms(cliff_ms, period_ms, periods)` returns a
   `blast_presale::blast_presale::VestingTerms`.
3. Shares: `blast_presale::blast_presale::recipient_share(recipient, bps)` or
   `blast_presale::blast_presale::vested_recipient_share(recipient, bps, terms)`. Gather them with `MakeMoveVec`
   into three lists: token recipients, raise recipients, and LP-fee recipients.
4. Eligibility: `blast_presale::blast_presale::open_eligibility(wallet_cap, max_participants, min_commitment)` or
   `blast_presale::blast_presale::allowlisted_eligibility(root, leaf_count)`.
5. Optional uncapped phase: `blast_presale::blast_presale::uncapped_for_eligible(starts_after_ms, hard_cap)` or
   `blast_presale::blast_presale::uncapped_for_anyone(starts_after_ms, max_participants, min_commitment,
   hard_cap)`, wrapped in `some`; otherwise `none`.
6. Fee split: `blast_presale::blast_presale::fee_split(fee_recipients, holder_rewards_bps)`.
7. Create, with type arguments `<Meme, Quote>`:
   - Cetus: `blast_presale::cetus::new(treasury_cap, currency, token_supply, token_allocation_bps,
     participant_vesting, liquidity_token_allocation_bps, recipient_allocations, burnable,
     raise_target, raise_allocations, duration_ms, liquidity_window_ms, eligibility, uncapped,
     fee_split, creation_policy, fee_policy, venue_config, cetus_config, pools, tick_spacing)`. It reads Cetus's fee rate for `tick_spacing`, mints the coin's Cetus
     `PoolCreationCap` from the treasury cap, registers the `<Meme, Quote>` pair at that tick
     spacing, and stores the cap in `VenueConfig` under `blast_presale::cetus::CreationCapKey`.
     Cetus aborts if it has no fee tier for the tick spacing or refuses the pair (the Quote must
     be in Cetus's permission-pair allowlist at that tick spacing).
   - Bluefin: `blast_presale::bluefin::new(treasury_cap, currency, ..., uncapped, fee_split,
     creation_policy, fee_policy, tick_spacing, pool_fee_rate)`. Tick spacing must be 1..=400 and
     the fee rate 1..=20,000 in Bluefin's fee unit (`blast_presale::bluefin::EInvalidTier`); the
     coin's symbol must be at most 32 bytes (`blast_presale::bluefin::ESymbolTooLong`).

   Both return `(Presale<Meme, Quote>, PresaleCap)` and emit `blast_presale::blast_presale::PresaleCreated`.
   The supply is minted and the `TreasuryCap` consumed: the Coin Registry supply becomes `Fixed`,
   or `BurnOnly` when `burnable` is true.
8. Optional partner: `blast_presale::blast_presale::set_partner(presale, creation_policy, partner,
   clock)` names a `blast_partners::blast_partners::Partner` the `CreationPolicy` currently
   accepts. Only possible here, before `share`. Who may call: the holder of the unshared
   `Presale` value, that is, the creator in this PTB.
9. `blast_presale::blast_presale::share(presale, start_ms, clock)`, same caller, fixes the windows
   and shares the sale. The
   start is `max(start_ms, now)`, so a sale can be published ahead of its start. Emits
   `blast_presale::blast_presale::PresaleOpened`.
10. `TransferObjects([presale_cap], creator)`.

`new` arguments:

| Argument | Meaning and rule |
| --- | --- |
| `token_supply` | Whole supply in atomic units, > 0. The `TreasuryCap` must have minted nothing (`EInitialSupplyNotZero`). |
| `token_allocation_bps` | Buyers' share of the supply, > 0. |
| `participant_vesting` | `Option<VestingTerms>`: when set, each buyer's tokens vest from that buyer's claim. |
| `liquidity_token_allocation_bps` | Tokens seeded into the pool, > 0. |
| `recipient_allocations` | Up to 64 token recipients, distinct nonzero addresses, each > 0 BPS, optionally vested. Buyers + LP + Blast's token rate + recipients = exactly 10,000 BPS. |
| `burnable` | `true`: supply becomes burn-only; `false`: fixed. |
| `raise_target` | Quote the sale must raise, atomic units, > 0. |
| `raise_allocations` | Up to 64 raise recipients paid in Quote at migration, optionally vested. Their BPS plus Blast's raise rate must stay below 10,000; the LP keeps the rest. |
| `duration_ms` | Commitment window length, > 0. |
| `liquidity_window_ms` | Time after the window before anyone may cancel an unmigrated funded sale; at least 7 days. |
| `eligibility` | `EligibilityPolicy::Open` or `EligibilityPolicy::Allowlisted` (below). |
| `uncapped` | Optional `blast_presale::blast_presale::UncappedPhase` (below). |
| `fee_split` | `blast_presale::blast_presale::FeeSplit`: up to 16 unvested, distinct LP-fee recipients plus a holder-reward share, totalling exactly 10,000 BPS. The creator takes LP fees by listing itself as a recipient. An empty list with 10,000 holder BPS is valid. |
| `tick_spacing`, `pool_fee_rate` | Pool tier. Cetus derives the fee rate from the tick spacing. |

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

- `uncapped_for_eligible`: only wallets the policy admits, with the policy's participant bound
  and, for an open policy, its minimum.
- `uncapped_for_anyone`: any wallet through `blast_presale::blast_presale::commit_uncapped`. `max_participants`
  must be at least the policy's bound (its `max_participants`, or the allowlist's `leaf_count`)
  and at most 65,536. `min_commitment` times the slots held to it must reach the raise: all slots
  under an open policy, only the slots beyond `leaf_count` under an allowlist.
- `hard_cap = true`: during the phase a commitment takes only what is left of the raise and
  returns the excess at once; when the raise is full, commitments abort with `EPresaleFilled`.
  `hard_cap = false`: the sale keeps overflowing and fills pro rata.

The creation call aborts unless the LP's tokens and Quote give a seed price both venues can pool
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

Who may call: *anyone*. `blast_presale::blast_presale::settle(presale, clock)` once `now >= end_ms` while `Open`.
If total commitments reach the raise the sale becomes `Funded` and emits
`blast_presale::blast_presale::PresaleFunded`; otherwise it becomes `Cancelled` and emits
`blast_presale::blast_presale::PresaleCancelled`.

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
sale's tick spacing, seeds a full-range position at the price the LP balances imply, burns the
position through Cetus LP-burn for its fee-claiming proof, and shares a new `Vault` holding
that proof and whatever the pool did not take. Nothing returns to the caller. Any venue failure
rolls the whole transition back.

#### Migrating to Bluefin

Who may call: *anyone*, while `Funded`, until someone cancels.

1. `blast_presale::blast_presale::settle(presale, clock)` if not yet settled.
2. `creation_fee = SplitCoins(GasCoin, [amount])`, where `amount` is the fee amount (the `u64` in
   the `(bool, u64)` pair) that Bluefin's `get_pool_creation_fee_amount<SUI>` (its `config`
   module) returns at submission time; Bluefin rejects another amount.
3. `blast_presale::bluefin::migrate<Meme, Quote>(sale, fee_policy, currency, quote_currency,
   bluefin_config, creation_fee, clock)`. `currency` and `quote_currency` are the shared Coin
   Registry `Currency<Meme>` and `Currency<Quote>` (read for both symbols and decimals and the
   Quote's icon URL); the Bluefin `GlobalConfig` (`bluefin_config`) is mutable.
4. On a partnered sale, `blast_presale::blast_presale::pay_protocol_fees_with_partner(...)`.

The adapter creates the pool `Pool<Meme, Quote>` (Meme is always coin A) named
`<Meme symbol>-<Quote symbol>` at the sale's tier, opens a full-range position aligned inward to
the tick spacing, adds the LP balances, moves the position into a new shared `Vault`, and
shares the pool.

#### Locking your own position without a presale

Who may call: *anyone*, with their own position. A team that adds liquidity to Cetus or Bluefin
itself, without a presale, can lock that position for good in a `Vault`, which then splits
its LP fees exactly as a migrated sale's vault does: Blast's LP-fee share first, then the team's
`FeeSplit` between its fee recipients and holder-reward rounds.

1. Create the pool and open and fund the position with the venue's own calls; keep whatever the
   venue did not take.
2. `fee_split = blast_presale::blast_presale::fee_split(...)`, as for a presale.
3. Cetus: `blast_presale::cetus::new_vault<Meme, Quote, CoinA, CoinB>(position,
   fee_split, creation_policy, fee_policy, pool, burn_manager)`, where `pool` is the
   `Pool<CoinA, CoinB>` holding the position (read) and `CoinA` and `CoinB` are Meme and Quote in
   the pool's order. The position is burned through Cetus LP-burn for its fee-claiming proof,
   which Cetus's `BurnManager` (mutable) issues only for positions it accepts.
   Bluefin: `blast_presale::bluefin::new_vault<Meme, Quote>(position, fee_split,
   creation_policy, fee_policy, pool)`, where `pool` is the `Pool<Meme, Quote>` holding the
   position (read); a pool whose first coin is not Meme is not supported.

The `CreationPolicy` must allow Quote and the venue's migrator witness, the same check a presale
passes. The vault snapshots the `FeePolicy`'s current LP-fee rates. It names no presale: its
`presale_id` and `presale_cap_id` are the zero ID, so no `PresaleCap` claims from it, and it holds
no residuals. It names no partner. A position from another pool aborts with
`blast_presale::cetus::EPositionPoolMismatch` or `blast_presale::bluefin::EPositionPoolMismatch`;
a position with no liquidity aborts with `presale_vault::EZeroLiquidity`. Fees are then collected
with the venue's `collect_fees`, and holder-reward rounds work as for any vault.

#### Paying a partnered sale's Blast fees

Who may call: *anyone*, once, after migration. `blast_presale::blast_presale::pay_protocol_fees_with_partner(presale,
fee_policy, partner, clock)` takes the Blast raise fee the migration held, pays the partner its
cut through `blast_partners::blast_partners::pay`, then pays Blast the rest of the raise fee and its whole token
fee at the `FeePolicy`'s current destination. Emits `blast_partners::blast_partners::PartnerPaid` (when the cut is
positive) and `blast_presale::blast_presale::ProtocolFeesPaid`. The partner is paid into its recipient's address
balance (the framework's `send_funds`), not as a coin object.

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
and every fee recipient at once and keeps the holder-reward share in the vault. Shared objects only; nothing returns.

- Cetus: `blast_presale::cetus::collect_fees<Meme, Quote, CoinA, CoinB>(vault, fee_policy,
  cetus_config, burn_manager, pool)` where `pool` is the vault's
  `Pool<CoinA, CoinB>` (same coin order as migration; another pool aborts with
  `blast_presale::cetus::EPositionPoolMismatch`).
- Bluefin: `blast_presale::bluefin::collect_fees<Meme, Quote>(vault, fee_policy, bluefin_config,
  pool, clock)` where `pool` is the vault's `Pool<Meme, Quote>`
  (`blast_presale::bluefin::EPositionPoolMismatch` otherwise).

Emits `presale_vault::FeesCollected`. A collection of zero is valid and emits nothing. Neither
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

The holder-reward share of LP fees accrues in the vault. Blast decides off chain who receives it.

1. Publish: `holder_rewards::publish_round(vault, admin_registry, admin_cap, number,
   start_checkpoint, end_checkpoint, root, manifest_digest, leaf_count, meme_amount, quote_amount,
   claim_deadline_ms, clock)`. *Blast admin* (`AdminCap`). `number` must be the vault's next round
   (starting at 0); the checkpoint interval must be non-empty and start where the previous
   round ended; `root` and `manifest_digest` are 32 bytes; 1..=65,536 leaves; a positive budget
   of at least one asset, taken from the vault's holder-reward balances; a future deadline.
   Shares a `holder_rewards::Round` and emits `holder_rewards::RoundPublished`.
2. Claim: `holder_rewards::claim(round, index, beneficiary, meme_amount, quote_amount, proof)`.
   *Anyone* may relay; payment goes to `beneficiary`. Each index pays once (a bitmap records it).
   Emits `holder_rewards::RewardClaimed`. Leaf:

   ```
   blake2b256( b"\x00blast-presale-holder-rewards-v1"
               || bcs(vault_id: ID)        // 32 bytes
               || bcs(round_number: u64) || bcs(index: u64)
               || bcs(beneficiary: address)
               || bcs(meme_amount: u64) || bcs(quote_amount: u64) )
   ```

   The proof follows the allowlist rules above (same node hash, positional order, exact depth).
3. Close: `holder_rewards::close_round(round, vault, clock)`. *Anyone*, once `now >=
   claim_deadline_ms`. Takes the shared round by value, returns its unclaimed balances to the
   vault's holder share, deletes it, and emits `holder_rewards::RoundClosed`.

Claims carry no deadline check: they work until someone closes the round.

#### Blast admin operations

Integrators cannot call these; they explain state changes. Each takes the `AdminRegistry` and
the `AdminCap` (*Blast admin*), except the two `SuperAdminCap` calls (*Blast super admin*).
`blast_presale_admin::transfer_super_admin` moves the `SuperAdminCap` itself.

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
| `holder_rewards::publish_round` | See above. |
| `blast_presale::package_admin::authorize_upgrade`, `blast_presale::package_admin::commit_upgrade` | Dependency-only upgrades. |
| `blast_presale_admin::replace_admin_cap` | `SuperAdminCap`: mints a new `AdminCap` (returned; transfer it) and stops the old one at once. Emits `blast_presale_admin::AdminCapReplaced`. |
| `blast_presale_admin::revoke_admin_cap` | `SuperAdminCap`: clears the accepted cap, stopping all admin calls. Emits `blast_presale_admin::AdminCapRevoked`. |

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

When a hard-capped phase fills the raise, `T` equals `R` and every refund is zero. If the sale
already overflowed before the phase started, the phase accepts nothing (`EPresaleFilled`) and the
earlier overflow fills pro rata as usual.

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

A sale may name one `blast_partners::blast_partners::Partner`, fixed at `share`. The partner earns a cut of
Blast's raise fee and of Blast's LP fees, never of Blast's token fee. The cut is
`floor(fee × share_bps / 10,000)` using the partner's share in force when paid (at most 8,000
BPS; Blast's changes to it take effect 7 days after being scheduled). Blast keeps the rest. On a
partnered sale, migration holds Blast's raise fee and tokens in the sale, and each collection
holds Blast's LP fees in the vault, until the two pay calls run.

#### LP-fee split

After Blast's LP fees, the rest of each asset is apportioned by largest remainder over the fee
recipients in order, then the holder-reward share. Ties favor fee recipients over holders and
earlier recipients over later ones. Recipients are paid as coins in the same transaction (a zero
amount sends nothing); the holder share stays in the vault for rounds. The split never changes
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
  when the sale has none. `share` aborts with `EInvalidWindow` if these overflow u64.
- Commits: allowed for `start_ms <= now < end_ms`. Before the start: `EPresaleNotStarted`. At or
  after the end: `EPresaleEnded`.
- Caps lift at `now >= uncapped start`.
- `blast_presale::blast_presale::set_protocol_fees`: in the creation PTB before `share`, or after it while
  `now < start_ms`. A sale shared with a start in the past can be repriced only in its creation PTB.
- `blast_presale::blast_presale::settle`: from `now >= end_ms`, at any later time.
- Migration: any time while `Funded`, including after the LP deadline, until someone cancels.
- `blast_presale::blast_presale::cancel_unlaunched`: from `now >= LP deadline`. The 7-day minimum means a funded
  sale stays migratable for at least a week after its end.
- Vesting starts at migration for recipients and at each claim for participants.
- `blast_presale::blast_presale::set_partner` needs `now < accepted_until_ms` for that partner.
- Holder rounds: the deadline must be in the future at publish; claims work until close; close
  needs `now >= claim_deadline_ms`.

### Reading state

The package exposes no public read functions on its objects. Read object fields over RPC
(object content and dynamic fields), and use events for history.

`Presale<SaleToken, Quote>` fields:

- Lifecycle and timing: `lifecycle`, `start_ms` (zero until shared), `duration_ms`,
  `liquidity_window_ms`, `uncapped` (with `starts_after_ms`, `access`, `hard_cap`).
- Raise progress: `raise_target`, `total_commitments`, `participants` (wallets that have
  committed and not yet claimed), `quote` (Quote held).
- Terms: `eligibility`, `token_allocation` (buyers' tokens), `participant_vesting`,
  `recipient_payouts` and `raise_payouts` (each recipient's exact amount and vesting),
  `fee_split`, `tick_spacing`, `pool_fee_rate`, `migration_witness` (the venue: the type name of
  `blast_presale::cetus::Witness`, `blast_presale::bluefin::Witness`, or a vendor migrator's
  witness).
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
- `AdminRegistry`: `admin_cap_id`.
- `Vault`: `presale_id`, `presale_cap_id`, `pool_id`, `fee_split`, `protocol_fees`
  (current LP rates), `partner_id`, `unpaid_protocol_meme`, `unpaid_protocol_quote`,
  `migration_meme_residual`, `migration_quote_residual`, `holder_rewards_meme`,
  `holder_rewards_quote` (unallocated holder share), `next_round`, `last_checkpoint`. The position
  is a dynamic object field keyed by `presale_vault::PositionKey`.
- `Round`: `vault_id`, `number`, `claim_deadline_ms`, `root`, `leaf_count`, `meme`, `quote`,
  `claimed_bitmap` (leaf `i` is bit `i % 256` of word `i / 256`).
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
| Create | `blast_presale::blast_presale::PresaleCreated` | All terms: supply split (BPS), recipients and vesting, raise split (BPS), window lengths, eligibility, uncapped phase, `migration_witness`, tier, fee split, Blast's snapshot rates and amounts, `treasury_cap_id`, `presale_cap_id`. |
| Share | `blast_presale::blast_presale::PresaleOpened` | `start_ms`, `end_ms`, `liquidity_deadline_ms`, `uncapped_from_ms`, `partner_id`. |
| Per-sale rates | `blast_presale::blast_presale::ProtocolFeesChanged` | New rates, Blast amounts, and new buyer `token_allocation`. |
| Commit | `blast_presale::blast_presale::Committed` | `quote` accepted, `wallet_commitment` (new total), `total_commitments`, `participants`. It has no wallet field: the wallet is the transaction sender. |
| Settle | `blast_presale::blast_presale::PresaleFunded` / `blast_presale::blast_presale::PresaleCancelled` | Funded: `accepted_quote`, `refundable_quote`, `token_allocation`. Cancelled: total refundable. |
| Migrate | `blast_presale::blast_presale::ProtocolFeesPaid` (unpartnered), `blast_presale::blast_presale::RaiseAllocated` (per raise recipient), `blast_presale::blast_presale::RecipientAllocated` (per token recipient), `blast_presale::blast_presale::PresaleMigrated`, then `presale_vault::VaultCreated` | Payouts with `vesting_id`; LP amounts; vault, pool, and position IDs. The vault event's third type argument is `blast_presale::cetus::Venue` or `blast_presale::bluefin::Venue`. |
| Partner pay | `blast_partners::blast_partners::PartnerPaid`, `blast_presale::blast_presale::ProtocolFeesPaid` | `partner_quote` is the partner's cut. |
| Claim | `blast_presale::blast_presale::Claimed` | `tokens`, `quote_refund`, `remaining_participants`, `vesting_id`. |
| Collect | `presale_vault::FeesCollected` | Gross, Blast's part, per-recipient amounts aligned with the vault's recipients, holder share. `protocol_destination` is `none` when held for a partner. |
| Vault partner pay | `presale_vault::ProtocolLpFeesPaid` | Partner and Blast amounts per asset. |
| Vault without a presale | `presale_vault::VaultCreated` | Zero `presale_id` and residuals; pool, position, liquidity, fee split, and Blast's rates. |
| Residuals | `presale_vault::MigrationResidualsClaimed` | Amounts claimed. |
| Rounds | `holder_rewards::RoundPublished`, `holder_rewards::RewardClaimed`, `holder_rewards::RoundClosed` | Budgets, unallocated holder balances, per-claim payouts, returns. |
| Vesting | `VestingCreated`, `VestingClaimed` (from `blast_fun_vesting`) | Schedule terms and releases. |

Admin events are listed in "Blast admin operations".

### Aborts

Errors are Move clever errors: the abort names the module and constant, and the message explains
it. Common ones by flow (module `blast_presale` unless named):

- Create: `creation_policy::EQuoteNotAllowed` / `creation_policy::EMigrationWitnessNotAllowed`
  (ask Blast to list it); `EInvalidAssetPair` (sale coin equals Quote); `EInitialSupplyNotZero`;
  `EInvalidTokenAllocation` (BPS not exactly 10,000 with Blast's token rate, duplicate or zero
  recipient, more than 64, or a zero apportioned amount); `EInvalidRaiseAllocation` (no LP share
  left after Blast, duplicates, zero amounts); `EInvalidWindow` (zero duration or LP window under
  7 days); `EUnreachableRaise` (minimum × slots below raise); `EInvalidEligibilityPolicy`;
  `EInvalidUncappedPhase`; `EInvalidFeeSplit`; `EInvalidVestingTerms`; `EUnseedablePrice`;
  `blast_presale::bluefin::EInvalidTier`; `blast_presale::bluefin::ESymbolTooLong`.
- Partner and share: `creation_policy::EPartnerNotAccepted`; `EInvalidLifecycle` (already shared);
  `EInvalidWindow`.
- Commit: `EPresaleNotStarted`, `EPresaleEnded` (check the window); `EZeroCommitment`;
  `EWrongEligibilityPolicy` (wrong commit function for the policy); `EInvalidEligibilityProof`
  (wrong index, cap, proof, sender, or a different cap than the wallet's first commit);
  `EWalletCapExceeded` (lower the amount, or wait for the uncapped phase);
  `EBelowMinimumCommitment` (first commit must reach the minimum); `EParticipantCapacityReached`;
  `EUncappedPhaseNotOpen` (no anyone-phase, or not started); `EPresaleFilled` (hard cap reached).
- Settle: `EPresaleNotEnded`; `EInvalidLifecycle` (already settled).
- Migrate: `EInvalidLifecycle` (not `Funded`: unsettled, underfunded, cancelled, or migrated);
  `EWrongMigrationWitness` (wrong venue); `blast_presale::cetus::EInvalidCoinOrder` (swap
  `CoinA`/`CoinB`); `blast_presale::cetus::EWrongCoinPair`; venue aborts (Bluefin creation fee
  amount).
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
- Admin-only: `blast_presale_admin::EInvalidAdminCap`, `EPresaleStarted`,
  `EProtocolFeesUnchanged`, `fee_policy::EInvalidFees`, `fee_policy::EFeesUnchanged`,
  `fee_policy::EInvalidDestination`, `presale_vault::EProtocolLpFeesUnchanged`,
  `creation_policy::EAllowanceUnchanged`, `creation_policy::EInvalidMigrationWitness`, and the
  `holder_rewards` publish checks (`EWrongRound`, `EInvalidInterval`, `EInvalidCommitment`,
  `EInvalidLeafCount`, `EEmptyBudget`, `EInvalidClaimDeadline`).

### Pitfalls

- Create, optionally `set_partner`, and `share` in one PTB. The `Presale` cannot be transferred,
  so a PTB that does not share it fails. The partner cannot be added later.
- Every commit returns a coin. Transfer it back to the sender, even when it is zero.
- Commits always credit the sender. Sponsored transactions work (the user stays the sender), but
  take Quote from the user's coins, not the sponsor's gas coin.
- A keeper PTB of `settle` then `migrate` aborts as a whole when the sale is underfunded
  (`settle` cancels, then `migrate` hits `EInvalidLifecycle`). Compare `total_commitments` with
  `raise_target` first and send `settle` alone when it falls short.
- Cetus calls need `CoinA`/`CoinB` in Cetus's order, both for `migrate` and for the pool type in
  `collect_fees`. Bluefin always has Meme as coin A.
- Bluefin migration needs a `Coin<SUI>` of exactly Bluefin's current pool-creation fee.
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
blocks existing sales. Only the package's own Cetus and Bluefin adapters create a
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
  power is creating sales. It is not Blast's `blast_presale_admin::AdminCap`.
- `blast_aftermath_dao_presale::blast_aftermath_dao_presale::PoolCreation<Lp>`: shared; binds one sale to the Aftermath
  `CreatePoolCapV2` of a freshly published LP coin `Lp`.

Create (*cap holder*, `blast_aftermath_dao_presale::blast_aftermath_dao_presale::AdminCap`), one PTB:

1. Beforehand, in its own transaction, publish a fresh Aftermath LP coin `Lp` (one per sale); its
   publication yields the `CreatePoolCapV2` that the `AdminCap` holder passes in.
2. Build the arguments as for any sale (no fee split or tier).
3. `blast_aftermath_dao_presale::blast_aftermath_dao_presale::new<Lp, SaleToken, Quote>(admin_cap, treasury_cap, currency,
   token_supply, token_allocation_bps, participant_vesting, liquidity_token_allocation_bps,
   recipient_allocations, burnable, raise_target, raise_allocations, duration_ms,
   liquidity_window_ms, eligibility, uncapped, create_pool_cap, creation_policy, fee_policy)`.
   It calls `blast_presale::blast_presale::new` with tick spacing and fee rate zero and a fee split giving the
   treasury 10,000 BPS and holders 0, sends the `PresaleCap` to the treasury, shares the
   `PoolCreation<Lp>`, emits `blast_aftermath_dao_presale::blast_aftermath_dao_presale::PoolCreationReserved`, and returns the
   unshared `Presale`.
4. Optional `blast_presale::blast_presale::set_partner(...)`; optional
   `blast_presale::blast_presale::set_protocol_fees(...)` to change this sale's Blast rates, which needs Blast's
   presale `AdminCap` in the same transaction; then `blast_presale::blast_presale::share(presale, start_ms, clock)`.

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
`AdminCap` can change the sale's four rates only before `start_ms` (including in its creation
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

**How does a partner get paid?** The creator names it with `blast_presale::blast_presale::set_partner` before
`share`. After migration, anyone calls `blast_presale::blast_presale::pay_protocol_fees_with_partner` once. After
each fee collection, anyone calls `presale_vault::pay_protocol_lp_fees_with_partner`. The partner
receives its current share of Blast's raise and LP fees, never of the token fee.

**Where is the liquidity, and can anyone withdraw it?** A Cetus position is burned through
Cetus LP-burn and the vault keeps only its fee-claiming proof. A Bluefin position sits in the
vault, and no function in the package removes it. Upgrades can only relink dependencies, so this
cannot change. On the Aftermath vendor route, the LP coin is sent to `0x0`.
