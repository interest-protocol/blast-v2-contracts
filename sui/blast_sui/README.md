# Blast SUI: `funSUI` and `blastSUI`

This independently deployed Sui Move package implements the single-validator
vault accepted in
[ADR 0053](../../docs/decisions/0053-single-validator-funsui-and-blastsui.md).
It depends only on the pinned `SuiSystem` framework package and must not import
`blast_fun`; its authority, version gate, and error registry are its own.

## Modules

- `blast.move` — canonical package OTW; `init` uses the framework's
  `claim_and_keep` path so the Publisher can immediately enter protocol custody.
- `fun_sui.move` / `blast_sui.move` — the two unrestricted nine-decimal coins.
  Their initial metadata includes the fixed Blast icon and is immutable because
  initialization deletes both `MetadataCap`s.
- `deposit_receipt.move` — the key-only `BlastSuiDepositReceipt`, fair delayed
  issuance, direct native cancellation, and wallet Display V2 metadata. Its
  one-time display creator locks the update cap at `@0x0`.
- `acl.move` — package-local administration with one shared
  `ProtocolAuthority` and one active `SuperAdminCap`. Every privileged action
  validates that cap against the registry. The same offchain maintainer may
  hold this cap and the launchpad's, but they are separate onchain objects.
  Delayed root acceptance returns the new key-only cap for composition;
  `acl::keep` stores it with the accepting sender.
- `package_admin.move` — permanent shared custody of this package's `Publisher`
  and `UpgradeCap` with no release or borrow path. `wrap` validates both and
  returns nothing. Authorization, policy restriction, and package-version
  activation require the active `SuperAdminCap`; commit is authorized only by
  the matching native receipt.
- `package_version.move` — the operational package generation that gates every
  administration and vault mutation.
- `custody.move` — one native ledger: liquid `Balance<SUI>`, at most one
  pending `StakedSui` (the pre-activation receipt, worth exactly its
  principal), at most one active `FungibleStakedSui`, and the conservative
  floor valuation of the active tokens at the rate the vault applies. A ledger
  never reads the pool itself.
- `vault.move` — one shared `Vault` owning both treasury caps, the `fun` and
  `blast` ledgers, the immutable pool ID, the cached pool
  exchange-rate entry (`rate_epoch`, `rate_sui`, `rate_pool_tokens`), the live
  `redeem_fee_bps`, and the unwind flag. `create` locks the whole seed
  `blastSUI` coin at `@0x0`.
- `math.move` — integer share accounting, the live-rate redemption fee, and
  the native pool-token rate conversions with their rounding directions.
- `lib/constants.move`, `lib/errors.move`, `lib/events.move`,
  `lib/events_wrapper.move` — package constants, the append-only error
  registry, replay-complete completed facts, and the `Event<T>` envelope.

## Vault behavior

Every mutation first asserts the current `PackageVersion`, then refreshes: an
inactive validator unwinds both ledgers into liquid SUI and switches the vault
to unwind-only mode; otherwise the pool exchange-rate table is read exactly
once at the current epoch. A present entry replaces the cached rate and permits
activated fun stake to convert to `FungibleStakedSui` when its rounding-loss
bound leaves the exit buffer safe. Otherwise the receipt remains intact for
its activation epoch and every safe-mode epoch, then is withdrawn in a normal
current-rate epoch after earning rewards so the position can be swept and
restaked without forfeiting deferred yield.
A missing entry (a safe-mode epoch writes none) keeps the cached rate. The
package performs no backward scan. Both active positions are
then revalued at the applied rate. The refresh sweeps fun yield — fun assets
above the `funSUI` supply plus the 0.1-SUI rounding reserve — into blast
custody: liquid SUI above the reserve first, then active pool tokens worth at
most the remaining surplus at the same rate. Fun principal never moves and
nothing moves from blast to fun. The locked seed supply always exists to own
that yield, so the sweep has no supply condition.

- `create` takes one owner seed `Coin<SUI>` of at least one SUI plus the
  0.1-SUI reserve and requires a pool exchange-rate entry for the current
  epoch, which initializes the cache. Exactly the reserve enters fun custody as
  liquid protocol capital that mints nothing; the remainder is the blast
  bootstrap, enters blast custody only, mints one `blastSUI` per MIST, and is
  staked. `create` returns nothing: the complete minted `Coin<BLAST_SUI>` is
  transferred to `@0x0` in the creation transaction, so `blastSUI` supply is
  permanently positive and the bootstrap backing can never be redeemed or
  removed. No vault field duplicates the locked amount; the treasury total
  supply and `VaultCreated.locked_blast_sui` record it. The vault is shared
  with `redeem_fee_bps = 2`.
