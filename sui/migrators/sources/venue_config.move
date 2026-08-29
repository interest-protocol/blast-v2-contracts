/// Admin-pinned production fee tier for every migration venue.
///
/// `launch::migrate` is deliberately permissionless, so no migration caller may
/// choose the venue fee tier or tick spacing of the pool that permanently
/// custodies the launch principal. This shared singleton pins one production
/// tier per venue. Every value starts unset and each route fails closed until a
/// live core administrator pins its venue, so tier policy stays correctable on
/// mainnet without a package upgrade even after the `UpgradeCap` is destroyed.
module blast_fun_migrators::venue_config;

use blast_fun::acl::AdminWitness;
use blast_fun_migrators::events;

// === Constants ===

const EVenueTierUnset: u64 = 0;
const EInvalidTickSpacing: u64 = 1;
const EInvalidFeeRate: u64 = 2;
const EUnchangedTier: u64 = 3;

// === Public Structs ===

/// Shared singleton holding the pinned per-venue tier policy.
///
/// A zero field is unset. Setters reject zero, so once a venue is pinned its
/// reads can never abort again; changes affect only later migrations.
public struct VenueConfig has key {
    id: UID,
    bluefin_tick_spacing: u32,
    bluefin_fee_rate: u64,
    cetus_tick_spacing: u32,
    fullsail_tick_spacing: u32,
    mmt_fee_rate: u64,
    turbos_tick_spacing: u32,
    turbos_fee_rate: u64,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    let config = VenueConfig {
        id: object::new(ctx),
        bluefin_tick_spacing: 0,
        bluefin_fee_rate: 0,
        cetus_tick_spacing: 0,
        fullsail_tick_spacing: 0,
        mmt_fee_rate: 0,
        turbos_tick_spacing: 0,
        turbos_fee_rate: 0,
    };
    let config_id = object::id(&config);

    transfer::share_object(config);
    events::venue_config_created(config_id);
}

// === Public Functions ===

/// Pins the Bluefin tick spacing and 1e6-denominated venue fee rate.
public fun set_bluefin_tier(
    self: &mut VenueConfig,
    _: &AdminWitness,
    tick_spacing: u32,
    fee_rate: u64,
) {
    assert_tier_inputs(tick_spacing, fee_rate);
    assert!(
        self.bluefin_tick_spacing != tick_spacing
            || self.bluefin_fee_rate != fee_rate,
        EUnchangedTier,
    );

    let old_tick_spacing = self.bluefin_tick_spacing;
    let old_fee_rate = self.bluefin_fee_rate;
    self.bluefin_tick_spacing = tick_spacing;
    self.bluefin_fee_rate = fee_rate;

    events::bluefin_tier_updated(
        old_tick_spacing,
        tick_spacing,
        old_fee_rate,
        fee_rate,
    );
}

/// Pins the Cetus tick spacing; the venue fee rate follows its registered tier.
public fun set_cetus_tick_spacing(
    self: &mut VenueConfig,
    _: &AdminWitness,
    tick_spacing: u32,
) {
    assert!(tick_spacing > 0, EInvalidTickSpacing);
    assert!(self.cetus_tick_spacing != tick_spacing, EUnchangedTier);

    let old_tick_spacing = self.cetus_tick_spacing;
    self.cetus_tick_spacing = tick_spacing;

    events::cetus_tick_spacing_updated(old_tick_spacing, tick_spacing);
}

/// Pins the Full Sail tick spacing; the venue fee rate follows its registered tier.
public fun set_fullsail_tick_spacing(
    self: &mut VenueConfig,
    _: &AdminWitness,
    tick_spacing: u32,
) {
    assert!(tick_spacing > 0, EInvalidTickSpacing);
    assert!(self.fullsail_tick_spacing != tick_spacing, EUnchangedTier);

    let old_tick_spacing = self.fullsail_tick_spacing;
    self.fullsail_tick_spacing = tick_spacing;

    events::fullsail_tick_spacing_updated(old_tick_spacing, tick_spacing);
}

/// Pins the MMT fee rate; the venue derives tick spacing from its fee table.
public fun set_mmt_fee_rate(
    self: &mut VenueConfig,
    _: &AdminWitness,
    fee_rate: u64,
) {
    assert!(fee_rate > 0, EInvalidFeeRate);
    assert!(self.mmt_fee_rate != fee_rate, EUnchangedTier);

    let old_fee_rate = self.mmt_fee_rate;
    self.mmt_fee_rate = fee_rate;

    events::mmt_fee_rate_updated(old_fee_rate, fee_rate);
}

/// Pins the Turbos tick spacing and fee so exactly one `Fee` tier object matches.
///
/// The fee is bounded to `u32` because the venue's `Fee` objects carry a
/// `u32`; a larger pin could never match any tier.
public fun set_turbos_tier(
    self: &mut VenueConfig,
    _: &AdminWitness,
    tick_spacing: u32,
    fee_rate: u64,
) {
    assert_tier_inputs(tick_spacing, fee_rate);
    assert!(fee_rate <= (std::u32::max_value!() as u64), EInvalidFeeRate);
    assert!(
        self.turbos_tick_spacing != tick_spacing
            || self.turbos_fee_rate != fee_rate,
        EUnchangedTier,
    );

    let old_tick_spacing = self.turbos_tick_spacing;
    let old_fee_rate = self.turbos_fee_rate;
    self.turbos_tick_spacing = tick_spacing;
    self.turbos_fee_rate = fee_rate;

    events::turbos_tier_updated(
        old_tick_spacing,
        tick_spacing,
        old_fee_rate,
        fee_rate,
    );
}

// === Package Functions ===

/// Returns the pinned Bluefin `(tick_spacing, fee_rate)`; aborts while unset.
public(package) fun bluefin_tier(self: &VenueConfig): (u32, u64) {
    assert!(
        self.bluefin_tick_spacing > 0 && self.bluefin_fee_rate > 0,
        EVenueTierUnset,
    );

    (self.bluefin_tick_spacing, self.bluefin_fee_rate)
}

/// Returns the pinned Cetus tick spacing; aborts while unset.
public(package) fun cetus_tick_spacing(self: &VenueConfig): u32 {
    assert!(self.cetus_tick_spacing > 0, EVenueTierUnset);

    self.cetus_tick_spacing
}

/// Returns the pinned Full Sail tick spacing; aborts while unset.
public(package) fun fullsail_tick_spacing(self: &VenueConfig): u32 {
    assert!(self.fullsail_tick_spacing > 0, EVenueTierUnset);

    self.fullsail_tick_spacing
}

/// Returns the pinned MMT fee rate; aborts while unset.
public(package) fun mmt_fee_rate(self: &VenueConfig): u64 {
    assert!(self.mmt_fee_rate > 0, EVenueTierUnset);

    self.mmt_fee_rate
}

/// Returns the pinned Turbos `(tick_spacing, fee_rate)`; aborts while unset.
public(package) fun turbos_tier(self: &VenueConfig): (u32, u64) {
    assert!(
        self.turbos_tick_spacing > 0 && self.turbos_fee_rate > 0,
        EVenueTierUnset,
    );

    (self.turbos_tick_spacing, self.turbos_fee_rate)
}

// === Private Functions ===

fun assert_tier_inputs(tick_spacing: u32, fee_rate: u64) {
    assert!(tick_spacing > 0, EInvalidTickSpacing);
    assert!(fee_rate > 0, EInvalidFeeRate);
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
