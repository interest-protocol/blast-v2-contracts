#!/usr/bin/env bash
# Mechanical boundary gate for the versioned Series1 foundation, Vault issuance,
# and permanent package-capability custody.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '%s\n' "$1" >&2; exit 1; }

policy_file="$package_dir/sources/policy.move"
lifecycle_file="$package_dir/sources/lifecycle.move"
accounting_math_file="$package_dir/sources/lib/accounting_math.move"
bounded_value_file="$package_dir/sources/lib/bounded_value.move"
package_version_file="$package_dir/sources/package_version.move"
acl_file="$package_dir/sources/acl.move"
vault_file="$package_dir/sources/vault.move"
package_admin_file="$package_dir/sources/package_admin.move"
series_one_file="$package_dir/sources/series_one.move"
events_file="$package_dir/sources/lib/events.move"
events_wrapper_file="$package_dir/sources/lib/events_wrapper.move"
production_sources=()
non_lifecycle_sources=()
non_accounting_math_sources=()
non_state_sources=()
non_acl_sources=()
non_vault_sources=()
non_package_admin_sources=()
non_publisher_sources=()
non_public_api_sources=()
non_events_wrapper_sources=()

while IFS= read -r -d '' source_file; do
  production_sources+=("$source_file")
  if [[ "$source_file" != "$lifecycle_file" ]]; then
    non_lifecycle_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$accounting_math_file" ]]; then
    non_accounting_math_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$package_version_file" \
    && "$source_file" != "$acl_file" \
    && "$source_file" != "$vault_file" \
    && "$source_file" != "$package_admin_file" \
    && "$source_file" != "$series_one_file" ]]; then
    non_state_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$acl_file" ]]; then
    non_acl_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$vault_file" ]]; then
    non_vault_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$package_admin_file" ]]; then
    non_package_admin_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$package_admin_file" \
    && "$source_file" != "$series_one_file" ]]; then
    non_publisher_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$acl_file" \
    && "$source_file" != "$policy_file" \
    && "$source_file" != "$vault_file" \
    && "$source_file" != "$package_admin_file" ]]; then
    non_public_api_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$events_wrapper_file" ]]; then
    non_events_wrapper_sources+=("$source_file")
  fi
done < <(find "$package_dir/sources" -type f -name '*.move' -print0 | sort -z)