- The reserve is not fun principal and never moves out of fun custody. It is a
  retained value target: the sweep keeps `funSUI` supply plus the reserve in
  fun custody, so retained fun yield replenishes whatever native rounding
  consumed. Every refresh, fun mint, and fun redemption asserts that fun
  custody's conservative assets are at least the `funSUI` supply
  (`fun_backing_below_supply`). If conversion would consume the exit buffer,
  an activated receipt waits through its activation epoch, then is withdrawn
  and delegated again after realizing one complete reward epoch. If the buffer
  reaches twice the native redemption margin, remaining active fun stake
  unwinds. Idle SUI above the retained reserve is eligible for redelegation, so
  a low buffer cannot permanently freeze or repeatedly forfeit fun yield.
- `mint_fun_sui` and `redeem_fun_sui` move exactly one MIST per `funSUI` unit
  against fun custody only and never require positive `blastSUI` supply.
- `request_blast_sui` requires at least one SUI, delegates it immediately, and
  returns a key-only `BlastSuiDepositReceipt`. The native `StakedSui` remains
  inside that receipt, outside vault custody and coin supply. The caller can
  compose the return value directly into claim or cancellation, or call
  `deposit_receipt::keep` to place it in the transaction sender's account.
  `claim_blast_sui` consumes an activated receipt, requires a current rate, and
  issues `floor(contributed_value * B / A_b)` shares before joining its pool
  tokens to blast custody. This prevents a deposit from taking rewards earned
  before activation. `deposit_receipt::cancel` needs no vault or package-version
  object and returns native principal plus earned rewards before or after
  activation, including after validator removal.
  `redeem_blast_sui` pays `floor(shares * A_b / B)` less
  `ceil(gross * redeem_fee_bps / 10_000)`; the fee stays in blast custody, and
  there is no fee balance or claim path. Every redemption is partial against
  the total supply because the locked seed shares can never be presented, so
  every redemption pays the current fee; a 0-bps setting is the only fee-free
  user redemption. There is no final-share drain, no fun unwind on zero blast
  supply, and no one-to-one restart deposit.
- Redemptions consume liquid SUI, then pending principal, then active tokens,
  and stay open during a safe-mode epoch: a `blastSUI` exit is quoted on the
  cached conservative valuation and the caller's `min_sui_out` is its
  protection.
  Pending withdrawals split only when both remaining native receipts satisfy
  the one-SUI minimum; otherwise they withdraw the whole receipt. An activated
  fun receipt that cannot convert safely is realized and restaked.
  One native redemption requests ceil pool tokens for the deficit plus three
  MIST; rounding residue stays liquid. Because the reserve is seeded at
  creation, a full `funSUI` exit is exact even when the position was converted
  in its activation epoch and fun custody has earned nothing yet.
- `set_redeem_fee` requires the active `SuperAdminCap`, rejects an unchanged
  value and any
  value above 100 bps, and emits the old and new rate.
- Every asset mutation delegates idle liquid SUI only when a current exchange-rate
  entry proves that the immutable pool itself is active. Blast custody stakes
  everything of at least one whole SUI, and fun custody stakes only liquid above
  the reserve when that excess reaches one whole SUI. Safe mode keeps new idle
  vault SUI liquid until a normal epoch. `sync` is the permissionless refresh,
  sweep, and delegation path.
- `donate_sui` is permissionless. It adds external SUI only to blast custody,
  mints no shares, and therefore increases the assets backing each existing
  blastSUI share. Donations of at least one SUI are delegated when possible;
  smaller donations remain liquid until the blast balance reaches that threshold.
- Unwind-only mode rejects fun mints, blast requests, and blast claims. Both
  coin redemptions, direct receipt cancellation, and donations stay open. A
  donation remains liquid in unwind-only mode. There is no pause and no
  administrative withdrawal path.

## Events

