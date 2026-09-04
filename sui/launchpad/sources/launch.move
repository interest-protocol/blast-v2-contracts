// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Normalized launch construction, custody, and one-time creator claim.
module blast_fun::launch;

use blast_fun::{
    acl::AdminWitness,
    bps::Bps,
    constants,
    creator_authority::{CreatorAuthority, CreatorCap},
    curve,
    events,
    fees::{Self, FeeLedger},
    launch_config::LaunchConfig,
    launch_ticket::LaunchTicket,
    package_version::PackageVersion,
    runtime_config::RuntimeConfig,
};
use std::type_name::{Self, TypeName};
use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    coin_registry::{Currency, MetadataCap},
};

use fun dispose_meme as Balance.dispose_meme;

// === Public Structs ===

/// Consensus lifecycle for one launch market and its terminal handoff.
public enum Lifecycle has copy, drop, store {
    Live,
    MigrationReady,
    Migrated,
}

/// Linear terminal balances that an authenticated external adapter must consume.
public struct MigrationPayload<phantom Meme, phantom Quote, phantom MigrationWitness> {
    meme: Balance<Meme>,
    quote: Balance<Quote>,
}

/// Pair-typed custody and immutable policy for one configured launch.
public struct Launch<phantom Meme, phantom Quote> has key {
    id: UID,
    lifecycle: Lifecycle,
    sell_burn_bps: Bps,
    virtual_quote: u64,
    migration_quote_target: u64,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    quote_migration_fee_bps: Bps,
    protocol_meme_graduation_fee_bps: Bps,
    meme_liquidity_provision_bps: Bps,
    migration_witness: TypeName,
    meme_reserve: Balance<Meme>,
    real_quote_reserve: Balance<Quote>,
    pending_burn: Balance<Meme>,
    protocol_meme_graduation_fee: Balance<Meme>,
    meme_liquidity_provision: Balance<Meme>,
    fee_ledger: FeeLedger<Meme, Quote>,
    metadata_cap: Option<MetadataCap<Meme>>,
    creator_authority: Option<CreatorAuthority<Meme>>,
}

// === Public Functions ===

/// Consumes one generated-coin ticket and returns normalized launch custody.
public fun new<Meme, Quote, MigrationWitness: drop>(
    ticket: LaunchTicket<Meme>,
    package_version: &PackageVersion,
    config: &LaunchConfig,
    ctx: &mut TxContext,
): Launch<Meme, Quote> {
    package_version.assert_current();
    assert!(
        type_name::with_original_ids<Meme>() != type_name::with_original_ids<Quote>(),
        blast_fun::errors::invalid_meme_quote_pair!(),
    );
    assert!(
        ticket.initial_supply() == constants::meme_total_supply_atomic_units!(),
        blast_fun::errors::invalid_initial_meme_supply!(),
    );

    let (
        virtual_quote,
        migration_quote_target,
        quote_fee_bps,
        meme_fee_bps,
        quote_migration_fee_bps,
        protocol_meme_graduation_fee_bps,
        meme_liquidity_provision_bps,
        migration_witness,
    ) = config.snapshot_for_launch<Quote, MigrationWitness>();
    let ticket_id = object::id(&ticket);
    // LaunchTicket construction already finalized Currency<Meme> as Fixed or BurnOnly.
    let (meme, metadata_cap, creator_authority, sell_burn_bps) =
        ticket.destroy();
    let initial_meme_supply = meme.value();
    let (meme_reserve, protocol_meme_graduation_fee, meme_liquidity_provision) =
        partition_meme(
            meme,
            protocol_meme_graduation_fee_bps,
            meme_liquidity_provision_bps,
        );
    let metadata_cap_id = object::id(&metadata_cap);

    let launch = Launch {
        id: object::new(ctx),
        lifecycle: Lifecycle::Live,
        sell_burn_bps,
        virtual_quote,
        migration_quote_target,
        quote_fee_bps,
        meme_fee_bps,
        quote_migration_fee_bps,
        protocol_meme_graduation_fee_bps,
        meme_liquidity_provision_bps,
        migration_witness,
        meme_reserve,
        real_quote_reserve: balance::zero(),
        pending_burn: balance::zero(),
        protocol_meme_graduation_fee,
        meme_liquidity_provision,
        fee_ledger: fees::new(),
        metadata_cap: option::some(metadata_cap),
        creator_authority: option::some(creator_authority),
    };

    launch.emit_created(
        ticket_id,
        initial_meme_supply,
        metadata_cap_id,
        ctx.sender(),
    );

    launch
}

