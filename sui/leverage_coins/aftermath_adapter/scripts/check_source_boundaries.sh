#!/usr/bin/env bash
# Mechanical boundary gate for adapter-owned versioning, products, and custody.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '%s\n' "$1" >&2; exit 1; }

manifest="$package_dir/Move.toml"
protocol_file="$package_dir/sources/protocol.move"
vault_file="$package_dir/sources/vault.move"
venue_account_file="$package_dir/sources/venue_account.move"
snapshot_file="$package_dir/sources/snapshot.move"
operations_file="$package_dir/sources/operations.move"
package_admin_file="$package_dir/sources/package_admin.move"
aftermath_file="$package_dir/sources/aftermath.move"
product_file="$package_dir/sources/product.move"
series_dir="$(cd "$package_dir/../series_one" && pwd)"

grep -q '^name = "blast_leverage_aftermath"$' "$manifest" \
  || fail "Move.toml must name blast_leverage_aftermath."
grep -q 'blast_leverage_series_one = { local = "../series_one" }' "$manifest" \
  || fail "The adapter must depend inward on Series1."
if grep -q 'blast_leverage_aftermath' "$series_dir/Move.toml"; then
  fail "Series1 must never depend back on the Aftermath adapter."
fi

for required in \
  "$protocol_file" \
  "$vault_file" \
  "$venue_account_file" \
  "$snapshot_file" \
  "$operations_file" \
  "$package_admin_file" \
  "$aftermath_file" \
  "$product_file" \
  "$package_dir/sources/lib/constants.move" \
  "$package_dir/sources/lib/errors.move" \
  "$package_dir/sources/lib/events.move" \
  "$package_dir/sources/lib/events_wrapper.move"; do
  [[ -f "$required" ]] || fail "Missing required adapter source: $required"
done

if grep -rniE 'AdapterRoot|AdapterDomain|venue_handoff' "$package_dir/sources"; then
  fail "The adapter must not reintroduce a per-adapter ACL root or handoff layer."
fi

grep -q '^public struct Product<phantom Tag>() has drop;$' "$product_file" \
  || fail "Product witnesses must be stateless, droppable, and tag-scoped."
grep -q '^public fun new<Tag>(): Product<Tag> {$' "$product_file" \
  || fail "Product tags must have one public stateless constructor."
if grep -Eq '\b(TxContext|AdminWitness|AdminCap|UID|key|store|copy)\b' "$product_file"; then
  fail "Product witnesses must carry no state or authority."
fi
if grep -rniE '^(public )?struct [A-Za-z0-9_]*AdminCap' "$package_dir/sources"; then
  fail "The adapter must not define an adapter-local AdminCap."
fi

grep -q '^public struct Protocol has key {$' "$protocol_file" \
  || fail "The adapter must own one shared version object."
if sed -n '/^public struct Protocol has key {$/,/^}$/p' "$protocol_file" \
  | grep -q 'authority:'; then
  fail "Series1 authority must remain global, not nested in this adapter."
fi
grep -q '^const PACKAGE_VERSION: u64 = 1;$' "$protocol_file" \
  || fail "The adapter must own its compiled package version."
if grep -rEq '\b(ProtocolAuthority|AdminCap)\b' "$package_dir/sources"; then
  fail "Adapter functions must accept a Series1 AdminWitness, not ACL state or caps."
fi
grep -q 'admin_witness: &AdminWitness' "$protocol_file" \
  || fail "Adapter version activation must accept a Series1 AdminWitness."
if grep -Eq '^public fun (grant_admin|revoke_admin|grant_role|revoke_role|destroy_admin_cap|begin_super_admin_transfer|cancel_super_admin_transfer|accept_super_admin_transfer|destroy_retired_super_admin_cap)\(' "$protocol_file"; then
  fail "Adapter protocol must not proxy Series1 ACL management."
fi
if grep -Eq 'fun sign_in\(' "$protocol_file"; then
  fail "Adapter protocol must not wrap Series1 sign-in."
fi

grep -q '^public struct Vault<phantom Product> has key {$' "$vault_file" \
  || fail "The adapter must define one Vault type per product witness."
grep -q 'series_state: State<Product>' "$vault_file" \
  || fail "The adapter Vault must wrap the Series1 state value."
if grep -qE 'adapter_storage|Bag|bag::' "$vault_file"; then
  fail "Vault must not carry speculative extension storage."
