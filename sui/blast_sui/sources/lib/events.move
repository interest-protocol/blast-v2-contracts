/// Replay-complete event payloads for blastSUI state transitions.
module blast_sui::events;

use std::type_name::TypeName;

// === Public Structs ===

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

/// Emitted after a delayed root-authority transfer is scheduled.
public struct SuperAdminTransferStarted has copy, drop {
    recipient: address,
    execute_after_ms: u64,
}

/// Emitted after a pending root-authority transfer is cancelled or replaced.
public struct SuperAdminTransferCancelled has copy, drop {
    recipient: address,
}

/// Emitted after the proposed recipient accepts root authority.
public struct SuperAdminTransferred has copy, drop {
    previous_super_admin_cap_id: ID,
    new_super_admin_cap_id: ID,
    recipient: address,
}

/// Emitted after checked activation advances the shared bytecode cutover.
public struct PackageVersionAdvanced has copy, drop {
    previous_version: u64,
    new_version: u64,
}

/// Emitted after the root grants and delivers one routine administrator.
public struct AdminGranted has copy, drop {
    admin_cap_id: ID,
    recipient: address,
}

/// Emitted after the root removes one routine administrator from the live registry.
public struct AdminRevoked has copy, drop {
    admin_cap_id: ID,
}

/// Emitted after an AdminCap holder deletes its object.
public struct AdminDestroyed has copy, drop {
    admin_cap_id: ID,
    was_active: bool,
}

/// Emitted after an active admin attaches one capability object to PackageAdmin.
public struct PackageCapabilityAdded has copy, drop {
    package_admin_id: ID,
    capability_id: ID,
    capability_type: TypeName,
}

/// Emitted after the validated package capabilities enter permanent shared custody.
public struct PackageAdminCreated has copy, drop {
    package_admin_id: ID,
    publisher_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    package_version: u64,
    policy: u8,
}

/// Emitted after the super-admin authorizes an exact package digest.
public struct UpgradeAuthorized has copy, drop {
    digest: vector<u8>,
}

/// Emitted after the native upgrade receipt advances the wrapped UpgradeCap.
public struct UpgradeCommitted has copy, drop {
    new_package_id: ID,
    previous_version: u64,
    new_version: u64,
}

