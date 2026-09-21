#!/usr/bin/env bash
# Mechanical boundary gate for the venue-neutral Boosts core and its shared domain.
# It pins what neither the compiler nor the Move tests check: immutable
# publication, the single dependency, venue neutrality, the domain marker and
# its role bits, the abilities of the sealed state and plan types, the one
# place a witness is consumed, and the lifecycle construction rules. Layering,
# imports, the error registry and the test seams are checked by the adapter
# gate, which covers both packages.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '%s\n' "$1" >&2; exit 1; }

publication_script="$package_dir/scripts/publish_immutable.sh"
[[ -f "$publication_script" ]] \
  || fail "The core must include its atomic immutable-publication script."
grep -q -- '--publish "$package_dir"' "$publication_script" \
  && grep -q -- '--assign series_upgrade_cap' "$publication_script" \
  && grep -q -- '--move-call 0x2::package::make_immutable series_upgrade_cap' "$publication_script" \
  || fail "Core publication must atomically consume the returned UpgradeCap."
if grep -qE -- 'transfer-objects|public_transfer|transfer::' "$publication_script"; then
  fail "Core publication must never transfer its UpgradeCap."
fi

domain_file="$package_dir/sources/blast_boosts_core.move"
state_file="$package_dir/sources/state.move"
policy_file="$package_dir/sources/policy.move"
lifecycle_file="$package_dir/sources/lifecycle.move"
observation_file="$package_dir/sources/observation.move"

# Production text of a module: everything before its Test-Only section.
production() { sed '/^\/\/ === Test-Only Functions ===/,$d' "$1"; }

# Production lines of a module with line numbers, skipping every #[test_only]
# item wherever it sits.
production_lines() {
  awk '
    /^#\[test_only\]/ { pending = 1; next }
    /^#\[/ { next }
    /^\/\/\// { next }
    /^[^[:space:]}\/]/ { in_test = pending; pending = 0 }
    { if (!in_test) print NR ":" $0 }
  ' "$1"
}

grep -q '^name = "blast_boosts_core"$' "$package_dir/Move.toml" \
  || fail "Move.toml must name blast_boosts_core."
grep -q '^edition = "2024"$' "$package_dir/Move.toml" \
  || fail "Move.toml must use edition 2024."
# The immutable shared administration package is the only permitted dependency
# beyond the implicit framework: the core imports the ACL rather than copying it.
declared_dependencies="$(
  sed -n '/^\[dependencies\]$/,/^\[/p' "$package_dir/Move.toml" \
    | grep -E '^[A-Za-z_][A-Za-z0-9_]* *=' \
    || true
)"
[[ "$declared_dependencies" == 'blast_admin = { local = "../../admin" }' ]] \
  || fail "The core may depend only on the local blast_admin package."

for required in \
  "$domain_file" \
  "$state_file" \
  "$policy_file" \
  "$lifecycle_file" \
  "$observation_file" \
  "$package_dir/sources/lib/accounting_math.move" \
  "$package_dir/sources/lib/rebalance_math.move"; do
  [[ -f "$required" ]] || fail "Missing required core source: $required"
done

for forbidden in \
  venue_handoff.move \
  package_admin.move \
  package_version.move \
  protocol.move \
  core.move \
  vault.move; do
  [[ ! -e "$package_dir/sources/$forbidden" ]] \
    || fail "$forbidden belongs outside the venue-neutral core."
done

# The core is published immutably and owns no reusable administration lifecycle.
for forbidden in \
  acl.move \
  upgrade.move \
  package_marker.move \
  lib/events.move \
  lib/blast_events.move; do
  [[ ! -e "$package_dir/sources/$forbidden" ]] \
    || fail "$forbidden reintroduces administration or replay state that blast_admin owns."
done

if grep -rniE 'aftermath|bluefin|pyth|deepbook' "$package_dir/sources"; then
  fail "Core source must remain venue and oracle neutral."
fi
if grep -rniE 'CoinRegistry|TreasuryCap|MetadataCap|CurrencyInitializer|sui::bag|dynamic_object_field|Publisher|UpgradeCap' \
  "$package_dir/sources"; then
  fail "Currency, venue-specific state, and package-upgrade custody belong to adapters."
fi
if grep -rniE 'AdapterRoot|AdapterDomain|adapter_witness|venue_handoff' \
  "$package_dir/sources"; then
  fail "The core must not carry adapter-family identity or handoff machinery."
fi

