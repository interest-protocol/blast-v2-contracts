#!/usr/bin/env bash
# Mechanical boundary gate for the immutable shared administration package.
set -euo pipefail

# Pipe consumers must read to EOF so a match cannot SIGPIPE the producer.

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

# Every line outside `#[test_only]` declarations, tracking braces so multi-line signatures and
# code appended after the test-only section are both attributed correctly.
non_test_lines() {
  awk '
    /^#\[test_only\]/ { pending = 1; next }
    depth == 0 && /^(public|fun|macro|entry|const|struct)/ { in_test = pending; pending = 0 }
    {
      if (!in_test) print NR ":" $0
      opens = gsub(/\{/, "{"); closes = gsub(/\}/, "}"); depth += opens - closes
      if (depth == 0 && closes > 0) in_test = 0
    }
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

# An immutable package is published once per lineage: every Published.toml entry must name a
# deployment record whose recorded source digest is this source, or the entry is stale.
published_manifest="$package_dir/Published.toml"
deployments_dir="${BLAST_DEPLOYMENTS_DIR:-$package_dir/../../../deployments}"
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
    # Only publication records participate: an object that names the package without recording
    # a source digest (for example an upgrade-custody enrollment reference) attests nothing
    # about the published source and must not enter the digest set as a null entry.
    recorded = [
        package
        for record in records
        for package in packages(json.loads(record.read_text()))
        if str(package["packageId"]).lower() == address and "sourceDigest" in package
    ]
    if not recorded:
        sys.exit(
            f"Published.toml names {address} on {environment} but no deployments/sui/{environment} record "
            "carries that packageId with a recorded sourceDigest; record the publication "
            "(deployments/README.md) or remove the stale entry."
        )
    digests = {package["sourceDigest"] for package in recorded}
    if digests != {digest}:
        sys.exit(
            f"Published.toml names {address} on {environment}, whose recorded sourceDigest "
            f"{sorted(map(str, digests))} is not this source's {digest}; an immutable package cannot be "
            "upgraded, so remove the stale entry and publish a new lineage."
        )
PY
fi

# Resolve the reviewed modules within their responsibility groups.
module_file() {
  case "$1" in
    delayed|delayed_action|delayed_set|delayed_map) printf '%s\n' "$package_dir/sources/delayed/$1.move" ;;
    package_admin|package_version) printf '%s\n' "$package_dir/sources/package/$1.move" ;;
    blast_admin_events|errors) printf '%s\n' "$package_dir/sources/lib/$1.move" ;;
    *) printf '%s\n' "$package_dir/sources/$1.move" ;;
  esac
}

required_modules="blast_acl delayed delayed_action delayed_set delayed_map package_version package_admin errors \
  blast_admin_events"
for module in $required_modules; do
  [[ -f "$(module_file "$module")" ]] \
    || fail "Missing required blast_admin module: $module.move"
done
if find "$package_dir/sources" -name '*.move' | grep -vE "^$package_dir/sources/(blast_acl|package/package_(admin|version)|lib/(blast_admin_events|errors)|delayed/delayed(_action|_set|_map)?)\.move$"; then
  fail "blast_admin sources must use the reviewed ACL, package, delayed, and lib locations."
fi
# Immutable once published: exactly these nine modules, so no second version, PackageAdmin or
# delayed type can be added without boundary review.
actual_modules="$(find "$package_dir/sources" -name '*.move' -exec basename {} .move \; | sort)"
expected_modules="$(printf '%s\n' $required_modules | sort)"
[[ "$actual_modules" == "$expected_modules" ]] \
  || fail "blast_admin must contain exactly its nine reviewed modules."

[[ -f "$publication_script" ]] \
  || fail "blast_admin must include its immutable publication builder."
expected_client_line='exec sui client --client.env mainnet ptb \'
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

# Pause bits are generic package infrastructure (ADR 0137); which bits exist stays consumer policy.
if grep -rniE '\b(fee|migration|creator|pool|venue)\b' "$package_dir/sources"; then
  fail "Consumer product policy must not enter blast_admin production source."
fi
if grep -rn 'sui::event::emit' "$package_dir/sources" \
  | grep -vE "$package_dir/sources/(lib/blast_admin_events|delayed/delayed(_action|_set|_map)?)\.move"; then
  fail "Only blast_admin_events.move and the delayed modules may emit shared administration events."
fi
package_admin_file="$package_dir/sources/package/package_admin.move"
if grep -rnE 'public(\(package\))?[[:space:]]+(entry[[:space:]]+)?fun[[:space:]]+[^ (]*(release|borrow|take|extract|transfer)[^ (]*' \
  "$package_admin_file"; then
  fail "PackageAdmin must expose no capability release or borrow path."
fi
if function_declarations "$package_admin_file" \
  | sed -nE 's/.*\)[[:space:]]*:[[:space:]]*([^{}]*)\{.*/\1/p' \
  | sed -E 's/&(mut[[:space:]]+)?Publisher//g' \
  | grep -E '(UpgradeCap|Publisher)([^A-Za-z0-9_]|$)' >/dev/null; then
  fail "PackageAdmin APIs may return the Publisher only by reference and never an UpgradeCap."