/// Shares one fully constructed launch as top-level protocol state.
public fun share<Meme, Quote>(self: Launch<Meme, Quote>) {
    transfer::share_object(self);
}

/// Consumes the launch's creator authority and returns both creator capabilities.
public fun claim_creator_cap<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    config: &RuntimeConfig,
    x_attestation: Option<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): (CreatorCap<Meme>, MetadataCap<Meme>) {
    package_version.assert_current();
    assert!(
        self.creator_authority.is_some() && self.metadata_cap.is_some(),
        blast_fun::errors::creator_authority_unavailable!(),
    );

    let authority = self.creator_authority.extract();
    let metadata_cap = self.metadata_cap.extract();
    let creator_cap = authority.claim_creator_cap(
        config,
        x_attestation,
        clock,
        ctx,
    );

    (creator_cap, metadata_cap)
}

/// Exchanges Quote for Meme and returns any terminal-target excess as a Quote coin.
public fun buy<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    quote_in: Coin<Quote>,
    min_meme_out: u64,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current();
    self.assert_live();

    let quote_supplied = quote_in.value();
    let (quote_in_gross, quote_refund) = curve::cap_buy_quote_input(
        self.real_quote_reserve.value(),
        self.migration_quote_target,
        quote_supplied,
        self.quote_fee_bps,
    );
    let (
        quote_fee,
        quote_in_net,
        meme_out_gross,
        meme_fee,
        meme_out_net,
        _,
        _,
        crossed_threshold,
    ) = curve::quote_buy(
        self.meme_reserve.value(),
        self.real_quote_reserve.value(),
        self.virtual_quote,
        self.migration_quote_target,
        quote_in_gross,
        self.quote_fee_bps,
        self.meme_fee_bps,
    );

    assert!(
        meme_out_net >= min_meme_out,
        blast_fun::errors::slippage_exceeded!(),
    );

    let mut quote_in = quote_in.into_balance();
    let quote_refund = quote_in.split(quote_refund);
    let quote_fee_balance = quote_in.split(quote_fee);
    self.real_quote_reserve.join(quote_in);

    let mut meme_out = self.meme_reserve.split(meme_out_gross);
    let meme_fee_balance = meme_out.split(meme_fee);
    if (crossed_threshold) {
        self.lifecycle = Lifecycle::MigrationReady;
    };

    self.accrue_and_emit_bought(
        meme_fee_balance,
        quote_fee_balance,
        runtime_config.protocol_fee_share(),
        ctx.sender(),
        quote_supplied,
        quote_in_gross,
        quote_refund.value(),
        quote_fee,
        quote_in_net,
        meme_out_gross,
        meme_fee,
        meme_out_net,
        crossed_threshold,
    );

    (meme_out.into_coin(ctx), quote_refund.into_coin(ctx))
}

/// Exchanges one Meme coin for Quote and escrows its sell-burn allocation.
public fun sell<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    meme_in: Coin<Meme>,
    min_quote_out: u64,
    ctx: &mut TxContext,
): Coin<Quote> {
    package_version.assert_current();
    self.assert_live();

    let meme_in_gross = meme_in.value();
    let (
        meme_fee,
        meme_in_after_fee,
        progress_bps,
        burn_bps,
        pending_burn_delta,
        meme_in_effective,
        quote_out_gross,
        quote_fee,
        quote_out_net,
        _,
        _,
    ) = curve::quote_sell(
        self.meme_reserve.value(),
        self.real_quote_reserve.value(),
        self.virtual_quote,
        self.migration_quote_target,
        meme_in_gross,
        self.quote_fee_bps,
        self.meme_fee_bps,
        self.sell_burn_bps,
    );

    assert!(
        quote_out_net >= min_quote_out,
        blast_fun::errors::slippage_exceeded!(),
    );

    let mut meme_in = meme_in.into_balance();
    let meme_fee_balance = meme_in.split(meme_fee);
    let pending_burn_total = self.pending_burn.join(meme_in.split(pending_burn_delta));
    self.meme_reserve.join(meme_in);

    let mut quote_out = self.real_quote_reserve.split(quote_out_gross);
    let quote_fee_balance = quote_out.split(quote_fee);
    let protocol_fee_share_bps = runtime_config.protocol_fee_share();

    self.accrue_and_emit_sold(
        meme_fee_balance,
        quote_fee_balance,
        protocol_fee_share_bps,
        ctx.sender(),
        meme_in_gross,
        meme_fee,
        meme_in_after_fee,
        progress_bps,
        burn_bps,
        pending_burn_delta,
        pending_burn_total,
        meme_in_effective,
        quote_out_gross,
        quote_fee,
        quote_out_net,
    );

    quote_out.into_coin(ctx)
}