# The reusable ACL lifecycle belongs to the immutable blast_admin package. This
# package may own only its domain marker, its governance constants, and the four
# role values every Boost adapter shares.
if grep -rnE '^public struct (ProtocolAuthority|Authority|SuperAdminCap|AdminCap|AdminWitness)\b' \
  "$package_dir/sources"; then
  fail "Administration types must come from blast_admin, never from a local copy."
fi
if grep -rnE '(grant|revoke)_(admin|role)|(begin|cancel|accept)_super_admin_transfer|fun sign_in' \
  "$package_dir/sources"; then
  fail "The core must not reimplement administrator membership or root rotation."
fi

grep -q '^public struct BLAST_BOOSTS_CORE() has drop;$' "$domain_file" \
  || fail "blast_boosts_core.move must own the domain one-time witness."
grep -q '^fun init(otw: BLAST_BOOSTS_CORE, ctx: &mut TxContext) {$' "$domain_file" \
  || fail "The core domain must be created from its own one-time witness."
grep -q '^    blast_admin::acl::new(otw, MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx);$' \
  "$domain_file" \
  || fail "The core domain must be created through the shared ACL constructor."
grep -q '^const MAX_ADMINS: u64 = 16;$' "$domain_file" \
  || fail "The core domain must keep its bounded administrator registry."
grep -q '^const ROOT_TRANSFER_DELAY_MS: u64 = 7 \* 24 \* 60 \* 60 \* 1_000;$' "$domain_file" \
  || fail "The core domain must keep its seven-day root-transfer delay."

# The four historical role meanings keep their exact bit values.
grep -q '^const VAULT_ISSUER_ROLE: u64 = 1;$' "$domain_file" \
  || fail "VAULT_ISSUER must remain role bit 1."
grep -q '^const RISK_ADMIN_ROLE: u64 = 2;$' "$domain_file" \
  || fail "RISK_ADMIN must remain role bit 2."
grep -q '^const SHUTDOWN_ADMIN_ROLE: u64 = 8;$' "$domain_file" \
  || fail "SHUTDOWN_ADMIN must remain role bit 8."
grep -q '^const PACKAGE_ADMIN_ROLE: u64 = 16;$' "$domain_file" \
  || fail "PACKAGE_ADMIN must remain role bit 16."

actual_domain_public="$(
  production "$domain_file" \
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
  || fail "The core domain must export exactly its four role accessors."

# Exactly one module may create the shared authority.
[[ "$(grep -rlF 'acl::new(' "$package_dir/sources" | wc -l)" -eq 1 ]] \
  || fail "Exactly one module may call the shared ACL constructor."

# --- Sealed state and linear plans ---

grep -q '^public struct State<phantom Product> has store {$' "$state_file" \
  || fail "Product state must be an adapter-storable, non-object value."
if grep -qE 'UID|Bag|TypeName|TreasuryCap|MetadataCap|CoinRegistry|share_object' "$state_file"; then
  fail "Product state must not own adapter objects, witnesses, or currency caps."
fi
for linear in Issuance MintPlan RedemptionPlan RebalancePlan; do
  grep -q "^public struct $linear<phantom Product> {$" "$state_file" \
    || fail "$linear must remain an ability-free, transaction-local carrier."
done
grep -q '^public fun issue<Product>($' "$state_file" \
  || fail "Issuance must be generic only over Product."
grep -q 'admin_witness.assert_role(domain::vault_issuer_role());' "$state_file" \
  || fail "Issuance must require VAULT_ISSUER."
grep -q '^        lifecycle: lifecycle::active(),$' "$state_file" \
  || fail "Every activated state must start Active."
grep -q '^public fun set_max_order_notional<Product>(' "$state_file" \
  || fail "Product state must own bounded maximum-order-notional mutation."
grep -Fq 'public fun begin_shutdown<Product>(' "$state_file" \
  || fail "Product state must own the irreversible shutdown transition."
grep -q '^use blast_admin::acl::AdminWitness;$' "$state_file" \
  || fail "State must import the shared AdminWitness without an alias."
grep -q 'admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,' "$state_file" \
  || fail "Issuance must take the typed core-domain witness."
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
      /^[0-9]+:\/\/ === / { function_name = "" }
      function_name != "" && function_name != "issue" && /AdminWitness/ { print }
    '
)"
[[ -z "$state_admin_witness_violations" ]] \
  || fail "Only state::issue may accept or reference AdminWitness."

# Observations are consumed by one operation: droppable, never copied or stored.
grep -q '^public struct PriceObservation has drop {$' "$observation_file" \
  || fail "PriceObservation must remain a drop-only, operation-scoped carrier."
