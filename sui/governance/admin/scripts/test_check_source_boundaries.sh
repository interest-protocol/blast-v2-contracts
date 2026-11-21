#!/usr/bin/env bash
# Self-tests the immutable-publication and source-boundary checker against unsafe variants.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$package_dir/scripts/check_source_boundaries.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

fail() { printf '%s\n' "$1" >&2; exit 1; }

# Portable in-place sed: GNU and BSD `sed -i` take incompatible arguments.
edit() {
  local script="$1" file="$2"
  sed "$script" "$file" > "$file.next"
  mv "$file.next" "$file"
}

new_case() {
  local name="$1"
  local case_dir="$tmp_root/$name"
  mkdir -p "$case_dir/scripts"
  cp "$package_dir/Move.toml" "$case_dir/Move.toml"
  cp -R "$package_dir/sources" "$case_dir/sources"
  cp -R "$package_dir/tests" "$case_dir/tests"
  cp "$package_dir/scripts/publish_immutable.sh" "$case_dir/scripts/publish_immutable.sh"
  printf '%s\n' "$case_dir"
}

run_checker() {
  local case_dir="$1"
  BLAST_DEPLOYMENTS_DIR="$case_dir/deployments" bash "$checker" "$case_dir"
}

expect_rejected() {
  local case_dir="$1"
  if run_checker "$case_dir" >/dev/null 2>&1; then
    fail "Boundary checker accepted unsafe fixture: $case_dir"
  fi
}

expect_accepted() {
  local case_dir="$1"
  run_checker "$case_dir" >/dev/null 2>&1 \
    || fail "Boundary checker rejected a safe fixture: $case_dir"
}

publish_record() {
  local case_dir="$1"
  local source_digest="$2"
  printf '[published.mainnet]\npublished-at = "0x1"\noriginal-id = "0x1"\n' > "$case_dir/Published.toml"
  mkdir -p "$case_dir/deployments/sui/mainnet"
  printf '{"packages":{"admin":{"packageId":"0x1","sourceDigest":"%s"}}}\n' "$source_digest" \
    > "$case_dir/deployments/sui/mainnet/record.json"
}

[[ -x "$checker" ]] || fail "Boundary checker must exist and be executable."
[[ -x "$package_dir/scripts/source_digest.sh" ]] \
  || fail "Source digest helper must exist and be executable."
[[ -f "$package_dir/scripts/publish_immutable.sh" ]] \
  || fail "Immutable publication script must exist."

bash "$checker" "$package_dir"

case_dir="$(new_case leaves_cap_alive)"
edit '/package::make_immutable/d' "$case_dir/scripts/publish_immutable.sh"
expect_rejected "$case_dir"

case_dir="$(new_case publishes_twice)"
edit $'/^exec sui client/i\\\nsui client publish "$package_dir"\n' \
  "$case_dir/scripts/publish_immutable.sh"
expect_rejected "$case_dir"

case_dir="$(new_case transfers_cap)"
edit 's|--move-call 0x2::package::make_immutable admin_upgrade_cap|--transfer-objects "[admin_upgrade_cap]" @0x1|' \
  "$case_dir/scripts/publish_immutable.sh"
expect_rejected "$case_dir"

case_dir="$(new_case wraps_cap)"
edit 's|--move-call 0x2::package::make_immutable admin_upgrade_cap|--move-call 0x2::transfer::public_transfer admin_upgrade_cap @0x1|' \
  "$case_dir/scripts/publish_immutable.sh"
expect_rejected "$case_dir"

case_dir="$(new_case adds_dependency)"
printf '\n[dependencies]\nUnsafe = { local = "../unsafe" }\n' >> "$case_dir/Move.toml"
expect_rejected "$case_dir"

case_dir="$(new_case exposes_capability)"
printf '\n#[test_only]\npublic fun upgrade_capability_for_testing<OTW: drop>(self: &mut PackageAdmin<OTW>): &mut UpgradeCap { self.upgrade_cap.borrow_mut() }\n' \
  >> "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case exposes_capability_tuple)"
printf '\n#[test_only]\npublic fun capabilities_for_testing<OTW: drop>(self: PackageAdmin<OTW>): (Publisher, UpgradeCap) { abort 0 }\n' \
  >> "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case exposes_publisher_by_value)"
printf '\n#[test_only]\npublic fun publisher_by_value_for_testing<OTW: drop>(self: PackageAdmin<OTW>): Publisher { abort 0 }\n' \
  >> "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case exposes_publisher_mutably)"
printf '\n#[test_only]\npublic fun publisher_mut_for_testing<OTW: drop>(self: &mut PackageAdmin<OTW>): &mut Publisher { &mut self.publisher }\n' \
  >> "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case publication_without_record)"
