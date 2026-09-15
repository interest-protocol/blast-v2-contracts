// On hold: the native DEX is commented out until it is redesigned against the
// migrators-owned LP-fee policy and authority (ADR 0083). Restore by removing the `// ` prefixes.
// #[test_only]
// /// Focused wiring tests for the independent DEX administration domain.
// ///
// /// The complete reusable ACL matrix belongs to `blast_admin`. These tests prove
// /// only that this package creates exactly one typed domain of its own, exports
// /// one role, keeps generic administration role-free, and cannot be reached by
// /// another product's capability.
// module blast_fun_dex::dex_domain_tests;
//
// use blast_admin::acl::{Self, Authority, SuperAdminCap, AdminCap, AdminWitness};
// use blast_fun_dex::{dex_domain::{Self, DEX_DOMAIN}, domain_fixture};
// use std::unit_test::{assert_eq, destroy};
// use sui::test_scenario::{Self, Scenario};
//
// use fun domain_end as DomainFixture.end;
// use fun domain_next_tx as DomainFixture.next_tx;
// use fun domain_sign_in as DomainFixture.sign_in;
//
// // === Constants ===
//
// const ROOT: address = @0xA11CE;
// const ADMIN: address = @0xAD;
// const MAX_ADMINS: u64 = 16;
// const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;
//
// // === Test-Only Types ===
//
// /// The live shared authority exactly as production initialization left it.
// public struct DomainFixture {
//     scenario: Scenario,
//     authority: Authority<DEX_DOMAIN>,
//     super_admin_cap: SuperAdminCap<DEX_DOMAIN>,
//     admin_cap: AdminCap<DEX_DOMAIN>,
// }
//
// // === Tests ===
//
// #[test]
// fun init_creates_one_dex_authority_with_its_module_constants() {
//     let mut fixture = start_with_roles(0);
//
//     fixture.next_tx!(ROOT, |f| {
//         assert_eq!(f.authority.max_admins_for_testing(), MAX_ADMINS);
//         assert_eq!(
//             f.authority.root_transfer_delay_ms_for_testing(),
//             ROOT_TRANSFER_DELAY_MS,
//         );
//         assert_eq!(
//             f.authority.active_super_admin_cap_id_for_testing(),
//             f.super_admin_cap.super_admin_cap_id_for_testing(),
//         );
//     });
//
//     fixture.end();
// }
//
// #[test]
// fun package_admin_role_is_the_single_exported_dex_role_bit() {
//     let role = dex_domain::package_admin_role();
//
//     assert_eq!(role, 1);
//     assert!(role != 0 && role & (role - 1) == 0);
// }
//
// #[test]
// fun a_zero_role_administrator_signs_in_for_generic_administration() {
//     let mut fixture = start_with_roles(0);
//
//     fixture.next_tx!(ADMIN, |f| {
//         let witness = f.sign_in();
//
//         assert_eq!(witness.roles_for_testing(), 0);
//     });
//
//     fixture.end();
// }
//
// #[test]
// #[expected_failure(
//     abort_code = blast_admin::errors::EAdminRoleNotGranted,
//     location = blast_admin::acl,
// )]
// fun a_zero_role_administrator_cannot_assert_the_package_admin_role() {
//     let mut fixture = start_with_roles(0);
//
//     fixture.next_tx!(ADMIN, |f| {
//         let witness = f.sign_in();
//
//         witness.assert_role(dex_domain::package_admin_role());
//     });
//
//     fixture.end();
// }
//
// #[test]
// /// A Launchpad administrator is live in its own registry, but its witness type
// /// is `AdminWitness<LAUNCHPAD_DOMAIN>`, which no DEX factory, pool-policy, or
// /// package operation takes. The one deliberate exception,
// /// `migration::claim_protocol_fees`, claims from a Launchpad-owned ledger.
// fun a_launchpad_capability_cannot_administer_the_dex() {
//     let mut fixture = start_with_roles(0);
//
//     fixture.next_tx!(ROOT, |f| {
//         let (launchpad_root, mut launchpad_authority) =
//             domain_fixture::new_launchpad_authority(f.scenario.ctx());
//         launchpad_authority.grant_admin(
//             &launchpad_root,
//             dex_domain::package_admin_role(),
//             ADMIN,
//             f.scenario.ctx(),
//         );
//
//         assert_eq!(launchpad_authority.max_admins_for_testing(), MAX_ADMINS);
//
//         destroy(launchpad_root);
//         destroy(launchpad_authority);
//     });
//
//     fixture.end();
// }
//
// #[test]
// #[expected_failure(
//     abort_code = blast_admin::errors::EInvalidAdminCap,
//     location = blast_admin::acl,
// )]
// /// Membership is per-registry: a live DEX administrator is unknown to a second
// /// DEX authority, so type identity alone never grants authority.
// fun an_administrator_from_another_registry_cannot_sign_in_here() {
//     let mut fixture = start_with_roles(0);
//
//     fixture.next_tx!(ADMIN, |f| {
//         let (foreign_root, foreign_authority) = acl::new_for_testing<DEX_DOMAIN>(
//             MAX_ADMINS,
//             ROOT_TRANSFER_DELAY_MS,
//             f.scenario.ctx(),
//         );
//         let witness = foreign_authority.sign_in(&f.admin_cap);
//
//         destroy(witness);
//         destroy(foreign_root);
//         destroy(foreign_authority);
//     });
//
//     fixture.end();
// }
//
// #[test]
// #[expected_failure(
//     abort_code = blast_admin::errors::EInvalidAdminCap,
//     location = blast_admin::acl,
// )]
// fun a_revoked_administrator_can_no_longer_sign_in() {
//     let mut fixture = start_with_roles(0);
//
//     fixture.next_tx!(ROOT, |f| {
//         let admin_cap_id = f.admin_cap.admin_cap_id_for_testing();
//
//         f.authority.revoke_admin(&f.super_admin_cap, admin_cap_id);
//     });
//
//     fixture.next_tx!(ADMIN, |f| {
//         let witness = f.sign_in();
//
//         destroy(witness);
//     });
//
//     fixture.end();
// }
//
// // === Private Test Helpers ===
//
// macro fun domain_next_tx(
//     $fixture: &mut DomainFixture,
//     $sender: address,
//     $fn: |&mut DomainFixture|,
// ) {
//     let fixture = $fixture;
//
//     fixture.scenario.next_tx($sender);
//     $fn(fixture);
// }
//
// /// Runs production initialization, then delivers one administrator to ADMIN.
// fun start_with_roles(roles: u64): DomainFixture {
//     let mut scenario = test_scenario::begin(ROOT);
//     dex_domain::init_for_testing(scenario.ctx());
//
//     scenario.next_tx(ROOT);
//     let mut authority = scenario.take_shared<Authority<DEX_DOMAIN>>();
//     let super_admin_cap = scenario.take_from_sender<SuperAdminCap<DEX_DOMAIN>>();
//     authority.grant_admin(&super_admin_cap, roles, ADMIN, scenario.ctx());
//
//     scenario.next_tx(ADMIN);
//     let admin_cap = scenario.take_from_sender<AdminCap<DEX_DOMAIN>>();
//
//     DomainFixture { scenario, authority, super_admin_cap, admin_cap }
// }
//
// fun domain_sign_in(self: &DomainFixture): AdminWitness<DEX_DOMAIN> {
//     self.authority.sign_in(&self.admin_cap)
// }
//
// fun domain_end(self: DomainFixture) {
//     destroy(self);
// }