/// Emitted after the super-admin irreversibly narrows upgrade policy.
public struct UpgradePolicyRestricted has copy, drop {
    previous_policy: u8,
    new_policy: u8,
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

/// Emitted after the super-admin changes the blastSUI redemption fee.
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

public(package) fun pool_custody(
    liquid_sui: u64,
    pending_sui: u64,
    active_pool_tokens: u64,
    active_sui: u64,
): PoolCustody {
    PoolCustody { liquid_sui, pending_sui, active_pool_tokens, active_sui }
}

public(package) fun exchange_rate(epoch: u64, sui_amount: u64, pool_token_amount: u64): ExchangeRate {
    ExchangeRate { epoch, sui_amount, pool_token_amount }
}

public(package) fun vault_custody(
    fun_custody: PoolCustody,
    blast_custody: PoolCustody,
    exchange_rate: ExchangeRate,
    fun_supply: u64,
    blast_supply: u64,
): VaultCustody {
    VaultCustody { fun_custody, blast_custody, exchange_rate, fun_supply, blast_supply }
}

public(package) fun super_admin_transfer_started(recipient: address, execute_after_ms: u64) {
    blast_sui::events_wrapper::emit_event(SuperAdminTransferStarted {
        recipient,
        execute_after_ms,
    });
}

public(package) fun super_admin_transfer_cancelled(recipient: address) {
    blast_sui::events_wrapper::emit_event(SuperAdminTransferCancelled { recipient });
}

public(package) fun super_admin_transferred(
    previous_super_admin_cap_id: ID,
    new_super_admin_cap_id: ID,
    recipient: address,
) {
    blast_sui::events_wrapper::emit_event(SuperAdminTransferred {
        previous_super_admin_cap_id,
        new_super_admin_cap_id,
        recipient,
    });
}

public(package) fun package_version_advanced(previous_version: u64, new_version: u64) {
    blast_sui::events_wrapper::emit_event(PackageVersionAdvanced {
        previous_version,
        new_version,
    });
}

public(package) fun admin_granted(admin_cap_id: ID, recipient: address) {
    blast_sui::events_wrapper::emit_event(AdminGranted { admin_cap_id, recipient });
}

public(package) fun admin_revoked(admin_cap_id: ID) {
    blast_sui::events_wrapper::emit_event(AdminRevoked { admin_cap_id });
}

public(package) fun admin_destroyed(admin_cap_id: ID, was_active: bool) {
    blast_sui::events_wrapper::emit_event(AdminDestroyed { admin_cap_id, was_active });
}

public(package) fun package_capability_added<Capability>(
    package_admin_id: ID,
    capability_id: ID,
) {
    blast_sui::events_wrapper::emit_event(PackageCapabilityAdded {
        package_admin_id,
        capability_id,
        capability_type: std::type_name::with_original_ids<Capability>(),
    });
}

public(package) fun package_admin_created(
    package_admin_id: ID,
    publisher_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    package_version: u64,
    policy: u8,
) {
    blast_sui::events_wrapper::emit_event(PackageAdminCreated {
        package_admin_id,
        publisher_id,
        upgrade_cap_id,
        package_id,
        package_version,
        policy,
    });
}

public(package) fun upgrade_authorized(digest: vector<u8>) {
    blast_sui::events_wrapper::emit_event(UpgradeAuthorized { digest });
}

public(package) fun upgrade_committed(
    new_package_id: ID,
    previous_version: u64,
    new_version: u64,
) {
    blast_sui::events_wrapper::emit_event(UpgradeCommitted {
        new_package_id,
        previous_version,
        new_version,
    });
}

public(package) fun upgrade_policy_restricted(previous_policy: u8, new_policy: u8) {
    blast_sui::events_wrapper::emit_event(UpgradePolicyRestricted {
        previous_policy,
        new_policy,
    });
}

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
    blast_sui::events_wrapper::emit_event(VaultCreated {
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

public(package) fun fun_sui_minted(sui_in: u64, custody: VaultCustody) {
    blast_sui::events_wrapper::emit_event(FunSuiMinted { sui_in, custody });
}

public(package) fun fun_sui_redeemed(fun_in: u64, custody: VaultCustody) {
    blast_sui::events_wrapper::emit_event(FunSuiRedeemed { fun_in, custody });
}

public(package) fun blast_sui_deposit_requested(
    receipt_id: ID,
    vault_id: ID,
    pool_id: ID,
    principal_sui: u64,
    activation_epoch: u64,
    custody: VaultCustody,
) {
    blast_sui::events_wrapper::emit_event(BlastSuiDepositRequested {
        receipt_id,
        vault_id,
        pool_id,
        principal_sui,
        activation_epoch,
        custody,
    });
}

public(package) fun blast_sui_deposit_claimed(
    receipt_id: ID,
    vault_id: ID,
    principal_sui: u64,
    contributed_sui: u64,
    pool_tokens: u64,
    blast_out: u64,
    custody: VaultCustody,
) {
    blast_sui::events_wrapper::emit_event(BlastSuiDepositClaimed {
        receipt_id,
        vault_id,
        principal_sui,
        contributed_sui,
        pool_tokens,
        blast_out,
        custody,
    });
}

public(package) fun blast_sui_deposit_cancelled(
    receipt_id: ID,
    vault_id: ID,
    principal_sui: u64,
    returned_sui: u64,
) {
    blast_sui::events_wrapper::emit_event(BlastSuiDepositCancelled {
        receipt_id,
        vault_id,
        principal_sui,
        returned_sui,
    });
}

public(package) fun blast_sui_donated(sui_in: u64, custody: VaultCustody) {
    blast_sui::events_wrapper::emit_event(BlastSuiDonated { sui_in, custody });
}

public(package) fun blast_sui_redeemed(
    blast_in: u64,
    gross_sui: u64,
    fee_sui: u64,
    net_sui: u64,
    custody: VaultCustody,
) {
    blast_sui::events_wrapper::emit_event(BlastSuiRedeemed {
        blast_in,
        gross_sui,
        fee_sui,
        net_sui,
        custody,
    });
}

public(package) fun fun_yield_swept(
    liquid_sui: u64,
    pool_tokens: u64,
    swept_sui: u64,
    custody: VaultCustody,
) {
    blast_sui::events_wrapper::emit_event(FunYieldSwept {
        liquid_sui,
        pool_tokens,
        swept_sui,
        custody,
    });
}

public(package) fun redeem_fee_changed(old_redeem_fee_bps: u64, new_redeem_fee_bps: u64) {
    blast_sui::events_wrapper::emit_event(RedeemFeeChanged {
        old_redeem_fee_bps,
        new_redeem_fee_bps,
    });
}

public(package) fun vault_synced(custody: VaultCustody) {
    blast_sui::events_wrapper::emit_event(VaultSynced { custody });
}

public(package) fun native_stake_unwound(custody: VaultCustody) {
    blast_sui::events_wrapper::emit_event(NativeStakeUnwound { custody });
}

// === Test-Only Functions ===

#[test_only]
public fun collect<T: copy + drop>(): vector<T> {
    let mut out = vector[];

    sui::event::events_by_type<blast_sui::events_wrapper::Event<T>>().do!(
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
public fun super_admin_transfer_started_fields(
    self: &SuperAdminTransferStarted,
): (address, u64) {
    (self.recipient, self.execute_after_ms)
}

#[test_only]
public fun super_admin_transfer_cancelled_fields(self: &SuperAdminTransferCancelled): address {
    self.recipient
}

#[test_only]
public fun super_admin_transferred_fields(self: &SuperAdminTransferred): (ID, ID, address) {
    (self.previous_super_admin_cap_id, self.new_super_admin_cap_id, self.recipient)
}

#[test_only]
public fun package_version_advanced_fields(self: &PackageVersionAdvanced): (u64, u64) {
    (self.previous_version, self.new_version)
}

#[test_only]
public fun admin_granted_fields(self: &AdminGranted): (ID, address) {
    (self.admin_cap_id, self.recipient)
}

#[test_only]
public fun admin_revoked_fields(self: &AdminRevoked): ID {
    self.admin_cap_id
}

#[test_only]
public fun admin_destroyed_fields(self: &AdminDestroyed): (ID, bool) {
    (self.admin_cap_id, self.was_active)
}

#[test_only]
public fun package_capability_added_fields(
    self: &PackageCapabilityAdded,
): (ID, ID, TypeName) {
    (self.package_admin_id, self.capability_id, self.capability_type)
}

#[test_only]
public fun package_admin_created_fields(
    self: &PackageAdminCreated,
): (ID, ID, ID, ID, u64, u8) {
    (
        self.package_admin_id,
        self.publisher_id,
        self.upgrade_cap_id,
        self.package_id,
        self.package_version,
        self.policy,
    )
}

#[test_only]
public fun upgrade_authorized_digest(self: &UpgradeAuthorized): vector<u8> {
    self.digest
}

#[test_only]
public fun upgrade_committed_fields(self: &UpgradeCommitted): (ID, u64, u64) {
    (self.new_package_id, self.previous_version, self.new_version)
}

#[test_only]
public fun upgrade_policy_restricted_fields(self: &UpgradePolicyRestricted): (u8, u8) {
    (self.previous_policy, self.new_policy)
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
