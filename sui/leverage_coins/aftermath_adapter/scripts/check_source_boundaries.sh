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
series_dir="$(cd "$package_dir/../core" && pwd)"

grep -q '^name = "blast_leverage_aftermath"$' "$manifest" \
  || fail "Move.toml must name blast_leverage_aftermath."
grep -q 'blast_leverage_core = { local = "../core" }' "$manifest" \
  || fail "The adapter must depend inward on the core."
if grep -q 'blast_leverage_aftermath' "$series_dir/Move.toml"; then
  fail "the core must never depend back on the Aftermath adapter."
fi

for required in \
  "$protocol_file" \
  "$vault_file" \
  "$venue_account_file" \
  "$snapshot_file" \
  "$operations_file" \
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

# A Vault is tagged by any non-primitive droppable type; the issuer role is
# the only gate, so no product wrapper or runtime witness value exists.
[[ ! -e "$package_dir/sources/product.move" ]] \
  || fail "The adapter must not reintroduce a Product wrapper; the issuer role is the only gate."
if grep -rniE '^(public )?struct [A-Za-z0-9_]*AdminCap' "$package_dir/sources"; then
  fail "The adapter must not define an adapter-local AdminCap."
fi

# The generation value, its checked arithmetic, and its replay event belong to
# blast_admin. This container owns only its compiled constants.
protocol_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$protocol_file")"

grep -q '^public struct Protocol has key {$' "$protocol_file" \
  || fail "The adapter must own one shared generation object."
protocol_fields="$(
  sed -n '/^public struct Protocol has key {$/,/^}$/p' "$protocol_file" \
    | tr -d '[:space:]'
)"
[[ "$protocol_fields" == 'publicstructProtocolhaskey{id:UID,generation:OperationalVersion<AFTERMATH>,}' ]] \
  || fail "The adapter generation must be the shared typed value and nothing else."
grep -q '^const PACKAGE_VERSION: u64 = 1;$' "$protocol_file" \
  || fail "The adapter must own its compiled package version."
grep -q '^const NEXT_PACKAGE_VERSION: u64 = 2;$' "$protocol_file" \
  || fail "The adapter must own the generation a governed upgrade cuts over to."
grep -q '^fun init(ctx: &mut TxContext) {$' "$protocol_file" \
  || fail "The adapter generation must be shared by its own initializer."
if grep -rEq '\b(ProtocolAuthority|SuperAdminCap|AdminCap)\b' "$package_dir/sources"; then
  fail "Adapter functions must accept a the core AdminWitness, not ACL state or caps."
fi
if grep -rnE '^public struct (Authority|SuperAdminCap|AdminCap|AdminWitness|OperationalVersion|UpgradeCustody)\b' \
  "$package_dir/sources"; then
  fail "Administration types must come from blast_admin, never from a local copy."
fi
if grep -Eq 'AdminWitness|activate' <<<"$protocol_production"; then
  fail "The adapter generation container must not carry administration or a separate activation."
fi
if grep -rEq 'fun sign_in\(|(grant|revoke)_(admin|role)' "$package_dir/sources"; then
  fail "The adapter must not proxy or reimplement the core ACL management."
fi

grep -q '^public struct Vault<phantom Product> has key {$' "$vault_file" \
  || fail "The adapter must define one Vault type per product witness."
grep -q 'series_state: State<Product>' "$vault_file" \
  || fail "The adapter Vault must wrap the the core state value."
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
if grep -qE 'admin_cap[^;]*option::none|admin_cap:[[:space:]]*option::none' <<<"$production_venue_account"; then
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
[[ "$(grep -Fo 'self.admin_cap.borrow()' <<<"$production_venue_account" | wc -l)" -eq 7 ]] \
  || fail "Retained authority may be borrowed only by its guard and four narrow venue operations."
for operation in deposit allocate withdraw execute_order; do
  operation_block="$(sed -n "/^public(package) fun $operation</,/^}/p" "$venue_account_file")"
  guard_line="$(grep -nE 'self.assert_(custody_binding|market_account)\(' <<<"$operation_block" | head -1 | cut -d: -f1)"
  borrow_line="$(grep -nF 'self.admin_cap.borrow()' <<<"$operation_block" | head -1 | cut -d: -f1)"
  [[ -n "$guard_line" && -n "$borrow_line" ]] && (( guard_line < borrow_line )) \
    || fail "$operation must authenticate retained custody before its first native capability use."
