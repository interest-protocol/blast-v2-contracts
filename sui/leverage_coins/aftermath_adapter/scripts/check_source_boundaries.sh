#!/usr/bin/env bash
# Mechanical boundary gate for adapter-owned versioning, products, and custody.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '%s\n' "$1" >&2; exit 1; }

manifest="$package_dir/Move.toml"
protocol_file="$package_dir/sources/protocol.move"
vault_file="$package_dir/sources/vault.move"
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

printf '%s\n' "Aftermath adapter source boundaries: OK"
