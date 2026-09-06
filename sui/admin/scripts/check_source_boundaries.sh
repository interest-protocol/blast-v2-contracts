#!/usr/bin/env bash
# Mechanical boundary gate for the immutable shared administration package.
set -euo pipefail

default_package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="${1:-$default_package_dir}"
publication_script="$package_dir/scripts/publish_immutable.sh"

fail() { printf '%s\n' "$1" >&2; exit 1; }

production_lines() {
  awk '
    /^#\[test_only\]/ { pending = 1; next }
    /^#\[/ { next }
    /^\/\/\// { next }
    /^[^[:space:]\/]/ { in_test = pending; pending = 0 }
    { if (!in_test) print NR ":" $0 }
  ' "$1"
}

function_declarations() {
  awk '
    /^[[:space:]]*(macro[[:space:]]+)?(public(\(package\))?[[:space:]]+)?(entry[[:space:]]+)?fun[[:space:]]+/ {
      declaration = $0
      collecting = 1
      if (index($0, "{") > 0) {
        print declaration
        collecting = 0
      }
      next
    }
    collecting {
      declaration = declaration " " $0
      if (index($0, "{") > 0) {
        print declaration
        collecting = 0
      }
    }
  ' "$1"
}

externally_callable_function_names() {
  production_lines "$1" | sed -nE \
    -e 's/^[0-9]+:[[:space:]]*public[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p' \
    -e 's/^[0-9]+:[[:space:]]*public[[:space:]]+entry[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p' \
    -e 's/^[0-9]+:[[:space:]]*public\(package\)[[:space:]]+entry[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p' \
    -e 's/^[0-9]+:[[:space:]]*entry[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p'
}

[[ -f "$package_dir/Move.toml" ]] || fail "blast_admin Move.toml is missing."
grep -q '^name = "blast_admin"$' "$package_dir/Move.toml" \
  || fail "Move.toml must name blast_admin."
grep -q '^edition = "2024"$' "$package_dir/Move.toml" \
  || fail "Move.toml must use edition 2024."
expected_sui_dependency='Sui = { git = "https://github.com/MystenLabs/sui.git", subdir = "crates/sui-framework/packages/sui-framework", rev = "06734f6ff0af45d8632a14a4dc4b100197f6b1a2" }'
grep -Fqx "$expected_sui_dependency" "$package_dir/Move.toml" \
  || fail "blast_admin must pin the repository Sui framework revision."