done
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
if sed -n '/^public fun issue</,/^)/p' "$vault_file" | grep -q '_: Product,'; then
  fail "Issuance takes no product witness value; the issuer role is the only gate."
fi
sed -n '/^public fun issue</,/^)/p' "$vault_file" \
  | grep -q '_risk_module: RiskModule,' \
  || fail "Issuance must consume the initially selected runtime risk witness."
# Custody is sealed at construction by the shared typed constructor, so no later
# call may re-read the Publisher or UpgradeCap to reprove provenance.
if sed -n '/^public fun issue</,/^}/p' "$vault_file" \
  | grep -qE 'PackageAdmin|assert_adapter_custody'; then
  fail "Vault issuance must not re-read sealed package custody."
fi
sed -n '/^public fun issue</,/^}/p' "$vault_file" \
  | grep -q 'is_primitive()' \
  || fail "Issuance must reject primitive product tags."
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
grep -q 'type_name::original_id<RiskModule>()' "$vault_file" \
  && grep -q '!= type_name::original_id<AFTERMATH>()' "$vault_file" \
  || fail "Risk witnesses must originate outside the adapter's public Product package."
sed -n '/^public fun rotate_risk_module</,/^)/p' "$vault_file" \
  | grep -q '_risk_module: RiskModule,' \
  || fail "Risk rotation must consume the newly selected runtime witness."
grep -q '^public fun begin_shutdown<Product>($' "$vault_file" \
  || fail "The adapter must expose irreversible shutdown."
sed -n '/^public fun begin_shutdown<Product>($/,/^}/p' "$vault_file" \
  | grep -q 'admin_witness.assert_role(domain::shutdown_admin_role());' \
  || fail "Only shutdown-role authority may begin shutdown."
sed -n '/^public fun rotate_risk_module</,/^}/p' "$vault_file" \
  | grep -q 'admin_witness.assert_role(domain::risk_admin_role());' \
  || fail "Risk rotation must require the the core risk-admin role."
grep -q 'admin_witness: &AdminWitness,' "$vault_file" \
  && fail "Every administered Vault operation must take the typed the core-domain witness."
witness_params="$(grep -c 'admin_witness: &AdminWitness<BLAST_LEVERAGE_CORE>,' "$vault_file")"
role_checks="$(grep -c 'admin_witness.assert_role(domain::' "$vault_file")"
[[ "$witness_params" -eq $((role_checks + 1)) ]] \
  || fail "Every administered Vault operation except issuance, whose issuer role the core asserts, must assert its own the core-domain role."

# Custody wraps the shared sealed value. Provenance is proved once, by this
# package for the Publisher module and by blast_admin for the cap.
package_admin_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$package_admin_file")"

package_admin_fields="$(
  sed -n '/^public struct PackageAdmin has key {$/,/^}$/p' "$package_admin_file" \
    | tr -d '[:space:]'
)"
[[ "$package_admin_fields" == 'publicstructPackageAdminhaskey{id:UID,custody:UpgradeCustody<AFTERMATH>,}' ]] \
  || fail "Adapter custody must be the shared sealed value and nothing else."
grep -q 'publisher.from_module<AFTERMATH>()' "$package_admin_file" \
  || fail "PackageAdmin must validate the canonical adapter Publisher."
grep -q 'upgrade_custody::new<AFTERMATH>(id.to_inner(), publisher, upgrade_cap)' \
  "$package_admin_file" \
  || fail "PackageAdmin must seal both capabilities through the shared constructor."
if grep -qE 'assert_adapter_custody|self\.publisher|self\.upgrade_cap' \
  <<<"$package_admin_production"; then
  fail "Sealed custody must not be reopened for field-peeking checks."
fi
if grep -qE '^public fun (commit_upgrade\(|activate)' <<<"$package_admin_production"; then
  fail "The only upgrade finalizer is one atomic commit-and-advance."