fi
grep -q '^public struct VenueAccount has store {$' "$venue_account_file" \
  || fail "VenueAccount must be a non-key, store-only custody value."
grep -q '^public struct Binding has copy, drop, store {$' "$venue_account_file" \
  || fail "Binding must remain a copyable stored value."
grep -q '^public struct Checkpoint has copy, drop, store {$' "$venue_account_file" \
  || fail "Checkpoint must remain a copyable stored value."
grep -q 'admin_cap: Option<AuthorityCap<ACCOUNT, ADMIN>>' "$venue_account_file" \
  || fail "VenueAccount must hold the exact optional Aftermath account admin cap."
if grep -rqE '\bASSISTANT\b|new_assistant' "$package_dir/sources"; then
  fail "The adapter must never create or store an Aftermath assistant cap."
fi
production_venue_account="$(
  sed '/^\/\/ === Test-Only Functions ===/,$d' "$venue_account_file"
)"
if grep -qE '^public fun .*([Cc]ap|[Vv]enue[Aa]ccount)' \
  <<<"$production_venue_account"; then
  fail "Venue capability and custody access must remain package-only."
fi
venue_account_fields="$(
  sed -n '/^public struct VenueAccount has store {$/,/^}$/p' "$venue_account_file" \
    | sed '1d;$d;s/^[[:space:]]*//'
)"
expected_venue_account_fields=$'admin_cap: Option<AuthorityCap<ACCOUNT, ADMIN>>,\naccount_object_id: ID,\naccount_number: u64,\nregistry_id: ID,\nclearing_house_id: ID,\nbase_oracle_id: ID,\ncollateral_oracle_id: ID,\ncollateral_type: TypeName,\ncheckpoint: Checkpoint,'
[[ "$venue_account_fields" == "$expected_venue_account_fields" ]] \
  || fail "VenueAccount must contain exactly the accepted custody and binding fields."
binding_fields="$(
  sed -n '/^public struct Binding has copy, drop, store {$/,/^}$/p' "$venue_account_file" \
    | sed '1d;$d;s/^[[:space:]]*//'
)"
expected_binding_fields=$'account_object_id: ID,\naccount_number: u64,\nregistry_id: ID,\nclearing_house_id: ID,\nbase_oracle_id: ID,\ncollateral_oracle_id: ID,\ncollateral_type: TypeName,'
[[ "$binding_fields" == "$expected_binding_fields" ]] \
  || fail "Binding must contain exactly five object ids, the account number, and collateral type."
checkpoint_fields="$(
  sed -n '/^public struct Checkpoint has copy, drop, store {$/,/^}$/p' "$venue_account_file" \
    | sed '1d;$d;s/^[[:space:]]*//'
)"
expected_checkpoint_fields=$'free_collateral: u64,\nallocated_collateral: u256,\nsigned_base: u256,\nsigned_quote_notional: u256,\nfunding_snapshot_long: u256,\nfunding_snapshot_short: u256,\nmarket_funding_long: u256,\nmarket_funding_short: u256,\nlot_size: u64,\npending_ask_base: u256,\npending_bid_base: u256,\npending_order_count: u64,\nmarket_pause_mode: u8,\nmarket_frozen: bool,\nposition_initial_margin_ratio: u256,\nmarket_initial_margin_ratio: u256,\nmarket_maintenance_margin_ratio: u256,'
[[ "$checkpoint_fields" == "$expected_checkpoint_fields" ]] \
  || fail "Checkpoint must contain exactly the accepted normalized raw fields."
constructor_block="$(
  sed -n '/^public(package) fun new($/,/^}/p' "$venue_account_file"
)"
[[ "$(grep -Fc 'authority::`for`(&admin_cap)' <<<"$constructor_block")" -eq 1 ]] \
  || fail "VenueAccount construction must read the cap binding exactly once."
awk '
  /assert_admin_cap_binding\(authority::`for`\(&admin_cap\), account_object_id\);/ {
    getline
    if ($0 == "    let admin_cap = option::some(admin_cap);") {
      getline
      if ($0 == "    VenueAccount {") found = 1
    }
  }
  END { exit !found }
' <<<"$constructor_block" \
  || fail "VenueAccount must check authority::for immediately before wrapping and retaining the cap."
[[ "$(grep -Fc 'option::some(admin_cap)' <<<"$constructor_block")" -eq 1 ]] \
  || fail "Production VenueAccount construction must always retain some admin cap."
if grep -q 'option::none' <<<"$production_venue_account"; then
  fail "Published VenueAccount code must have no path that constructs a missing admin cap."
