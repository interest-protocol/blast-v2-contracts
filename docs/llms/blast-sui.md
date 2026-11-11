## blastSUI and funSUI

### What it is

Package `blast_sui` is a liquid-staking vault that delegates its SUI to the
staking pool of one validator chosen at creation and issues two coins against it:

- **funSUI** (`fun_sui::FUN_SUI`) is a stable SUI unit: mint it with SUI and
  redeem it for SUI exactly one-to-one, with no fee. It earns no yield. It is
  meant as SUI quote liquidity for Blast launches and pools, and anyone may
  mint, transfer, or redeem it.
- **blastSUI** (`blast_sui::blast_sui::BLAST_SUI`) is a yield-bearing share of
  the vault's blast custody. It receives the staking rewards of its own SUI and
  of the SUI backing funSUI. You deposit SUI, receive a deposit receipt holding
  native stake, and after that stake activates (the next epoch) you exchange the
  receipt for blastSUI at the current rate. Redeeming blastSUI pays a small fee
  that stays in the vault for the remaining holders.

Both coins have 9 decimals (1 SUI = 10^9 MIST) and are registered in Sui's Coin
Registry.

### Objects and authority

| Object | Kind | Notes |
| --- | --- | --- |
| `blast_sui::vault::Vault` | shared singleton | holds both treasury caps (as dynamic object fields keyed `blast_sui::vault::TreasuryKey<CoinType>`), both coins' metadata caps and the receipt's display cap (keyed `blast_sui::vault::CapabilityKey<Capability>`), the fun and blast custody ledgers, the cached exchange rate, the delayed `redeem_fee`, and `unwind_only`. Only one can exist: `blast_sui::vault::create` consumes both treasury caps. No call releases any capability. Every vault call takes it mutably, except `blast_sui::vault::unpause`. |
| `package_version::PackageVersion<BLAST_SUI_PACKAGE>` | shared singleton | the active version and the three deposit pause bits; every vault call takes it and aborts on outdated bytecode |
| `deposit_receipt::BlastSuiDepositReceipt` | owned, `key` only | a pending blastSUI deposit: `vault_id` and the native `StakedSui`. It cannot be transferred, wrapped, or deleted except by this package's calls. |
| `blast_admin::package_admin::PackageAdmin<BLAST_SUI_PACKAGE>` | shared | seals the package `Publisher` and `UpgradeCap`, and holds the delayed upgrade slot |
| `Coin<FUN_SUI>`, `Coin<BLAST_SUI>` | owned coins | unrestricted |
| `SuiSystemState` | Sui system object at `0x5` | passed mutably to every staking call |

Roles in Blast's shared ACL (see the administration guide):

- `blast_sui_domain::FeeAdmin`: schedules the blastSUI redemption fee and its
  delay.
- `blast_sui_domain::CancelAdmin`: cancels a pending fee change.
- `blast_admin::package_admin::PauseAdmin<BLAST_SUI_PACKAGE>`: pauses deposits.
- `blast_admin::package_admin::UnpauseAdmin<BLAST_SUI_PACKAGE>`: releases deposits
  through `blast_sui::vault::unpause`.
- `blast_admin::package_admin::UpgradeAdmin<BLAST_SUI_PACKAGE>` and
  `blast_admin::package_admin::CancelAdmin<BLAST_SUI_PACKAGE>`: schedule and
  cancel upgrades.

Pausing covers deposits only. There is no administrative withdrawal, no way to
change the validator, and no claim on the reserve or on fees in the current
source.

### Custody model

The vault keeps two separate ledgers, each a `custody::Custody`:

- **fun custody** backs funSUI one-to-one, plus a protocol-funded rounding
  reserve `R` = 0.1 SUI (100,000,000 MIST) that mints nothing.
- **blast custody** backs blastSUI, including the bootstrap seed whose shares
  are locked forever at `0x0`.

Each ledger has four layers:

- `liquid_sui`: SUI at face value.
- `pending_stakes`: up to three native `StakedSui` receipts waiting to activate,
  each counted at its principal, ordered by activation epoch. Requests in the
  same epoch join one receipt.
- `active_stake`: at most one `FungibleStakedSui` of the vault's pool.
- `active_sui`: the conservative SUI value of the active pool tokens:
  `floor(active_pool_tokens * rate_sui / rate_pool_tokens)` at the vault's
  cached rate, recomputed at every refresh and after every movement of active
  tokens (zero after a full exit).

A ledger's assets are `A = liquid_sui + pending principal + active_sui`. Write
`A_f`, `F` for fun assets and funSUI supply, and `A_b`, `B` for blast assets and
blastSUI supply.

Every vault call except `blast_sui::vault::create`,
`blast_sui::vault::top_up_fun_reserve`, `blast_sui::vault::unpause`, and the three
redemption-fee calls first **refreshes** the vault:

1. If the validator has left the active set, both ledgers unwind every native
   position into liquid SUI and the vault becomes `unwind_only` (emits
   `NativeStakeUnwound`). That refresh and every later one skip steps 2 and 3.
2. If the pool has a usable exchange-rate entry for the current epoch (both
   components positive), the vault
   caches it (`rate_epoch`, `rate_sui`, `rate_pool_tokens`) and converts every
   arrived blast pending receipt into the active position. Without an entry (a
   safe-mode epoch), it keeps the cached rate, which never exceeds the live one.
3. Both ledgers are revalued at the cached rate. With a current entry, arrived
   fun receipts convert oldest-first while fun custody's buffer `A_f - F`,
   minus the conversion's worst-case rounding loss
   `ceil(rate_sui / rate_pool_tokens)`, stays above 60 MIST. A receipt that
   cannot convert safely waits through its activation epoch and is then
   withdrawn to liquid SUI with its rewards in a later epoch that has a current
   rate.
4. **Fun yield sweep**: fun assets above `F + R` move to blast custody, liquid
   SUI first (keeping `R` liquid), then active pool tokens worth at most the
   remaining surplus at the cached rate (emits `FunYieldSwept`). Fun principal
   never moves, and nothing ever moves from blast to fun.
5. If funSUI exists, fun custody holds active pool tokens, and the fun buffer
   `A_f - F` is at most 60 MIST, every fun native position (pending receipts
   and active pool tokens) unwinds to liquid SUI to protect exact redemptions.
6. The vault asserts `A_f >= F`.

After the operation, idle SUI is delegated, but only when `rate_epoch` is the
current epoch and the vault is not `unwind_only`: fun custody stakes liquid SUI
above `R`, blast custody stakes all liquid SUI, each only when that excess is at
least 1 SUI. When a ledger already holds three pending receipts and the newest
cannot be joined, the excess stays liquid instead of aborting.

Withdrawals take liquid SUI first, then pending receipts (newest first,
splitting a receipt when both halves stay at least 1 SUI), then active pool
tokens (requesting enough for the amount plus a 30-MIST rounding margin, rounded
up). Any excess withdrawn stays liquid in the same ledger.

### Lifecycle

1. **Deployment.** Publishing sends both treasury caps and metadata caps and a
   `package_version::Publication<BLAST_SUI_PACKAGE>` to the publisher.
   `blast_admin::package_admin::wrap` turns the publication and the `UpgradeCap`
   into the shared `PackageAdmin` and a `PackageVersion` with every deposit bit
   paused.
2. **Creation.** `blast_sui::vault::create` (holder of both treasury caps and both
   metadata caps) takes the Display registry, an owner seed of at least 1.1 SUI,
   and a pool ID. The pool's validator must be active and the pool must have a
   usable current-epoch rate. `R` goes to fun custody; the rest goes to blast
   custody, mints one blastSUI per MIST, is staked, and every minted blastSUI is
   sent to `0x0`. blastSUI supply is therefore never zero, and the seed's backing
   can never be redeemed. Blast then raises the fee delay and releases deposits.