fi
actual_package_admin_public="$(
  printf '%s\n' "$package_admin_production" \
    | sed -nE 's/^public[[:space:]]+fun[[:space:]]+([a-zA-Z0-9_]+).*/\1/p' \
    | sort
)"
expected_package_admin_public="$(printf '%s\n' \
  authorize_upgrade \
  commit_upgrade_and_advance \
  has_upgrade_cap \
  make_immutable \
  restrict_to_additive \
  restrict_to_dependency_only \
  wrap \
  | sort)"
[[ "$actual_package_admin_public" == "$expected_package_admin_public" ]] \
  || fail "The adapter package-administration surface changed without boundary review."
[[ "$(grep -c 'protocol.assert_current();' <<<"$package_admin_production")" -eq 4 ]] \
  || fail "Every non-finalizer custody transition must check the current generation first."
[[ "$(grep -c 'admin_witness.assert_role(domain::package_admin_role());' \
  <<<"$package_admin_production")" -eq 5 ]] \
  || fail "Every custody transition must assert the the core package-admin role."
grep -q 'protocol.assert_next();' "$package_admin_file" \
  || fail "The finalizer must prove the exact next generation before committing."
grep -q 'self.custody.commit_upgrade(custodian_id, receipt);' "$package_admin_file" \
  || fail "The finalizer must commit the receipt into the same sealed capability."
grep -q 'protocol.advance();' "$package_admin_file" \
  || fail "The finalizer must advance the generation in the same transaction."
if grep -qE '\bpackage::(version|only_(additive|dep)_upgrades|make_immutable)\(' \
  <<<"$package_admin_production"; then
  fail "Native upgrade transitions belong to blast_admin, not to this package."
fi
if grep -nE '^(public|entry|public\(package\)) fun [^(]+\([^)]*\): (&)?(Publisher|UpgradeCap)' \
  <<<"$package_admin_production" \
  || grep -nE 'transfer::(public_)?transfer|burn_publisher' <<<"$package_admin_production"; then
  fail "Package administration must expose no capability escape."
fi

# Reusable custody, generation, and policy facts are emitted by blast_admin.
if grep -nE '^public struct (PackageAdminCreated|UpgradeAuthorized|UpgradeCommitted|UpgradePolicyRestricted|UpgradeCapDestroyed|PackageVersionAdvanced)\b' \
  "$package_dir/sources/lib/events.move"; then
  fail "Reusable administration events must come from blast_admin, not a consumer copy."
fi

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
grep -q 'capture_(binding,account,registry,clearing_house,base_oracle,collateral_oracle,base_price_info,collateral_price_info,clock,false,);let(observation,checkpoint,_)=into_observation(captured)' <<<"$strict_capture_shape" \
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
grep -q 'let pnl = position.unrealized_pnl(base_fixed);' "$snapshot_file" \
  || fail "Shareholder NAV must anchor unrealized PnL to the authenticated Pyth index."
if grep -q 'position.unrealized_pnl(mark_fixed)' "$snapshot_file"; then
  fail "Mark price may affect venue margin and divergence, not shareholder NAV."
fi
grep -q 'let (position_collateral, notional_representable) = base_notional_health(' "$snapshot_file" \
  || fail "Current leverage notional must use base size and the authenticated Pyth index."
snapshot_shape="$(tr -d '[:space:]' < "$snapshot_file")"
grep -q 'base_notional_health(position_base,base_risk_price,collateral_price,)' \
  <<<"$snapshot_shape" \
  && grep -q 'normalize_pyth_component_health(price_magnitude,&expo,true)' \
  <<<"$snapshot_shape" \
  || fail "Current leverage notional must ceil the Pyth base numerator."
if grep -q 'usd_fixed_to_collateral_u64_up_health(ifixed::abs(signed_quote_notional)' "$snapshot_file"; then
  fail "Historical quote cost basis must not determine current leverage notional."
fi
grep -q 'margin_safe: margin_safe(margin, requirement)' "$snapshot_file" \
  || fail "Snapshot margin safety must compare margin against its requirement."
grep -q '!margin_negative && margin >= requirement' "$snapshot_file" \
  || fail "Snapshot margin safety must reject signed-negative margin carriers."
