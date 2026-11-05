## Vault

### What it is

Package `blast_vault` holds the one LP vault every Blast sale migrates into. A vault keeps a
venue's liquidity position with no removal path, so the liquidity is locked for good. It splits
every LP-fee collection: Blast's share first, then the sale's fee split across the owner, auto-LP,
holder rewards, burn, and address routes. It also pays holder-reward rounds by Merkle proof. Only
an admitted venue's code can create a vault or move its fees, and only from terms an admitted
package witness sealed; integrators reach a vault through the
venue's calls, and call the owner, round, and payout functions on it directly.

### Objects and authority

- `blast_vault_package::VaultRegistry` (shared singleton) lists the admitted witness types: the
  venues that may create vaults and the issuers whose sealed terms they may use (the launchpad's
  and the presale's package witnesses). A witness is admitted by its type, which only its own module
  can construct. A venue obtains terms only from `blast_core::migration::redeem`; it never accepts
  terms from its caller.
- `blast_vault::vault::Vault<Meme, Quote>` (shared, one per migrated sale) holds the position under
  the venue's key, the terms the sale sealed (`blast_core::migration::VaultTerms`), the fee split
  and Blast's share, each behind a notice, and the owner, auto-LP, holder-reward, and burn
  balances.
- `blast_vault::holder_rewards::Round<Meme, Quote>` (shared, one per published round) holds one
  round's holder budget, its Merkle root, the claimed-leaf bitmap, and an optional gas reserve.
- `blast_admin::package_version::PackageVersion<BLAST_VAULT_PACKAGE>` (shared) gates every call by
  code version and holds the admin pause bit.
- Owner authority is a `blast_core::owner_proof::OwnerProof` that the sale's product issues to its
  creator-authority holder in the same PTB. A vault accepts it only for its own sale and package
  witness.

Blast admins hold these roles: `VenueAdmin` admits and removes venue and package witnesses; `FeeAdmin` changes Blast's
per-vault share; `RewardsAdmin` schedules rounds and settles gas reserves; `BuybackAdmin` spends
the burn route's Quote on buybacks; `CancelAdmin` cancels any pending change.

### Lifecycle

1. A venue creates the vault with `blast_vault::vault::new`, unshared, from terms the sale sealed.
   It aborts unless the venue's witness and the terms' sealing witness are both admitted. Blast's
   share is at most 3,000 basis points per asset because `migration::vault_terms` refuses to seal
   more.
2. The venue attaches its position and shares the vault with
   `blast_vault::vault::share_with_position`, which settles the migration residuals and emits
   `blast_vault_events::VaultCreated`.
3. Each fee collection through the venue calls `blast_vault::vault::split_fees`.
4. Holder-reward rounds are scheduled, published, claimed, and closed (see Flows).

A vault never closes; its position cannot be removed.

### Flows

#### Claim the owner's balances

1. Call the sale product's owner-proof function to get an `OwnerProof` (cap holder: the sale's
   creator authority).
2. Call `blast_vault::vault::claim_owner_balances` with the vault (shared), the proof, and the
   package version. It returns a `Coin<Meme>` and a `Coin<Quote>` holding every owner fee and
   owner residual, and emits `blast_vault_events::OwnerBalancesClaimed`. Transfer or use both coins
   in the same PTB.

#### Change the fee split (owner)

1. Get an `OwnerProof`, then call `blast_vault::vault::schedule_fee_split` with the proposed
   `blast_core::fee_split::FeeSplit` and the `Clock` (`0x6`). It is ready after a fixed 48-hour
   notice.
2. Once ready, the venue settles fees under the current split and applies the new one with
   `blast_vault::vault::apply_fee_split`, so every fee follows the split it accrued under. Integrators
   check readiness with `blast_vault::vault::assert_fee_split_ready`.
3. The owner may cancel with `blast_vault::vault::cancel_fee_split`, even once ready.

#### Pay Blast's partnered fees