All payloads are wrapped in `events_wrapper::Event<T>`. Administration emits
`ProtocolAuthorityCreated`, `SuperAdminTransferStarted`, `SuperAdminTransferCancelled`,
`SuperAdminTransferred`, `PackageVersionCreated`, `PackageVersionAdvanced`,
`PackageAdminCreated`, `UpgradeAuthorized`, `UpgradeCommitted`, and
`UpgradePolicyRestricted`. The receipt and vault flows emit `VaultCreated`,
`FunSuiMinted`, `FunSuiRedeemed`, `BlastSuiDepositRequested`,
`BlastSuiDepositClaimed`, `BlastSuiDepositCancelled`, `BlastSuiRedeemed`,
`BlastSuiDonated`, `FunYieldSwept`, `RedeemFeeChanged`, `VaultSynced`, and
`NativeStakeUnwound`. `VaultCreated`
records the seed split as `fun_reserve_sui` and `bootstrap_sui`, and
`locked_blast_sui` as the seed shares transferred to `@0x0` whose backing is
permanent. Every completed vault mutation fact carries the final `VaultCustody`
snapshot of both ledgers, both supplies,
and the applied `ExchangeRate` (`epoch`, `sui_amount`, `pool_token_amount`),
which is the cached entry and may trail the transaction epoch during safe mode.

## Error registry

Codes are append-only. Each macro in `sources/lib/errors.move` inlines its
number into the raising module. Retired codes remain reserved.

| Code | Macro | Raised from | Meaning |
| ---: | --- | --- | --- |
| 0 | `zero_amount` | `math`, `vault` | An operation requires a positive atomic coin amount. |
| 1 | `invalid_share_amount` | `math` | The number of shares exceeds the live blastSUI supply. |
| 2 | *(retired)* | — | Residual-equity bootstrap state replaced by separate custody ledgers. |
| 3 | `zero_blast_shares` | `math` | A positive SUI deposit rounded down to zero blastSUI shares. |
| 4 | `zero_sui_redemption` | `math` | A positive blastSUI redemption rounded down to zero SUI. |
| 5 | *(retired)* | — | Fun custody is settled by the yield sweep instead of asserted. |
| 6 | *(retired)* | — | Residual-owner guard removed with the final-holder block. |
| 7 | *(retired)* | — | Package `UpgradeAdminCap` replaced by the local ACL. |
| 8 | `invalid_package_digest` | `package_admin` | A Sui package digest must contain exactly 32 bytes. |
| 9 | `invalid_package_publisher` | `package_admin` | The supplied Publisher was not claimed by this package's canonical module. |
| 10 | `invalid_upgrade_cap` | `package_admin` | The supplied `UpgradeCap` does not authorize the original `blast_sui` package. |
| 11 | `package_version_mismatch` | `package_version` | Shared package state does not accept this bytecode generation. |
| 12 | `package_version_overflow` | `package_version` | Advancing the package generation would overflow `u64`. |
| 13 | `upgrade_policy_not_more_restrictive` | `package_admin` | An upgrade policy can only become more restrictive. |
| 14 | `unwind_only` | `vault` | The validator left the active set, so the vault accepts redemptions only. |
| 15 | `validator_not_active` | `vault` | The fixed validator is not in the active validator set. |
| 16 | *(retired)* | — | The caller-supplied validator check was removed; the validator is derived from the immutable pool ID. |
| 17 | `nonzero_initial_supply` | `vault` | A treasury cap entering vault custody already has supply. |
| 18 | *(retired)* | — | funSUI mints no longer require positive blastSUI supply. |
| 19 | `slippage_exceeded` | `vault` | The output is below the caller's minimum. |
| 20 | `insufficient_native_redemption` | `custody` | Native redemption returned less SUI than the ledger's conservative valuation. |
| 21 | *(retired)* | — | Final-holder block replaced by the seed supply locked at `@0x0`. |
| 22 | `blast_assets_depleted` | `math` | blastSUI shares exist but blast custody holds no assets to price them. |
| 23 | `bootstrap_below_native_minimum` | `vault` | The owner seed cannot fund the fun reserve plus a blast bootstrap of at least the native one-SUI stake minimum. |
| 24 | *(retired)* | — | Routine `AdminCap` authorization was removed. |
| 25 | `invalid_super_admin_cap` | `acl` | The supplied `SuperAdminCap` is no longer the active root capability. |
| 26–29 | *(retired)* | — | Routine administrators and role authorization were removed. |
| 30 | `invalid_super_admin_recipient` | `acl` | The root cannot be transferred to the zero address or its current holder. |
| 31 | `no_pending_super_admin_transfer` | `acl` | No pending super-admin transfer exists. |
| 32 | `not_pending_super_admin_recipient` | `acl` | The transaction sender is not the proposed super-admin recipient. |
| 33 | `super_admin_transfer_not_ready` | `acl` | The pending super-admin transfer delay has not elapsed. |
| 34 | `super_admin_transfer_time_overflow` | `acl` | The transfer execution timestamp would overflow `u64`. |
| 35 | `super_admin_cap_still_active` | `acl` | A super-admin cap can be destroyed only after a replacement made it inert. |
| 36 | `super_admin_transfer_unchanged` | `acl` | The pending super-admin transfer already names this recipient. |
| 37 | `redeem_fee_above_maximum` | `vault` | The requested redemption fee exceeds the immutable 100 bps maximum. |
| 38 | `redeem_fee_unchanged` | `vault` | The requested redemption fee equals the live rate. |
| 39 | `fun_backing_below_supply` | `vault` | Fun custody's conservative assets fell below the funSUI supply. |
| 40 | `stale_exchange_rate` | `vault` | The staking pool has no exchange-rate entry for the current epoch: creation cannot initialize the cache, or a blastSUI receipt cannot be claimed at a current valuation. |
| 41 | `blast_deposit_below_native_minimum` | `vault` | A blastSUI request is below the framework's one-SUI native staking minimum. |
| 42 | `blast_deposit_not_active` | `vault` | A blastSUI receipt is claimed before its native stake activation epoch. |
| 43 | `wrong_receipt_vault` | `deposit_receipt` | A blastSUI receipt was presented to a different vault. |
| 44 | `wrong_receipt_pool` | `deposit_receipt` | A blastSUI receipt's native stake belongs to a different staking pool. |
| 45 | `zero_sui_after_fee` | `vault` | A blastSUI redemption fee would leave no SUI output, so no shares are burned. |
| 46 | *(retired)* | — | Display V2 uniqueness is enforced by the framework registry. |
| 47 | `wrong_delegation_pool` | `custody`, `vault` | Native delegation returned stake from a pool other than the vault's immutable pool. |