3. **Normal.** All flows below are open.
4. **Safe-mode epoch** (no usable current rate entry). funSUI mints, both redemptions,
   deposit requests, donations, cancellations, and `sync` work on the cached
   rate; claims abort; new SUI stays liquid until a normal epoch.
5. **Unwind-only** (validator left the active set). Mints, deposit requests, and
   claims abort; both redemptions, donations, `sync`, and receipt cancellation
   keep working. All SUI stays liquid. Nothing in the current source clears
   `unwind_only`.

### Flows

Every `vault` user call below (mint, redeem, request, claim, donate, `sync`)
takes the shared `Vault` (mutable), the shared `PackageVersion` (immutable), and
`SuiSystemState` at `0x5` (mutable). Only the redemption-fee schedule and apply
calls take the `Clock`.

#### Mint funSUI (anyone)

1. Split the exact SUI amount from a gas or SUI coin.
2. `blast_sui::vault::mint_fun_sui` with that `Coin<SUI>`. Returns
   `Coin<FUN_SUI>` of the same value; emits `FunSuiMinted`.
3. Transfer the returned coin or pass it to the next command.

#### Redeem funSUI (anyone)

1. `blast_sui::vault::redeem_fun_sui` with a `Coin<FUN_SUI>` (positive value).
   Returns `Coin<SUI>` of exactly the same value; emits `FunSuiRedeemed`. No
   fee, no minimum-out parameter. Works in safe mode and unwind-only.

#### Deposit SUI for blastSUI (anyone)

Transaction 1, epoch `E`:

1. Split at least 1 SUI (1,000,000,000 MIST) from a SUI coin. The whole coin is
   staked; no change is returned.
2. `blast_sui::vault::request_blast_sui` with that coin. It delegates the SUI to
   the vault's validator immediately and returns a `BlastSuiDepositReceipt`
   whose stake activates at epoch `E + 1`. Emits `BlastSuiDepositRequested` with
   `receipt_id`, `principal_sui`, and `activation_epoch`.
3. `deposit_receipt::keep` with the receipt: it moves to the sender's account.
   The receipt has no `store`, so a TransferObjects command cannot move it;
   `keep` is the only way to hold it, and only for the sender.

Transaction 2, any epoch from `activation_epoch` on with a current rate entry:

1. `blast_sui::vault::claim_blast_sui` with the owned receipt (by value) and
   `min_blast_out`. Returns `Coin<BLAST_SUI>`; emits `BlastSuiDepositClaimed`.
   The receipt is consumed and its stake joins blast custody.

The receipt's own stake keeps earning rewards until you claim, and the claim
values it at the current rate, so waiting loses nothing. Rewards that existing
holders earned before your stake activated stay with them.

#### Cancel a deposit (receipt owner)

1. `deposit_receipt::cancel` with the owned receipt and `SuiSystemState`. It
   needs neither the vault nor `PackageVersion`. Returns `Coin<SUI>`: the
   principal before activation, principal plus rewards after. Emits
   `BlastSuiDepositCancelled`. Works at any time, including in safe mode, in
   unwind-only, and after the validator is removed.

#### Redeem blastSUI (anyone)

1. Optionally dev-inspect the same call with `min_sui_out = 0` to read the exact
   payout.
2. `blast_sui::vault::redeem_blast_sui` with a `Coin<BLAST_SUI>` and
   `min_sui_out`. Returns `Coin<SUI>`; emits `BlastSuiRedeemed` with
   `gross_sui`, `fee_sui`, and `net_sui`. Works in safe mode (on the cached
   rate) and unwind-only.

#### Donate SUI to blastSUI holders (anyone)

1. `blast_sui::vault::donate_sui` with a positive `Coin<SUI>`. It joins blast
   custody, mints nothing, and raises the value of every blastSUI share,
   including the locked seed shares. Emits `BlastSuiDonated`. The donor gets
   nothing back.