/// Drains creator trade fees under the launch's typed creator capability.
public fun claim_creator_fees<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    creator_cap: &CreatorCap<Meme>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current();

    let (meme, quote) = self.fee_ledger.claim_creator_fees(creator_cap, ctx);

    events::creator_fees_claimed<Meme, Quote>(
        self.id.to_inner(),
        ctx.sender(),
        meme.value(),
        quote.value(),
    );

    (meme, quote)
}

/// Drains protocol trade and graduation fees under live admin authority.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current();

    let (meme, quote) = self.fee_ledger.claim_protocol_fees(admin_witness, ctx);

    events::protocol_fees_claimed<Meme, Quote>(
        self.id.to_inner(),
        ctx.sender(),
        meme.value(),
        quote.value(),
    );

    (meme, quote)
}

/// Performs the permissionless terminal transition and returns a typed adapter handoff.
public fun migrate<Meme, Quote, MigrationWitness: drop>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    currency: &mut Currency<Meme>,
    ctx: &mut TxContext,
): MigrationPayload<Meme, Quote, MigrationWitness> {
    package_version.assert_current();
    assert!(
        self.lifecycle == Lifecycle::MigrationReady,
        blast_fun::errors::invalid_launch_lifecycle!(),
    );
    assert!(
        self.migration_witness
            == type_name::with_original_ids<MigrationWitness>(),
        blast_fun::errors::invalid_migration_witness!(),
    );
    let burnable = currency.is_supply_burn_only();

    let (
        quote,
        protocol_meme_graduation_fee_amount,
        quote_migration_fee_amount,
        protocol_meme_fee_total,
        protocol_quote_fee_total,
    ) = self.accrue_graduation_fees();
    let meme = self.meme_liquidity_provision.withdraw_all();
    let mut disposal = self.pending_burn.withdraw_all();
    let disposed_meme = disposal.join(self.meme_reserve.withdraw_all());

    disposal.dispose_meme(currency, burnable, ctx);

    self.lifecycle = Lifecycle::Migrated;

    events::migrated<Meme, Quote, MigrationWitness>(
        self.id.to_inner(),
        ctx.sender(),
        burnable,
        meme.value(),
        quote.value(),
        disposed_meme,
        currency.total_supply().destroy_some(),
        protocol_meme_graduation_fee_amount,
        quote_migration_fee_amount,
        protocol_meme_fee_total,
        protocol_quote_fee_total,
    );

    MigrationPayload { meme, quote }
}

/// Opens the linear handoff with the witness owned by the selected adapter.
public fun redeem_migration<Meme, Quote, MigrationWitness: drop>(
    self: MigrationPayload<Meme, Quote, MigrationWitness>,
    _: MigrationWitness,
): (Balance<Meme>, Balance<Quote>) {
    let MigrationPayload { meme, quote } = self;

    (meme, quote)
}

// === Private Functions ===

/// Partitions the initial Meme balance into curve, protocol, and destination-pool custody.
fun partition_meme<Meme>(
    mut meme: Balance<Meme>,
    protocol_meme_graduation_fee_bps: Bps,
    meme_liquidity_provision_bps: Bps,
): (Balance<Meme>, Balance<Meme>, Balance<Meme>) {
    assert!(
        protocol_meme_graduation_fee_bps.value()
            <= constants::max_protocol_meme_graduation_fee_bps!(),
        blast_fun::errors::invalid_protocol_meme_graduation_fee_bps!(),
    );
    assert!(
        meme_liquidity_provision_bps.value() > 0
            && meme_liquidity_provision_bps.value()
                <= constants::max_meme_liquidity_provision_bps!(),
        blast_fun::errors::invalid_meme_liquidity_provision_bps!(),
    );
    assert!(
        protocol_meme_graduation_fee_bps.value()
            + meme_liquidity_provision_bps.value()
            < constants::basis_points_denominator!(),
        blast_fun::errors::invalid_meme_supply_partition_bps!(),
    );

    let initial_supply = meme.value();
    let protocol_meme_fee_amount =
        protocol_meme_graduation_fee_bps.apply_up(initial_supply);
    let provision_amount = meme_liquidity_provision_bps.apply_down(initial_supply);

    assert!(
        provision_amount > 0,
        blast_fun::errors::zero_meme_liquidity_provision!(),
    );
    assert!(
        protocol_meme_fee_amount + provision_amount < initial_supply,
        blast_fun::errors::zero_meme_curve_inventory!(),
    );

    let protocol_meme_fee = meme.split(protocol_meme_fee_amount);
    let provision = meme.split(provision_amount);

    (meme, protocol_meme_fee, provision)
}