When the sale named a partner, Blast's cut is held in the vault. Anyone calls
`blast_vault::vault::pay_protocol_fees_with_partner` with the vault, the package version, the
treasury, and the partner (all shared). The partner receives its cut of each asset, the treasury the
rest, and `blast_core::blast_core_events::ProtocolFeesPaid` is emitted. Without a partner, Blast's
cut is paid to the treasury during each collection.

#### Claim a holder reward

1. Read the round's leaf for your address from Blast's published allocation: the index, the
   beneficiary, the Meme and Quote amounts, and the proof (a list of 32-byte siblings).
2. Call `blast_vault::holder_rewards::claim` with the round (shared), the package version, those
   values, and the `Clock`. Anyone may relay a claim; the coins always go to the committed
   beneficiary. It emits `blast_vault_events::RewardClaimed`.

#### Close a round

At or after its claim deadline, anyone calls `blast_vault::holder_rewards::close_round` with the
round, the package version, its vault, and the `Clock`. Every unclaimed balance and any unsettled gas
reserve returns to the vault's holder rewards, and `blast_vault_events::RoundClosed` is emitted.

#### Publish a scheduled round

Once a scheduled round's notice has passed, anyone calls
`blast_vault::holder_rewards::publish_round` with the vault, the package version, the treasury, and
the `Clock`. It reserves the round's budget from the vault, opens claims for the scheduled window,
shares the `Round`, and emits `blast_vault_events::RoundPublished`.

### Economics

- Each collection first takes Blast's share of each asset, rounded up
  (`blast_core::protocol_fees::take_cut`). The rest is apportioned over the fee split's routes by
  largest remainder (`blast_core::fee_split::apportion`), so the routes always sum to what is left.
- Address routes are paid at once. Owner, auto-LP, and holder-reward routes accrue in the vault.
  The burn route's Meme is burned when the supply is burn-only, or sent to `0x0` when it is
  fixed; its Quote is kept for buybacks.
- Migration residuals go to Blast or the owner, as the sale's terms say.
- A round's gas reserve is at most 10% of its Quote budget. It is reimbursed to the treasury once,
  measured and capped, with `blast_vault::holder_rewards::settle_gas_reserve` (Blast admin:
  `RewardsAdmin`); the rest returns to the vault at once.

### Time rules

- Witness admissions start at zero notice, so Blast lists its products and venues at launch while
  the package is still paused; Blast then raises the notice before unpausing. Afterwards each
  admission and notice change waits the applied notice. Removing a witness takes effect at once:
  a removed venue creates no more vaults, and a removed package witness's sales can no longer migrate.
- Fee-split and Blast-share changes always wait 48 hours; no call changes that notice.
- A round waits the vault's round notice, 2 hours at creation, before anyone may publish it.
- Claims are open while the clock is before the deadline; a round closes at or after it.

### Pause

The package is published fully paused. The admin pause bit stops Blast-share changes, buybacks,
round scheduling and publication, and gas settlement. It never stops venue admissions, fee
collection, owner claims, partner payouts, holder claims, round closing, or cancellations.
Unpausing with `blast_vault_package::unpause` runs only on the current version and requires a
nonzero witness admission notice and a nonzero core `blast_core::blast_treasury::Treasury` notice,
with no pending admission or change to zero; it takes the `Treasury` beside the registry.

### Upgrades and immutability

The vault is upgradeable through `blast_admin`'s generic administration and is to be made
immutable after its audit. An `UpgradeAdmin<BLAST_VAULT_PACKAGE>` schedules that with
`blast_admin::package_admin::schedule_make_immutable` and, once the 48-hour upgrade notice has
passed, executes it with `blast_vault::blast_vault_package::make_immutable` (the shared
`PackageAdmin`, the role witness, the `PackageVersion` and `Clock`). The call runs only on the
current vault version (code 9 from `blast_admin::package_version` otherwise) and then destroys
the `UpgradeCap`; no later upgrade or repair is possible.

### Reading state