printf '[published.mainnet]\npublished-at = "0x1"\noriginal-id = "0x1"\n' > "$case_dir/Published.toml"
expect_rejected "$case_dir"

case_dir="$(new_case publication_with_stale_digest)"
publish_record "$case_dir" "sha256:stale"
expect_rejected "$case_dir"

case_dir="$(new_case publication_with_matching_record)"
publish_record "$case_dir" "$(bash "$package_dir/scripts/source_digest.sh" "$case_dir")"
expect_accepted "$case_dir"

case_dir="$(new_case publication_with_matching_record_and_bare_reference)"
publish_record "$case_dir" "$(bash "$package_dir/scripts/source_digest.sh" "$case_dir")"
# A later custody record may name the same packageId without recording a source digest (an
# enrollment reference, not a publication); it must not enter the digest set as a null entry.
printf '%s\n' '{"upgradeCustody":{"enrollments":[{"packagesEnrolled":{"admin":{"packageId":"0x1","upgradeCapId":"0x2"}}}]}}' \
  > "$case_dir/deployments/sui/mainnet/reference.json"
expect_accepted "$case_dir"

case_dir="$(new_case publication_with_bare_reference_only)"
printf '[published.mainnet]\npublished-at = "0x1"\noriginal-id = "0x1"\n' > "$case_dir/Published.toml"
mkdir -p "$case_dir/deployments/sui/mainnet"
printf '%s\n' '{"upgradeCustody":{"enrollments":[{"packagesEnrolled":{"admin":{"packageId":"0x1","upgradeCapId":"0x2"}}}]}}' \
  > "$case_dir/deployments/sui/mainnet/reference.json"
expect_rejected "$case_dir"

case_dir="$(new_case unclaimed_publication)"
edit 's/sui::package::claim(otw, ctx)/sui::package::test_claim(otw, ctx)/' "$case_dir/sources/package/package_version.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_activation_path)"
# Leave more than a pipe buffer after the match to exercise pipefail.
{
  printf '\nfun activate<OTW: drop>(self: &mut PackageVersion<OTW>) {\n'
  awk 'BEGIN { for (i = 0; i < 16384; i++) print "    let _ = 0;" }'
  printf '}\n'
} >> "$case_dir/sources/package/package_version.move"
expect_rejected "$case_dir"

case_dir="$(new_case skips_versions)"
edit 's/self.version = previous_version + 1;/self.version = previous_version + 2;/' \
  "$case_dir/sources/package/package_version.move"
expect_rejected "$case_dir"

case_dir="$(new_case second_version_write)"
printf '\nfun rewind<OTW: drop>(self: &mut PackageVersion<OTW>) { self.version = 1; }\n' \
  >> "$case_dir/sources/package/package_version.move"
expect_rejected "$case_dir"

case_dir="$(new_case public_version_constructor)"
printf '\npublic fun new<OTW: drop>(ctx: &mut TxContext): PackageVersion<OTW> { abort 0 }\n' \
  >> "$case_dir/sources/package/package_version.move"
expect_rejected "$case_dir"

case_dir="$(new_case public_package_admin_constructor)"
printf '\npublic fun new_package_admin<OTW: drop>(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext): PackageAdmin<OTW> { new(publisher, upgrade_cap, ctx) }\n' \
  >> "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case second_package_admin_constructor)"
printf '\nfun rogue<OTW: drop>(publisher: Publisher, upgrade_cap: UpgradeCap, upgrade: DelayedAction<UpgradeKey<OTW>, UpgradeAction>, ctx: &mut TxContext): PackageAdmin<OTW> { PackageAdmin { id: object::new(ctx), publisher, upgrade_cap: option::some(upgrade_cap), upgrade } }\n' \
  >> "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case narrows_upgrade_policy)"
printf '\nfun rogue<OTW: drop>(self: &mut PackageAdmin<OTW>) { self.upgrade_cap.borrow_mut().only_additive_upgrades(); }\n' \
  >> "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case readds_a_folded_module)"
printf 'module blast_admin::operational_version;\n' > "$case_dir/sources/operational_version.move"
expect_rejected "$case_dir"

case_dir="$(new_case drops_delayed_map)"
rm "$case_dir/sources/delayed/delayed_map.move"
expect_rejected "$case_dir"

case_dir="$(new_case map_without_readers)"
edit 's/^public fun parent</fun parent</' "$case_dir/sources/delayed/delayed_map.move"
expect_rejected "$case_dir"

case_dir="$(new_case second_mutable_publisher)"
printf '\nfun rogue<OTW: drop>(self: &mut PackageAdmin<OTW>): &mut Publisher { &mut self.publisher }\n' \
  >> "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case delayed_without_destructor)"