fi
if grep -qE 'admin_cap\.(destroy|extract|take|fill|swap|replace)|self\.admin_cap[[:space:]]*=|self\.admin_cap\.borrow_mut\(' \
  <<<"$production_venue_account"; then
  fail "Published VenueAccount code must never clear, take, or replace the retained admin cap."
fi
if grep -qE 'option::(destroy|extract|take|fill|swap|replace)[^(]*\([^)]*admin_cap' \
  <<<"$production_venue_account"; then
  fail "Published VenueAccount code must never mutate the retained admin-cap option through a free function."
fi
custody_binding_block="$(
  sed -n '/^public(package) fun assert_custody_binding(/,/^}/p' "$venue_account_file"
)"
custody_some_line="$(grep -nF 'self.admin_cap.is_some()' <<<"$custody_binding_block" | cut -d: -f1)"
custody_borrow_line="$(grep -nF 'authority::`for`(self.admin_cap.borrow())' <<<"$custody_binding_block" | cut -d: -f1)"
if [[ -z "$custody_some_line" || -z "$custody_borrow_line" ]] \
  || (( custody_some_line >= custody_borrow_line )); then
  fail "Every production admin-cap borrow must first assert that the retained option is some."
fi
[[ "$(grep -Fc 'self.admin_cap.borrow()' <<<"$production_venue_account")" -eq 1 ]] \
  || fail "VenueAccount must have one checked production borrow of the retained admin cap."
grep -A1 '^#\[test_only\]$' "$venue_account_file" \
  | grep -q '^public fun new_for_testing(' \
  || fail "The missing-cap VenueAccount constructor must remain test-only."
if grep -qE '\): *&?(mut )?AuthorityCap<|: *&mut AuthorityCap<' \
  <<<"$production_venue_account"; then
  fail "VenueAccount must not return or mutably borrow the admin cap."
fi
grep -q 'assert_venue_account_installable(self.venue_account.is_some());' "$vault_file" \
  || fail "Vault installation must apply the one-time guard immediately before storage."
grep -q 'venue_account: Option<VenueAccount>' "$vault_file" \
  || fail "Vault must store one typed optional VenueAccount."
if grep -qE 'Bag|bag::|dynamic_(object_)?field' "$venue_account_file"; then
  fail "VenueAccount must use direct typed storage only."
fi
grep -q '^public fun issue<Product: drop, RiskModule: drop>($' "$vault_file" \
  || fail "Issuance must be generic over product and risk witnesses."
sed -n '/^public fun issue</,/^)/p' "$vault_file" \
  | grep -q '_: Product,' \
  || fail "Issuance must consume a runtime product witness."
grep -q 'type_name::original_id<Product>()' "$vault_file" \
  || fail "Issuance must inspect the product witness origin."
grep -q 'type_name::original_id<AFTERMATH>()' "$vault_file" \
  || fail "Product witnesses must originate from the Aftermath adapter package."
grep -q 'registry.new_currency<Vault<Product>>' "$vault_file" \
  || fail "Coin Registry must enforce one currency per product witness type."
grep -q 'initializer.finalize(ctx)' "$vault_file" \
  || fail "Issuance must retain the claimed MetadataCap."
grep -q 'let vault_id = vault.id.to_inner();' "$vault_file" \
  || fail "Vault identity must use its UID directly inside vault.move."
grep -q '^): Vault<Product> {$' "$vault_file" \
  || fail "Issuance must return the owned key-only Vault."
if sed -n '/^public fun issue</,/^}/p' "$vault_file" \
  | grep -q 'transfer::share_object'; then
  fail "Issuance and sharing must remain separate operations."
fi
sed -n '/^public fun share</,/^}/p' "$vault_file" \
  | grep -q 'transfer::share_object(self);' \
  || fail "Only the adapter share function may publish an issued Vault."
grep -q '^public fun set_max_order_notional<Product, RiskModule: drop>($' "$vault_file" \
  || fail "The adapter must expose selected-risk-module maximum-order-notional control."
sed -n '/^public fun set_max_order_notional</,/^}/p' "$vault_file" \
  | grep -q 'presented_witness == self.risk_module_witness' \
  || fail "Notional-cap control must authenticate the selected risk module."
grep -q '^public fun enter_reduce_only<Product>($' "$vault_file" \
  || fail "The adapter must expose the Series1 risk-admin degradation route."