#### Sync (anyone)

1. `blast_sui::vault::sync`. Runs the refresh, then delegates idle SUI. Emits
   `VaultSynced` with the full custody snapshot. Use it to observe a departed
   validator, convert arrived stake, or get a fresh snapshot (dev-inspect).

#### Top up the fun reserve (anyone)

1. `blast_sui::vault::top_up_fun_reserve` with `PackageVersion` and a positive
   `Coin<SUI>`. It joins fun custody without a refresh, so it works even while
   fun custody is below the funSUI supply and every other call aborts. Emits
   `FunReserveToppedUp`. The caller gets nothing back; anything above `F + R`
   moves to blast custody at the next refresh.

#### Change the redemption fee (Blast admin, `FeeAdmin`)

1. `blast_acl::sign_in` with type argument `blast_sui_domain::FeeAdmin`.
2. `blast_sui::vault::schedule_redeem_fee` with the vault, `PackageVersion`, the
   witness, the new BPS (0 to 100), the delay in force after this change, and the
   `Clock`. A new schedule replaces a pending one and restarts its wait. A change
   of neither value aborts with code 16 from `blast_admin`'s `delayed` module.
3. After the applied delay, *anyone* calls `blast_sui::vault::apply_redeem_fee`
   with the vault, `PackageVersion`, and the `Clock`.
4. A holder of `blast_sui_domain::CancelAdmin` may call
   `blast_sui::vault::cancel_redeem_fee` at any time before it applies, even once
   ready.

The fee's lifecycle events come from `blast_admin::delayed`, typed by
`blast_sui::vault::RedeemFeeKey`, with the vault's ID as their parent.

#### Pause and release (Blast admin)

- `blast_admin::package_admin::pause` (`PauseAdmin<BLAST_SUI_PACKAGE>`) sets any
  of three bits immediately: 1 stops `blast_sui::vault::mint_fun_sui`, 2 stops
  `blast_sui::vault::request_blast_sui`, 4 stops
  `blast_sui::vault::claim_blast_sui`. Nothing else reads them: both redemptions,
  donations, top-ups, `sync`, and receipt cancellation stay open.
- `blast_sui::vault::unpause` (`UnpauseAdmin<BLAST_SUI_PACKAGE>`) clears bits. It
  aborts with `EUnguardedDelay` while the fee delay is zero or a pending change
  would make it zero.

#### Package custody and upgrades (Blast admin)

Upgrades use the generic `blast_admin::package_admin` calls typed by
`BLAST_SUI_PACKAGE`: `UpgradeAdmin<BLAST_SUI_PACKAGE>` schedules the exact digest,
waits the applied delay (48 hours at wrap), then authorizes, upgrades, and commits
in one PTB, which advances the version. See the administration guide.

### Economics

All amounts are atomic units (MIST for SUI, 10^-9 of a coin for funSUI and
blastSUI). BPS are out of 10,000.

- **funSUI**: mint `x` SUI → `x` funSUI; redeem `x` funSUI → `x` SUI. No fee, no
  rounding. funSUI earns nothing.
- **blastSUI value**: one blastSUI is worth `A_b / B` SUI at the conservative
  valuation.
- **Claim**: the receipt's stake converts natively to `pool_tokens`; then
  `contributed_sui = floor(pool_tokens * rate_sui / rate_pool_tokens)` and
  `blast_out = floor(contributed_sui * B / A_b)`, with `A_b` and `B` measured
  after the refresh and before the deposit joins. `blast_out` must be positive
  and at least `min_blast_out`.
- **Redemption** of `s` blastSUI: `gross = floor(s * A_b / B)`,
  `fee = ceil(gross * redeem_fee_bps / 10,000)`, `net = gross - fee`. `net`
  must be positive and at least `min_sui_out`. The fee stays in blast custody.
  Because the seed shares are never presented, every redemption is partial and
  pays the fee.
