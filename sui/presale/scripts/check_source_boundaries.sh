#!/usr/bin/env bash
# Structural gates for blast_presale administration and upgrade custody (ADR 0097, ADR 0099).
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources="$package_dir/sources"

fail() {
  printf 'check_source_boundaries: %s\n' "$1" >&2
  exit 1
}

# 1. Administration comes only from the shared Blast ACL.
if rg -n '^public struct (ACL|Authority|SuperAdminCap|AdminCap|AdminWitness)\b' "$sources"; then
  fail "Administration types must come from blast_admin, never from a local copy."
fi
if rg -n 'fun init\(' "$sources/blast_presale_domain.move"; then
  fail "blast_presale_domain must not create administration state."
fi
[ "$(rg '^public struct ' "$sources/blast_presale_domain.move" | sort)" == "$(printf '%s\n' \
  'public struct FeeAdmin()' \
  'public struct RewardsAdmin()' \
  'public struct TreasuryAdmin()' \
  'public struct UpgradeAdmin()' | sort)" ] \
  || fail "blast_presale_domain must declare exactly the reviewed ability-free roles."
if rg -n '^[^/]*AdminWitness<' "$sources" \
  | rg -v 'AdminWitness<(FeeAdmin|RewardsAdmin|TreasuryAdmin|UpgradeAdmin)>|use blast_admin::'; then
  fail "Every administrator witness must name one concrete blast_presale role."
fi

# 2. Upgrade custody stays sealed and dependency-only, so every generation runs identical logic.
admin_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$sources/package_admin.move")"
wrap_body="$(sed -n '/^public fun wrap(/,/^}/p' <<<"$admin_production")"
rg -q 'custody\.restrict_to_dependency_only\(custodian_id\);' <<<"$wrap_body" \
  || fail "wrap must narrow the sealed cap to dependency-only upgrades before sharing it."
if rg -n '\bmake_immutable\b|\brestrict_to_additive\b' "$sources"; then
  fail "Presale custody must stay relinkable and dependency-only."
fi
if rg -U -n '^public fun [^(]+\([^)]*\): (&)?(Publisher|UpgradeCap)' <<<"$admin_production"; then
  fail "No custody path may release the sealed Publisher or UpgradeCap."
fi
if rg -n 'transfer::(public_)?transfer\(' <<<"$admin_production"; then
  fail "The framework UpgradeCap must never leave sealed custody."
fi
[ "$(rg -c '^    _: &AdminWitness<UpgradeAdmin>,$' <<<"$admin_production")" -eq 2 ] \
  || fail "Authorizing and committing an upgrade must each require the upgrade-admin role."

printf 'blast_presale source boundaries hold.\n'
