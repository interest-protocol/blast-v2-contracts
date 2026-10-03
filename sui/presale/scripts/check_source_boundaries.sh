#!/usr/bin/env bash
# Structural gates for blast_presale administration and upgrade custody (ADR 0099).
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

# 1. Package-local two-tier administration: a key-only SuperAdminCap that only replaces or revokes
#    the one AdminCap the shared AdminRegistry accepts. No shared ACL or role types.
if rg -n 'blast_admin|AdminWitness' "$package_dir/Move.toml" "$sources"; then
  fail "Presale administration must not depend on the shared Blast ACL."
fi
admin_source="$sources/blast_presale_admin.move"
admin_module="$(production "$admin_source")"
[ "$(rg '^public struct ' "$admin_source" | rg -v 'has copy, drop \{$' | sort)" == "$(printf '%s\n' \
  'public struct AdminCap has key, store {' \
  'public struct AdminRegistry has key {' \
  'public struct SuperAdminCap has key {' | sort)" ] \
  || fail "blast_presale_admin must declare exactly the reviewed caps and registry."
mints() {
  for file in "$sources"/*.move; do
    production "$file" | rg -c "$1" | sed "s|^|$(basename "$file"):|" || true
  done
}
[ "$(mints '\bSuperAdminCap \{ id')" == "blast_presale_admin.move:1" ] \
  && sed -n '/^fun init(/,/^}/p' <<<"$admin_module" | rg -q 'SuperAdminCap \{ id' \
  || fail "Only init may mint the SuperAdminCap."
[ "$(mints '\bAdminCap \{ id')" == "blast_presale_admin.move:2" ] \
  && sed -n '/^fun init(/,/^}/p' <<<"$admin_module" | rg -q '\bAdminCap \{ id' \
  && sed -n '/^public fun replace_admin_cap(/,/^}/p' <<<"$admin_module" | rg -q '\bAdminCap \{ id' \
  || fail "Only init and replace_admin_cap may mint an AdminCap."
for function in replace_admin_cap revoke_admin_cap; do
  sed -n "/^public fun $function(/,/^}/p" <<<"$admin_module" | rg -q '_: &SuperAdminCap[,)]' \
    || fail "$function must require the SuperAdminCap."
done
if rg -n 'SuperAdminCap' "$sources" | rg -v '^[^:]*blast_presale_admin\.move:'; then
  fail "The SuperAdminCap must have no power outside blast_presale_admin."
fi
# Every function of any visibility whose parameters name AdminCap, under any binding, must check
# it against the AdminRegistry as its first statement, before it reads or changes anything.
for file in "$sources"/*.move; do
  production "$file" | awk -v file="$(basename "$file")" '
    function parameters(signature,    i, depth, start) {
      sub(/^public\(package\) /, "", signature)
      start = index(signature, "(")
      for (i = start; i <= length(signature); i++) {
        if (substr(signature, i, 1) == "(") depth++
        if (substr(signature, i, 1) == ")" && --depth == 0) return substr(signature, start, i - start + 1)
      }
      return signature
    }
    /^(public(\(package\))? )?(entry )?(macro )?fun / { inside = 1; in_signature = 1; signature = ""; first = "" }
    inside && in_signature { signature = signature $0 "\n"; if ($0 ~ /\{$/) in_signature = 0; next }
    inside && first == "" && $0 !~ /^[[:space:]]*$/ { first = $0 }
    inside && /^}/ {
      inside = 0
      takes = parameters(signature)
      if (takes !~ /(^|[^A-Za-z0-9_])AdminCap([^A-Za-z0-9_]|$)/) next
      if (file == "blast_presale_admin.move" && signature ~ /fun assert_admin_cap\(/) next
      if (takes !~ /admin_registry: &AdminRegistry[,)]/ || takes !~ /admin_cap: &AdminCap[,)]/ \
        || first !~ /^    admin_registry\.assert_admin_cap\(admin_cap\);$/) {
        sub(/^public\(package\)/, "package", signature)
        print file ": " substr(signature, 1, index(signature, "(") - 1)
        unchecked = 1
      }
    }
    END { exit unchecked }
  ' || fail "Every function taking an AdminCap must first check it against the AdminRegistry."
done

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
[ "$(rg -c '^    admin_cap: &AdminCap,$' <<<"$admin_production")" -eq 2 ] \
  || fail "Authorizing and committing an upgrade must each require the AdminCap."

printf 'blast_presale source boundaries hold.\n'
