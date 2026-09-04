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
package_admin_file="$package_dir/sources/package_admin.move"
aftermath_file="$package_dir/sources/aftermath.move"
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
  "$package_admin_file" \
  "$aftermath_file" \
  "$package_dir/sources/lib/constants.move" \
  "$package_dir/sources/lib/errors.move" \
  "$package_dir/sources/lib/events.move" \
  "$package_dir/sources/lib/events_wrapper.move"; do
  [[ -f "$required" ]] || fail "Missing required adapter source: $required"
done

if grep -rniE 'AdapterRoot|AdapterDomain|venue_handoff' "$package_dir/sources"; then
  fail "The adapter must not reintroduce a per-adapter ACL root or handoff layer."
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
grep -q 'admin_cap: AuthorityCap<ACCOUNT, ADMIN>' "$venue_account_file" \
  || fail "VenueAccount must hold the exact Aftermath account admin cap."
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
expected_venue_account_fields=$'admin_cap: AuthorityCap<ACCOUNT, ADMIN>,\naccount_object_id: ID,\naccount_number: u64,\nregistry_id: ID,\nclearing_house_id: ID,\nbase_oracle_id: ID,\ncollateral_oracle_id: ID,\ncollateral_type: TypeName,\ncheckpoint: Checkpoint,'
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
    if ($0 == "    VenueAccount {") found = 1
  }
  END { exit !found }
' <<<"$constructor_block" \
  || fail "VenueAccount must check authority::for immediately before cap custody."
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
grep -q 'capture_(binding, account, registry, clearing_house, base_oracle, collateral_oracle, base_price_info, collateral_price_info, clock, false, true)' "$snapshot_file" \
  || fail "Strict capture must delegate to the shared authenticated capture path."
grep -q 'capture_(binding, account, registry, clearing_house, base_oracle, collateral_oracle, base_price_info, collateral_price_info, clock, true, !is_unexpected_change(change))' "$snapshot_file" \
  || fail "Health capture must delegate to the shared authenticated capture path."
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
grep -q 'economics_valid && margin_safe(margin, requirement)' "$snapshot_file" \
  || fail "Snapshot margin safety must compare margin against its requirement."
grep -q '!margin_negative && margin >= requirement' "$snapshot_file" \
  || fail "Snapshot margin safety must reject signed-negative margin carriers."
grep -q 'clearing_house.market_pause_mode() == 0 && !clearing_house.is_frozen()' "$snapshot_file" \
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

printf '%s\n' "Aftermath adapter source boundaries: OK"
