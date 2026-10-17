#!/usr/bin/env bash
# Structural gates for blast_presale administration (ADR 0097), upgrade custody (ADR 0099), and partner
# binding (ADRs 0106 and 0107).
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources="$package_dir/sources"

fail() {
  printf 'check_source_boundaries: %s\n' "$1" >&2
  exit 1
}

production() {
  sed '/^\/\/ === Test-Only Functions ===/,$d' "$1"
}

# 1. Administration comes only from the shared Blast ACL (ADR 0097): the package declares its
#    ability-free roles, and each administrator action takes exactly the one role pinned here.
if rg -n '^public struct (ACL|Authority|SuperAdminCap|AdminCap|AdminRegistry|AdminWitness)\b' "$sources"; then
  fail "Administration types must come from blast_admin, never from a local copy."
fi
domain_source="$sources/blast_presale_domain.move"
if rg -n 'fun ' "$domain_source"; then
  fail "blast_presale_domain must only declare roles."
fi
[ "$(rg '^public struct ' "$domain_source" | sort)" == "$(printf '%s\n' \
  'public struct AdapterAdmin()' \
  'public struct FeeAdmin()' \
  'public struct ListingAdmin()' \
  'public struct RewardsAdmin()' \
  'public struct TreasuryAdmin()' \
  'public struct UpgradeAdmin()' | sort)" ] \
  || fail "blast_presale_domain must declare exactly the reviewed ability-free roles."