sed -n '/^public fun enter_reduce_only<Product>($/,/^}/p' "$vault_file" \
  | grep -q 'admin_witness.assert_risk_admin();' \
  || fail "The adapter must authorize ReduceOnly before mutating Series1 state."

grep -q 'publisher.from_module<AFTERMATH>()' "$package_admin_file" \
  || fail "PackageAdmin must validate the canonical adapter Publisher."
grep -q 'type_name::original_id<AFTERMATH>()' "$package_admin_file" \
  || fail "PackageAdmin must validate the original adapter package id."
grep -q 'sui::package::claim_and_keep(otw, ctx);' "$aftermath_file" \
  || fail "Adapter initialization must claim and keep its Publisher."

if grep -rnE '^[[:space:]]*(public[[:space:]]+entry|entry)[[:space:]]+fun' \
  "$package_dir/sources"; then
  fail "Adapter functions remain composable and must not become entry wrappers."
fi

grep -q '^public(package) fun capture<Collateral>($' "$snapshot_file" \
  || fail "Snapshot capture must remain package-only."
grep -q '^public(package) fun capture_health<Collateral>($' "$snapshot_file" \
  || fail "Snapshot health capture must remain package-only."
strict_capture_shape="$(
  sed -n '/^public(package) fun capture<Collateral>($/,/^}/p' "$snapshot_file" \
    | tr -d '[:space:]'
)"
grep -q 'capture_(binding,account,registry,clearing_house,base_oracle,collateral_oracle,base_price_info,collateral_price_info,clock,false,);let(observation,checkpoint,_)=into_observation(captured,false,true)' <<<"$strict_capture_shape" \
  || fail "Strict capture must delegate to the shared authenticated capture path."
health_capture_shape="$(
  sed -n '/^public(package) fun capture_health<Collateral>($/,/^}/p' "$snapshot_file" \
    | tr -d '[:space:]'
)"
grep -q '):CapturedSnapshot{capture_(binding,account,registry,clearing_house,base_oracle,collateral_oracle,base_price_info,collateral_price_info,clock,true,)' <<<"$health_capture_shape" \
  || fail "Health capture must delegate to the shared authenticated capture path."
grep -q '^public struct CapturedSnapshot {$' "$snapshot_file" \
  || fail "Health capture must remain linear until checkpoint classification."
[[ "$(grep -Fc 'binding.assert_exact(' "$snapshot_file")" -eq 1 ]] \
  || fail "Strict and health capture must share one binding authentication path."
grep -q 'base_price_info: &PriceInfoObject,' "$snapshot_file" \
  || fail "Snapshot capture must authenticate the exact base Pyth object."
grep -q 'collateral_price_info: &PriceInfoObject,' "$snapshot_file" \
  || fail "Snapshot capture must authenticate the exact collateral Pyth object."
grep -q 'price_feed::from(aftermath_feed)' "$snapshot_file" \
  || fail "Snapshot capture must bind the Aftermath feed to Pyth from()."
grep -q 'normalize_feed_price(aftermath_price) == normalized_price' "$snapshot_file" \
  || fail "Snapshot capture must require normalized feed/Pyth equality."
grep -q 'market::base_oracle_price(params, base_oracle, clock)' "$snapshot_file" \
  || fail "Snapshot capture must use the bound named base oracle getter."
grep -q 'market::collateral_oracle_price(params, collateral_oracle, clock)' "$snapshot_file" \
  || fail "Snapshot capture must use the bound named collateral oracle getter."
grep -q 'position::compute_margin_and_requirement' "$snapshot_file" \
  || fail "Snapshot capture must compare the named venue margin and requirement."
grep -q 'margin_safe: margin_safe(margin, requirement)' "$snapshot_file" \
  || fail "Snapshot margin safety must compare margin against its requirement."
grep -q '!margin_negative && margin >= requirement' "$snapshot_file" \
  || fail "Snapshot margin safety must reject signed-negative margin carriers."
grep -q 'venue_operational: clearing_house.market_pause_mode() == 0' "$snapshot_file" \
  && grep -q '&& !clearing_house.is_frozen()' "$snapshot_file" \
  || fail "Venue operation must require allowed pause mode and not-frozen state."
grep -q 'observation::new_health_price' "$snapshot_file" \
  || fail "Health capture must preserve authenticated zero oracle prices."
grep -q 'observation::new_health_position' "$snapshot_file" \
  || fail "Health capture must preserve malformed live venue facts."
