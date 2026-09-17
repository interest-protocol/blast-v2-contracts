/// Shared venue policy stored as sealed per-venue dynamic fields.
///
/// `launch::migrate` is deliberately permissionless, so no migration caller may
/// choose the economic policy of the pool that permanently custodies the launch
/// principal. Each venue module owns its policy, validates writes under a live
/// core `AdminWitness`, and seals its dynamic-field namespace with a private key
/// constructor. Entries remain extensible without changing this object's frozen
/// layout, and the singleton stays correctable after the `UpgradeCap` is
/// destroyed.
module blast_fun_migrators::venue_config;

// === Errors ===

#[error(code = 0)]
const EInvalidTickSpacing: vector<u8> = b"Venue tick spacing must be greater than zero.";
#[error(code = 1)]
const EInvalidFeeRate: vector<u8> = b"Venue fee rate must be greater than zero.";
#[error(code = 2)]
const EUnchangedTier: vector<u8> = b"Venue tier must differ from its current pinned values.";
#[error(code = 3)]
const EVenueTierUnset: vector<u8> = b"Venue tier must be pinned before an override-only read.";

// === Public Structs ===

/// A sealed field name that binds one venue's tier entry to its witness type.
public struct TierKey<phantom Venue>() has copy, drop, store;

/// One pinned `(tick_spacing, fee_rate)` pair in venue-native units.
public struct Tier has copy, drop, store {
    tick_spacing: u32,
    fee_rate: u64,
}

/// Shared singleton holding sealed policy entries for registered venues.
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

    let (old_tick_spacing, old_fee_rate) = if (self.has_tier<Venue>()) {
        let tier_mut = self.id.dynamic_field_mut<_, Tier>(TierKey<Venue>());
        let old_tick_spacing = tier_mut.tick_spacing;
        let old_fee_rate = tier_mut.fee_rate;
        assert!(
            old_tick_spacing != tick_spacing || old_fee_rate != fee_rate,
            EUnchangedTier,
        );
        *tier_mut = Tier { tick_spacing, fee_rate };
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

/// Reports whether the venue has a stored tier.
public(package) fun has_tier<Venue>(self: &VenueConfig): bool {
    self.id.has_dynamic_field(TierKey<Venue>())
}

/// Returns the pinned `(tick_spacing, fee_rate)`; aborts while no pin exists.
public(package) fun tier<Venue>(self: &VenueConfig): (u32, u64) {
    assert!(self.has_tier<Venue>(), EVenueTierUnset);

    let tier = self.id.dynamic_field<_, Tier>(TierKey<Venue>());

    (tier.tick_spacing, tier.fee_rate)
}

/// Adds a policy under a key constructible only by its concern-owning module.
public(package) fun add_policy<Key: copy + drop + store, Policy: store>(
    self: &mut VenueConfig,
    key: Key,
    policy: Policy,
) {
    self.id.add_dynamic_field(key, policy);
}

/// Reports whether the concern-owning module has installed its policy override.
public(package) fun has_policy<Key: copy + drop + store>(
    self: &VenueConfig,
    key: Key,
): bool {
    self.id.has_dynamic_field(key)
}

/// Borrows an installed policy through its concern-owned sealed key.
public(package) fun policy<Key: copy + drop + store, Policy: store>(
    self: &VenueConfig,
    key: Key,
): &Policy {
    self.id.dynamic_field(key)
}

/// Mutably borrows an installed policy through its concern-owned sealed key.
public(package) fun policy_mut<Key: copy + drop + store, Policy: store>(
    self: &mut VenueConfig,
    key: Key,
): &mut Policy {
    self.id.dynamic_field_mut(key)
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

// === Imports ===

use blast_fun_migrators::events;

use sui::dynamic_field;

use fun dynamic_field::add as UID.add_dynamic_field;

use fun dynamic_field::borrow as UID.dynamic_field;

use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;

use fun dynamic_field::exists as UID.has_dynamic_field;