/// Partitions terminal Quote into migration principal and protocol revenue.
fun partition_quote<Quote>(
    mut quote: Balance<Quote>,
    quote_migration_fee_bps: Bps,
): (Balance<Quote>, Balance<Quote>) {
    let fee_amount = quote_migration_fee_bps.apply_up(quote.value());
    let migration_fee = quote.split(fee_amount);

    (quote, migration_fee)
}

fun assert_live<Meme, Quote>(self: &Launch<Meme, Quote>) {
    assert!(
        self.lifecycle == Lifecycle::Live,
        blast_fun::errors::invalid_launch_lifecycle!(),
    );
}

fun accrue_graduation_fees<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
): (Balance<Quote>, u64, u64, u64, u64) {
    let (quote, quote_migration_fee) = partition_quote(
        self.real_quote_reserve.withdraw_all(),
        self.quote_migration_fee_bps,
    );
    let protocol_meme_graduation_fee =
        self.protocol_meme_graduation_fee.withdraw_all();
    let protocol_meme_graduation_fee_amount =
        protocol_meme_graduation_fee.value();
    let quote_migration_fee_amount = quote_migration_fee.value();
    let (
        _,
        _,
        protocol_meme_fee_total,
        protocol_quote_fee_total,
    ) = self.fee_ledger.accrue_protocol_fees(
        protocol_meme_graduation_fee,
        quote_migration_fee,
    );

    (
        quote,
        protocol_meme_graduation_fee_amount,
        quote_migration_fee_amount,
        protocol_meme_fee_total,
        protocol_quote_fee_total,
    )
}

fun dispose_meme<Meme>(
    disposal: Balance<Meme>,
    currency: &mut Currency<Meme>,
    burn_supply: bool,
    ctx: &mut TxContext,
) {
    if (burn_supply) {
        currency.burn_balance(disposal);
    } else {
        transfer::public_transfer(disposal.into_coin(ctx), @0x0);
    };
}

fun accrue_trade_fees<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    meme_fee: Balance<Meme>,
    quote_fee: Balance<Quote>,
    protocol_fee_share_bps: Bps,
): (u64, u64, u64, u64, u64, u64, u64, u64) {
    if (meme_fee.value() == 0 && quote_fee.value() == 0) {
        meme_fee.destroy_zero();
        quote_fee.destroy_zero();
        let (
            protocol_meme_fee_total,
            creator_meme_fee_total,
            protocol_quote_fee_total,
            creator_quote_fee_total,
        ) = self.fee_ledger.totals();

        (
            0,
            0,
            0,
            0,
            protocol_meme_fee_total,
            creator_meme_fee_total,
            protocol_quote_fee_total,
            creator_quote_fee_total,
        )
    } else {
        self.fee_ledger.accrue(
            meme_fee,
            quote_fee,
            protocol_fee_share_bps,
        )
    }
}

fun accrue_and_emit_bought<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    meme_fee_balance: Balance<Meme>,
    quote_fee_balance: Balance<Quote>,
    protocol_fee_share_bps: Bps,
    buyer: address,
    quote_supplied: u64,
    quote_in_gross: u64,
    quote_refund: u64,
    quote_fee: u64,
    quote_in_net: u64,
    meme_out_gross: u64,
    meme_fee: u64,
    meme_out_net: u64,
    crossed_threshold: bool,
) {
    let (
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
    ) = self.accrue_trade_fees(
        meme_fee_balance,
        quote_fee_balance,
        protocol_fee_share_bps,
    );

    events::bought<Meme, Quote>(
        self.id.to_inner(),
        buyer,
        quote_supplied,
        quote_in_gross,
        quote_refund,
        quote_fee,
        quote_in_net,
        meme_out_gross,
        meme_fee,
        meme_out_net,
        protocol_fee_share_bps.value(),
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
        self.meme_reserve.value(),
        self.real_quote_reserve.value(),
        crossed_threshold,
    );
}