grep -q 'assert_position_signs(signed_base, signed_quote_notional, position.is_long_or_flat())' "$snapshot_file" \
  || fail "Strict capture must reject incoherent venue position signs."
grep -q 'assert!(base_representable && notional_representable' "$snapshot_file" \
  || fail "Strict capture must reject unrepresentable base and notional facts."
grep -q 'assert!(equity_representable && !ifixed::is_neg(allocated_collateral)' "$snapshot_file" \
  || fail "Strict capture must reject unrepresentable equity facts."
grep -q 'assert!(down < std::u256::max_value!()' "$snapshot_file" \
  || fail "Strict USD ceil conversion must guard its final increment."
grep -q '&& signs_coherent' "$snapshot_file" \
  || fail "Health capture must retain incoherent position signs as unhealthy facts."
grep -q '&& mark_representable' "$snapshot_file" \
  || fail "Health capture must retain an unrepresentable mark as an unhealthy fact."
grep -q 'assert_pyth_price_info(base_price_info, base_feed);' "$snapshot_file" \
  || fail "Base Pyth identity must precede named oracle calculation."
grep -q 'assert_pyth_price_info(collateral_price_info, collateral_feed);' "$snapshot_file" \
  || fail "Collateral Pyth identity must precede named oracle calculation."
base_pyth_line="$(grep -nF 'assert_pyth_price_info(base_price_info, base_feed);' "$snapshot_file" | cut -d: -f1)"
collateral_pyth_line="$(grep -nF 'assert_pyth_price_info(collateral_price_info, collateral_feed);' "$snapshot_file" | cut -d: -f1)"
base_oracle_line="$(grep -nF 'let base_fixed = market::base_oracle_price(params, base_oracle, clock);' "$snapshot_file" | cut -d: -f1)"
collateral_oracle_line="$(grep -nF 'let collateral_fixed = market::collateral_oracle_price(params, collateral_oracle, clock);' "$snapshot_file" | cut -d: -f1)"
if (( base_pyth_line >= base_oracle_line || collateral_pyth_line >= collateral_oracle_line )); then
  fail "Each Pyth identity check must precede its named oracle calculation."
fi
if grep -q 'for_testing.*capture' "$snapshot_file"; then
  fail "Snapshot capture must not accept caller-shaped test economics."
fi

grep -q '^public fun initialize<Product, RiskModule: drop, Collateral>($' "$operations_file" \
  || fail "The adapter must expose one atomic generic initialization operation."
grep -q '^const MAX_INITIALIZATION_ORDERS: u64 = 16;$' "$operations_file" \
  || fail "Initialization must keep its reviewed 16-order work bound."
initialization_block="$(
  sed -n '/^public fun initialize<Product, RiskModule: drop, Collateral>($/,/^}/p' "$operations_file"
)"
initialization_signature="$(sed -n '1,/^) {$/p' <<<"$initialization_block")"
grep -q 'base_price_info: &PriceInfoObject,' <<<"$initialization_signature" \
  || fail "Initialization must accept the exact base Pyth price object."
grep -q 'collateral_price_info: &PriceInfoObject,' <<<"$initialization_signature" \
  || fail "Initialization must accept the exact collateral Pyth price object."
if grep -qE '(^|[[:space:]])(side|direction|order_size|market_id|source_id|share_amount):' \
  <<<"$initialization_signature"; then
  fail "Initialization must not accept caller-selected trade or share parameters."
