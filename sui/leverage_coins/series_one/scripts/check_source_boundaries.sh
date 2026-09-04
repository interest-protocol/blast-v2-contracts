#!/usr/bin/env bash
# Mechanical boundary gate for venue-neutral Series1 state and global ACL.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '%s\n' "$1" >&2; exit 1; }

acl_file="$package_dir/sources/acl.move"
state_file="$package_dir/sources/state.move"
policy_file="$package_dir/sources/policy.move"
lifecycle_file="$package_dir/sources/lifecycle.move"
observation_file="$package_dir/sources/observation.move"
events_wrapper_file="$package_dir/sources/lib/events_wrapper.move"

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
  || fail "Move.toml must use edition 2024."
if grep -qE '^\[(dev-)?dependencies(\]|[.])' "$package_dir/Move.toml"; then
  fail "Series1 must use only the implicit framework dependencies."
fi

for required in \
  "$acl_file" \
  "$state_file" \
  "$policy_file" \
  "$lifecycle_file" \
  "$observation_file" \
  "$package_dir/sources/lib/accounting_math.move" \
  "$package_dir/sources/lib/bounded_value.move" \
  "$package_dir/sources/lib/events.move" \
  "$events_wrapper_file"; do
  [[ -f "$required" ]] || fail "Missing required Series1 source: $required"
done

for forbidden in \
  venue_handoff.move \
  package_admin.move \
  package_version.move \
  series_one.move \
  vault.move; do
  [[ ! -e "$package_dir/sources/$forbidden" ]] \
    || fail "$forbidden belongs outside the venue-neutral Series1 core."
done

if grep -rniE 'aftermath|bluefin|pyth|deepbook' "$package_dir/sources"; then
  fail "Series1 source must remain venue and oracle neutral."
fi
if grep -rniE 'CoinRegistry|TreasuryCap|MetadataCap|CurrencyInitializer|sui::bag|dynamic_object_field|Publisher|UpgradeCap' \
  "$package_dir/sources"; then
  fail "Currency, venue-specific state, and package-upgrade custody belong to adapters."
fi
if grep -rniE 'AdapterRoot|AdapterDomain|adapter_witness|venue_handoff' \
  "$package_dir/sources"; then
  fail "Series1 must not carry adapter-family identity or handoff machinery."
fi

grep -q '^public struct ProtocolAuthority has key {$' "$acl_file" \
  || fail "Series1 must own one shared non-generic ProtocolAuthority."
grep -q '^public struct AdminCap has key, store {$' "$acl_file" \
  || fail "AdminCap must be Series1-wide and non-generic."
grep -q '^public struct AdminWitness(u8) has drop;$' "$acl_file" \
  || fail "AdminWitness must snapshot the complete Series1 role bitmap."
grep -q 'transfer::share_object(authority);' "$acl_file" \
  || fail "Series1 initialization must share its global authority."
grep -q 'roles > 0 && roles & constants::all_admin_roles!() == roles' "$acl_file" \
  || fail "ACL role sets must remain validated bitmaps."

grep -q '^public struct State<phantom Product> has store {$' "$state_file" \
  || fail "Series product state must be an adapter-storable, non-object value."
if grep -qE 'UID|Bag|TypeName|TreasuryCap|MetadataCap|CoinRegistry|share_object' "$state_file"; then
  fail "Series state must not own adapter objects, witnesses, or currency caps."
fi
grep -q '^public fun new<Product>($' "$state_file" \
  || fail "Series state construction must be generic only over Product."
grep -q 'admin_witness.assert_role(constants::vault_issuer_role!());' "$state_file" \
  || fail "Series state construction must require VAULT_ISSUER."
grep -q 'lifecycle: lifecycle::new(),' "$state_file" \
  || fail "Every new Series state must start uninitialized."
grep -q '^public fun set_max_order_notional<Product>($' "$state_file" \
  || fail "Series state must own bounded maximum-order-notional mutation."
grep -q '^public fun enter_reduce_only<Product>($' "$state_file" \
  || fail "Series state must own the ReduceOnly lifecycle transition."
grep -q '^    acl::AdminWitness,$' "$state_file" \
  || fail "State must import AdminWitness without an alias."
if production_lines "$state_file" | grep -Eq 'AdminWitness[[:space:]]+as[[:space:]]'; then
  fail "State must not alias AdminWitness around the function scanner."
fi
state_admin_witness_violations="$(
  production_lines "$state_file" \
    | awk '
      /^[0-9]+:[[:space:]]*(macro[[:space:]]+)?(public(\(package\))?[[:space:]]+)?fun[[:space:]]+/ {
        declaration = $0
        sub(/^[0-9]+:[[:space:]]*(macro[[:space:]]+)?(public(\(package\))?[[:space:]]+)?fun[[:space:]]+/, "", declaration)
        sub(/[<(].*$/, "", declaration)
        function_name = declaration
      }
      function_name != "" && function_name != "new" && /AdminWitness/ { print }
    '
)"
[[ -z "$state_admin_witness_violations" ]] \
  || fail "Only State::new may accept or reference AdminWitness."

grep -q '^public struct PriceObservation {$' "$observation_file" \
  || fail "PriceObservation must remain an ability-free linear carrier."
grep -q '^public struct PositionObservation {$' "$observation_file" \
  || fail "PositionObservation must remain an ability-free linear carrier."
grep -q '^public enum FundingSettlement {$' "$observation_file" \
  || fail "FundingSettlement must remain an ability-free linear carrier."
for unpacker in unpack_price unpack_position unpack_funding; do
  grep -q "^public(package) fun $unpacker" "$observation_file" \
    || fail "$unpacker must remain package-only."
  if production_lines "$observation_file" | grep -q "public fun $unpacker"; then
    fail "$unpacker must not be exposed outside Series1."
  fi
