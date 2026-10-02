#!/usr/bin/env bash
# Self-tests the immutable-publication and source-boundary checker against unsafe variants.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$package_dir/scripts/check_source_boundaries.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

fail() { printf '%s\n' "$1" >&2; exit 1; }

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
sed -i '/package::make_immutable/d' "$case_dir/scripts/publish_immutable.sh"
expect_rejected "$case_dir"

case_dir="$(new_case publishes_twice)"
sed -i '/^exec sui client/i sui client publish "$package_dir"' \
  "$case_dir/scripts/publish_immutable.sh"
expect_rejected "$case_dir"

case_dir="$(new_case transfers_cap)"
sed -i 's|--move-call 0x2::package::make_immutable admin_upgrade_cap|--transfer-objects "[admin_upgrade_cap]" @0x1|' \
  "$case_dir/scripts/publish_immutable.sh"
expect_rejected "$case_dir"

case_dir="$(new_case wraps_cap)"
sed -i 's|--move-call 0x2::package::make_immutable admin_upgrade_cap|--move-call 0x2::transfer::public_transfer admin_upgrade_cap @0x1|' \
  "$case_dir/scripts/publish_immutable.sh"
expect_rejected "$case_dir"

case_dir="$(new_case adds_dependency)"
printf '\n[dependencies]\nUnsafe = { local = "../unsafe" }\n' >> "$case_dir/Move.toml"
expect_rejected "$case_dir"

case_dir="$(new_case exposes_capability)"
printf '\n#[test_only]\npublic fun upgrade_capability_for_testing<PackageMarker: drop>(self: &mut UpgradeCustody<PackageMarker>): &mut UpgradeCap { self.upgrade_cap.borrow_mut() }\n' \
  >> "$case_dir/sources/upgrade_custody.move"
expect_rejected "$case_dir"

case_dir="$(new_case exposes_capability_tuple)"
printf '\n#[test_only]\npublic fun capabilities_for_testing<PackageMarker: drop>(self: UpgradeCustody<PackageMarker>): (Publisher, UpgradeCap) { abort 0 }\n' \
  >> "$case_dir/sources/upgrade_custody.move"
expect_rejected "$case_dir"

case_dir="$(new_case exposes_publisher_by_value)"
printf '\n#[test_only]\npublic fun publisher_for_testing<PackageMarker: drop>(self: UpgradeCustody<PackageMarker>): Publisher { abort 0 }\n' \
  >> "$case_dir/sources/upgrade_custody.move"
expect_rejected "$case_dir"

case_dir="$(new_case exposes_publisher_mutably)"
printf '\n#[test_only]\npublic fun publisher_mut_for_testing<PackageMarker: drop>(self: &mut UpgradeCustody<PackageMarker>): &mut Publisher { &mut self.publisher }\n' \
  >> "$case_dir/sources/upgrade_custody.move"
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

case_dir="$(new_case adds_activation_path)"
printf '\npublic fun activate<PackageMarker: drop>(self: &mut OperationalVersion<PackageMarker>) {}\n' \
  >> "$case_dir/sources/operational_version.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_acl_entry_path)"
printf '\npublic entry fun rogue(self: &mut ACL) {}\n' \
  >> "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_custody_entry_path)"
printf '\npublic entry fun rogue<PackageMarker: drop>(self: &mut UpgradeCustody<PackageMarker>) {}\n' \
  >> "$case_dir/sources/upgrade_custody.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_bare_acl_entry_path)"
printf '\nentry fun rogue(self: &mut ACL) {}\n' \
  >> "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_bare_custody_entry_path)"
printf '\nentry fun rogue<PackageMarker: drop>(self: &mut UpgradeCustody<PackageMarker>) {}\n' \
  >> "$case_dir/sources/upgrade_custody.move"
expect_rejected "$case_dir"

case_dir="$(new_case copyable_admin_witness)"
sed -i \
  's/public struct AdminWitness<phantom Role>() has drop;/public struct AdminWitness<phantom Role>() has copy, drop;/' \
  "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case untimelocked_nominee)"
sed -i 's/^    pending_super_admin: Timelocked<Option<address>>,$/    pending_super_admin: Option<address>,/' \
  "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case unpinned_timelock)"
sed -i 's/rev = "63b6cf86c0e1a74f699610fe182b1de8d8789a14"/rev = "main"/' "$case_dir/Move.toml"
expect_rejected "$case_dir"

case_dir="$(new_case domain_typed_acl)"
sed -i 's/^public struct ACL has key {$/public struct ACL<phantom Domain> has key {/' \
  "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case storable_root)"
sed -i 's/^public struct SuperAdminCap has key {$/public struct SuperAdminCap has key, store {/' \
  "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case per_domain_constructor)"
printf '\npublic fun new<Domain: drop>(otw: Domain, ctx: &mut TxContext) { abort 0 }\n' \
  >> "$case_dir/sources/blast_acl.move"
expect_rejected "$case_dir"

printf 'blast_admin boundary checker self-tests passed\n'