fi
awk '
  /^\).* \{$/ {
    getline
    found = 1
    valid = ($0 == "    protocol.assert_current();")
  }
  END { exit !(found && valid) }
' <<<"$initialization_block" \
  || fail "Initialization must check the adapter version first."
[[ "$(grep -Fc 'vault.initialization_constraints(&risk_module)' <<<"$initialization_block")" -eq 1 ]] \
  || fail "Initialization must authenticate the selected risk witness exactly once."
[[ "$(grep -Fc 'vault.install_venue_account(venue_account);' <<<"$initialization_block")" -eq 1 ]] \
  || fail "Initialization must install exactly one VenueAccount."
[[ "$(grep -Fc 'snapshot::capture_initialization(' <<<"$initialization_block")" -eq 2 ]] \
  || fail "Initialization must capture exactly one pre-trade and one final snapshot."
[[ "$(grep -Fc 'clearing_house::start_session(' <<<"$initialization_block")" -eq 1 ]] \
  || fail "Initialization must use one Aftermath session."
[[ "$(grep -Fc 'clearing_house::end_session(' <<<"$initialization_block")" -eq 1 ]] \
  || fail "Initialization must end its one Aftermath session."
initialization_shape="$(tr -d '[:space:]' <<<"$initialization_block")"
grep -q 'clearing_house::settle_position_funding(&mutclearing_house,collateral_oracle,account_number,clock,);' \
  <<<"$initialization_shape" \
  || fail "Initialization funding settlement must use the bound collateral oracle."
[[ "$(grep -Fc 'clearing_house::share(clearing_house);' <<<"$initialization_block")" -eq 1 ]] \
  || fail "Initialization must return the ClearingHouse through its defining share port."
[[ "$(grep -Fc 'account::consume_policy_and_share_account(account, share_policy);' <<<"$initialization_block")" -eq 1 ]] \
  || fail "Initialization must consume the account share policy and share the account."
[[ "$(grep -Fc 'emit_vault_initialized<Product>(' <<<"$initialization_block")" -eq 1 ]] \
  || fail "Initialization must call one state-derived activation event helper."
activation_event_block="$(
  sed -n '/^public(package) fun emit_vault_initialized<Product>($/,/^}/p' "$operations_file"
)"
[[ "$(grep -Fc 'events::vault_initialized<Product>(' <<<"$activation_event_block")" -eq 1 ]] \
  || fail "The state-derived activation helper must emit exactly one activation event."
grep -q 'vault.venue_binding().unpack_binding()' <<<"$activation_event_block" \
  || fail "Activation events must read immutable binding fields from the resulting Vault."
grep -q 'let checkpoint = \*vault.venue_checkpoint();' <<<"$activation_event_block" \
  || fail "Activation events must read the resulting Vault checkpoint."
grep -q 'let seed_reserve = vault.maintenance_reserve();' <<<"$activation_event_block" \
  || fail "Activation events must read the resulting Series reserve."
grep -q 'position_side == policy::short()' "$operations_file" \
  || fail "Initialization must map Aftermath true to ask/short and false to bid/long."
grep -q 'aftermath_order_side,' <<<"$initialization_block" \
  || fail "Initialization must use only the policy-derived Aftermath order side."

initialization_line() {
  local needle="$1"
  grep -nF "$needle" <<<"$initialization_block" | head -1 | cut -d: -f1
}
version_line="$(initialization_line 'protocol.assert_current();')"
risk_line="$(initialization_line 'vault.initialization_constraints(&risk_module)')"
create_line="$(initialization_line 'account::create_account<Collateral>(registry, ctx)')"
binding_line="$(initialization_line 'venue_account::assert_admin_cap_binding(')"
deposit_line="$(initialization_line 'account::deposit_collateral(')"
allocate_line="$(initialization_line 'clearing_house::allocate_collateral(')"
position_line="$(initialization_line 'clearing_house::create_market_position(')"
imr_line="$(initialization_line 'clearing_house::set_position_initial_margin_ratio(')"
pre_capture_line="$(grep -nF 'snapshot::capture_initialization(' <<<"$initialization_block" | sed -n '1s/:.*//p')"
session_start_line="$(initialization_line 'clearing_house::start_session(')"
session_end_line="$(initialization_line 'clearing_house::end_session(')"
settle_line="$(initialization_line 'clearing_house::settle_position_funding(')"
final_capture_line="$(grep -nF 'snapshot::capture_initialization(' <<<"$initialization_block" | sed -n '2s/:.*//p')"
activate_line="$(initialization_line 'vault.initialize_series(')"
mint_line="$(initialization_line 'vault.mint_locked_shares(')"
seal_line="$(initialization_line 'venue_account::new(admin_cap, binding, checkpoint)')"
account_share_line="$(initialization_line 'account::consume_policy_and_share_account(account, share_policy);')"
install_line="$(initialization_line 'vault.install_venue_account(venue_account);')"
clearing_share_line="$(initialization_line 'clearing_house::share(clearing_house);')"
event_line="$(initialization_line 'emit_vault_initialized<Product>(')"
initialization_order=(
  "$version_line" "$risk_line" "$create_line" "$binding_line" "$deposit_line"
  "$allocate_line" "$position_line" "$imr_line" "$pre_capture_line"
  "$session_start_line" "$session_end_line" "$settle_line" "$final_capture_line"
  "$activate_line" "$mint_line" "$seal_line" "$account_share_line" "$install_line"
  "$clearing_share_line" "$event_line"
)
for ((i = 1; i < ${#initialization_order[@]}; i++)); do
  if (( initialization_order[i - 1] >= initialization_order[i] )); then
    fail "Initialization must preserve the authenticated atomic call sequence."
  fi
done

order_sizes_block="$(
  sed -n '/^fun order_sizes($/,/^}/p' "$operations_file"
)"
order_count_line="$(grep -nF 'let order_count = initialization_order_count(' <<<"$order_sizes_block" | cut -d: -f1)"
vector_line="$(grep -nF 'let mut orders = vector[];' <<<"$order_sizes_block" | cut -d: -f1)"
bounded_loop_line="$(grep -nF 'while (orders.length() < order_count) {' <<<"$order_sizes_block" | cut -d: -f1)"
if [[ -z "$order_count_line" || -z "$vector_line" || -z "$bounded_loop_line" ]] \
  || (( order_count_line >= vector_line || vector_line >= bounded_loop_line )); then
  fail "Initialization must prove its order count before vector construction and bounded looping."
fi
grep -q 'count <= MAX_INITIALIZATION_ORDERS' "$operations_file" \
  || fail "Initialization order count must enforce the fixed adapter work bound."
grep -q 'initialization_order_count_exceeded!' "$operations_file" \
  || fail "Initialization order-count overflow must keep its dedicated abort identity."

production_operations="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$operations_file")"
if grep -qE '^public fun .*order' <<<"$production_operations"; then
  fail "The adapter must not expose a generic public order function."
fi

grep -q '^public fun sync_health<Product, Collateral>($' "$operations_file" \
  || fail "The adapter must expose one permissionless health synchronization operation."
sync_block="$(
  sed -n '/^public fun sync_health<Product, Collateral>($/,/^}/p' "$operations_file"
)"
sync_signature="$(sed -n '1,/^) {$/p' <<<"$sync_block")"
grep -q 'base_price_info: &PriceInfoObject,' <<<"$sync_signature" \
  || fail "Health sync must accept the exact base Pyth price object."