grep -q '^public struct PositionObservation has drop {$' "$observation_file" \
  || fail "PositionObservation must remain a drop-only, operation-scoped carrier."
grep -q '^public enum FundingSettlement has drop {$' "$observation_file" \
  || fail "FundingSettlement must remain a drop-only, operation-scoped carrier."

if grep -rnE '^[[:space:]]*(public[[:space:]]+entry|entry)[[:space:]]+fun' \
  "$package_dir/sources"; then
  fail "The core exposes composable functions, not entry wrappers."
fi
# The core raises aborts and returns values; every administration replay fact is
# emitted by blast_admin and every product fact by the adapter.
if grep -rn 'sui::event::emit\|sui::event::' "$package_dir/sources"; then
  fail "The core emits no events; replay facts belong to blast_admin and the adapters."
fi

# --- Public surface ---
# The policy constructors and the State transitions are the cross-package ABI;
# a change here is a reviewed boundary decision.

actual_policy_public="$(
  production "$policy_file" \
    | sed -nE 's/^public[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p' \
    | sort
)"
expected_policy_public="$(printf '%s\n' \
  long \
  new_price_policy \
  new_rebalance_policy \
  new_vault_policy \
  short \
  | sort)"
[[ "$actual_policy_public" == "$expected_policy_public" ]] \
  || fail "The public policy-construction surface changed without boundary review."

actual_state_public="$(
  production "$state_file" \
    | sed -nE 's/^public[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p' \
    | sort
)"
expected_state_public="$(printf '%s\n' \
  accept_rebalance_fill \
  activate \
  admin_fee \
  assert_active \
  assert_can_sync \
  assert_execution \
  assert_order_notional_allowed \
  assert_seed_execution \
  assert_seed_order_notional_allowed \
  assert_settled \
  assert_unwinding \
  base \
  base_price \
  base_to_buy \
  base_to_sell \
  begin_shutdown \
  collateral_price \
  complete_mint \
  complete_rebalance \
  complete_redemption \
  donate \
  equity \
  finalize_shutdown \
  is_emergency \
  is_increase \
  is_increasing \
  issue \
  lot_size \
  maintenance_reserve \
  max_order_base \
  mint_position \
  needs_rebalance \
  next_rebalance_order \
  notional \
  order_base \
  prepare_mint \
  prepare_rebalance \
  prepare_redemption \
  rebalance_position \
  redemption_position \
  redemption_shares \
  seed_side \
  seed_terms \
  set_fees \
  set_max_order_notional \
  set_nav_cap \
  settle_funding \
  shutdown_claim_quote \
  side \
  unwind_constraints \
  | sort)"
[[ "$actual_state_public" == "$expected_state_public" ]] \
  || fail "The production State surface changed without boundary review."

# --- Lifecycle construction ---
# lifecycle.move alone constructs variants: Active through its constructor and
# the two forward transitions in place. Exactly one production call creates a
# lifecycle, and no stored lifecycle field is ever assigned.

actual_lifecycle_construction="$(
  production_lines "$lifecycle_file" \
    | grep -vE '=>' \
    | sed -nE 's/^[0-9]+:[[:space:]]*(.*Lifecycle::(Active|Unwinding|Settled).*)$/\1/p'
)"
expected_lifecycle_construction="$(printf '%s\n' \
  'public(package) fun active(): Lifecycle { Lifecycle::Active }' \
  '*self = Lifecycle::Unwinding;' \
  '*self = Lifecycle::Settled;')"
[[ "$actual_lifecycle_construction" == "$expected_lifecycle_construction" ]] \
  || fail "Only the Active constructor and the two forward transitions may construct lifecycle variants."

lifecycle_creations=0
for source_file in $(find "$package_dir/sources" -type f -name '*.move' | sort); do
  if [[ "$source_file" != "$lifecycle_file" ]]; then
    count="$(production_lines "$source_file" | grep -Ec 'lifecycle::active\(\)' || true)"
    lifecycle_creations=$((lifecycle_creations + count))
    if production_lines "$source_file" | grep -Eq 'Lifecycle::(Active|Unwinding|Settled)'; then
      fail "Only lifecycle.move may construct a production Lifecycle variant."
    fi
  fi
  if production_lines "$source_file" | grep -Eq '\.lifecycle[[:space:]]*='; then
    fail "Stored lifecycle fields may change only through lifecycle transitions."
  fi
done
[[ "$lifecycle_creations" -eq 1 ]] \
  || fail "Exactly one production call may create a lifecycle."

printf '%s\n' "Core source boundaries: OK"