The next new error must use code 48.

## Native framework limits

The package performs one current-epoch exchange-rate-table lookup and never
implements a backward scan. The pinned Sui framework can still scan backward
inside native `StakedSui` withdrawal, conversion, and
`FungibleStakedSui` redemption when safe mode has omitted exchange-rate
entries for many epochs. Application code cannot remove that framework cost.
Production operations must gas-test these paths after a long safe-mode run and
monitor their transaction budgets. Receipt cancellation remains independent of
the shared vault and `PackageVersion`, so an upgrade or vault-side failure does
not add an application-level exit dependency.

A validator address can register a fresh pool after its old pool becomes
inactive. The vault therefore treats a current exchange-rate entry for its
immutable pool—not address membership—as the proof required for conversion and
delegation, and it validates the pool ID returned by every native stake request.
If the address is reused before the vault observes departure, the old pool's
rate stays stale: donations and funSUI mints remain liquid, both redemptions and
receipt cancellation remain live, and blastSUI requests fail rather than enter
the new pool. Operations should still call `sync` during departure and use a
new address for any replacement validator.

## Deployment runbook

1. Publish the package. Before any raw-cap upgrade, call `package_admin::wrap`
   with the original Publisher and `UpgradeCap`; upgrading the raw cap first
   changes its package ID and permanently makes this intake reject it.
2. Complete the framework's second Coin Registry step for both OTW currencies:
   call `coin_registry::finalize_registration` for the `funSUI` and `blastSUI`
   `Currency` objects transferred during package initialization.
3. Initialize the package-local ACL and `PackageVersion`, then create the
   receipt Display V2 through `deposit_receipt::create_display` with the system
   `DisplayRegistry` at `0xd`. Confirm the derived display is shared and its
   `DisplayCap` is owned by `@0x0`.
4. Wait until the selected validator's second active epoch so its pool has a
   current exchange-rate entry. Create the vault with that pool ID and the owner
   seed, then verify the emitted validator binding, 0.1-SUI fun reserve, blast
   bootstrap, locked seed shares, and 2-bps redemption fee.

## Upgrade runbook

1. Build and audit the candidate bytecode, then use the active
   `SuperAdminCap` to authorize its exact 32-byte digest.
2. Execute the native package upgrade and commit the matching native upgrade
   receipt into `PackageAdmin`.
3. Advance `PackageVersion` only after the upgraded package is committed and
   integrations are ready to use the new generation. Pass the existing
   `ProtocolAuthority` and active `SuperAdminCap` to the new generation's
   `package_admin::activate_package_version`.
4. Verify that old-generation vault calls fail the version gate, new-generation
   calls succeed, both coin redemptions remain usable, and deposit receipts can
   still cancel directly.

## Verification

Run with the workspace-pinned Sui CLI from this directory, or use
`bash scripts/verify.sh [build|lint|test|all]`:

```bash
sui move build --build-env testnet
sui move build --build-env mainnet
sui move lint --warnings-are-errors
sui move test --lint --warnings-are-errors
```