grep -q 'collateral_price_info: &PriceInfoObject,' <<<"$sync_signature" \
  || fail "Health sync must accept the exact collateral Pyth price object."
if grep -qE '(^|[[:space:]])(cap|side|direction|order_size|market_id|source_id|share_amount):' \
  <<<"$sync_signature"; then
  fail "Permissionless health sync must not accept authority or trade choices."
fi
awk '
  /^\).* \{$/ {
    getline
    found = 1
    valid = ($0 == "    protocol.assert_current();")
  }
  END { exit !(found && valid) }
' <<<"$sync_block" \
  || fail "Health sync must check the adapter version first."
sync_shape="$(tr -d '[:space:]' <<<"$sync_block")"
grep -q 'clearing_house::settle_position_funding(clearing_house,collateral_oracle,account::account_id(account),clock,);' \
  <<<"$sync_shape" \
  || fail "Health sync funding settlement must use the bound collateral oracle."
grep -q 'if(!snapshot::checkpoint_unchanged(stored,before)){snapshot::unexpected_change()}' \
  <<<"$(sed -n '/^fun classify_sync_change($/,/^}/p' "$operations_file" | tr -d '[:space:]')" \
  || fail "Stored checkpoint drift must be unexpected and never funding."
sync_line() {
  local needle="$1"
  grep -nF "$needle" <<<"$sync_block" | head -1 | cut -d: -f1
}
sync_version_line="$(sync_line 'protocol.assert_current();')"
sync_cap_line="$(sync_line 'vault.assert_venue_custody_binding();')"
sync_pre_line="$(grep -nF 'snapshot::capture_health(' <<<"$sync_block" | sed -n '1s/:.*//p')"
sync_candidate_line="$(sync_line 'let funding_candidate = position::calculate_position_funding_internal(')"
sync_settle_line="$(sync_line 'clearing_house::settle_position_funding(')"
sync_post_line="$(grep -nF 'snapshot::capture_health(' <<<"$sync_block" | sed -n '2s/:.*//p')"
sync_classify_line="$(sync_line 'let change = classify_sync_change(')"
sync_apply_line="$(sync_line 'apply_post_capture(')"
sync_order=(
  "$sync_version_line" "$sync_cap_line" "$sync_pre_line"
  "$sync_candidate_line" "$sync_settle_line" "$sync_post_line"
  "$sync_classify_line" "$sync_apply_line"
)
for ((i = 1; i < ${#sync_order[@]}; i++)); do
  if [[ -z "${sync_order[i - 1]}" || -z "${sync_order[i]}" ]] \
    || (( sync_order[i - 1] >= sync_order[i] )); then
    fail "Health sync must preserve settlement, classification, persistence, policy, and event order."
  fi
done
[[ "$(grep -Fc 'apply_post_capture(' <<<"$sync_block")" -eq 1 ]] \
  || fail "Health sync must delegate exactly once to the connected post-capture phase."
post_capture_block="$(
  sed -n '/^public(package) fun apply_post_capture<Product>($/,/^}/p' "$operations_file"
)"
post_capture_line() {
  local needle="$1"
  grep -nF "$needle" <<<"$post_capture_block" | head -1 | cut -d: -f1
}
post_stored_line="$(post_capture_line 'let stored_checkpoint = *vault.venue_checkpoint();')"
post_fields_line="$(post_capture_line 'snapshot::funding_change_fields(&change)')"
post_settle_line="$(post_capture_line 'vault.settle_funding(is_cost, amount)')"
post_finish_line="$(post_capture_line 'let (observation, checkpoint) = snapshot::finish_health(')"
post_persist_line="$(post_capture_line 'vault.replace_venue_checkpoint(checkpoint);')"
post_policy_line="$(post_capture_line 'let lifecycle_changed = vault.sync_health(')"
post_funding_event_line="$(post_capture_line 'events::funding_settled<Product>(')"
post_health_decision_line="$(post_capture_line 'let (emit_health, health_reason) = health_event_decision(')"
post_health_event_line="$(post_capture_line 'events::health_synchronized<Product>(')"
post_capture_order=(
  "$post_stored_line" "$post_fields_line" "$post_settle_line" "$post_finish_line"
  "$post_persist_line" "$post_policy_line" "$post_funding_event_line"
  "$post_health_decision_line" "$post_health_event_line"
)
for ((i = 1; i < ${#post_capture_order[@]}; i++)); do
  if [[ -z "${post_capture_order[i - 1]}" || -z "${post_capture_order[i]}" ]] \
    || (( post_capture_order[i - 1] >= post_capture_order[i] )); then
    fail "The connected post-capture helper must preserve settlement, persistence, policy, and event order."
  fi
done
[[ "$(grep -Fc 'vault.replace_venue_checkpoint(checkpoint);' <<<"$post_capture_block")" -eq 1 ]] \
  || fail "The post-capture helper must persist exactly one authenticated checkpoint."
[[ "$(grep -Fc 'events::funding_settled<Product>(' <<<"$post_capture_block")" -eq 1 ]] \
  || fail "The post-capture helper must have one exact-funding event site."
[[ "$(grep -Fc 'events::health_synchronized<Product>(' <<<"$post_capture_block")" -eq 1 ]] \
  || fail "The post-capture helper must have one degradation event site."
test_post_capture_block="$(
  sed -n '/^public fun apply_post_capture_for_testing<Product>($/,/^}/p' "$operations_file"
)"
[[ "$(grep -Fc 'apply_post_capture(' <<<"$test_post_capture_block")" -eq 1 ]] \
  || fail "The test-only post-capture seam must invoke the exact production helper once."

for mutation in \
  'issue<Product: drop, RiskModule: drop>' \
  'rotate_risk_module<Product, RiskModule: drop>' \
  'set_max_order_notional<Product, RiskModule: drop>' \
  'enter_reduce_only<Product>'; do
  mutation_block="$(sed -n "/^public fun ${mutation//\//\\/}(/,/^}/p" "$vault_file")"
  awk '
    /^\).* \{$/ {
      getline
      found = 1
      valid = ($0 == "    protocol.assert_current();")
    }
    END { exit !(found && valid) }
  ' <<<"$mutation_block" \
    || fail "Public Vault mutation $mutation must check the adapter version first."
done
for mutation in authorize_upgrade commit_upgrade restrict_to_additive restrict_to_dependency_only; do
  mutation_block="$(sed -n "/^public fun $mutation(/,/^}/p" "$package_admin_file")"
  awk '
    /^\).* \{$/ {
      getline
      found = 1
      valid = ($0 == "    protocol.assert_current();")
    }
    END { exit !(found && valid) }
  ' <<<"$mutation_block" \
    || fail "Public PackageAdmin mutation $mutation must check the adapter version first."
done

printf '%s\n' "Aftermath adapter source boundaries: OK"
