/// Shared venue tier policy stored as sealed per-venue dynamic fields.
///
/// `launch::migrate` is deliberately permissionless, so no migration caller may
/// choose the venue fee tier or tick spacing of the pool that permanently
/// custodies the launch principal. Each venue module owns its tier policy: it
/// compiles a researched default, seals writes with its own venue witness, and
/// gates its public setter with a live core `AdminWitness`. Entries live as
/// dynamic fields rather than struct fields so a package upgrade can register
/// a new venue without touching this object's frozen layout, and the singleton
/// stays correctable on mainnet even after the `UpgradeCap` is destroyed.
module blast_fun_migrators::venue_config;

use blast_fun_migrators::events;
use sui::dynamic_field;

// === Constants ===

const EInvalidTickSpacing: u64 = 0;
const EInvalidFeeRate: u64 = 1;
const EUnchangedTier: u64 = 2;
const EVenueTierUnset: u64 = 3;

// === Public Structs ===

/// A sealed field name that binds one venue's tier entry to its witness type.
public struct TierKey<phantom Venue>() has copy, drop, store;

/// One pinned `(tick_spacing, fee_rate)` pair in venue-native units.
public struct Tier has copy, drop, store {
    tick_spacing: u32,
    fee_rate: u64,
}

/// Shared singleton holding one sealed tier entry per registered venue.
public struct VenueConfig has key {
    id: UID,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    let config = VenueConfig { id: object::new(ctx) };
    let config_id = object::id(&config);

    transfer::share_object(config);
    events::venue_config_created(config_id);
}

// === Package Functions ===

/// Pins or replaces one venue's tier; only the venue module holds the witness.
///
/// A zero old value in the emitted fact means the venue module's compiled
/// default was active before this pin.
public(package) fun set_tier<Venue: drop>(
    self: &mut VenueConfig,
    _venue: Venue,
    tick_spacing: u32,
    fee_rate: u64,
) {
    assert!(tick_spacing > 0, EInvalidTickSpacing);
    assert!(fee_rate > 0, EInvalidFeeRate);

    let (old_tick_spacing, old_fee_rate) = if (self.contains<Venue>()) {
        let tier: &mut Tier =
            dynamic_field::borrow_mut(&mut self.id, TierKey<Venue>());
        let old_tick_spacing = tier.tick_spacing;
        let old_fee_rate = tier.fee_rate;
        assert!(
            old_tick_spacing != tick_spacing || old_fee_rate != fee_rate,
            EUnchangedTier,
        );
        *tier = Tier { tick_spacing, fee_rate };
        (old_tick_spacing, old_fee_rate)
    } else {
        dynamic_field::add(
            &mut self.id,
            TierKey<Venue>(),
            Tier { tick_spacing, fee_rate },
        );
        (0, 0)
    };

    events::venue_tier_updated<Venue>(
        old_tick_spacing,
        tick_spacing,
        old_fee_rate,
        fee_rate,
    );
}

/// Reports whether an admin pin overrides the venue module's compiled default.
public(package) fun contains<Venue>(self: &VenueConfig): bool {
    dynamic_field::exists(&self.id, TierKey<Venue>())
}

/// Returns the pinned `(tick_spacing, fee_rate)`; aborts while no pin exists.
public(package) fun tier<Venue>(self: &VenueConfig): (u32, u64) {
    assert!(self.contains<Venue>(), EVenueTierUnset);

    let tier: &Tier = dynamic_field::borrow(&self.id, TierKey<Venue>());

    (tier.tick_spacing, tier.fee_rate)
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