- Find a sale's vault without an indexer: its object ID is derived from the shared
  `blast_vault_package::VaultRegistry` and the key `blast_vault::vault::VaultKey { package_witness, origin }`,
  whose BCS is the sealing package witness's type name as a length-prefixed `String` (ULEB128
  length, then the ASCII name, with the original package ID written without `0x`) followed by the
  sale's 32-byte ID: `0x2::dynamic_field::hash_type_and_key(registry_id,
  0x2::derived_object::DerivedObjectKey<blast_vault::vault::VaultKey>, bcs(key))`. The launchpad's
  sealing package witness is `blast_fun::blast_fun::PackageWitness` and the presale's
  `blast_presale::blast_presale_package::PackageWitness`. Each sale has exactly one vault; a
  second `blast_vault::vault::new` for the same terms aborts in `sui::derived_object`.

- `blast_vault::vault::pool_id`: the pool the vault's position belongs to.
- The venue's positions are dynamic object fields of the vault, under the venue's
  `PositionKey` and, once auto-LP has opened one, `AutoLpPositionKey`; only the venue's own code
  can borrow them, so read them as object fields.
- Events carry every balance change; index `FeesCollected` for per-route amounts.

### Events

- `blast_vault_events::VaultCreated`: vault, pool, position, liquidity, terms, and residuals.
- `blast_vault_events::FeesCollected`: gross amounts, Blast's cut, and each route's amounts, in
  route order.
- `blast_vault_events::AutoLpPositionOpened`, `blast_vault_events::AutoLiquidityAdded`: auto-LP.
- `blast_vault_events::BuybackBurned`: Quote spent and Meme burned. The vault measures both from
  the buyback receipt, as it measures `AutoLiquidityAdded` from the auto-LP receipt.
- Burned Meme leaves the supply when the Meme `Currency` is burn-only; when its supply is fixed
  it is sent to `0x0` instead. Both supply states are final, so an indexer reads the
  currency's supply state once to tell the two apart.
- `blast_vault_events::OwnerBalancesClaimed`: the owner's payout.
- `blast_vault_events::RoundPublished`, `blast_vault_events::RewardClaimed`,
  `blast_vault_events::GasReserveSettled`, `blast_vault_events::RoundClosed`: rounds.

### Aborts

- Vault creation: `unadmitted_venue`, then `unadmitted_package_witness`. Scheduling Blast's share above
  3,000 basis points per asset aborts with `invalid_protocol_bps`.
- A venue's buyback or auto-LP return: `wrong_vault` for another vault's receipt,
  `returned_exceeds_taken` when it returns more than it took.
- Owner claim with nothing accrued: `nothing_to_claim`. A proof for another sale or package
  aborts in `blast_core::owner_proof`.
- Holder claim: `claims_closed` past the deadline, `invalid_index`, `already_claimed`,
  `invalid_beneficiary` for `0x0`, `empty_claim` for zero amounts, and `invalid_proof` when any
  leaf value or the proof is wrong.
- Closing a round early: `claims_still_open`; with another vault: `wrong_vault`.
- Publishing: the scheduled round's notice must have passed, the treasury must still be the one it
  expected (`treasury_changed`), and the vault must still hold its budget
  (`insufficient_budget`).

### Pitfalls

- The coins from an owner claim must be consumed in the same PTB.
- An `OwnerProof` cannot be stored or dropped; create it in the PTB that uses it.
- A claim relayed by anyone still pays the beneficiary in the leaf, never the relayer.
- A leaf's beneficiary must be an account. A claim pays by coin transfer, so a beneficiary that is
  an object (a pool, a vesting schedule, another vault) could never receive it, and the claimed
  leaf never returns to the vault. Blast's allocation leaves object-held balances out; nothing on
  chain tells the two apart.

### Q&A

**Can anyone withdraw the liquidity?** No. The position is held under the venue's key with no
removal path; only the venue's code can borrow it to collect fees or add auto-LP.

**Who receives the burn route's Meme?** Nobody: it is burned when the supply is burn-only, or sent
to `0x0` when it is fixed.

**Do claims stop when Blast pauses the vault package?** No. Holder claims, owner claims, fee
collection, and round closing never pause.

**What happens to unclaimed rewards?** At the deadline anyone closes the round and they return to
the vault's holder rewards for later rounds.

**Can Blast change its share?** Yes, up to 3,000 basis points per asset, after a fixed 48-hour
notice and only for fees collected afterwards.