- **Redemption fee**: default 2 BPS, maximum 100 BPS (1%), changed by `FeeAdmin`
  after its delay. Zero is the only fee-free setting.
- **Dust**: every rounding favors the vault's remaining holders: share minting
  rounds down, redemption gross rounds down, the fee rounds up, and pool-token
  valuations round down. Over-withdrawn SUI stays liquid in the ledger.
- **Yield**: blast custody keeps its own staking rewards, every redemption fee,
  and every donation, and receives fun custody's yield above `F + R`. The locked
  seed shares earn their pro-rata part forever.
- Example: `A_b` = 1,050 SUI, `B` = 1,000 blastSUI, fee 2 BPS. Redeeming 10
  blastSUI gives `gross` = 10,500,000,000 MIST, `fee` = 2,100,000 MIST, `net` =
  10,497,900,000 MIST.

### Time rules

- Native stake requested in epoch `E` activates at `E + 1`. A receipt can be
  claimed when `activation_epoch <= current epoch`.
- A claim also needs the vault's cached rate to be the current epoch's
  (`rate_epoch == current epoch`), which the claim's own refresh provides in any
  normal epoch. In a safe-mode epoch the claim aborts; retry in the next normal
  epoch.
- `blast_sui::vault::create` requires the pool to have a usable current-epoch
  rate entry.
- A redemption-fee change waits the delay applied when it was scheduled.
- New SUI is delegated only in an epoch with a current rate; in a safe-mode
  epoch it stays liquid (still counted at face value) until a later call.
- Cancellation has no time limit and no epoch requirement.

### Reading state

The vault has no public getters; read object content over RPC, or use events.

- Vault fields: `pool_id` (the fixed staking pool), `fun_custody` and
  `blast_custody` (`liquid_sui`, `pending_stakes`, `active_stake`,
  `active_sui`), `rate_epoch`, `rate_sui`, `rate_pool_tokens`, `redeem_fee` (its
  `value`, `delay_ms`, and any pending change), `unwind_only`.
- Supplies: the `total_supply` of the treasury caps under the vault's dynamic
  object fields `TreasuryKey<FUN_SUI>` and `TreasuryKey<BLAST_SUI>`, or
  `fun_supply` and `blast_supply` in the latest event snapshot.
- blastSUI price: `A_b / B`, from the latest `custody` snapshot: the sum of
  `blast_custody.liquid_sui`, `blast_custody.pending_sui`, and
  `blast_custody.active_sui`, over `blast_supply`.
- Fresh numbers: dev-inspect `blast_sui::vault::sync` and read its
  `VaultSynced`; or dev-inspect the exact claim or redemption with a zero
  minimum.
- Validator: derive it from `pool_id` through the Sui system state;
  `VaultCreated` records it at creation.
- A receipt: `vault_id` and `staked_sui` (`pool_id`, `stake_activation_epoch`,
  `principal`).
- Locked seed: `VaultCreated.locked_blast_sui`.

### Events

Every event is wrapped in the envelope `blast_sui::blast_events::Event<T>`;
filter on the envelope type with the payload as its type argument.

Snapshot types embedded in most events:

- `blast_sui::events::VaultCustody`: `fun_custody`, `blast_custody`,
  `exchange_rate`, `fun_supply`, `blast_supply`.
- `blast_sui::events::PoolCustody`: `liquid_sui`, `pending_sui`,
  `active_pool_tokens`, `active_sui`. The ledger's assets are
  `liquid_sui + pending_sui + active_sui`.
- `blast_sui::events::ExchangeRate`: `epoch`, `sui_amount`, `pool_token_amount`,
  the rate entry applied; `epoch` may trail the transaction's epoch after a
  safe-mode epoch.

