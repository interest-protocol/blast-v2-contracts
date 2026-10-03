// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::blast_presale_admin_tests;

// === Constants ===

const PUBLISHER: address = @0xB1A57;
const COLD_MULTISIG: address = @0xC01D;

// === Tests ===

#[test]
/// Publication sends the publisher the super administrator and the one AdminCap the shared
/// registry accepts.
fun publication_sends_both_caps_and_registers_the_admin_cap() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    blast_presale_admin::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    assert_eq!(test_scenario::ids_for_sender<SuperAdminCap>(&scenario).length(), 1);
    assert_eq!(test_scenario::ids_for_sender<AdminCap>(&scenario).length(), 1);
    let admin_registry = scenario.take_shared<AdminRegistry>();
    let admin_cap = scenario.take_from_sender<AdminCap>();

    admin_registry.assert_admin_cap(&admin_cap);
    assert_eq!(admin_registry.admin_cap_id_for_testing(), option::some(object::id(&admin_cap)));

    scenario.return_to_sender(admin_cap);
    test_scenario::return_shared(admin_registry);
    scenario.end();
}

#[test]
/// Replacing the AdminCap registers the new cap and reports the one it displaced.
fun the_super_admin_replaces_the_admin_cap() {
    let mut ctx = tx_context::dummy();
    let (mut admin_registry, old_admin_cap) = blast_presale_admin::new_for_testing(&mut ctx);
    let super_admin = super_admin_for_testing(&mut ctx);

    let new_admin_cap = admin_registry.replace_admin_cap(&super_admin, &mut ctx);

    admin_registry.assert_admin_cap(&new_admin_cap);
    let (previous_admin_cap_id, admin_cap_id) = only_event<AdminCapReplaced>()
        .admin_cap_replaced_fields();
    assert_eq!(previous_admin_cap_id, option::some(object::id(&old_admin_cap)));
    assert_eq!(admin_cap_id, object::id(&new_admin_cap));

    admin_registry.destroy_for_testing(new_admin_cap);
    destroy(old_admin_cap);
    destroy(super_admin);
}

#[test]
#[expected_failure(
    abort_code = blast_presale_admin::EInvalidAdminCap,
    location = blast_presale::blast_presale_admin,
)]
/// A replaced AdminCap stops working at once.
fun a_replaced_admin_cap_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut admin_registry, old_admin_cap) = blast_presale_admin::new_for_testing(&mut ctx);
    let super_admin = super_admin_for_testing(&mut ctx);
    let _new_admin_cap = admin_registry.replace_admin_cap(&super_admin, &mut ctx);

    admin_registry.assert_admin_cap(&old_admin_cap);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale_admin::EInvalidAdminCap,
    location = blast_presale::blast_presale_admin,
)]
/// After a revocation no AdminCap is accepted.
fun a_revoked_admin_cap_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut admin_registry, admin_cap) = blast_presale_admin::new_for_testing(&mut ctx);
    let super_admin = super_admin_for_testing(&mut ctx);

    admin_registry.revoke_admin_cap(&super_admin);

    assert_eq!(only_event<AdminCapRevoked>().admin_cap_revoked_fields(), object::id(&admin_cap));
    assert_eq!(admin_registry.admin_cap_id_for_testing(), option::none());
    admin_registry.assert_admin_cap(&admin_cap);
    abort
}

#[test]
/// A revocation can be followed by a replacement, which restores administration under a new cap.
fun a_replacement_after_a_revocation_restores_administration() {
    let mut ctx = tx_context::dummy();
    let (mut admin_registry, revoked_admin_cap) = blast_presale_admin::new_for_testing(&mut ctx);
    let super_admin = super_admin_for_testing(&mut ctx);
    admin_registry.revoke_admin_cap(&super_admin);

    let admin_cap = admin_registry.replace_admin_cap(&super_admin, &mut ctx);

    admin_registry.assert_admin_cap(&admin_cap);
    let (previous_admin_cap_id, _) = only_event<AdminCapReplaced>().admin_cap_replaced_fields();
    assert_eq!(previous_admin_cap_id, option::none());

    admin_registry.destroy_for_testing(admin_cap);
    destroy(revoked_admin_cap);
    destroy(super_admin);
}

#[test]
#[expected_failure(
    abort_code = blast_presale_admin::ENoAdminCap,
    location = blast_presale::blast_presale_admin,
)]
fun nothing_can_be_revoked_twice() {
    let mut ctx = tx_context::dummy();
    let (mut admin_registry, _admin_cap) = blast_presale_admin::new_for_testing(&mut ctx);
    let super_admin = super_admin_for_testing(&mut ctx);
    admin_registry.revoke_admin_cap(&super_admin);

    admin_registry.revoke_admin_cap(&super_admin);
    abort
}

#[test]
/// The super administrator moves to the cold multisig through its own transfer.
fun the_super_admin_transfers_to_a_new_holder() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    blast_presale_admin::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    scenario.take_from_sender<SuperAdminCap>().transfer_super_admin(COLD_MULTISIG);

    scenario.next_tx(COLD_MULTISIG);
    assert_eq!(test_scenario::ids_for_sender<SuperAdminCap>(&scenario).length(), 1);
    assert_eq!(test_scenario::ids_for_address<SuperAdminCap>(PUBLISHER).length(), 0);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_presale_admin::EInvalidRecipient,
    location = blast_presale::blast_presale_admin,
)]
fun the_super_admin_cannot_go_to_the_zero_address() {
    let mut ctx = tx_context::dummy();

    super_admin_for_testing(&mut ctx).transfer_super_admin(@0x0);
}

// === Test Helpers ===

fun only_event<Event: copy + drop>(): Event {
    let events = event::events_by_type<Event>();
    assert_eq!(events.length(), 1);
    events[0]
}

// === Imports ===

use blast_presale::blast_presale_admin::{
    Self,
    AdminCap,
    AdminCapReplaced,
    AdminCapRevoked,
    AdminRegistry,
    SuperAdminCap,
    super_admin_for_testing,
};

use std::unit_test::{assert_eq, destroy};

use sui::{event, test_scenario};
