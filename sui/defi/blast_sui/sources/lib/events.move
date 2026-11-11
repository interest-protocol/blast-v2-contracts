// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

module blast_sui::events;

// === Public Types ===

/// One ledger's native stake in one pool after a completed transition.
///
/// `active_sui` is the floor valuation of `active_pool_tokens` at the pool's last applied
/// exchange rate less exact native output since.
public struct PositionCustody has copy, drop {
    pending_sui: u64,
    active_pool_tokens: u64,
    active_sui: u64,
}

/// A pool's exchange-rate entry the vault last observed and applies to both ledgers.
///
/// `epoch` is the entry's table key; `sui_amount` and `pool_token_amount` are
/// the native primitives. A refresh in an epoch without a usable entry (safe mode)
/// keeps the previous entry, so `epoch` may trail the transaction epoch.
public struct ExchangeRate has copy, drop {
    epoch: u64,
    sui_amount: u64,
    pool_token_amount: u64,
}

/// One admitted pool: its applied rate and its position in each ledger.
public struct PoolSnapshot has copy, drop {
    pool_id: ID,
    exchange_rate: ExchangeRate,
    fun_position: PositionCustody,
    blast_position: PositionCustody,
}

/// Final custody and supply snapshot after a completed transition.
///
/// A ledger's conservative backing is its liquid SUI plus, for every pool, its position's
/// `pending_sui` and `active_sui`.
public struct VaultCustody has copy, drop {
    fun_liquid: u64,
    blast_liquid: u64,
    pools: vector<PoolSnapshot>,
    fun_supply: u64,
    blast_supply: u64,
}