| Event | Emitted by | Key fields |
| --- | --- | --- |
| `blast_sui::events::VaultCreated` | `create` | `vault_id`, `validator`, `pool_id`, `fun_reserve_sui`, `bootstrap_sui`, `locked_blast_sui`, `redeem_fee_bps`, `custody` |
| `blast_sui::events::FunSuiMinted` | `mint_fun_sui` | `sui_in`, `custody` |
| `blast_sui::events::FunSuiRedeemed` | `redeem_fun_sui` | `fun_in`, `custody` |
| `blast_sui::events::BlastSuiDepositRequested` | `request_blast_sui` | `receipt_id`, `vault_id`, `pool_id`, `principal_sui`, `activation_epoch`, `custody` |
| `blast_sui::events::BlastSuiDepositClaimed` | `claim_blast_sui` | `receipt_id`, `principal_sui`, `contributed_sui`, `claimed_pool_tokens`, `blast_out`, `custody` |
| `blast_sui::events::BlastSuiDepositCancelled` | `deposit_receipt::cancel` | `receipt_id`, `vault_id`, `principal_sui`, `returned_sui` (no snapshot: the vault is untouched) |
| `blast_sui::events::BlastSuiDonated` | `donate_sui` | `sui_in`, `custody` |
| `blast_sui::events::BlastSuiRedeemed` | `redeem_blast_sui` | `blast_in`, `gross_sui`, `fee_sui`, `net_sui`, `custody` |
| `blast_sui::events::FunYieldSwept` | any refresh that moves yield | `swept_liquid_sui`, `swept_pool_tokens`, `swept_sui`, `custody` at that point |
| `blast_sui::events::NativeStakeUnwound` | the refresh that observes a departed validator | `custody` |
| `blast_sui::events::VaultSynced` | `sync` | `custody` |
| `blast_sui::events::FunReserveToppedUp` | `top_up_fun_reserve` | `sui_in`, `custody` |

Redemption-fee lifecycle, pause, and upgrade events come from `blast_admin`
without an envelope. An indexer gets the vault's full state after each transition from the
last snapshot in the transaction, and links a deposit's request, claim, or
cancellation by `receipt_id`.

### Aborts

Codes are plain `u64` values, raised in the `blast_sui` module that detects them
(`vault`, `custody`, `math`, or `deposit_receipt`).

| Code | Name | Typical flow | Fix |
| --- | --- | --- | --- |
| 0 | `EZeroAmount` | any mint, redeem, donation, top-up | pass a positive coin |
| 1 | `EInvalidShareAmount` | redeem blastSUI | cannot exceed supply (unreachable in practice) |
| 2 | `EZeroBlastShares` | claim | the deposit rounded to zero shares |
| 3 | `EZeroSuiRedemption` | redeem blastSUI | redeem more shares |
| 4 | `EUnwindOnly` | mint funSUI, request, claim | the validator left; redeem or cancel instead |
| 5 | `EValidatorNotActive` | create | choose an active validator |
| 6 | `ENonzeroInitialSupply` | create | treasury caps must have zero supply |
| 7 | `ESlippageExceeded` | claim, redeem blastSUI | lower the minimum or retry |
| 8 | `EInsufficientNativeRedemption` | redemptions | native output fell short of the valuation; the vault fails closed |
| 9 | `EBlastAssetsDepleted` | claim, redeem blastSUI | blast custody holds nothing to price shares |
| 10 | `EBootstrapBelowNativeMinimum` | create | seed at least 1.1 SUI |
| 11 | `ERedeemFeeAboveMaximum` | schedule fee | at most 100 BPS |
| 12 | `EFunBackingBelowSupply` | any refresh, funSUI mint or redeem | fun custody fell below supply; `blast_sui::vault::top_up_fun_reserve` restores it |
| 13 | `EStaleExchangeRate` | claim, create | safe-mode epoch; retry in the next normal epoch |
| 14 | `EBlastDepositBelowNativeMinimum` | request | deposit at least 1 SUI |
| 15 | `EBlastDepositNotActive` | claim | wait for `activation_epoch` |
| 16 | `EWrongReceiptVault` | claim | the receipt belongs to another vault |
| 17 | `EWrongReceiptPool` | claim | the receipt's stake is from another pool |
| 18 | `EZeroSuiAfterFee` | redeem blastSUI | the fee consumed the payout; redeem more |
| 19 | `EWrongDelegationPool` | request, or any call that stakes | the validator address now runs a different pool than the vault's; deposits stay closed, redeem or cancel instead |
| 20 | `EUnguardedDelay` | `blast_sui::vault::unpause` | raise the fee delay above zero first |

