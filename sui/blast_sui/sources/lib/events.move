// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

module blast_sui::events;

// === Public Types ===

/// Final native custody buckets of one ledger after a completed transition.
///
/// Conservative ledger backing is `liquid_sui + pending_sui + active_sui`, where
/// `active_sui` is the floor valuation of `active_pool_tokens` at the last
/// applied exchange rate less exact native output since.
public struct PoolCustody has copy, drop {
    liquid_sui: u64,
    pending_sui: u64,
    active_pool_tokens: u64,
    active_sui: u64,
}

/// The pool exchange-rate entry the vault last observed and applies to both ledgers.
///
/// `epoch` is the entry's table key; `sui_amount` and `pool_token_amount` are
/// the native primitives. A refresh in an epoch without an entry (safe mode)
/// keeps the previous entry, so `epoch` may trail the transaction epoch.
public struct ExchangeRate has copy, drop {
    epoch: u64,
    sui_amount: u64,
    pool_token_amount: u64,
}

/// Final custody and supply snapshot of both ledgers after a completed transition.
public struct VaultCustody has copy, drop {
    fun_custody: PoolCustody,
    blast_custody: PoolCustody,
    exchange_rate: ExchangeRate,
    fun_supply: u64,
    blast_supply: u64,
}

/// Emitted after an active admin attaches one capability object to PackageAdmin.
public struct PackageCapabilityAdded has copy, drop {
    package_admin_id: ID,
    capability_id: ID,
    capability_type: TypeName,
}

/// Emitted after the single-validator vault is created from the owner seed.
///
/// `fun_reserve_sui` is the protocol-funded fun safety reserve and
/// `bootstrap_sui` the blast bootstrap; their sum is the owner seed.
/// `locked_blast_sui` is the blastSUI minted one per bootstrap MIST and
/// transferred to `@0x0` in the same transaction: those shares can never be
/// redeemed, so their backing stays in blast custody permanently. No stored
/// field duplicates it; the treasury total supply and this fact are sufficient.
public struct VaultCreated has copy, drop {
    vault_id: ID,
    validator: address,
    pool_id: ID,
    fun_reserve_sui: u64,
    bootstrap_sui: u64,
    locked_blast_sui: u64,
    redeem_fee_bps: u64,
    custody: VaultCustody,
}

/// Emitted after SUI enters fun custody one-to-one for funSUI.
public struct FunSuiMinted has copy, drop {
    sui_in: u64,
    custody: VaultCustody,
}

/// Emitted after funSUI is burned one-to-one for SUI from fun custody.
public struct FunSuiRedeemed has copy, drop {
    fun_in: u64,
    custody: VaultCustody,
}

/// Emitted after native stake is placed in a key-only blastSUI deposit receipt.
public struct BlastSuiDepositRequested has copy, drop {
    receipt_id: ID,
    vault_id: ID,
    pool_id: ID,
    principal_sui: u64,
    activation_epoch: u64,
    custody: VaultCustody,
}

/// Emitted after an activated receipt enters blast custody and mints blastSUI.
public struct BlastSuiDepositClaimed has copy, drop {
    receipt_id: ID,
    vault_id: ID,
    principal_sui: u64,
    contributed_sui: u64,
    pool_tokens: u64,
    blast_out: u64,
    custody: VaultCustody,
}

/// Emitted after a receipt is cancelled directly back to native SUI.
public struct BlastSuiDepositCancelled has copy, drop {
    receipt_id: ID,
    vault_id: ID,
    principal_sui: u64,
    returned_sui: u64,
}

/// Emitted after external SUI enters blast custody without minting blastSUI.
public struct BlastSuiDonated has copy, drop {
    sui_in: u64,
    custody: VaultCustody,
}

/// Emitted after blastSUI shares are burned for their share of blast custody less the retained fee.
public struct BlastSuiRedeemed has copy, drop {
    blast_in: u64,
    gross_sui: u64,
    fee_sui: u64,
    net_sui: u64,
    custody: VaultCustody,
}

/// Emitted after fun yield above the funSUI claim and reserve moved into blast custody.
public struct FunYieldSwept has copy, drop {
    liquid_sui: u64,
    pool_tokens: u64,
    swept_sui: u64,
    custody: VaultCustody,
}

/// Emitted after the `FeeAdmin` changes the blastSUI redemption fee.
public struct RedeemFeeChanged has copy, drop {
    old_redeem_fee_bps: u64,
    new_redeem_fee_bps: u64,
}

/// Emitted after a permissionless refresh, sweep, and idle delegation pass.
public struct VaultSynced has copy, drop {
    custody: VaultCustody,
}

/// Emitted after both ledgers withdrew every native position because the validator left the active set.
public struct NativeStakeUnwound has copy, drop {
    custody: VaultCustody,
}

// === Package Functions ===

/// Constructs one pool-custody snapshot without emitting it.
public(package) fun pool_custody(
    liquid_sui: u64,
    pending_sui: u64,
    active_pool_tokens: u64,
    active_sui: u64,
): PoolCustody {
    PoolCustody { liquid_sui, pending_sui, active_pool_tokens, active_sui }
}

