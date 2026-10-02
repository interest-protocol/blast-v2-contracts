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
[[ "$dependency_names" == "$(printf '%s\n' Sui blast_fun_timelock)" ]] \
  || fail "blast_admin may depend only on the pinned Sui framework and Blast timelock."
expected_timelock_dependency='blast_fun_timelock = { git = "https://github.com/interest-protocol/blast-util-contracts.git", subdir = "sui/timelock", rev = "63b6cf86c0e1a74f699610fe182b1de8d8789a14" }'
grep -Fqx "$expected_timelock_dependency" "$package_dir/Move.toml" \
  || fail "blast_admin must pin the published immutable Blast timelock revision."
if grep -qE '^\[dev-dependencies(\]|[.])' "$package_dir/Move.toml"; then
  fail "blast_admin may not add dev-only dependencies."
fi

# An immutable package is published once per lineage: every Published.toml entry must name a
# deployment record whose recorded source digest is this source, or the entry is stale.
published_manifest="$package_dir/Published.toml"
deployments_dir="${BLAST_DEPLOYMENTS_DIR:-$package_dir/../../deployments}"
if [[ -f "$published_manifest" ]]; then
  source_digest="$(bash "$(dirname "${BASH_SOURCE[0]}")/source_digest.sh" "$package_dir")"
  python3 - "$published_manifest" "$deployments_dir" "$source_digest" <<'PY' || exit 1
import json, pathlib, sys

manifest, deployments, digest = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]

environment, entries = None, []
for line in manifest.read_text().splitlines():
    line = line.strip()
    if line.startswith("[published.") and line.endswith("]"):
        environment = line[len("[published."):-1]
    elif environment and line.startswith("published-at"):
        entries.append((environment, line.split("=", 1)[1].strip().strip('"').lower()))

def packages(node):
    if isinstance(node, dict):
        if "packageId" in node:
            yield node
        for value in node.values():
            yield from packages(value)
    elif isinstance(node, list):
        for value in node:
            yield from packages(value)

for environment, address in entries:
    records = sorted((deployments / "sui" / environment).glob("*.json"))
    recorded = [
        package
        for record in records
        for package in packages(json.loads(record.read_text()))
        if str(package["packageId"]).lower() == address
    ]
    if not recorded:
        sys.exit(
            f"Published.toml names {address} on {environment} but no deployments/sui/{environment} record "
            "carries that packageId; record the publication (deployments/README.md) or remove the stale entry."
        )
    digests = {package.get("sourceDigest") for package in recorded}
    if digests != {digest}:
        sys.exit(
            f"Published.toml names {address} on {environment}, whose recorded sourceDigest "
            f"{sorted(map(str, digests))} is not this source's {digest}; an immutable package cannot be "
            "upgraded, so remove the stale entry and publish a new lineage."
        )
PY
fi

for module in blast_acl operational_version upgrade_custody errors blast_admin_events; do
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
  | grep -v "$package_dir/sources/blast_admin_events.move"; then
  fail "Only blast_admin_events.move may emit shared administration events."
fi
if grep -rnE 'public(\(package\))?[[:space:]]+(entry[[:space:]]+)?fun[[:space:]]+[^ (]*(release|borrow|take|extract|transfer)[^ (]*' \
  "$package_dir/sources/upgrade_custody.move"; then
  fail "Upgrade custody must expose no capability release or borrow path."
fi
if function_declarations "$package_dir/sources/upgrade_custody.move" \
  | grep -Eq '\)[[:space:]]*:[[:space:]]*[^{}]*(UpgradeCap|(^|[^&])Publisher)([^A-Za-z0-9_]|$)'; then
  fail "Custody APIs may return the Publisher only by immutable reference and never an UpgradeCap."
fi
if grep -nE 'transfer::(public_)?transfer|burn_publisher' "$package_dir/sources/upgrade_custody.move"; then
  fail "Sealed native capabilities must not leave UpgradeCustody."
fi
grep -q '^    upgrade_cap: Option<UpgradeCap>,$' "$package_dir/sources/upgrade_custody.move" \
  || fail "UpgradeCustody must record irreversible cap absence with Option<UpgradeCap>."
grep -q '^const INITIAL_NATIVE_VERSION: u64 = 1;$' "$package_dir/sources/upgrade_custody.move" \
  || fail "Production intake must require a freshly published, never-upgraded native cap."
if production_lines "$package_dir/sources/upgrade_custody.move" \
  | grep -Eq 'fun[[:space:]]+new_checked'; then
  fail "Custody intake must have exactly one constructor path."
fi

acl_file="$package_dir/sources/blast_acl.move"
if grep -q 'operational_version\|OperationalVersion' "$acl_file"; then
  fail "ACL lifecycle must remain independent of consumer operational versions."
fi
grep -Fqx 'public struct ACL has key {' "$acl_file" \
  || fail "ACL must be one untyped shared singleton."
grep -Fqx 'public struct SuperAdminCap has key {' "$acl_file" \
  || fail "SuperAdminCap must be untyped and must not have store."
grep -Fqx 'public struct AdminCap has key, store {' "$acl_file" \
  || fail "AdminCap must remain transferable and untyped; roles live in the ACL."
grep -Fqx 'public struct AdminWitness<phantom Role>() has drop;' "$acl_file" \
  || fail "AdminWitness must be a drop-only, role-typed proof."
grep -Fqx '    admins: VecMap<ID, VecSet<TypeName>>,' "$acl_file" \
  || fail "ACL must list every live admin and its roles inline."
grep -Fqx '    pending_super_admin: Timelocked<Option<address>>,' "$acl_file" \
  || fail "A nominated super admin must wait out the timelock before it can accept."
[[ "$(grep -c '^fun init(ctx: &mut TxContext) {$' "$acl_file")" -eq 1 ]] \
  || fail "The singleton must be created only by package initialization."
if grep -qE 'types::is_one_time_witness|fun new<' "$acl_file"; then
  fail "The ACL must not be constructible per consumer domain."
fi

actual_acl_public="$({
  externally_callable_function_names "$acl_file"
} | sort)"
expected_acl_public="$(printf '%s\n' \
  accept_super_admin_transfer \
  begin_super_admin_transfer \
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
  publisher \
  restrict_to_additive \
  restrict_to_dependency_only \
  | sort)"
[[ "$actual_custody_public" == "$expected_custody_public" ]] \
  || fail "The production UpgradeCustody surface changed without boundary review."

printf 'blast_admin source boundaries passed\n'
