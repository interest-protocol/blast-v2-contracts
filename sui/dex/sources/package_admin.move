// On hold: the native DEX is commented out until it is redesigned against the
// migrators-owned LP-fee policy and authority (ADR 0083). Restore by removing the `// ` prefixes.
// /// Sealed custody for the DEX package's Publisher and UpgradeCap.
// ///
// /// The DEX owns its administration outright: every transition here accepts
// /// `AdminWitness<DEX_DOMAIN>` and asserts the role this package exports. No
// /// Launchpad capability reaches package custody.
// module blast_fun_dex::package_admin;
//
// use blast_admin::{
//     acl::AdminWitness,
//     upgrade_custody::{Self, UpgradeCustody},
// };
// use blast_fun_dex::{
//     dex_domain::{Self, DEX_DOMAIN},
//     package_marker::PACKAGE_MARKER,
//     pool::Factory
// };
// use sui::package::{Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket};
//
// // === Errors ===
//
// #[error(code = 0)]
// const EInvalidPackagePublisher: vector<u8> =
//     b"Publisher must be claimed by the canonical DEX package module.";
//
// // === Public Structs ===
//
// /// Shared custody for this package's framework Publisher and UpgradeCap.
// public struct PackageAdmin has key {
//     id: UID,
//     custody: UpgradeCustody<PACKAGE_MARKER>,
// }
//
// // === Public Functions ===
//
// /// Validates and permanently seals the DEX Publisher and raw UpgradeCap.
// public fun wrap(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
//     // from_module compares both the package address and the canonical module name.
//     assert!(publisher.from_module<PACKAGE_MARKER>(), EInvalidPackagePublisher);
//
//     let id = object::new(ctx);
//     let custody = upgrade_custody::new<PACKAGE_MARKER>(id.to_inner(), publisher, upgrade_cap);
//
//     transfer::share_object(PackageAdmin { id, custody });
// }
//
// /// Authorizes the exact package digest under the sealed cap's current policy.
// public fun authorize_upgrade(
//     self: &mut PackageAdmin,
//     factory: &Factory,
//     admin_witness: &AdminWitness<DEX_DOMAIN>,
//     digest: vector<u8>,
// ): UpgradeTicket {
//     factory.assert_current();
//     admin_witness.assert_role(dex_domain::package_admin_role());
//     let custodian_id = self.id.to_inner();
//
//     self.custody.authorize_upgrade(custodian_id, digest)
// }
//
// /// Commits the native receipt and advances one operational generation at once.
// ///
// /// This is the only upgrade finalizer. Both mutations belong to the same
// /// transaction, so a failure at either step rolls back the whole upgrade.
// public fun commit_upgrade_and_advance(
//     self: &mut PackageAdmin,
//     factory: &mut Factory,
//     admin_witness: &AdminWitness<DEX_DOMAIN>,
//     receipt: UpgradeReceipt,
// ) {
//     admin_witness.assert_role(dex_domain::package_admin_role());
//     factory.assert_next();
//     let custodian_id = self.id.to_inner();
//
//     self.custody.commit_upgrade(custodian_id, receipt);
//     factory.advance();
// }
//
// /// Irreversibly narrows the sealed UpgradeCap to additive upgrades.
// public fun restrict_to_additive(
//     self: &mut PackageAdmin,
//     factory: &Factory,
//     admin_witness: &AdminWitness<DEX_DOMAIN>,
// ) {
//     factory.assert_current();
//     admin_witness.assert_role(dex_domain::package_admin_role());
//     let custodian_id = self.id.to_inner();
//
//     self.custody.restrict_to_additive(custodian_id);
// }
//
// /// Irreversibly narrows the sealed UpgradeCap to dependency-only upgrades.
// public fun restrict_to_dependency_only(
//     self: &mut PackageAdmin,
//     factory: &Factory,
//     admin_witness: &AdminWitness<DEX_DOMAIN>,
// ) {
//     factory.assert_current();
//     admin_witness.assert_role(dex_domain::package_admin_role());
//     let custodian_id = self.id.to_inner();
//
//     self.custody.restrict_to_dependency_only(custodian_id);
// }
//
// /// Irreversibly destroys native upgrade authority for this package.
// public fun make_immutable(
//     self: &mut PackageAdmin,
//     factory: &Factory,
//     admin_witness: &AdminWitness<DEX_DOMAIN>,
// ) {
//     factory.assert_current();
//     admin_witness.assert_role(dex_domain::package_admin_role());
//     let custodian_id = self.id.to_inner();
//
//     self.custody.make_immutable(custodian_id);
// }
//
// /// Reports whether native upgrade authority remains sealed in custody.
// public fun has_upgrade_cap(self: &PackageAdmin): bool {
//     self.custody.has_upgrade_cap()
// }
//
// // === Test-Only Functions ===
//
// #[test_only]
// public fun new_for_testing(ctx: &mut TxContext): PackageAdmin {
//     let id = object::new(ctx);
//     let custody = upgrade_custody::new<PACKAGE_MARKER>(
//         id.to_inner(),
//         blast_fun_dex::package_marker::publisher_for_testing(ctx),
//         sui::package::test_publish(
//             std::type_name::original_id<PACKAGE_MARKER>().to_id(),
//             ctx,
//         ),
//     );
//
//     PackageAdmin { id, custody }
// }
//
// #[test_only]
// public fun id_for_testing(self: &PackageAdmin): ID {
//     self.id.to_inner()
// }
//
// #[test_only]
// public fun publisher_id_for_testing(self: &PackageAdmin): ID {
//     self.custody.publisher_id_for_testing()
// }
//
// #[test_only]
// public fun upgrade_cap_id_for_testing(self: &PackageAdmin): ID {
//     self.custody.upgrade_cap_id_for_testing()
// }
//
// #[test_only]
// public fun package_id_for_testing(self: &PackageAdmin): ID {
//     self.custody.current_package_id_for_testing()
// }
//
// #[test_only]
// public fun version_for_testing(self: &PackageAdmin): u64 {
//     self.custody.native_version_for_testing()
// }
//
// #[test_only]
// public fun policy_for_testing(self: &PackageAdmin): u8 {
//     self.custody.policy_for_testing()
// }
