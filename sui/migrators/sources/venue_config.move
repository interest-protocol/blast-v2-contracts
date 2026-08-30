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

use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::borrow as UID.dynamic_field;
use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;
use fun dynamic_field::exists as UID.has_dynamic_field;

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
    transfer::share_object(VenueConfig { id: object::new(ctx) });
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

    let (old_tick_spacing, old_fee_rate) = if (self.has_tier_override<Venue>()) {
        let tier_override_mut: &mut Tier =
            self.id.dynamic_field_mut(TierKey<Venue>());
        let old_tick_spacing = tier_override_mut.tick_spacing;
        let old_fee_rate = tier_override_mut.fee_rate;
        assert!(
            old_tick_spacing != tick_spacing || old_fee_rate != fee_rate,
            EUnchangedTier,
        );
        *tier_override_mut = Tier { tick_spacing, fee_rate };
        (old_tick_spacing, old_fee_rate)
    } else {
        self.id.add_dynamic_field(
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
public(package) fun has_tier_override<Venue>(self: &VenueConfig): bool {
    self.id.has_dynamic_field(TierKey<Venue>())
}

/// Returns the pinned `(tick_spacing, fee_rate)`; aborts while no pin exists.
public(package) fun tier_override<Venue>(self: &VenueConfig): (u32, u64) {
    assert!(self.has_tier_override<Venue>(), EVenueTierUnset);

    let tier_override: &Tier = self.id.dynamic_field(TierKey<Venue>());

    (tier_override.tick_spacing, tier_override.fee_rate)
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