grep -q 'venue_operational: clearing_house.market_pause_mode() == 0' "$snapshot_file" \
  && grep -q '&& !clearing_house.is_frozen()' "$snapshot_file" \
  || fail "Venue operation must require allowed pause mode and not-frozen state."
grep -q 'assert_position_signs(signed_base, signed_quote_notional, position.is_long_or_flat())' "$snapshot_file" \
  || fail "Strict capture must reject incoherent venue position signs."
grep -q 'assert!(base_representable && notional_representable' "$snapshot_file" \
  || fail "Strict capture must reject unrepresentable base and notional facts."
grep -q 'assert!(equity_representable,' "$snapshot_file" \
  || fail "Strict capture must reject unrepresentable equity facts."
grep -q 'assert!(down < std::u256::max_value!()' "$snapshot_file" \
  || fail "Strict USD ceil conversion must guard its final increment."
grep -q 'let economics_valid = signs_coherent' "$snapshot_file" \
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
allocation_shape="$(
  sed -n '/clearing_house::allocate_collateral(/,/);/p' <<<"$initialization_block" \
    | tr -d '[:space:]'
)"
grep -q 'clearing_house::allocate_collateral(&mutclearing_house,&admin_cap,&mutaccount,seed_amount,);' \
  <<<"$allocation_shape" \
  || fail "The whole seed, including the accounting reserve, must remain position margin."
[[ "$(grep -Fc 'clearing_house::start_session(' <<<"$initialization_block")" -eq 1 ]] \
  || fail "Initialization must keep one session call site inside its bounded order loop."