grep_move_sources() {
  local pattern="$1"
  shift

  (($# > 0)) || return 1
  grep -nHE "$pattern" "$@"
}

# Prints `line:content` for every line of a Move source that is not part of a
# top-level item attributed `#[test_only]`. Position in the file is irrelevant:
# a production item placed after the test-only section marker is still checked.
production_lines() {
  awk '
    /^#\[test_only\]/ { pending = 1; next }
    /^#\[/ { next }
    /^\/\/\// { next }
    /^[^[:space:]}\/]/ { in_test = pending; pending = 0 }
    { if (!in_test) print NR ":" $0 }
  ' "$1"
}

grep -q '^name = "blast_leverage_series_one"$' "$package_dir/Move.toml" \
  || fail "Move.toml must name blast_leverage_series_one."
grep -q '^edition = "2024"$' "$package_dir/Move.toml" \
  || fail "Move.toml must use the stable 2024 edition."
if grep -qE '^\[(dev-)?dependencies(\]|[.])' "$package_dir/Move.toml"; then
  fail "The current Series1 slice uses only the implicit framework."
fi

pinned_rev="06734f6ff0af45d8632a14a4dc4b100197f6b1a2"
grep -q "rev = \"$pinned_rev\"" "$package_dir/Move.lock" \
  || fail "Move.lock must stay pinned to $pinned_rev."
for environment in mainnet testnet; do
  grep -q "^\[pinned.$environment.blast_leverage_series_one\]$" "$package_dir/Move.lock" \
    || fail "Move.lock must pin the $environment environment."
done

[[ -f "$policy_file" ]] || fail "Series1 policy must live in policy.move."
[[ -f "$lifecycle_file" ]] || fail "Series1 lifecycle must live in lifecycle.move."
[[ -f "$accounting_math_file" ]] || fail "Series1 accounting must live in lib/accounting_math.move."
[[ -f "$bounded_value_file" ]] || fail "Reusable bounds must live in lib/bounded_value.move."
[[ -f "$package_version_file" ]] || fail "The operational cutover must live in package_version.move."
[[ -f "$acl_file" ]] || fail "Role administration must live in acl.move."
[[ -f "$vault_file" ]] || fail "Shared Vault issuance must live in vault.move."
[[ -f "$package_admin_file" ]] || fail "Package-capability custody must live in package_admin.move."
[[ -f "$series_one_file" ]] || fail "Package provenance must live in series_one.move."
[[ -f "$events_file" ]] || fail "State-transition payloads must live in lib/events.move."
[[ -f "$events_wrapper_file" ]] || fail "The stable event envelope must live in lib/events_wrapper.move."

later_global_gates='Balance<|Coin<|DynamicField|dynamic_field'
if grep_move_sources "$later_global_gates" "${production_sources[@]}"; then
  fail "Asset balances and loose coins are later gates."
fi

vault_only_gates='TreasuryCap|MetadataCap|coin_registry|Bag|dynamic_object_field'
if grep_move_sources "$vault_only_gates" "${non_vault_sources[@]}"; then
  fail "Only vault.move may issue currency or own treasury and adapter-extension custody."
fi

for source_file in "${non_package_admin_sources[@]}"; do
  if production_lines "$source_file" | grep -qE 'UpgradeCap|UpgradeReceipt|UpgradeTicket'; then
    fail "Only package_admin.move may hold or use native package-upgrade authority."
  fi
done

for source_file in "${non_publisher_sources[@]}"; do
  if production_lines "$source_file" | grep -qE 'Publisher'; then
    fail "Only series_one.move and package_admin.move may claim or hold the Publisher."
  fi
done

if grep_move_sources 'UID|TxContext|object::new|share_object' "${non_state_sources[@]}"; then
  fail "Only approved state and package-provenance modules may use object state or TxContext."
fi

if grep_move_sources 'Clock|VecMap|public struct (ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness)' \
  "${non_acl_sources[@]}"; then
  fail "Only acl.move may own authority state, roles, or root-transfer time."
fi

if grep_move_sources 'sui::event::emit' "${non_events_wrapper_sources[@]}"; then
  fail "Only events_wrapper.move may call the framework event emitter."
fi

if grep -rniE 'aftermath|pyth|bluefin|deepbook|blast_fun' \
  "$package_dir/sources" "$package_dir/tests"; then
  fail "The pure Series1 slice must not import a venue, oracle, or launchpad."
fi

if grep -rni 'blast_leverage_core' \
  "$package_dir/sources" \
  "$package_dir/tests" \
  "$package_dir/Move.toml" \
  "$package_dir/README.md" \
  "$package_dir/docs"; then
  fail "Series1 must not depend on a separate leverage-core package."
fi

for source_file in "${non_public_api_sources[@]}"; do
  if production_lines "$source_file" \
    | grep -qE '^[0-9]+:[[:space:]]*(public[[:space:]]+|public[[:space:]]+entry[[:space:]]+|entry[[:space:]]+)fun[[:space:]]'; then
    fail "Only acl.move, policy.move, vault.move, and package_admin.move may expose production public functions."
  fi
done

for public_api_file in "$acl_file" "$policy_file" "$vault_file" "$package_admin_file"; do
  if production_lines "$public_api_file" \
    | grep -qE '^[0-9]+:[[:space:]]*(public[[:space:]]+entry[[:space:]]+|entry[[:space:]]+)fun[[:space:]]'; then
    fail "Series1 public operations remain composable public functions, not entry wrappers."
  fi
done

actual_acl_public="$({
  production_lines "$acl_file" \
    | sed -nE 's/^[0-9]+:[[:space:]]*public[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p'
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
  || fail "The production ACL public-function surface changed without boundary review."

actual_policy_public="$({
  production_lines "$policy_file" \
    | sed -nE 's/^[0-9]+:[[:space:]]*public[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p'
} | sort)"
expected_policy_public="$(printf '%s\n' \
  long \
  new_rebalance_policy \
  new_tier_policy \
  new_valuation \
  short \
  | sort)"
[[ "$actual_policy_public" == "$expected_policy_public" ]] \
  || fail "The production policy-construction surface changed without boundary review."

actual_vault_public="$({
  production_lines "$vault_file" \
    | sed -nE 's/^[0-9]+:[[:space:]]*public[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p'
} | sort)"
[[ "$actual_vault_public" == "issue" ]] \
  || fail "The production Vault public-function surface changed without boundary review."

actual_package_admin_public="$({
  production_lines "$package_admin_file" \
    | sed -nE 's/^[0-9]+:[[:space:]]*public[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p'
} | sort)"
expected_package_admin_public="$(printf '%s\n' \
  activate_package_version \
  authorize_upgrade \
  commit_upgrade \
  new \
  restrict_to_additive \
  restrict_to_dependency_only \
  share \
  | sort)"
[[ "$actual_package_admin_public" == "$expected_package_admin_public" ]] \
  || fail "The production package-admin public-function surface changed without boundary review."

if production_lines "$package_admin_file" \
  | grep -qE 'public\(package\)[[:space:]]+fun|make_immutable|burn_publisher|transfer::(public_)?transfer[[:space:]]*[(]'; then
  fail "PackageAdmin must expose no capability release, destruction, transfer, or package-only access path."
fi

[[ "$(grep -c 'package_version.assert_current();' "$acl_file")" -eq 9 ]] \
  || fail "Every ACL mutation and sign-in except inert retired-cap deletion must version-check."
[[ "$(grep -c 'package_version.assert_current();' "$vault_file")" -eq 1 ]] \
  || fail "Vault issuance must perform exactly one package-version check."
[[ "$(grep -c 'package_version.assert_current();' "$package_admin_file")" -eq 4 ]] \
  || fail "Every package-admin mutation except version activation must version-check."
[[ "$(grep -c 'assert_role(constants::package_admin_role!());' "$package_admin_file")" -eq 4 ]] \
  || fail "Upgrade authorization, policy restriction, and activation require PACKAGE_ADMIN."

