#!/usr/bin/env bash
# Mechanical boundary gate for venue-neutral Series1 state and its shared domain.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '%s\n' "$1" >&2; exit 1; }

publication_script="$package_dir/scripts/publish_immutable.sh"
[[ -f "$publication_script" ]] \
  || fail "Series1 must include its atomic immutable-publication script."
grep -q -- '--publish "$package_dir"' "$publication_script" \
  && grep -q -- '--assign series_upgrade_cap' "$publication_script" \
  && grep -q -- '--move-call 0x2::package::make_immutable series_upgrade_cap' "$publication_script" \
  || fail "Series1 publication must atomically consume the returned UpgradeCap."
if grep -qE -- 'transfer-objects|public_transfer|transfer::' "$publication_script"; then
  fail "Series1 publication must never transfer its UpgradeCap."
fi

domain_file="$package_dir/sources/series_one_domain.move"
state_file="$package_dir/sources/state.move"
policy_file="$package_dir/sources/policy.move"
lifecycle_file="$package_dir/sources/lifecycle.move"
observation_file="$package_dir/sources/observation.move"

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
# The immutable shared administration package is the only permitted dependency
# beyond the implicit framework: Series1 imports the ACL rather than copying it.
declared_dependencies="$(
  sed -n '/^\[dependencies\]$/,/^\[/p' "$package_dir/Move.toml" \
    | grep -E '^[A-Za-z_][A-Za-z0-9_]* *=' \
    || true
)"
[[ "$declared_dependencies" == 'blast_admin = { local = "../../admin" }' ]] \
  || fail "Series1 may depend only on the local blast_admin package."

for required in \
  "$domain_file" \
  "$state_file" \
  "$policy_file" \
  "$lifecycle_file" \
  "$observation_file" \
  "$package_dir/sources/lib/accounting_math.move" \
  "$package_dir/sources/lib/bounded_value.move"; do
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

# Series1 is published immutably and owns no reusable administration lifecycle.
for forbidden in \
  acl.move \
  upgrade.move \
  package_marker.move \
  lib/events.move \
  lib/events_wrapper.move; do
  [[ ! -e "$package_dir/sources/$forbidden" ]] \
    || fail "$forbidden reintroduces administration or replay state that blast_admin owns."
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

# The reusable ACL lifecycle belongs to the immutable blast_admin package. This
# package may own only its domain marker, its governance constants, and the four
# role values every Series1 adapter shares.
if grep -rnE '^public struct (ProtocolAuthority|Authority|SuperAdminCap|AdminCap|AdminWitness)\b' \
  "$package_dir/sources"; then
  fail "Administration types must come from blast_admin, never from a local copy."
fi
if grep -rnE '(grant|revoke)_(admin|role)|(begin|cancel|accept)_super_admin_transfer|fun sign_in' \
  "$package_dir/sources"; then
  fail "Series1 must not reimplement administrator membership or root rotation."
fi

domain_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$domain_file")"

grep -q '^public struct SERIES_ONE_DOMAIN has drop {}$' "$domain_file" \
  || fail "series_one_domain.move must own the domain one-time witness."
grep -q '^fun init(otw: SERIES_ONE_DOMAIN, ctx: &mut TxContext) {$' "$domain_file" \
  || fail "The Series1 domain must be created from its own one-time witness."
grep -q '^    blast_admin::acl::new(otw, MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx);$' \
  "$domain_file" \
  || fail "The Series1 domain must be created through the shared ACL constructor."
grep -q '^const MAX_ADMINS: u64 = 16;$' "$domain_file" \
  || fail "The Series1 domain must keep its bounded administrator registry."
grep -q '^const ROOT_TRANSFER_DELAY_MS: u64 = 7 \* 24 \* 60 \* 60 \* 1_000;$' "$domain_file" \
  || fail "The Series1 domain must keep its seven-day root-transfer delay."

# The four historical role meanings keep their exact bit values, widened to u64.
grep -q '^const VAULT_ISSUER_ROLE: u64 = 1;$' "$domain_file" \
  || fail "VAULT_ISSUER must remain role bit 1."
grep -q '^const RISK_ADMIN_ROLE: u64 = 2;$' "$domain_file" \
  || fail "RISK_ADMIN must remain role bit 2."
grep -q '^const SHUTDOWN_ADMIN_ROLE: u64 = 8;$' "$domain_file" \
  || fail "SHUTDOWN_ADMIN must remain role bit 8."
grep -q '^const PACKAGE_ADMIN_ROLE: u64 = 16;$' "$domain_file" \
  || fail "PACKAGE_ADMIN must remain role bit 16."

actual_domain_public="$(
  printf '%s\n' "$domain_production" \
    | sed -nE 's/^public[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p' \
    | sort
)"
expected_domain_public="$(printf '%s\n' \
  package_admin_role \
  risk_admin_role \
  shutdown_admin_role \
  vault_issuer_role \
  | sort)"
