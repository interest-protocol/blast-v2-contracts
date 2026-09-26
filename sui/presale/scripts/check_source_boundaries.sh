#!/usr/bin/env bash
# Presale source boundaries (ADR 0094, ADR 0096): every administrator action asserts exactly its
# one role, and no other production function takes an administrator witness.
set -euo pipefail

cd "$(dirname "$0")/.."

failures=0

# Prints `module:function` for every production function whose signature takes an AdminWitness.
witness_functions() {
  awk '
    FNR == 1 { module = FILENAME; sub(/.*\//, "", module); sub(/\.move$/, "", module); test_only = 0 }
    /^#\[test_only\]/ { test_only = 1; next }
    /^(public(\(package\))? )?fun / {
      signature = ""; name = $0
      sub(/^(public(\(package\))? )?fun /, "", name); sub(/[<(].*/, "", name)
      collecting = !test_only; test_only = 0
    }
    collecting { signature = signature $0 }
    collecting && /\{$/ {
      if (signature ~ /AdminWitness</) print module ":" name
      collecting = 0
    }
  ' sources/*.move sources/lib/*.move | LC_ALL=C sort | tr '\n' ' '
}

# Prints every role a function's body asserts.
asserted_roles() {
  awk -v name="$2" '
    $0 ~ "^(public(\\(package\\))? )?fun " name "[<(]" { collecting = 1 }
    collecting { print }
    collecting && /^}/ { exit }
  ' "sources/$1.move" | grep -o 'assert_role(blast_presale_domain::[a-z_]*()' | tr '\n' ' ' || true
}

expected_map=(
  'package_admin:authorize_upgrade:package_admin_role'
  'package_admin:commit_upgrade_and_advance:package_admin_role'
  'package_admin:make_immutable:package_admin_role'
  'presale_config:set_fee_bps:fee_admin_role'
  'presale_config:set_fee_destination:treasury_admin_role'
)

expected_functions="$(printf '%s\n' "${expected_map[@]}" | cut -d: -f1,2 | LC_ALL=C sort | tr '\n' ' ')"
if [[ "$(witness_functions)" != "$expected_functions" ]]; then
  echo "Administrator actions are '$(witness_functions)', expected '${expected_functions}'." >&2
  failures=$((failures + 1))
fi

for entry in "${expected_map[@]}"; do
  IFS=: read -r module function role <<<"$entry"
  actual="$(asserted_roles "$module" "$function")"
  if [[ "$actual" != "assert_role(blast_presale_domain::${role}() " ]]; then
    echo "${module}::${function} must assert exactly ${role}; it asserts '${actual}'." >&2
    failures=$((failures + 1))
  fi
done

if ((failures != 0)); then
  exit 1
fi

echo 'Presale source boundaries: OK'