fi
if grep -nE 'transfer::(public_)?transfer|burn_publisher' "$package_admin_file"; then
  fail "Sealed native capabilities must not leave PackageAdmin."
fi
if grep -rnE 'only_additive_upgrades|only_dep_upgrades|restrict_to' "$package_dir/sources"; then
  fail "make_immutable is the one terminal upgrade action; upgrade policy is never narrowed."
fi
grep -q '^    upgrade_cap: Option<UpgradeCap>,$' "$package_admin_file" \
  || fail "PackageAdmin must record irreversible cap absence with Option<UpgradeCap>."
grep -q '^const INITIAL_UPGRADE_CAP_VERSION: u64 = 1;$' "$package_admin_file" \
  || fail "Production intake must require a freshly published, never-upgraded native cap."
[[ "$(production_lines "$package_admin_file" | grep -cE 'PackageAdmin[[:space:]]*\{[[:space:]]*id')" -eq 1 ]] \
  || fail "PackageAdmin must have exactly one private constructor path."

acl_file="$package_dir/sources/blast_acl.move"
if grep -q 'package_version\|PackageVersion' "$acl_file"; then
  fail "ACL lifecycle must remain independent of consumer package versions."
fi
grep -Fqx 'public struct ACL has key {' "$acl_file" \
  || fail "ACL must be one untyped shared singleton."
grep -Fqx 'public struct SuperAdminCap has key {' "$acl_file" \
  || fail "SuperAdminCap must be untyped and must not have store."
grep -Fqx 'public struct AdminCap has key, store {' "$acl_file" \
  || fail "AdminCap must remain transferable and untyped; roles live in the ACL."
grep -Fqx 'public struct AdminWitness<phantom Role>() has drop;' "$acl_file" \
  || fail "AdminWitness must be a drop-only, role-typed proof."
grep -Fqx '    admins: Table<ID, VecSet<TypeName>>,' "$acl_file" \
  || fail "ACL must store each live admin and its roles in a Table."
grep -Fqx '    super_admin_transfer: DelayedAction<SuperAdminTransfer, address>,' "$acl_file" \
  || fail "A nominated super admin must wait out the fixed delay before it can accept."
if grep -qE '\.schedule_delay\(|\.apply_delay\(|schedule_action_delay|apply_action_delay' "$acl_file"; then
  fail "The root transfer delay is a fixed constant with no change path."
fi
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
  admin_count \
  admin_roles \
  begin_super_admin_transfer \
  cancel_super_admin_transfer \
  destroy_admin_cap \
  destroy_retired_super_admin_cap \
  grant_admin \
  grant_role \
  has_role \
  is_admin \
  max_roles_per_admin \
  revoke_admin \
  revoke_role \
  sign_in \
  super_admin_cap_id \
  super_admin_transfer \
  super_admin_transfer_delay_ms \
  | sort)"
[[ "$actual_acl_public" == "$expected_acl_public" ]] \
  || fail "The production ACL surface changed without boundary review."

for delayed_module in delayed delayed_action delayed_set delayed_map; do
  if production_lines "$(module_file "$delayed_module")" \
    | grep -E 'fun[[:space:]]+(set|force|replace|bypass)[a-z_]*[[:space:]]*[<(]' >/dev/null; then
    fail "Delayed values must expose no immediate setter or bypass ($delayed_module)."
  fi
done
expect_delayed_surface() {
  local module="$1"; shift
  local actual expected
  actual="$(externally_callable_function_names "$(module_file "$module")" | sort)"
  expected="$(printf '%s\n' "$@" | sort)"
  [[ "$actual" == "$expected" ]] || fail "The production $module surface changed without boundary review."
}
# blast_admin is immutable and future packages may hold its types in other ways, so every delayed
# type keeps a complete API: its destructor and read-only readers, pinned here.
expect_delayed_surface delayed apply assert_ready cancel delay_ms destroy is_guarded is_ready key \
  deadline_delay_ms deadline_ready_at_ms max_delay_ms new pending_delay_ms pending_delay_ready_at_ms parent pending proposal_delay_ms proposal_ready_at_ms \
  proposal_value schedule schedule_delay schedule_value value
expect_delayed_surface delayed_action action apply_delay cancel delay_ms destroy is_delay_ready \
  is_guarded is_ready key new parent pending pending_action pending_delay schedule schedule_delay \
  take_action
expect_delayed_surface delayed_set admission_deadline admission_ready_at_ms apply_add apply_delay \
  cancel_add cancel_delay contains delay_ms destroy is_delay_ready is_guarded is_pending is_ready \
  key member length members new parent pending_count pending_delay remove schedule_add \
  schedule_delay
expect_delayed_surface delayed_map apply apply_delay cancel cancel_delay changed_entry changed_value \
  contains delay_ms destroy length entry_proposal_deadline entry_proposal_value entry_ready_at_ms \
  is_delay_ready is_guarded is_pending is_ready key new parent pending pending_count pending_delay \
  schedule schedule_delay value