dependency_names="$(awk '
  /^\[dependencies\]$/ { in_dependencies = 1; next }
  /^\[/ { in_dependencies = 0 }
  in_dependencies && /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=/ {
    line = $0
    sub(/^[[:space:]]*/, "", line)
    sub(/[[:space:]]*=.*/, "", line)
    print line
  }
' "$package_dir/Move.toml")"
[[ "$dependency_names" == "Sui" ]] \
  || fail "blast_admin may depend only on the pinned Sui framework."
if grep -qE '^\[dev-dependencies(\]|[.])' "$package_dir/Move.toml"; then
  fail "blast_admin may not add dev-only dependencies."
fi

for module in acl operational_version upgrade_custody errors events; do
  [[ -f "$package_dir/sources/$module.move" ]] \
    || fail "Missing required blast_admin module: $module.move"
done

[[ -f "$publication_script" ]] \
  || fail "blast_admin must include its immutable publication builder."
expected_client_line='exec sui client --client.env "$environment" ptb \'
grep -Fqx "$expected_client_line" "$publication_script" \
  || fail "Publication must use the reviewed Sui PTB command."
client_invocation_count="$(grep -Ec '^[[:space:]]*(exec[[:space:]]+)?sui[[:space:]]+client([[:space:]]|$)' "$publication_script" || true)"
[[ "$client_invocation_count" -eq 1 ]] \
  || fail "Publication must invoke the Sui client exactly once."
publish_flag_count="$(grep -o -- '--publish' "$publication_script" | wc -l)"
[[ "$publish_flag_count" -eq 1 ]] \
  || fail "Publication must contain exactly one PTB publish command."
if grep -Eq 'sui[[:space:]]+client[[:space:]]+publish([[:space:]]|$)' "$publication_script"; then
  fail "Publication must not run a standalone publish transaction."
fi
grep -q -- '--publish "$package_dir"' "$publication_script" \
  || fail "Publication must publish the reviewed package directory."
grep -q -- '--assign admin_upgrade_cap' "$publication_script" \
  || fail "Publication must bind the returned UpgradeCap."
grep -q -- '--move-call 0x2::package::make_immutable admin_upgrade_cap' "$publication_script" \
  || fail "Publication must pass the returned UpgradeCap directly to make_immutable."
if grep -qE -- 'transfer-objects|public_transfer|transfer::|upgrade_custody|wrap' "$publication_script"; then
  fail "Immutable publication must never transfer or wrap its UpgradeCap."
fi
[[ "$(grep -o 'admin_upgrade_cap' "$publication_script" | wc -l)" -eq 2 ]] \
  || fail "The publication cap may appear only at assignment and make_immutable consumption."
publish_line="$(grep -n -- '--publish "$package_dir"' "$publication_script" | cut -d: -f1)"
assign_line="$(grep -n -- '--assign admin_upgrade_cap' "$publication_script" | cut -d: -f1)"
immutable_line="$(grep -n -- '--move-call 0x2::package::make_immutable admin_upgrade_cap' "$publication_script" | cut -d: -f1)"
[[ "$publish_line" -lt "$assign_line" && "$assign_line" -lt "$immutable_line" ]] \
  || fail "Publication must publish, bind, then consume the UpgradeCap in that order."

if grep -rniE '\b(fee|pause|migration|creator|pool|venue)\b' "$package_dir/sources"; then
  fail "Consumer product policy must not enter blast_admin production source."
fi
if grep -rn 'sui::event::emit' "$package_dir/sources" \
  | grep -v "$package_dir/sources/events.move"; then
  fail "Only events.move may emit shared administration events."
fi
if grep -rnE 'public(\(package\))?[[:space:]]+(entry[[:space:]]+)?fun[[:space:]]+[^ (]*(release|borrow|take|extract|transfer)[^ (]*' \
  "$package_dir/sources/upgrade_custody.move"; then
  fail "Upgrade custody must expose no capability release or borrow path."
fi
if function_declarations "$package_dir/sources/upgrade_custody.move" \
  | grep -Eq '\)[[:space:]]*:[[:space:]]*[^{}]*(Publisher|UpgradeCap)([^A-Za-z0-9_]|$)'; then
  fail "Production and test-only custody APIs must not return Publisher or UpgradeCap values."
fi
if grep -nE 'transfer::(public_)?transfer|burn_publisher' "$package_dir/sources/upgrade_custody.move"; then
  fail "Sealed native capabilities must not leave UpgradeCustody."
fi
grep -q '^    upgrade_cap: Option<UpgradeCap>,$' "$package_dir/sources/upgrade_custody.move" \
  || fail "UpgradeCustody must record irreversible cap absence with Option<UpgradeCap>."
grep -q '^const INITIAL_NATIVE_VERSION: u64 = 0;$' "$package_dir/sources/upgrade_custody.move" \
  || fail "Production intake must require a never-upgraded native cap."

acl_file="$package_dir/sources/acl.move"
if grep -q 'operational_version\|OperationalVersion' "$acl_file"; then
  fail "ACL lifecycle must remain independent of consumer operational versions."
fi
grep -q '^public struct Authority<phantom Domain: drop> has key {$' "$acl_file" \
  || fail "Authority must be compile-time domain separated."
grep -q '^public struct SuperAdminCap<phantom Domain: drop> has key {$' "$acl_file" \
  || fail "SuperAdminCap must not have store."
grep -q '^public struct AdminCap<phantom Domain: drop> has key, store {$' "$acl_file" \
  || fail "AdminCap must remain transferable and domain separated."
grep -q '^public struct AdminWitness<phantom Domain: drop> has drop {$' "$acl_file" \
  || fail "AdminWitness must be a drop-only domain-typed snapshot."
grep -q 'admins: VecMap<ID, u64>,' "$acl_file" \
  || fail "Authority must keep bounded u64 role bitmaps in VecMap."
grep -q 'types::is_one_time_witness(&otw)' "$acl_file" \
  || fail "ACL bootstrap must authenticate a genuine domain OTW."

actual_acl_public="$({
  externally_callable_function_names "$acl_file"
} | sort)"
expected_acl_public="$(printf '%s\n' \
  accept_super_admin_transfer \
  assert_role \
  begin_super_admin_transfer \
  bootstrap \
  cancel_super_admin_transfer \
  destroy_admin_cap \
  destroy_retired_super_admin_cap \
  grant_admin \
  grant_role \
  revoke_admin \
  revoke_role \
  sign_in \
  | sort)"
[[ "$actual_acl_public" == "$expected_acl_public" ]] \
  || fail "The production ACL surface changed without boundary review."

version_file="$package_dir/sources/operational_version.move"
if production_lines "$version_file" | grep -Eq 'fun[[:space:]]+(activate|set_generation|set_version)'; then
  fail "Operational generation must expose no separate activation or arbitrary setter."
fi
actual_version_public="$({
  externally_callable_function_names "$version_file"
} | sort)"
expected_version_public="$(printf '%s\n' advance assert_current assert_next new | sort)"
[[ "$actual_version_public" == "$expected_version_public" ]] \
  || fail "The production operational-version surface changed without boundary review."

custody_file="$package_dir/sources/upgrade_custody.move"
actual_custody_public="$({
  externally_callable_function_names "$custody_file"
} | sort)"
expected_custody_public="$(printf '%s\n' \
  authorize_upgrade \
  commit_upgrade \
  has_upgrade_cap \
  make_immutable \
  new \
  restrict_to_additive \
  restrict_to_dependency_only \
  | sort)"
[[ "$actual_custody_public" == "$expected_custody_public" ]] \
  || fail "The production UpgradeCustody surface changed without boundary review."

printf 'blast_admin source boundaries passed\n'