Calls into outdated bytecode after an upgrade abort with code 9 from
`blast_admin`'s `package_version` module: rebuild the PTB against the latest
package version. A paused deposit aborts with code 21 from the same module. A
role failure in `blast_acl::sign_in` aborts with `blast_admin` code 1 or 5.

### Pitfalls

- `blast_sui::vault::request_blast_sui` stakes the whole coin. Split the exact
  amount first; the minimum is 1 SUI.
- Call `deposit_receipt::keep` in the same PTB as the request. A TransferObjects
  command on the receipt fails, and an unconsumed receipt aborts the PTB.
- A receipt cannot be given to another account; only the requesting account can
  claim or cancel it.
- A claim in the request's epoch or in a safe-mode epoch aborts (codes 15, 13).
- funSUI does not earn yield; blastSUI does.
- The blastSUI price uses a conservative valuation at the cached rate. Always
  set `min_sui_out` and `min_blast_out`, ideally from a dev-inspect of the same
  call.
- The fee applies to every blastSUI redemption, however small or large.
- Vault calls take the shared `Vault` mutably, so vault transactions are
  sequenced through consensus.
- After an upgrade, PTBs pinned to the old package ID abort (code 9 from
  `package_version`).

### Q&A

**What is the difference between funSUI and blastSUI?** funSUI is always worth
exactly 1 SUI and earns nothing. blastSUI is a share of blast custody whose SUI
value grows with staking rewards, including the rewards on the SUI backing
funSUI.

**How long until my deposit becomes blastSUI?** Your SUI is staked at once and
activates at the next epoch. From then on, in any normal epoch, call
`blast_sui::vault::claim_blast_sui` with your receipt. Until you claim, your
stake keeps earning and is counted in your claim.

**Can I get my SUI back before claiming?** Yes. `deposit_receipt::cancel`
returns your principal, plus rewards once active, at any time, without touching
the vault.

**What does redeeming blastSUI cost?** `ceil(gross * redeem_fee_bps / 10,000)`
MIST, where the fee starts at 2 BPS and can never exceed 100 BPS. The fee stays
in the vault for the remaining holders.

**Is funSUI always redeemable one-to-one?** Yes: redemption returns exactly one
MIST per unit with no fee, from fun custody only. The vault checks fun custody
covers the funSUI supply after every operation; if it ever did not, the call
would abort rather than underpay.

**Which validator does the vault use, and can it change?** The staking pool set
at creation (`pool_id`). No call changes it.

**What happens if the validator leaves the active set?** The next refresh
unwinds all stake to liquid SUI and the vault becomes unwind-only: redemptions,
donations, and cancellations work; mints, deposits, and claims abort.

**Can Blast pause the vault or take user funds?** Blast can pause deposits only:
funSUI mints, deposit requests, and claims. Redemptions, donations, and receipt
cancellation never pause, and no call withdraws funds for anyone but coin holders
and receipt owners. Blast's `UpgradeAdmin<BLAST_SUI_PACKAGE>` can upgrade the
package after its 48-hour delay.

**How do I compute the blastSUI to SUI rate?** Divide blast custody's assets
(`liquid_sui + pending_sui + active_sui`) by `blast_supply`, from the latest
event snapshot or a dev-inspected `sync`.

**Why can't blastSUI supply reach zero?** Creation sends the bootstrap shares to
`0x0`, where no one can redeem them. This removes every empty-vault edge case,
and those shares keep their pro-rata part of the vault forever.