edit 's/^public fun destroy</fun destroy</' "$case_dir/sources/delayed/delayed_set.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_acl_entry_path)"
printf '\npublic entry fun rogue(self: &mut ACL) {}\n' \
  >> "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_package_admin_entry_path)"
printf '\npublic entry fun rogue<OTW: drop>(self: &mut PackageAdmin<OTW>) {}\n' \
  >> "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_bare_acl_entry_path)"
printf '\nentry fun rogue(self: &mut ACL) {}\n' \
  >> "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_bare_package_admin_entry_path)"
printf '\nentry fun rogue<OTW: drop>(self: &mut PackageAdmin<OTW>) {}\n' \
  >> "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case copyable_admin_witness)"
edit \
  's/public struct AdminWitness<phantom Role>() has drop;/public struct AdminWitness<phantom Role>() has copy, drop;/' \
  "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case undelayed_nominee)"
edit 's/^    super_admin_transfer: DelayedAction<SuperAdminTransfer, address>,$/    super_admin_transfer: Option<address>,/' \
  "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case changeable_root_transfer_delay)"
printf '\nfun rogue(self: &mut ACL, clock: &Clock) { self.super_admin_transfer.schedule_delay(0, clock); }\n' \
  >> "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case extra_dependency)"
awk '{ print } /^\[dependencies\]$/ { print "blast_fun_timelock = { local = \"../timelock\" }" }' \
  "$case_dir/Move.toml" > "$case_dir/Move.toml.next"
mv "$case_dir/Move.toml.next" "$case_dir/Move.toml"
expect_rejected "$case_dir"

case_dir="$(new_case stray_source_folder)"
mkdir -p "$case_dir/sources/extra"
cp "$case_dir/sources/lib/errors.move" "$case_dir/sources/extra/errors_copy.move"
expect_rejected "$case_dir"

case_dir="$(new_case set_immediate_setter)"
printf '\npublic fun force_value(self: &mut u64) { *self = 0; }\n' >> "$case_dir/sources/delayed/delayed_set.move"
expect_rejected "$case_dir"

case_dir="$(new_case delayed_immediate_setter)"
printf '\npublic fun set_value<K: copy + drop + store, T: copy + drop + store>(self: &mut Delayed<K, T>, value: T) { self.value = value; }\n' \
  >> "$case_dir/sources/delayed/delayed.move"
expect_rejected "$case_dir"

case_dir="$(new_case domain_typed_acl)"
edit 's/^public struct ACL has key {$/public struct ACL<phantom Domain> has key {/' \
  "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case storable_root)"
edit 's/^public struct SuperAdminCap has key {$/public struct SuperAdminCap has key, store {/' \
  "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case per_domain_constructor)"
printf '\npublic fun new<Domain: drop>(otw: Domain, ctx: &mut TxContext) { abort 0 }\n' \
  >> "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case package_admin_entry_path)"
printf '\npublic fun rogue<OTW: drop>(self: &mut PackageAdmin<OTW>) {}\n' \
  >> "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case package_version_setter)"
printf '\npublic fun rogue<OTW: drop>(self: &mut PackageVersion<OTW>) {}\n' \
  >> "$case_dir/sources/package/package_version.move"
expect_rejected "$case_dir"

case_dir="$(new_case storable_package_admin)"
edit 's/^public struct PackageAdmin<phantom OTW: drop> has key {$/public struct PackageAdmin<phantom OTW: drop> has key, store {/' \
  "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case untyped_package_role)"
edit 's/^public struct UnpauseAdmin<phantom OTW>()$/public struct UnpauseAdmin()/' \
  "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case unpinned_unpause_witness)"
edit '/^    package_witness: TypeName,$/d' "$case_dir/sources/package/package_version.move"
expect_rejected "$case_dir"

case_dir="$(new_case unchecked_unpause_witness)"
edit '/package_version.assert_unpause_witness<_, PackageWitness>();/d' \
  "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case unchecked_publisher_witness)"
edit '/package_version.assert_package_witness<_, PackageWitness>();/d' \
  "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case unchecked_immutability_witness)"
awk '/^public fun make_immutable</ { inside = 1 } inside && /assert_package_witness/ { inside = 0; next } { print }' \
  "$case_dir/sources/package/package_admin.move" > "$case_dir/next.move"
mv "$case_dir/next.move" "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case mutable_publisher)"
edit 's/^): &Publisher {$/): \&mut Publisher {/' "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

case_dir="$(new_case second_publisher_path)"
printf '\nfun rogue<OTW: drop>(self: &PackageAdmin<OTW>): &Publisher { &self.publisher }\n' \
  >> "$case_dir/sources/package/package_admin.move"
expect_rejected "$case_dir"

printf 'blast_admin boundary checker self-tests passed\n'