presale_roles='AdapterAdmin|FeeAdmin|ListingAdmin|RewardsAdmin|TreasuryAdmin|UpgradeAdmin'
for file in "$sources"/*.move; do
  production "$file" | { rg -n '^[^/]*AdminWitness<' || true; } \
    | { rg -v "^[0-9]+:    _: &AdminWitness<($presale_roles)>,\$" || true; } \
    | sed "s|^|$(basename "$file"):|"
done | { ! rg .; } \
  || fail "Every administrator witness must be a borrowed, unused AdminWitness of one presale role."
admin_roles="$(for file in "$sources"/*.move; do
  production "$file" | awk -v module="$(basename "$file" .move)" '
    /^(public(\(package\))? )?(entry )?fun / {
      name = $0
      sub(/^.*fun /, "", name)
      sub(/[<(].*$/, "", name)
    }
    /^[^/]*AdminWitness</ && match($0, /AdminWitness<[A-Za-z]+>/) {
      print module ":" name ":" substr($0, RSTART + 13, RLENGTH - 14)
    }
  '
done | sort)"
[ "$admin_roles" == "$(printf '%s\n' \
  'blast_presale:set_protocol_fees:FeeAdmin' \
  'creation_policy:add_partner:FeeAdmin' \
  'creation_policy:remove_partner:FeeAdmin' \
  'creation_policy:set_migration_witness_allowed:AdapterAdmin' \
  'creation_policy:set_quote_allowed:ListingAdmin' \
  'fee_policy:set_destination:TreasuryAdmin' \
  'fee_policy:set_fees:FeeAdmin' \
  'holder_rewards:publish_round:RewardsAdmin' \
  'holder_rewards:settle_gas_reserve:RewardsAdmin' \
  'package_admin:authorize_upgrade:UpgradeAdmin' \
  'package_admin:commit_upgrade:UpgradeAdmin' \
  'presale_vault:set_protocol_lp_fees:FeeAdmin' | sort)" ] \
  || { printf '%s\n' "$admin_roles" >&2; fail "Every administrator action must take exactly its pinned presale role."; }

# 2. Upgrade custody stays sealed and dependency-only, so every generation runs identical logic.
admin_production="$(production "$sources/package_admin.move")"
seal_body="$(sed -n '/^fun seal_dependency_only(/,/^}/p' <<<"$admin_production")"
rg -q 'upgrade_cap\.only_dep_upgrades\(\);' <<<"$seal_body" \
  || fail "Sealing must narrow the cap to dependency-only upgrades before sharing it."
rg -q 'transfer::share_object\(seal_dependency_only\(upgrade_cap, ctx\)\);' <<<"$admin_production" \
  || fail "wrap must share only a cap sealed by seal_dependency_only."
if rg -n '\bmake_immutable\b|\bonly_additive_upgrades\b' "$sources"; then
  fail "Presale custody must stay relinkable and dependency-only."
fi
if rg -U -n '^public fun [^(]+\([^)]*\): (&)?(mut )?UpgradeCap' <<<"$admin_production"; then
  fail "No custody path may release the sealed UpgradeCap."
fi
if rg -n 'transfer::(public_)?transfer\(' <<<"$admin_production"; then
  fail "The framework UpgradeCap must never leave sealed custody."
fi
[ "$(rg -c '^    _: &AdminWitness<UpgradeAdmin>,$' <<<"$admin_production")" -eq 2 ] \
  || fail "Authorizing and committing an upgrade must each require the UpgradeAdmin role."

# 3. A sale's Blast partner is named only by set_partner on its initializer, so `finalize` fixes it
#    before the sale exists (ADRs 0106 and 0110), and its vault keeps that partner for good
#    (ADR 0107).
presale_production="$(production "$sources/blast_presale.move")"
set_partner_body="$(sed -n '/^public fun set_partner</,/^}/p' <<<"$presale_production")"
[ "$(rg -c 'self\.partner_id = ' <<<"$presale_production")" == 1 ] \
  && rg -q '^    self: &mut PresaleInitializer<SaleToken, Quote>,$' <<<"$set_partner_body" \
  && rg -q '^    self\.partner_id = option::some\(partner_id\);$' <<<"$set_partner_body" \
  || fail "Only set_partner, on the initializer, may name a sale's partner."
vault_production="$(production "$sources/presale_vault.move")"
if rg -q '\.partner_id = ' <<<"$vault_production"; then
  fail "A presale vault's partner is the sale's, fixed when the vault is created."
fi
# 4. A sale's window is fixed by `finalize` from its initializer, and only settle, closing it
#    early, shortens it (ADR 0110).
set_windows_body="$(sed -n '/^public fun set_windows</,/^}/p' <<<"$presale_production")"
settle_body="$(sed -n '/^public fun settle</,/^}/p' <<<"$presale_production")"
[ "$(rg -c 'self\.duration_ms = ' <<<"$presale_production")" == 2 ] \
  && rg -q '^    self: &mut PresaleInitializer<SaleToken, Quote>,$' <<<"$set_windows_body" \
  && rg -q '^    self\.duration_ms = duration_ms;$' <<<"$set_windows_body" \
  && rg -q 'self\.duration_ms = now_ms - self\.start_ms;$' <<<"$settle_body" \
  || fail "Only settle, closing a sale early, may shorten its window."

# 5. Aftermath's vault seams (ADR 0116): a vault built before its position, the one call that
#    shares it with one, the venue predicate, and the one object-owned coin receipt reach only
#    the Aftermath venue outside the vault, and the vault's position is never transferred.
for seam in 'vault::new\(' '\.share_with_position\(' '\.has_position\(' '\.receive_fee\('; do
  callers="$(for file in "$sources"/*.move; do
    [ "$(basename "$file")" == "presale_vault.move" ] && continue
    production "$file" | { rg -q "$seam" && basename "$file"; } || true
  done | sort | tr '\n' ' ')"
  [ "$callers" == "aftermath.move " ] \
    || fail "Only the Aftermath venue may reach the vault seam ${seam} (found: ${callers:-none})."
done
[ "$(rg -c 'transfer::public_receive\(' "$sources/presale_vault.move")" == 1 ] \
  && ! rg -q 'transfer::(public_)?receive\(|Receiving<' "$sources"/blast_presale.move "$sources"/cetus.move "$sources"/bluefin.move \
  || fail "Object-owned coins reach a vault only through presale_vault::receive_fee."
if rg -q 'transfer::(public_)?transfer\([^)]*position' "$sources"; then
  fail "A vault's position is never transferred."
fi
[ "$(rg -c 'transfer::public_transfer\(lp, @0x0\)' "$sources/aftermath.move")" == 1 ] \
  || fail "Aftermath's migration must send its LP coin to 0x0 exactly once."

# 6. The presale's Aftermath stubs, including linkage-only dependencies, match the vendor's
#    byte for byte (ADR 0116). Its ABI gate covers the consumed AMM and DAO-fee interfaces too.
vendor_interfaces="$package_dir/../vendors/aftermath_dao_presale/interfaces"
for stub in aftermath_amm aftermath_dao_fee aftermath_math aftermath_utils \
  aftermath_protocol_fee_vault aftermath_treasury aftermath_insurance_fund aftermath_referral_vault; do
  diff -r "$package_dir/interfaces/$stub" "$vendor_interfaces/$stub" >/dev/null \
    || fail "The presale's ${stub} link stub must match the vendor package's byte for byte."
done

printf 'blast_presale source boundaries hold.\n'