/// Emitted after the vault is created from the owner seed and admits its first validator.
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
///
/// `delegated_sui` is the part of `sui_in` staked to the picked `pool_id`; the rest stays
/// liquid, subject to the vault's idle delegation.
public struct FunSuiMinted has copy, drop {
    pool_id: ID,
    sui_in: u64,
    delegated_sui: u64,
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
///
/// `claimed_pool_tokens` is the receipt's converted active stake joined to blast
/// custody, and `contributed_sui` its floor valuation at the applied rate.
public struct BlastSuiDepositClaimed has copy, drop {
    receipt_id: ID,
    vault_id: ID,
    principal_sui: u64,
    contributed_sui: u64,
    claimed_pool_tokens: u64,
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

/// Emitted after SUI enters fun custody without minting, refreshing, or delegating.
public struct FunReserveToppedUp has copy, drop {
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
///
/// `swept_liquid_sui` and `swept_active_sui` are the amounts moved, not balances, the latter
/// valuing each pool's moved tokens at its applied rate; `swept_sui` is their total.
public struct FunYieldSwept has copy, drop {
    swept_liquid_sui: u64,
    swept_active_sui: u64,
    swept_sui: u64,
    custody: VaultCustody,
}

/// The vault's full custody snapshot. `sync` and `remove_validator` emit it after refreshing
/// every pool; `apply_validator` emits it without a refresh, so other pools' rates may predate
/// the current epoch.
public struct VaultSynced has copy, drop {
    custody: VaultCustody,
}

/// Emitted after a pool left the vault and both ledgers withdrew its native positions, on
/// departure from the active set or on removal.
public struct PoolUnwound has copy, drop {
    pool_id: ID,
    custody: VaultCustody,
}

// === Package Functions ===

/// Constructs one ledger's position snapshot without emitting it.
public(package) fun position_custody(
    pending_sui: u64,
    active_pool_tokens: u64,
    active_sui: u64,
): PositionCustody {
    PositionCustody { pending_sui, active_pool_tokens, active_sui }
}

/// Constructs the applied staking exchange-rate snapshot.
public(package) fun exchange_rate(epoch: u64, sui_amount: u64, pool_token_amount: u64): ExchangeRate {
    ExchangeRate { epoch, sui_amount, pool_token_amount }
}

/// Constructs one pool's snapshot.
public(package) fun pool_snapshot(
    pool_id: ID,
    exchange_rate: ExchangeRate,
    fun_position: PositionCustody,
    blast_position: PositionCustody,
): PoolSnapshot {
    PoolSnapshot { pool_id, exchange_rate, fun_position, blast_position }
}

/// Constructs the complete vault-custody snapshot embedded in transition events.
public(package) fun vault_custody(
    fun_liquid: u64,
    blast_liquid: u64,
    pools: vector<PoolSnapshot>,
    fun_supply: u64,
    blast_supply: u64,
): VaultCustody {
    VaultCustody { fun_liquid, blast_liquid, pools, fun_supply, blast_supply }
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
public(package) fun fun_sui_minted(
    pool_id: ID,
    sui_in: u64,
    delegated_sui: u64,
    custody: VaultCustody,
) {
    blast_sui::blast_events::emit_event(FunSuiMinted { pool_id, sui_in, delegated_sui, custody });
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
    claimed_pool_tokens: u64,
    blast_out: u64,
    custody: VaultCustody,
) {
    blast_sui::blast_events::emit_event(BlastSuiDepositClaimed {
        receipt_id,
        vault_id,
        principal_sui,
        contributed_sui,
        claimed_pool_tokens,
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

/// Emits an uncompensated fun-custody top-up and the resulting custody state.
public(package) fun fun_reserve_topped_up(sui_in: u64, custody: VaultCustody) {
    blast_sui::blast_events::emit_event(FunReserveToppedUp { sui_in, custody });
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
    swept_liquid_sui: u64,
    swept_active_sui: u64,
    swept_sui: u64,
    custody: VaultCustody,
) {
    blast_sui::blast_events::emit_event(FunYieldSwept {
        swept_liquid_sui,
        swept_active_sui,
        swept_sui,
        custody,
    });
}

/// Emits the canonical custody snapshot after a permissionless sync.
public(package) fun vault_synced(custody: VaultCustody) {
    blast_sui::blast_events::emit_event(VaultSynced { custody });
}

/// Emits custody after a pool left the vault and its native positions were unwound.
public(package) fun pool_unwound(pool_id: ID, custody: VaultCustody) {
    blast_sui::blast_events::emit_event(PoolUnwound { pool_id, custody });
}

// === Test-Only Types ===

#[test_only]
/// One ledger's custody summed across every pool.
public struct LedgerTotals has copy, drop {
    liquid_sui: u64,
    pending_sui: u64,
    active_pool_tokens: u64,
    active_sui: u64,
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
public fun position_custody_fields(self: &PositionCustody): (u64, u64, u64) {
    (self.pending_sui, self.active_pool_tokens, self.active_sui)
}

#[test_only]
public fun exchange_rate_fields(self: &ExchangeRate): (u64, u64, u64) {
    (self.epoch, self.sui_amount, self.pool_token_amount)
}

#[test_only]
public fun pool_snapshot_fields(
    self: &PoolSnapshot,
): (ID, ExchangeRate, PositionCustody, PositionCustody) {
    (self.pool_id, self.exchange_rate, self.fun_position, self.blast_position)
}

#[test_only]
public fun vault_custody_pools(self: &VaultCustody): vector<PoolSnapshot> {
    self.pools
}

#[test_only]
public fun vault_custody_liquid(self: &VaultCustody): (u64, u64) {
    (self.fun_liquid, self.blast_liquid)
}

#[test_only]
/// One ledger summed across pools: `(liquid, pending, active tokens, active SUI)`.
public fun ledger_totals_fields(self: &LedgerTotals): (u64, u64, u64, u64) {
    (self.liquid_sui, self.pending_sui, self.active_pool_tokens, self.active_sui)
}

#[test_only]
/// Conservative backing of one ledger: liquid, pending principal, and active valuation.
public fun pool_assets(self: &LedgerTotals): u64 {
    self.liquid_sui + self.pending_sui + self.active_sui
}

#[test_only]
/// Both ledgers summed across pools, the first pool's rate (zero with no pool), and supplies.
public fun vault_custody_fields(
    self: &VaultCustody,
): (LedgerTotals, LedgerTotals, ExchangeRate, u64, u64) {
    let rate = if (self.pools.is_empty()) {
        ExchangeRate { epoch: 0, sui_amount: 0, pool_token_amount: 0 }
    } else {
        self.pools[0].exchange_rate
    };

    (self.fun_totals(), self.blast_totals(), rate, self.fun_supply, self.blast_supply)
}

#[test_only]
public fun fun_totals(self: &VaultCustody): LedgerTotals {
    let mut totals = LedgerTotals {
        liquid_sui: self.fun_liquid,
        pending_sui: 0,
        active_pool_tokens: 0,
        active_sui: 0,
    };
    self.pools.do_ref!(|pool| totals.add(&pool.fun_position));

    totals
}

#[test_only]
public fun blast_totals(self: &VaultCustody): LedgerTotals {
    let mut totals = LedgerTotals {
        liquid_sui: self.blast_liquid,
        pending_sui: 0,
        active_pool_tokens: 0,
        active_sui: 0,
    };
    self.pools.do_ref!(|pool| totals.add(&pool.blast_position));

    totals
}

#[test_only]
fun add(self: &mut LedgerTotals, position: &PositionCustody) {
    self.pending_sui = self.pending_sui + position.pending_sui;
    self.active_pool_tokens = self.active_pool_tokens + position.active_pool_tokens;
    self.active_sui = self.active_sui + position.active_sui;
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
public fun fun_sui_minted_fields(self: &FunSuiMinted): (ID, u64, u64, VaultCustody) {
    (self.pool_id, self.sui_in, self.delegated_sui, self.custody)
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
        self.claimed_pool_tokens,
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
public fun fun_reserve_topped_up_fields(self: &FunReserveToppedUp): (u64, VaultCustody) {
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
    (self.swept_liquid_sui, self.swept_active_sui, self.swept_sui, self.custody)
}

#[test_only]
public fun vault_synced_custody(self: &VaultSynced): VaultCustody {
    self.custody
}

#[test_only]
public fun pool_unwound_fields(self: &PoolUnwound): (ID, VaultCustody) {
    (self.pool_id, self.custody)
}