fun accrue_and_emit_sold<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    meme_fee_balance: Balance<Meme>,
    quote_fee_balance: Balance<Quote>,
    protocol_fee_share_bps: Bps,
    seller: address,
    meme_in_gross: u64,
    meme_fee: u64,
    meme_in_after_fee: u64,
    progress_bps: u64,
    burn_bps: u64,
    pending_burn_delta: u64,
    pending_burn_total: u64,
    meme_in_effective: u64,
    quote_out_gross: u64,
    quote_fee: u64,
    quote_out_net: u64,
) {
    let (
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
    ) = self.accrue_trade_fees(
        meme_fee_balance,
        quote_fee_balance,
        protocol_fee_share_bps,
    );

    events::sold<Meme, Quote>(
        self.id.to_inner(),
        seller,
        meme_in_gross,
        meme_fee,
        meme_in_after_fee,
        progress_bps,
        burn_bps,
        pending_burn_delta,
        pending_burn_total,
        meme_in_effective,
        quote_out_gross,
        quote_fee,
        quote_out_net,
        protocol_fee_share_bps.value(),
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
        self.meme_reserve.value(),
        self.real_quote_reserve.value(),
    );
}

fun emit_created<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    ticket_id: ID,
    initial_meme_supply: u64,
    metadata_cap_id: ID,
    launcher: address,
) {
    events::launch_created<Meme, Quote>(
        self.id.to_inner(),
        ticket_id,
        self.migration_witness,
        launcher,
        metadata_cap_id,
        self.sell_burn_bps.value(),
        initial_meme_supply,
        self.meme_reserve.value(),
        self.real_quote_reserve.value(),
        self.pending_burn.value(),
        self.protocol_meme_graduation_fee.value(),
        self.meme_liquidity_provision.value(),
        0,
        0,
        0,
        0,
        self.virtual_quote,
        self.migration_quote_target,
        self.quote_fee_bps.value(),
        self.meme_fee_bps.value(),
        self.quote_migration_fee_bps.value(),
        self.protocol_meme_graduation_fee_bps.value(),
        self.meme_liquidity_provision_bps.value(),
    );
}

// === Test-Only Functions ===

#[test_only]
/// Exposes the private initial Meme partition to focused arithmetic tests.
public fun partition_meme_for_testing<Meme>(
    meme: Balance<Meme>,
    protocol_meme_graduation_fee_bps: Bps,
    meme_liquidity_provision_bps: Bps,
): (Balance<Meme>, Balance<Meme>, Balance<Meme>) {
    partition_meme(
        meme,
        protocol_meme_graduation_fee_bps,
        meme_liquidity_provision_bps,
    )
}

#[test_only]
/// Exposes the private terminal Quote partition to focused arithmetic tests.
public fun partition_quote_for_testing<Quote>(
    quote: Balance<Quote>,
    quote_migration_fee_bps: Bps,
): (Balance<Quote>, Balance<Quote>) {
    partition_quote(quote, quote_migration_fee_bps)
}

#[test_only]
public fun initial_balances_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
): (u64, u64, u64, u64, u64) {
    (
        self.meme_reserve.value(),
        self.real_quote_reserve.value(),
        self.pending_burn.value(),
        self.protocol_meme_graduation_fee.value(),
        self.meme_liquidity_provision.value(),
    )
}

#[test_only]
public fun policy_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
): (u64, u64, u64, u64, u64, u64, u64, TypeName) {
    (
        self.virtual_quote,
        self.migration_quote_target,
        self.quote_fee_bps.value(),
        self.meme_fee_bps.value(),
        self.quote_migration_fee_bps.value(),
        self.protocol_meme_graduation_fee_bps.value(),
        self.meme_liquidity_provision_bps.value(),
        self.migration_witness,
    )
}

#[test_only]
public fun metadata_cap_id_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
): ID {
    object::id(self.metadata_cap.borrow())
}

#[test_only]
public fun has_creator_authority_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
): bool {
    self.creator_authority.is_some()
}

#[test_only]
public fun has_metadata_cap_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
): bool {
    self.metadata_cap.is_some()
}

#[test_only]
public fun lifecycle_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
): (bool, bool, bool) {
    (
        self.lifecycle == Lifecycle::Live,
        self.lifecycle == Lifecycle::MigrationReady,
        self.lifecycle == Lifecycle::Migrated,
    )
}

#[test_only]
public fun sell_burn_bps_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
): u64 {
    self.sell_burn_bps.value()
}

#[test_only]
public fun fee_totals_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
): (u64, u64, u64, u64) {
    self.fee_ledger.totals()
}