/// Constructs the applied staking exchange-rate snapshot.
public(package) fun exchange_rate(epoch: u64, sui_amount: u64, pool_token_amount: u64): ExchangeRate {
    ExchangeRate { epoch, sui_amount, pool_token_amount }
}

/// Constructs the complete vault-custody snapshot embedded in transition events.
public(package) fun vault_custody(
    fun_custody: PoolCustody,
    blast_custody: PoolCustody,
    exchange_rate: ExchangeRate,
    fun_supply: u64,
    blast_supply: u64,
): VaultCustody {
    VaultCustody { fun_custody, blast_custody, exchange_rate, fun_supply, blast_supply }
}

/// Emits attachment of one typed capability to package custody.
public(package) fun package_capability_added<Capability>(
    package_admin_id: ID,
    capability_id: ID,
) {
    blast_sui::blast_events::emit_event(PackageCapabilityAdded {
        package_admin_id,
        capability_id,
        capability_type: std::type_name::with_original_ids<Capability>(),
    });
}

/// Emits vault creation, locked bootstrap supply, and initial custody state.
public(package) fun vault_created(
    vault_id: ID,
    validator: address,
    pool_id: ID,
    fun_reserve_sui: u64,
    bootstrap_sui: u64,
    locked_blast_sui: u64,
    redeem_fee_bps: u64,
    custody: VaultCustody,
) {
    blast_sui::blast_events::emit_event(VaultCreated {
        vault_id,
        validator,
        pool_id,
        fun_reserve_sui,
        bootstrap_sui,
        locked_blast_sui,
        redeem_fee_bps,
        custody,
    });
}

/// Emits a one-to-one funSUI mint and the resulting custody state.
public(package) fun fun_sui_minted(sui_in: u64, custody: VaultCustody) {
    blast_sui::blast_events::emit_event(FunSuiMinted { sui_in, custody });
}

/// Emits a funSUI redemption and the resulting custody state.
public(package) fun fun_sui_redeemed(fun_in: u64, custody: VaultCustody) {
    blast_sui::blast_events::emit_event(FunSuiRedeemed { fun_in, custody });
}

/// Emits creation of an external native-stake deposit receipt.
public(package) fun blast_sui_deposit_requested(
    receipt_id: ID,
    vault_id: ID,
    pool_id: ID,
    principal_sui: u64,
    activation_epoch: u64,
    custody: VaultCustody,
) {
    blast_sui::blast_events::emit_event(BlastSuiDepositRequested {
        receipt_id,
        vault_id,
        pool_id,
        principal_sui,
        activation_epoch,
        custody,
    });
}

/// Emits settlement of an activated receipt into blast custody and shares.
public(package) fun blast_sui_deposit_claimed(
    receipt_id: ID,
    vault_id: ID,
    principal_sui: u64,
    contributed_sui: u64,
    pool_tokens: u64,
    blast_out: u64,
    custody: VaultCustody,
) {
    blast_sui::blast_events::emit_event(BlastSuiDepositClaimed {
        receipt_id,
        vault_id,
        principal_sui,
        contributed_sui,
        pool_tokens,
        blast_out,
        custody,
    });
}

/// Emits cancellation of an external receipt back into native SUI.
public(package) fun blast_sui_deposit_cancelled(
    receipt_id: ID,
    vault_id: ID,
    principal_sui: u64,
    returned_sui: u64,
) {
    blast_sui::blast_events::emit_event(BlastSuiDepositCancelled {
        receipt_id,
        vault_id,
        principal_sui,
        returned_sui,
    });
}

/// Emits an uncompensated SUI donation and the resulting custody state.
public(package) fun blast_sui_donated(sui_in: u64, custody: VaultCustody) {
    blast_sui::blast_events::emit_event(BlastSuiDonated { sui_in, custody });
}

/// Emits a blastSUI redemption quote, fee, payout, and resulting custody state.
public(package) fun blast_sui_redeemed(
    blast_in: u64,
    gross_sui: u64,
    fee_sui: u64,
    net_sui: u64,
    custody: VaultCustody,
) {
    blast_sui::blast_events::emit_event(BlastSuiRedeemed {
        blast_in,
        gross_sui,
        fee_sui,
        net_sui,
        custody,
    });
}

/// Emits fun-custody yield moved into blast custody.
public(package) fun fun_yield_swept(
    liquid_sui: u64,
    pool_tokens: u64,
    swept_sui: u64,
    custody: VaultCustody,
) {
    blast_sui::blast_events::emit_event(FunYieldSwept {
        liquid_sui,
        pool_tokens,
        swept_sui,
        custody,
    });
}

/// Emits a completed redemption-fee update.
public(package) fun redeem_fee_changed(old_redeem_fee_bps: u64, new_redeem_fee_bps: u64) {
    blast_sui::blast_events::emit_event(RedeemFeeChanged {
        old_redeem_fee_bps,
        new_redeem_fee_bps,
    });
}

