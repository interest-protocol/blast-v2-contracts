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

expect_rejected() {
  local case_dir="$1"
  if bash "$checker" "$case_dir" >/dev/null 2>&1; then
    fail "Boundary checker accepted unsafe fixture: $case_dir"
  fi
}

[[ -x "$checker" ]] || fail "Boundary checker must exist and be executable."
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

case_dir="$(new_case adds_activation_path)"
printf '\npublic fun activate<PackageMarker: drop>(self: &mut OperationalVersion<PackageMarker>) {}\n' \
  >> "$case_dir/sources/operational_version.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_acl_entry_path)"
printf '\npublic entry fun rogue<Domain: drop>(self: &mut Authority<Domain>) {}\n' \
  >> "$case_dir/sources/acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_custody_entry_path)"
printf '\npublic entry fun rogue<PackageMarker: drop>(self: &mut UpgradeCustody<PackageMarker>) {}\n' \
  >> "$case_dir/sources/upgrade_custody.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_bare_acl_entry_path)"
printf '\nentry fun rogue<Domain: drop>(self: &mut Authority<Domain>) {}\n' \
  >> "$case_dir/sources/acl.move"
expect_rejected "$case_dir"

case_dir="$(new_case adds_bare_custody_entry_path)"
printf '\nentry fun rogue<PackageMarker: drop>(self: &mut UpgradeCustody<PackageMarker>) {}\n' \
  >> "$case_dir/sources/upgrade_custody.move"
expect_rejected "$case_dir"

printf 'blast_admin boundary checker self-tests passed\n'