[[ "$actual_domain_public" == "$expected_domain_public" ]] \
  || fail "The Series1 domain must export exactly its four role accessors."

# Exactly one module may create the shared authority.
[[ "$(grep -rlF 'acl::new(' "$package_dir/sources" | wc -l)" -eq 1 ]] \
  || fail "Exactly one module may call the shared ACL constructor."

grep -q '^public struct State<phantom Product> has store {$' "$state_file" \
  || fail "Series product state must be an adapter-storable, non-object value."
if grep -qE 'UID|Bag|TypeName|TreasuryCap|MetadataCap|CoinRegistry|share_object' "$state_file"; then
  fail "Series state must not own adapter objects, witnesses, or currency caps."
fi
grep -q '^public fun new<Product>($' "$state_file" \
  || fail "Series state construction must be generic only over Product."
grep -q 'admin_witness.assert_role(series_one_domain::vault_issuer_role());' "$state_file" \
  || fail "Series state construction must require VAULT_ISSUER."
grep -q 'lifecycle: lifecycle::new(),' "$state_file" \
  || fail "Every new Series state must start uninitialized."
grep -q '^public fun set_max_order_notional<Product>($' "$state_file" \
  || fail "Series state must own bounded maximum-order-notional mutation."
grep -q '^public fun enter_reduce_only<Product>($' "$state_file" \
  || fail "Series state must own the ReduceOnly lifecycle transition."
grep -q '^use blast_admin::acl::AdminWitness;$' "$state_file" \
  || fail "State must import the shared AdminWitness without an alias."
grep -q 'admin_witness: &AdminWitness<SERIES_ONE_DOMAIN>,' "$state_file" \
  || fail "State construction must take the typed Series1-domain witness."
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
# Series1 raises aborts and returns values; every administration replay fact is
# emitted by blast_admin, so this package emits nothing of its own.
if grep -rn 'sui::event::emit\|sui::event::' "$package_dir/sources"; then
  fail "Series1 emits no events; administration replay facts belong to blast_admin."
fi

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
  with_fee_limits \
  | sort)"
[[ "$actual_policy_public" == "$expected_policy_public" ]] \
  || fail "The public policy-construction surface changed without boundary review."

actual_state_public="$({
  production_lines "$state_file" \
    | sed -nE 's/^[0-9]+:[[:space:]]*public[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p'
} | sort)"
expected_state_public="$(printf '%s\n' \
  accept_rebalance_fill \
  active_constraints \
  admin_fee \
  assert_active \
  assert_active_execution \
  assert_active_observation \
  assert_initialization_execution \
  assert_order_notional_allowed \
  assert_rebalance_execution \
  assert_redemption_cash_out \
  assert_user_fee_limit \
  complete_donation \
  complete_mint \
  complete_rebalance \
  complete_redemption \
  donate \
  enter_reduce_only \
  fee_allocation \
  fee_settings \
  initialization_constraints \
  initialize \
  maintenance_reserve \
  mint_deposit \
  mint_valuation \
  new \
  order_base \
  prepare_donation \
  prepare_initialization \
  prepare_mint \
  prepare_rebalance \
  prepare_redemption \
  rebalance_order \
  rebalance_valuation \
  redemption_order_base \
  redemption_terms \
  redemption_valuation \
  release_buffer \
  set_fees \
  set_max_order_notional \
  settle_funding \
  sync_health \
  | sort)"
[[ "$actual_state_public" == "$expected_state_public" ]] \
  || fail "The production Series1 State surface changed without boundary review."

for plan in MintPlan RedemptionPlan RebalancePlan DonationPlan; do
  grep -q "^public struct $plan<phantom Product> {" "$state_file" \
    || fail "$plan must remain a linear transaction-local carrier."
done
if grep -qE 'module_lower_bps|module_upper_bps|is_risk_module_allowed' "$policy_file"; then
  fail "Maintenance must have exactly one public band, without a privileged inner window."
fi
rebalance_prepare="$(sed -n '/^public fun prepare_rebalance</,/^}/p' "$state_file")"
grep -q 'scaled < (nav as u128) \* (risk.public_lower_bps() as u128)' <<<"$rebalance_prepare" \
  && grep -q 'scaled > (nav as u128) \* (risk.public_upper_bps() as u128)' <<<"$rebalance_prepare" \
  || fail "Rebalance triggers must use strict exact-ratio cross products."
health_block="$(sed -n '/^public fun sync_health</,/^}/p' "$state_file")"
if grep -Eq 'self.lifecycle\.(degrade|enter_|activate)|self.maintenance_reserve[[:space:]]*=' <<<"$health_block"; then
  fail "Ordinary health validation must not change lifecycle or reserve allocation."
fi

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