[[ "$(grep -Fc 'clearing_house::end_session(' <<<"$initialization_block")" -eq 1 ]] \
  || fail "Initialization must keep one matching end-session call site."
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
grep -q 'let binding = vault.venue_binding();' <<<"$activation_event_block" \
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
update_line="$(initialization_line 'update_funding_when_due(&binding, &mut clearing_house, base_oracle, clock);')"
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
  "$allocate_line" "$position_line" "$imr_line" "$update_line" "$pre_capture_line"
  "$session_start_line" "$session_end_line" "$settle_line" "$final_capture_line"
  "$activate_line" "$mint_line" "$seal_line" "$account_share_line" "$install_line"
  "$clearing_share_line" "$event_line"
)
for ((i = 1; i < ${#initialization_order[@]}; i++)); do
  if (( initialization_order[i - 1] >= initialization_order[i] )); then
    fail "Initialization must preserve the authenticated atomic call sequence."
  fi
done

activation_markers=(
  BLAST_ACTIVATION_BOUNDARY_A1
  BLAST_ACTIVATION_BOUNDARY_A2
  BLAST_ACTIVATION_BOUNDARY_A3
  BLAST_ACTIVATION_BOUNDARY_A4
  BLAST_ACTIVATION_BOUNDARY_A5
  BLAST_ACTIVATION_BOUNDARY_A6
  BLAST_ACTIVATION_BOUNDARY_A7
)
previous_marker_line=0
for marker in "${activation_markers[@]}"; do
  [[ "$(grep -Fc "// $marker" <<<"$initialization_block")" -eq 1 ]] \
    || fail "Initialization evidence marker $marker must occur exactly once."
  marker_line="$(initialization_line "// $marker")"
  if (( marker_line <= previous_marker_line )); then
    fail "Initialization evidence markers must remain in A1-A7 order."
  fi
  previous_marker_line="$marker_line"
done
awk '
  /BLAST_ACTIVATION_BOUNDARY_A1/ { if (previous != "    );") exit 1; found[1] = 1 }
  /BLAST_ACTIVATION_BOUNDARY_A2/ { if (previous != "    vault.mint_locked_shares(locked_shares, seed_funder, ctx);") exit 1; found[2] = 1 }
  /BLAST_ACTIVATION_BOUNDARY_A3/ { if (previous != "    let venue_account = venue_account::new(admin_cap, binding, checkpoint);") exit 1; found[3] = 1 }
  /BLAST_ACTIVATION_BOUNDARY_A4/ { if (previous != "    account::consume_policy_and_share_account(account, share_policy);") exit 1; found[4] = 1 }
  /BLAST_ACTIVATION_BOUNDARY_A5/ { if (previous != "    vault.install_venue_account(venue_account);") exit 1; found[5] = 1 }
  /BLAST_ACTIVATION_BOUNDARY_A6/ { if (previous != "    clearing_house::share(clearing_house);") exit 1; found[6] = 1 }
  /BLAST_ACTIVATION_BOUNDARY_A7/ { if (previous != "    );") exit 1; found[7] = 1 }
  { previous = $0 }
  END {
    for (i = 1; i <= 7; i++) if (!found[i]) exit 1
  }
' <<<"$initialization_block" \
  || fail "Each activation evidence marker must immediately follow its complete reviewed statement."

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
session_loop="$(
  sed -n '/while (!orders.is_empty()) {/,/^    };/p' <<<"$initialization_block"
)"
[[ "$(grep -Fc 'clearing_house::start_session(' <<<"$session_loop")" -eq 1 ]] \
  && [[ "$(grep -Fc 'clearing_house::place_market_order(' <<<"$session_loop")" -eq 1 ]] \
  && [[ "$(grep -Fc 'clearing_house::end_session(' <<<"$session_loop")" -eq 1 ]] \
  || fail "Every bounded initialization order must use its own complete Aftermath session."
grep -q 'clearing_house::filled_base_and_quote(' <<<"$session_loop" \
  && grep -q 'vault.assert_order_notional_allowed(actual_fill_notional(' <<<"$session_loop" \
  || fail "Each session must enforce the live cap against its actual filled quote."
grep -q 'vault.assert_initialization_execution(' <<<"$session_loop" \
  || fail "Strict execution tolerance must be enforced for every individual order."

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
classification_shape="$(
  sed -n '/^fun classify_sync_changes($/,/^}/p' "$operations_file" \
    | tr -d '[:space:]'
)"
grep -q 'snapshot::checkpoint_ready_for_settlement(stored,before)' \
  <<<"$classification_shape" \
  || fail "Market funding-rate advancement must remain eligible for exact settlement."
grep -q 'snapshot::classify_preexisting_funding(stored,before)' \
  <<<"$classification_shape" \
  && grep -q 'snapshot::classify_change(before,after,funding_candidate,collateral_price,)' \
  <<<"$classification_shape" \
  || fail "Preexisting and local funding must be classified as two ordered edges."
sync_line() {
  local needle="$1"
  grep -nF "$needle" <<<"$sync_block" | head -1 | cut -d: -f1
}
sync_version_line="$(sync_line 'protocol.assert_current();')"
sync_cap_line="$(sync_line 'vault.assert_venue_custody_binding();')"
sync_update_line="$(sync_line 'update_funding_when_due(&binding, clearing_house, base_oracle, clock);')"
sync_pre_line="$(grep -nF 'snapshot::capture_health(' <<<"$sync_block" | sed -n '1s/:.*//p')"
sync_candidate_line="$(sync_line 'let funding_candidate = position::calculate_position_funding_internal(')"
sync_settle_line="$(sync_line 'clearing_house::settle_position_funding(')"
sync_post_line="$(grep -nF 'snapshot::capture_health(' <<<"$sync_block" | sed -n '2s/:.*//p')"
sync_classify_line="$(sync_line 'let (preexisting_change, local_change) = classify_sync_changes(')"
sync_apply_line="$(sync_line 'apply_post_capture(')"
sync_order=(
  "$sync_version_line" "$sync_cap_line" "$sync_update_line" "$sync_pre_line"
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
post_net_line="$(post_capture_line 'let net = preexisting_change.net_funding(local_change);')"
post_fields_line="$(post_capture_line 'let checkpoint_clean = net.is_clean();')"
post_settle_line="$(post_capture_line 'vault.settle_funding(is_cost, amount)')"
post_finish_line="$(post_capture_line 'let checkpoint = post_capture.finish_health();')"
post_persist_line="$(post_capture_line 'vault.replace_venue_checkpoint(checkpoint);')"
post_funding_event_line="$(post_capture_line 'events::funding_settled<Product>(')"
post_health_decision_line="$(post_capture_line 'if (diagnostic_changed) {')"
post_health_event_line="$(post_capture_line 'events::health_synchronized<Product>(')"
post_capture_order=(
  "$post_stored_line" "$post_net_line" "$post_fields_line"
  "$post_settle_line" "$post_finish_line"
  "$post_persist_line" "$post_funding_event_line"
  "$post_health_decision_line" "$post_health_event_line"
)
for ((i = 1; i < ${#post_capture_order[@]}; i++)); do
  if [[ -z "${post_capture_order[i - 1]}" || -z "${post_capture_order[i]}" ]] \
    || (( post_capture_order[i - 1] >= post_capture_order[i] )); then
    fail "The connected post-capture helper must preserve settlement, persistence, and event order."
  fi
done
[[ "$(grep -Fc 'vault.replace_venue_checkpoint(checkpoint);' <<<"$post_capture_block")" -eq 1 ]] \
  || fail "The post-capture helper must persist exactly one authenticated checkpoint."
[[ "$(grep -Fc 'events::funding_settled<Product>(' <<<"$post_capture_block")" -eq 1 ]] \
  || fail "One accepted checkpoint must emit exactly one aggregate net-funding fact."
[[ "$(grep -Fc 'events::health_synchronized<Product>(' <<<"$post_capture_block")" -eq 1 ]] \
  || fail "The post-capture helper must have one diagnostic-novelty event site."
grep -q 'if (checkpoint_clean) {' <<<"$post_capture_block" \
  && grep -q 'vault.note_checkpoint_health(&checkpoint, checkpoint_clean)' <<<"$post_capture_block" \
  || fail "Ordinary health must preserve lifecycle and distinguish accepted from diagnostic identities."

for operation in mint redeem rebalance donate release_buffer; do
  operation_block="$(sed -n "/^public fun $operation</,/^}/p" "$operations_file")"
  grep -q 'protocol.assert_current();' <<<"$operation_block" \
    && grep -q 'vault.assert_active();' <<<"$operation_block" \
    && grep -q 'sync_health(' <<<"$operation_block" \
    || fail "$operation must check version and active lifecycle and reconcile funding."
done
for operation in unwind finalize_shutdown; do
  operation_block="$(sed -n "/^public fun $operation</,/^}/p" "$operations_file")"
  grep -q 'protocol.assert_current();' <<<"$operation_block" \
    && grep -q 'vault.assert_unwinding();' <<<"$operation_block" \
    && grep -q 'vault.assert_collateral_type<_, Collateral>();' <<<"$operation_block" \
    || fail "$operation must enforce version, irreversible lifecycle and exact collateral."
  first_statement="$(sed -n '/^) {$/,$p' <<<"$operation_block" | sed -n '2p')"
  [[ "$first_statement" == '    protocol.assert_current();' ]] \
    || fail "$operation must check version before external access."
  signature="$(sed -n '1,/^) {$/p' <<<"$operation_block")"
  if grep -Eq 'AdminWitness|RiskModule|side:|size:|tolerance:|write_off:|amount:' <<<"$signature"; then
    fail "$operation may expose no authority or caller economic choices."
  fi
done
shutdown_block="$(sed -n '/^public fun begin_shutdown</,/^}/p' "$vault_file")"
if grep -Eq 'Price|Oracle|Account|ClearingHouse|snapshot::|settle_' <<<"$shutdown_block"; then
  fail "Beginning shutdown must not depend on venue or valuation availability."
fi
unwind_market_block="$(sed -n '/^fun unwind_market</,/^}/p' "$operations_file")"
grep -Fq 'while (orders < MAX_ACTIVE_ORDERS && remaining > 0)' <<<"$unwind_market_block" \
  && grep -Fq 'is_ask, requested, true, clock, ctx' <<<"$unwind_market_block" \
  && grep -Fq 'actual_fill_notional(filled_quote, collateral_price)' <<<"$unwind_market_block" \
  && grep -Fq 'vault.assert_unwind_execution' <<<"$unwind_market_block" \
  && grep -Fq 'assert_reduction_checkpoint' <<<"$unwind_market_block" \
  && grep -Fq 'remaining = remaining - filled;' <<<"$unwind_market_block" \
  || fail "Normal unwind must be bounded, exact close-only, freshly priced and actual-fill capped."
frozen_block="$(sed -n '/^fun unwind_frozen</,/^}/p' "$operations_file")"
grep -Fq 'settlement_valuation_prices()' <<<"$frozen_block" \
  && grep -Fq 'close_position_at_settlement_prices' <<<"$frozen_block" \
  || fail "Frozen unwind must use only the pinned direct settlement operation."
if grep -Eq 'execute_order|market_order|capture_health|PriceInfo' <<<"$frozen_block"; then
  fail "Direct settlement must not masquerade as a market order or require a live Pyth object."
fi
claim_block="$(sed -n '/^public fun redeem_shutdown</,/^}/p' "$vault_file")"
grep -Fq 'burn_redeemed_shares(shares)' <<<"$claim_block" \
  && grep -Fq 'TerminalCashKey()' <<<"$claim_block" \
  && grep -Fq 'self.share_supply() - locked' <<<"$claim_block" \
  || fail "Terminal claims must consume native shares and actual local cash with locked seed excluded."
if grep -Eq 'snapshot::|clearing_house|withdraw_collateral|retain_admin_cash|fee_bps' <<<"$claim_block"; then
  fail "Terminal claims must require no venue and charge no protocol fee."
fi
for helper in complete_unwind complete_finalization; do
  grep -q "^fun $helper<" "$operations_file" \
    || fail "$helper is an operation-private completion boundary."
done
rebalance_block="$(sed -n '/^public fun rebalance</,/^}/p' "$operations_file")"
redemption_block="$(sed -n '/^public fun redeem</,/^}/p' "$operations_file")"
withdrawal_proof_line="$(grep -nF 'receipt.unwound_checkpoint.assert_withdrawal_checkpoint(&final_checkpoint, receipt.redemption_cash_required());' <<<"$redemption_block" | cut -d: -f1)"
redemption_completion_line="$(grep -nF 'let cash = complete_redemption(' <<<"$redemption_block" | cut -d: -f1)"
[[ -n "$withdrawal_proof_line" && -n "$redemption_completion_line" ]] \
  && (( withdrawal_proof_line < redemption_completion_line )) \
  || fail "Public redemption must prove its signed withdrawal before native completion/burn."
rebalance_signature="$(sed -n '1,/^) {$/p' <<<"$rebalance_block")"
if grep -qE 'AdminWitness|RiskModule|order_size:|side:|target:|tolerance:|fee:' <<<"$rebalance_signature"; then
  fail "Permissionless rebalance must expose no privileged access or caller economic choices."
fi
grep -q 'while (index < MAX_ACTIVE_ORDERS)' <<<"$rebalance_block" \
  && grep -q 'vault.rebalance_order(&plan)' <<<"$rebalance_block" \
  && grep -q 'vault.accept_rebalance_fill' <<<"$rebalance_block" \
  && grep -q 'actual_fill_notional(filled_quote, collateral_price)' <<<"$rebalance_block" \
  || fail "Rebalance must bound work, recompute from accepted fills, and cap actual quote."
grep -q 'seed_funder: address,' <<<"$initialization_signature" \
  && grep -q 'vault.seed_facts()' <<<"$activation_event_block" \
  || fail "Activation must record immutable seed ownership and emit the stored facts."
test_post_capture_block="$(
  sed -n '/^public fun apply_post_capture_for_testing<Product>($/,/^}/p' "$operations_file"
)"
[[ "$(grep -Fc 'apply_post_capture(' <<<"$test_post_capture_block")" -eq 1 ]] \
  || fail "The test-only post-capture seam must invoke the exact production helper once."

for mutation in \
  'issue<Product: drop, RiskModule: drop>' \
  'rotate_risk_module<Product, RiskModule: drop>' \
  'set_max_order_notional<Product, RiskModule: drop>' \
  'begin_shutdown<Product>' \
  'redeem_shutdown<Product, Collateral>'; do
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
for mutation in \
  authorize_upgrade \
  restrict_to_additive \
  restrict_to_dependency_only \
  make_immutable; do
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

# The post-upgrade finalizer runs against bytecode the current generation has
# not accepted yet, so it proves the exact next generation instead.
finalizer_block="$(
  sed -n '/^public fun commit_upgrade_and_advance(/,/^}/p' "$package_admin_file"
)"
awk '
  /^\).* \{$/ {
    getline
    found = 1
    valid = ($0 == "    admin_witness.assert_role(domain::package_admin_role());")
  }
  END { exit !(found && valid) }
' <<<"$finalizer_block" \
  || fail "The finalizer must assert the package-admin role before any other effect."
if grep -q 'protocol.assert_current();' <<<"$finalizer_block"; then
  fail "The finalizer must prove the next generation, not the current one."
fi

# --- Funding update before every accepted settlement (ADR 0074, T-005) ---
update_helper_block="$(sed -n '/^fun update_funding_when_due<Collateral>($/,/^}/p' "$operations_file")"
[[ -n "$update_helper_block" ]] \
  || fail "The adapter must own one package-private guarded funding update helper."
update_shape="$(tr -d '[:space:]' <<<"$update_helper_block")"
grep -q 'binding.assert_funding_update_inputs(object::id(clearing_house),object::id(base_oracle));let(funding_frequency_ms' <<<"$update_shape" \
  || fail "The funding update must authenticate the bound market and base oracle before reading or mutating them."
grep -q 'let(funding_frequency_ms,_)=market::funding_params(clearing_house.market_params());' <<<"$update_shape" \
  || fail "The funding update guard must read the frequency as the first funding parameter of the bound market."
grep -q 'letfunding_last_upd_ms=market::funding_last_upd_ms(clearing_house.market_state());' <<<"$update_shape" \
  || fail "The funding update guard must read the bound market's last funding update time."
grep -q 'if(is_time_to_update_funding(clock.timestamp_ms(),funding_last_upd_ms,funding_frequency_ms)){clearing_house::update_funding(clearing_house,base_oracle,clock);};' <<<"$update_shape" \
  || fail "A venue funding update must be guarded by the due-time check and read the base oracle storage."
[[ "$(grep -Fc 'clearing_house::update_funding(' "$operations_file")" -eq 1 ]] \
  || fail "The venue funding update must have exactly one guarded call site."
[[ "$(grep -Fc 'update_twaps(' "$operations_file")" -eq 0 ]] \
  || fail "The adapter must not call the venue TWAP update."
guard_shape="$(sed -n '/^fun is_time_to_update_funding(/,/^}/p' "$operations_file" | tr -d '[:space:]')"
grep -q 'funding_frequency_ms>0&&now>=next_funding_update_time_ms(funding_last_upd_ms,funding_frequency_ms)' <<<"$guard_shape" \
  || fail "The due-time guard must mirror the pinned venue formula and treat a zero frequency as never due."
[[ "$(grep -Fc 'clearing_house::settle_position_funding(' "$operations_file")" -eq 3 ]] \
  || fail "Every funding settlement must be one of the three guarded call sites."
settlement_function_check() {
  local header="$1" capture="$2" label="$3"
  local block update_line capture_line settle_line
  block="$(sed -n "/^${header}\$/,/^}/p" "$operations_file")"
  update_line="$( (grep -nF 'update_funding_when_due(' <<<"$block" || true) | head -1 | cut -d: -f1)"
  capture_line="$( (grep -nF "$capture" <<<"$block" || true) | head -1 | cut -d: -f1)"
  settle_line="$( (grep -nF 'clearing_house::settle_position_funding(' <<<"$block" || true) | head -1 | cut -d: -f1)"
  [[ "$(grep -Fc 'update_funding_when_due(' <<<"$block")" -eq 1 ]] \
    || fail "${label} must call the guarded funding update exactly once."
  if [[ -z "$update_line" || -z "$capture_line" || -z "$settle_line" ]] \
    || (( update_line >= capture_line )) || (( capture_line >= settle_line )); then
    fail "${label} must update funding when due before its pre-settlement capture and its settlement."
  fi
}
settlement_function_check 'public fun initialize<Product, RiskModule: drop, Collateral>(' 'snapshot::capture_initialization(' 'Initialization'
settlement_function_check 'public fun sync_health<Product, Collateral>(' 'snapshot::capture_health(' 'Health sync'
settlement_function_check 'fun unwind_market<Product, Collateral>(' 'snapshot::capture_health(' 'Terminal unwind'

printf '%s\n' "Aftermath adapter source boundaries: OK"