for delayed_module in delayed delayed_action delayed_set delayed_map; do
  grep -Eq '^public fun destroy<' "$(module_file "$delayed_module")" \
    || fail "$delayed_module must keep its destructor."
  grep -Eq '^public fun (parent|key)<' "$(module_file "$delayed_module")" \
    || fail "$delayed_module must expose its parent and key readers."
done

package_version_file="$package_dir/sources/package/package_version.move"
actual_package_version_public="$(externally_callable_function_names "$package_version_file" | sort)"
expected_package_version_public="$(printf '%s\n' \
  assert_current \
  assert_not_paused \
  version \
  is_paused \
  keep \
  new_publication \
  package_witness \
  paused \
  publication_package_witness \
  publication_publisher_id \
  publication_valid_pause_bits \
  valid_pause_bits \
  | sort)"
[[ "$actual_package_version_public" == "$expected_package_version_public" ]] \
  || fail "The production package-version surface changed without boundary review."
grep -Fqx 'public struct PackageVersion<phantom OTW: drop> has key {' "$package_version_file" \
  || fail "PackageVersion must be a key-only shared object typed by its package one-time witness (OTW)."
grep -Fqx 'public struct Publication<phantom OTW: drop> has key {' "$package_version_file" \
  || fail "Publication must be key-only so only its own module can deliver it."
[[ "$(grep -Fxc '    package_witness: TypeName,' "$package_version_file")" -eq 2 ]] \
  || fail "Publication and PackageVersion must pin the package's exact package witness type."
[[ "$(grep -Fc 'type_name::with_defining_ids<PackageWitness>() == self.package_witness' "$package_version_file")" -eq 2 ]] \
  || fail "Clearing pause bits and borrowing the Publisher must each require the exact package witness."
grep -Fq 'sui::package::claim(otw, ctx)' "$package_version_file" \
  || fail "A publication must be claimable only with the consumer package's one-time witness."
if production_lines "$package_version_file" | grep -E 'fun[[:space:]]+(activate|set_version|set_version)' >/dev/null; then
  fail "The version must expose no separate activation or arbitrary setter."
fi
[[ "$(non_test_lines "$package_version_file" | grep -cE 'self\.version[[:space:]]*=[^=]')" -eq 1 ]] \
  || fail "Only advance may move the version, by exactly one."
grep -Fq 'self.version = previous_version + 1;' "$package_version_file" \
  || fail "advance must move the version by exactly one."

actual_package_admin_public="$(externally_callable_function_names "$package_admin_file" | sort)"
expected_package_admin_public="$(printf '%s\n' \
  apply_upgrade_delay \
  authorize_upgrade \
  cancel_upgrade_action \
  clear_pause_bits \
  commit_upgrade_and_advance \
  current_package_id \
  has_upgrade_cap \
  initial_upgrade_delay_ms \
  is_upgrade_delay_guarded \
  make_immutable \
  upgrade_cap_version \
  pause \
  pending_upgrade \
  publisher \
  publisher_id \
  publisher_mut \
  schedule_make_immutable \
  schedule_upgrade \
  schedule_upgrade_delay \
  upgrade_cap_id \
  upgrade_delay_ms \
  upgrade_digest \
  upgrade_policy \
  wrap \
  | sort)"
[[ "$actual_package_admin_public" == "$expected_package_admin_public" ]] \
  || fail "The production package-administration surface changed without boundary review."
grep -Fqx 'public struct PackageAdmin<phantom OTW: drop> has key {' "$package_admin_file" \
  || fail "PackageAdmin must be a key-only shared object typed by its package one-time witness (OTW)."
grep -Fq 'package_version.assert_unpause_witness<_, PackageWitness>();' "$package_admin_file" \
  || fail "clear_pause_bits must check the pinned package witness."
[[ "$(function_declarations "$package_admin_file" | grep -cE '\)[[:space:]]*:[[:space:]]*&Publisher[[:space:]]*\{')" -eq 2 ]] \
  || fail "Only publisher (and its test-only twin) may return the Publisher by immutable reference."
[[ "$(function_declarations "$package_admin_file" | grep -cE '\)[[:space:]]*:[[:space:]]*&mut[[:space:]]+Publisher[[:space:]]*\{')" -eq 1 ]] \
  || fail "Only publisher_mut may return the Publisher by mutable reference."
[[ "$(grep -Fc 'package_version.assert_package_witness<_, PackageWitness>();' "$package_admin_file")" -eq 3 ]] \
  || fail "publisher, publisher_mut and make_immutable must each check the pinned package witness."
sed -n '/^public fun make_immutable</,/^}/p' "$package_admin_file" \
  | grep -F 'package_version.assert_package_witness<_, PackageWitness>();' >/dev/null \
  || fail "make_immutable must check the pinned package witness before ending upgrades."
for role in UpgradeAdmin PauseAdmin UnpauseAdmin CancelAdmin; do
  grep -Fqx "public struct $role<phantom OTW>()" "$package_admin_file" \
    || fail "$role must be an ability-free role typed by its package one-time witness (OTW)."
done

printf 'blast_admin source boundaries passed\n'