grep -q 'publisher.from_module<SERIES_ONE>()' "$package_admin_file" \
  || fail "PackageAdmin construction must validate the canonical Publisher module."
grep -q 'type_name::original_id<SERIES_ONE>()' "$package_admin_file" \
  || fail "PackageAdmin construction must validate the original package id."
grep -q 'digest.length() == constants::package_digest_length!()' "$package_admin_file" \
  || fail "Upgrade authorization must require an exact package digest."
grep -q 'sui::package::claim_and_keep(otw, ctx);' "$series_one_file" \
  || fail "Series1 initialization must claim and keep its Publisher."

grep -q 'coin_registry::new_currency<Vault<AdapterRoot>>' "$vault_file" \
  && fail "Vault issuance must use receiver syntax for the dynamic currency constructor."
grep -q 'registry.new_currency<Vault<AdapterRoot>>' "$vault_file" \
  || fail "Vault issuance must use the registry-enforced dynamic currency constructor."
grep -q 'let vault_id = vault.id.to_inner();' "$vault_file" \
  || fail "Vault identity must use direct UID access inside vault.move."
grep -q 'initializer.finalize(ctx)' "$vault_file" \
  || fail "Vault issuance must retain the claimed MetadataCap."
if grep -q 'finalize_and_delete_metadata_cap' "$vault_file"; then
  fail "Vault issuance must not delete its MetadataCap."
fi
grep -q 'TreasuryKey<Vault<AdapterRoot>>()' "$vault_file" \
  || fail "The share TreasuryCap must use its stable dynamic-object-field key."
grep -q 'MetadataKey<Vault<AdapterRoot>>()' "$vault_file" \
  || fail "The share MetadataCap must use its stable dynamic-object-field key."

for initializer_file in "$package_version_file" "$acl_file" "$series_one_file"; do
  if sed -n '/^fun init(/,/^\/\/ ===/p' "$initializer_file" | grep -q 'events::'; then
    fail "Package initialization must remain eventless."
  fi
done

grep -q '^const PACKAGE_VERSION: u64 = 1;$' "$package_version_file" \
  || fail "package_version.move must keep its compiled version private and explicit."
grep -q 'checked_add(1)' "$package_version_file" \
  || fail "Operational activation must advance with checked arithmetic."

if grep_move_sources \
  'Lifecycle::(Uninitialized|Active|ReduceOnly|ShutdownPending|ShutdownSettled)' \
  "${non_lifecycle_sources[@]}"; then
  fail "Only lifecycle.move may construct or inspect lifecycle variants."
fi

if grep -nE '^[[:space:]]*[*][[:space:]]*self[[:space:]]*=' "$lifecycle_file" \
  | grep -vE 'Lifecycle::(ReduceOnly|ShutdownPending);[[:space:]]*$'; then
  fail "Activation, resume, and settlement require future Vault proofs."
fi

# Every production construction site of a lifecycle variant is whitelisted, so a
# constructor-shaped helper cannot hand out `Active` or `ShutdownSettled`.
# Match arms inspect a variant and are excluded through their `=>` token.
if production_lines "$lifecycle_file" \
  | grep -vE '=>' \
  | grep -E 'Lifecycle::(Active|ShutdownSettled)'; then
  fail "Only test-only seams may construct an active or settled lifecycle."
fi

if grep_move_sources '[.]lifecycle[[:space:]]*=[^=]' "${production_sources[@]}"; then
  fail "A stored lifecycle changes only through lifecycle.move transitions."
fi

lifecycle_constructor_calls="$(
  { grep -hoE 'lifecycle::new[[:space:]]*[(]' "${non_lifecycle_sources[@]}" || true; } \
    | wc -l | tr -d '[:space:]'
)"
[[ "$lifecycle_constructor_calls" -eq 1 ]] \
  || fail "Only and exactly the Vault constructor may create a lifecycle."

if grep -nE \
  'current_(leverage|nav|price)|book_depth|volatility|order_book' \
  "$policy_file"; then
  fail "Derived live market values must not be stored in immutable policy."
fi

raw_accounting_functions='fee_up|credit_fee|mint_quote|redemption_quote|leverage_bps_up|target_notional_down|mint_base_delta_down|mint_base_bounds|assert_mint_base_within_bounds'
if grep -nE \
  "^[[:space:]]*public(\\(package\\))?[[:space:]]+fun[[:space:]]+($raw_accounting_functions)[[:space:]]*[(]" \
  "$accounting_math_file"; then
  fail "Raw accounting functions must remain private behind reserve-aware package functions."
fi

if grep_move_sources \
  'accounting_math::.*absorb_funding_cost' \
  "${non_accounting_math_sources[@]}"; then
  fail "A typed funding completion must gate every production reserve debit."
fi

if grep_move_sources \
  '(^|[^[:alnum:]])mark([^[:alnum:]]|$)' \
  "$accounting_math_file"; then
  fail "A venue mark must never enter shareholder-NAV or share-pricing math."
fi

printf 'Source boundaries hold.\n'