/// Emits the canonical custody snapshot after a permissionless sync.
public(package) fun vault_synced(custody: VaultCustody) {
    blast_sui::blast_events::emit_event(VaultSynced { custody });
}

/// Emits custody after every native position has been unwound.
public(package) fun native_stake_unwound(custody: VaultCustody) {
    blast_sui::blast_events::emit_event(NativeStakeUnwound { custody });
}

// === Test-Only Functions ===

#[test_only]
public fun collect<T: copy + drop>(): vector<T> {
    let mut out = vector[];

    sui::event::events_by_type<blast_sui::blast_events::Event<T>>().do!(
        |event| out.push_back(event.unwrap()),
    );

    out
}

#[test_only]
/// Returns the single emitted payload of type `T`, aborting with `abort_code` otherwise.
public fun collect_one<T: copy + drop>(abort_code: u64): T {
    let mut events = collect<T>();

    assert!(events.length() == 1, abort_code);

    events.pop_back()
}

#[test_only]
public fun pool_custody_fields(self: &PoolCustody): (u64, u64, u64, u64) {
    (self.liquid_sui, self.pending_sui, self.active_pool_tokens, self.active_sui)
}

#[test_only]
/// Conservative backing of one ledger: liquid, pending principal, and active valuation.
public fun pool_assets(self: &PoolCustody): u64 {
    self.liquid_sui + self.pending_sui + self.active_sui
}

#[test_only]
public fun exchange_rate_fields(self: &ExchangeRate): (u64, u64, u64) {
    (self.epoch, self.sui_amount, self.pool_token_amount)
}

#[test_only]
public fun vault_custody_fields(
    self: &VaultCustody,
): (PoolCustody, PoolCustody, ExchangeRate, u64, u64) {
    (
        self.fun_custody,
        self.blast_custody,
        self.exchange_rate,
        self.fun_supply,
        self.blast_supply,
    )
}

#[test_only]
public fun package_capability_added_fields(
    self: &PackageCapabilityAdded,
): (ID, ID, TypeName) {
    (self.package_admin_id, self.capability_id, self.capability_type)
}

#[test_only]
public fun vault_created_fields(
    self: &VaultCreated,
): (ID, address, ID, u64, u64, u64, u64, VaultCustody) {
    (
        self.vault_id,
        self.validator,
        self.pool_id,
        self.fun_reserve_sui,
        self.bootstrap_sui,
        self.locked_blast_sui,
        self.redeem_fee_bps,
        self.custody,
    )
}

#[test_only]
public fun fun_sui_minted_fields(self: &FunSuiMinted): (u64, VaultCustody) {
    (self.sui_in, self.custody)
}

#[test_only]
public fun fun_sui_redeemed_fields(self: &FunSuiRedeemed): (u64, VaultCustody) {
    (self.fun_in, self.custody)
}

#[test_only]
public fun blast_sui_deposit_requested_fields(
    self: &BlastSuiDepositRequested,
): (ID, ID, ID, u64, u64, VaultCustody) {
    (
        self.receipt_id,
        self.vault_id,
        self.pool_id,
        self.principal_sui,
        self.activation_epoch,
        self.custody,
    )
}

#[test_only]
public fun blast_sui_deposit_claimed_fields(
    self: &BlastSuiDepositClaimed,
): (ID, ID, u64, u64, u64, u64, VaultCustody) {
    (
        self.receipt_id,
        self.vault_id,
        self.principal_sui,
        self.contributed_sui,
        self.pool_tokens,
        self.blast_out,
        self.custody,
    )
}

#[test_only]
public fun blast_sui_deposit_cancelled_fields(
    self: &BlastSuiDepositCancelled,
): (ID, ID, u64, u64) {
    (self.receipt_id, self.vault_id, self.principal_sui, self.returned_sui)
}

#[test_only]
public fun blast_sui_donated_fields(self: &BlastSuiDonated): (u64, VaultCustody) {
    (self.sui_in, self.custody)
}

#[test_only]
public fun blast_sui_redeemed_fields(
    self: &BlastSuiRedeemed,
): (u64, u64, u64, u64, VaultCustody) {
    (self.blast_in, self.gross_sui, self.fee_sui, self.net_sui, self.custody)
}

#[test_only]
public fun fun_yield_swept_fields(self: &FunYieldSwept): (u64, u64, u64, VaultCustody) {
    (self.liquid_sui, self.pool_tokens, self.swept_sui, self.custody)
}

#[test_only]
public fun redeem_fee_changed_fields(self: &RedeemFeeChanged): (u64, u64) {
    (self.old_redeem_fee_bps, self.new_redeem_fee_bps)
}

#[test_only]
public fun vault_synced_custody(self: &VaultSynced): VaultCustody {
    self.custody
}

#[test_only]
public fun native_stake_unwound_custody(self: &NativeStakeUnwound): VaultCustody {
    self.custody
}

// === Imports ===

use std::type_name::TypeName;