done

if grep -rnE '^[[:space:]]*(public[[:space:]]+entry|entry)[[:space:]]+fun' \
  "$package_dir/sources"; then
  fail "Series1 exposes composable functions, not entry wrappers."
fi
if grep -rn 'sui::event::emit' "$package_dir/sources" \
  | grep -v "$events_wrapper_file"; then
  fail "Only events_wrapper.move may call the framework event emitter."
fi

actual_acl_public="$({
  production_lines "$acl_file" \
    | sed -nE 's/^[0-9]+:[[:space:]]*public[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p'
} | sort)"
expected_acl_public="$(printf '%s\n' \
  accept_super_admin_transfer \
  assert_package_admin \
  assert_risk_admin \
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
  || fail "The production Series1 ACL surface changed without boundary review."

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
  || fail "The public policy-construction surface changed without boundary review."

actual_state_public="$({
  production_lines "$state_file" \
    | sed -nE 's/^[0-9]+:[[:space:]]*public[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p'
} | sort)"
expected_state_public="$(printf '%s\n' \
  assert_initialization_execution \
  assert_order_notional_allowed \
  enter_reduce_only \
  initialization_constraints \
  initialization_target_notional \
  initialize \
  new \
  prepare_initialization \
  set_max_order_notional \
  settle_funding \
  sync_health \
  | sort)"
[[ "$actual_state_public" == "$expected_state_public" ]] \
  || fail "The production Series1 State surface changed without boundary review."

prepare_initialization_block="$(
  sed -n '/^public fun prepare_initialization<Product>($/,/^}/p' "$state_file"
)"
grep -q 'self.lifecycle.assert_can_activate();' <<<"$prepare_initialization_block" \
  || fail "Seed preflight must require an uninitialized lifecycle."
grep -q ') = observation.unpack_position();' <<<"$prepare_initialization_block" \
  || fail "Seed preflight must consume one linear position observation."
grep -q 'absolute_base == 0 && absolute_notional == 0' <<<"$prepare_initialization_block" \
  || fail "Seed preflight must require an exactly flat position."
initialization_constraints_block="$(
  sed -n '/^public fun initialization_constraints<Product>($/,/^}/p' "$state_file"
)"
grep -q 'self.lifecycle.assert_can_activate();' <<<"$initialization_constraints_block" \
  || fail "Initialization constraints must reject an activated State before venue mutation."
grep -q 'self.tier_policy.side(),' <<<"$initialization_constraints_block" \
  || fail "Initialization constraints must return the immutable Series side."
grep -q 'self.max_order_notional.current(),' <<<"$initialization_constraints_block" \
  || fail "Initialization constraints must return the live per-order notional cap."

initialization_execution_block="$(
  sed -n '/^public fun assert_initialization_execution<Product>($/,/^}/p' "$state_file"
)"
grep -q 'assert_execution_within_strict_tolerance' <<<"$initialization_execution_block" \
  || fail "Initialization must use the immutable strict execution tolerance."

actual_initialize_shape="$(
  sed -n '/^public fun initialize<Product>($/,/^}/p' "$state_file" \
    | tr -d '[:space:]'
)"
expected_initialize_shape='publicfuninitialize<Product>(self:&mutState<Product>,observation:PositionObservation,seed_reserve:u64,reference_time_ms:u64,):u64{self.lifecycle.assert_can_activate();letseed_nav=validated_initialization_nav(self,observation,seed_reserve,reference_time_ms,);self.lifecycle.activate();self.maintenance_reserve=seed_reserve;seed_nav}'
[[ "$actual_initialize_shape" == "$expected_initialize_shape" ]] \
  || fail "State initialization must validate immutably before its final activation and reserve writes."

actual_initialization_validator_signature="$(
  sed -n '/^fun validated_initialization_nav<Product>($/,/): u64 {/p' "$state_file" \
    | tr -d '[:space:]'
)"
expected_initialization_validator_signature='funvalidated_initialization_nav<Product>(self:&State<Product>,observation:PositionObservation,seed_reserve:u64,reference_time_ms:u64,):u64{'
[[ "$actual_initialization_validator_signature" == "$expected_initialization_validator_signature" ]] \
  || fail "Initialization validation must consume its observation through immutable State access."

actual_lifecycle_construction="$(
  production_lines "$lifecycle_file" \
    | grep -vE '=>' \
    | sed -nE 's/^[0-9]+:[[:space:]]*(.*Lifecycle::(Active|ShutdownSettled).*)$/\1/p'
)"
[[ "$actual_lifecycle_construction" == '*self = Lifecycle::Active;' ]] \
  || fail "Only lifecycle activation may construct Active; ShutdownSettled stays test-only."

activation_calls=0
for source_file in $(find "$package_dir/sources" -type f -name '*.move' | sort); do
  if [[ "$source_file" != "$lifecycle_file" ]]; then
    count="$(
      production_lines "$source_file" \
        | grep -Ec '(\.activate|lifecycle::activate)\(' \
        || true
    )"
    activation_calls=$((activation_calls + count))
    if production_lines "$source_file" \
      | grep -Eq 'Lifecycle::(Uninitialized|Active|ReduceOnly|ShutdownPending|ShutdownSettled)'; then
      fail "Only lifecycle.move may construct a production Lifecycle variant."
    fi
  fi
  if production_lines "$source_file" | grep -Eq '\.lifecycle[[:space:]]*='; then
    fail "Stored lifecycle fields may change only through lifecycle transitions."
  fi
done
[[ "$activation_calls" -eq 1 ]] \
  || fail "Exactly one production State call may invoke lifecycle activation."

printf '%s\n' "Series1 source boundaries: OK"
